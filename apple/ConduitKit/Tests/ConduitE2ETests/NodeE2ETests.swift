import Foundation
import CryptoKit
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Collects a node's event stream and lets tests await specific events.
actor EventHub {
    private var buffer: [ConduitEvent] = []
    private var waiters: [(check: @Sendable (ConduitEvent) -> Bool, continuation: CheckedContinuation<ConduitEvent, Never>)] = []
    private var pump: Task<Void, Never>?

    func attach(to node: ConduitNode) {
        pump = Task {
            for await event in node.events {
                self.push(event)
            }
        }
    }

    private func push(_ event: ConduitEvent) {
        buffer.append(event)
        waiters.removeAll { waiter in
            if waiter.check(event) {
                waiter.continuation.resume(returning: event)
                return true
            }
            return false
        }
    }

    func stop() {
        pump?.cancel()
    }

    func allEvents() -> [ConduitEvent] {
        buffer
    }

    /// Awaits the first event (past or future) matching `check`.
    func waitFor(
        timeoutSeconds: Double = 30,
        _ check: @escaping @Sendable (ConduitEvent) -> Bool
    ) async throws -> ConduitEvent {
        if let existing = buffer.first(where: check) {
            return existing
        }
        return try await withTimeout(seconds: timeoutSeconds) {
            await withCheckedContinuation { continuation in
                Task { await self.enqueue(check: check, continuation: continuation) }
            }
        }
    }

    /// Current number of buffered events; pass to `waitFor(since:)` to ignore
    /// already-seen events (needed when the same event type recurs, e.g. a
    /// second pairing whose prompt must not match the first's stale one).
    func mark() -> Int { buffer.count }

    func waitFor(
        since index: Int,
        timeoutSeconds: Double = 30,
        _ check: @escaping @Sendable (ConduitEvent) -> Bool
    ) async throws -> ConduitEvent {
        if let existing = buffer.dropFirst(index).first(where: check) {
            return existing
        }
        // Register a waiter that re-scans only buffer[index...], so it can never
        // match a stale earlier event of the same type but also cannot miss one
        // that landed while this waiter was being scheduled.
        return try await withTimeout(seconds: timeoutSeconds) {
            await withCheckedContinuation { continuation in
                Task { await self.enqueueFutureOnly(since: index, check: check, continuation: continuation) }
            }
        }
    }

    private func enqueueFutureOnly(
        since index: Int,
        check: @escaping @Sendable (ConduitEvent) -> Bool,
        continuation: CheckedContinuation<ConduitEvent, Never>
    ) {
        // Re-check from `index` before parking.
        //
        // `waitFor(since:)` scans the buffer, then registers the waiter from
        // inside a *nested* Task — so any event arriving in the gap between
        // those two steps was appended to the buffer with no waiter present,
        // and then never seen by the waiter that arrived a moment later. The
        // wait then hung for its whole timeout. The window is invisible on an
        // idle machine and wide open under full-suite load, which is exactly
        // when it bit: the first test of a suite, where the event being awaited
        // is produced by the very call that precedes the wait.
        //
        // Re-scanning here closes it: this runs on the actor, so it cannot
        // interleave with `push`.
        if let existing = buffer.dropFirst(index).first(where: check) {
            continuation.resume(returning: existing)
            return
        }
        waiters.append((check, continuation))
    }

    private func enqueue(
        check: @escaping @Sendable (ConduitEvent) -> Bool,
        continuation: CheckedContinuation<ConduitEvent, Never>
    ) {
        if let existing = buffer.first(where: check) {
            continuation.resume(returning: existing)
            return
        }
        waiters.append((check, continuation))
    }
}

struct TestNode {
    let node: ConduitNode
    let hub: EventHub
    let root: URL
    let deviceID: String
    let port: UInt16

    static func launch(name: String, deviceClass: DeviceClass) async throws -> TestNode {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-e2e-\(UUID().uuidString)")
        let config = NodeConfiguration(
            deviceName: name,
            deviceClass: deviceClass,
            appVersion: "e2e",
            receiveDirectory: root.appendingPathComponent("received"),
            stateDirectory: root.appendingPathComponent("state")
        )
        let store = FileIdentityStore(fileURL: root.appendingPathComponent("identity.json"))
        let node = try ConduitNode(config: config, identityStore: store)
        let hub = EventHub()
        await hub.attach(to: node)
        try await node.start()
        let deviceID = await node.localDeviceID
        let port = try #require(await node.localListenPort)
        return TestNode(node: node, hub: hub, root: root, deviceID: deviceID, port: port)
    }

    func cleanup() async {
        await node.stop()
        await hub.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private func writeRandomFile(at url: URL, megabytes: Int) throws -> String {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    for _ in 0..<megabytes {
        let chunk = Data((0..<(1024 * 1024)).map { _ in UInt8.random(in: .min ... .max) })
        try handle.write(contentsOf: chunk)
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).hexString
}

private func autoConfirmPairing(_ testNode: TestNode) -> Task<String?, Never> {
    Task {
        guard case .pairingPrompt(let prompt) = try? await testNode.hub.waitFor({
            if case .pairingPrompt = $0 { return true }
            return false
        }) else { return nil }
        await testNode.node.resolvePairingPrompt(flowID: prompt.flowID, accept: true)
        return "\(prompt.code)|\(prompt.wordA)-\(prompt.wordB)"
    }
}

@Suite(.serialized) struct NodeE2ETests {
    /// The Phase 1 acceptance path end-to-end over real TLS on loopback:
    /// pair with code confirmation → session → clipboard both ways → 12 MiB
    /// file over the bulk lane with hash verification → resume from a partial.
    @Test(.timeLimit(.minutes(3))) func pairThenTransferThenResume() async throws {
        let mac = try await TestNode.launch(name: "Studio Mac", deviceClass: .desktop)
        let phone = try await TestNode.launch(name: "Leroy iPhone", deviceClass: .phone)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        // --- Pair (initiator: mac → phone), auto-confirming on both screens ---
        await phone.node.setPairingAcceptance(true)
        let macConfirm = autoConfirmPairing(mac)
        let phoneConfirm = autoConfirmPairing(phone)
        await mac.node.beginPairing(host: "127.0.0.1", port: phone.port)

        _ = try await mac.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        let macShown = await macConfirm.value
        let phoneShown = await phoneConfirm.value
        #expect(macShown != nil && macShown == phoneShown, "both screens must show the same code and words")
        await phone.node.setPairingAcceptance(false)

        let macPeers = await mac.node.pinnedPeers()
        let phonePeers = await phone.node.pinnedPeers()
        #expect(macPeers.map(\.deviceID) == [phone.deviceID])
        #expect(phonePeers.map(\.deviceID) == [mac.deviceID])

        // --- Connect and reach ready on both sides ---
        await mac.node.connect(toDevice: phone.deviceID, host: "127.0.0.1", port: phone.port)
        _ = try await mac.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == phone.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }

        // --- Clipboard, both directions ---
        await mac.node.sendClipboard(.text("hello from the mac"), to: phone.deviceID)
        let clip1 = try await phone.hub.waitFor { if case .clipboardReceived = $0 { return true }; return false }
        if case .clipboardReceived(let from, let body) = clip1 {
            #expect(from == mac.deviceID)
            #expect(body.textValue == "hello from the mac")
        }
        await phone.node.sendClipboard(.text("hello from the phone"), to: mac.deviceID)
        let clip2 = try await mac.hub.waitFor { if case .clipboardReceived = $0 { return true }; return false }
        if case .clipboardReceived(_, let body) = clip2 {
            #expect(body.textValue == "hello from the phone")
        }

        // --- File transfer with offer/accept UX and hash verification ---
        let fileURL = mac.root.appendingPathComponent("dataset.bin")
        let sourceHash = try writeRandomFile(at: fileURL, megabytes: 12)
        await mac.node.sendFile(url: fileURL, to: phone.deviceID)

        let offerEvent = try await phone.hub.waitFor { if case .incomingFileOffer = $0 { return true }; return false }
        guard case .incomingFileOffer(let fromID, let offer) = offerEvent else { return }
        #expect(fromID == mac.deviceID)
        #expect(offer.name == "dataset.bin")
        #expect(offer.sha256 == sourceHash)
        await phone.node.respondToFileOffer(fileID: offer.fileID, accept: true)

        let completed = try await phone.hub.waitFor {
            if case .transferCompleted(let id, _) = $0 { return id == offer.fileID }
            return false
        }
        guard case .transferCompleted(_, let savedTo) = completed else { return }
        let savedURL = try #require(savedTo)
        let (savedHash, savedSize) = try FileSendEngine.sha256AndSize(of: savedURL)
        #expect(savedHash == sourceHash)
        #expect(savedSize == 12 * 1024 * 1024)

        // Sender saw completion too, and the bulk lane carried the payload.
        _ = try await mac.hub.waitFor {
            if case .transferCompleted(let id, _) = $0 { return id == offer.fileID }
            return false
        }
        let usedBulk = await phone.hub.allEvents().contains {
            if case .transferUpdated(let snapshot) = $0 { return snapshot.lane == "bulk" }
            return false
        }
        #expect(usedBulk, "chunks should ride the dedicated bulk connection")

        // --- Resume: a partial from an interrupted transfer completes without re-prompting ---
        let file2 = mac.root.appendingPathComponent("resume-me.bin")
        let file2Hash = try writeRandomFile(at: file2, megabytes: 8)
        let (_, file2Size) = try FileSendEngine.sha256AndSize(of: file2)
        let chunkSize = ProtocolConstants.defaultChunkSize
        let seededChunks: UInt64 = 6 // 3 MiB already "received" before the blip

        let partials = phone.root.appendingPathComponent("state/partials")
        try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
        let sourceHandle = try FileHandle(forReadingFrom: file2)
        let seedData = try #require(try sourceHandle.read(upToCount: Int(seededChunks) * Int(chunkSize)))
        try? sourceHandle.close()
        try seedData.write(to: partials.appendingPathComponent("\(file2Hash).part"))
        let meta: [String: Any] = [
            "sha256": file2Hash, "size": file2Size, "chunkSize": chunkSize,
            "receivedChunks": seededChunks, "accepted": true, "name": "resume-me.bin",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: partials.appendingPathComponent("\(file2Hash).json"))

        await mac.node.sendFile(url: file2, to: phone.deviceID)
        let resumed = try await phone.hub.waitFor {
            if case .transferCompleted(let id, let url) = $0 { return id != offer.fileID && url != nil }
            return false
        }
        guard case .transferCompleted(_, let resumedURL) = resumed else { return }
        let (resumedHash, resumedSize) = try FileSendEngine.sha256AndSize(of: try #require(resumedURL))
        #expect(resumedHash == file2Hash, "resumed file must hash-verify end to end")
        #expect(resumedSize == file2Size)

        // The user was never re-prompted: exactly one incomingFileOffer in the whole test.
        let offerPrompts = await phone.hub.allEvents().filter {
            if case .incomingFileOffer = $0 { return true }
            return false
        }
        #expect(offerPrompts.count == 1, "auto-resume must not re-prompt for an already-accepted file")
    }

    /// A declined offer reaches the sender as a failure, not a hang.
    @Test(.timeLimit(.minutes(2))) func declinedOfferFailsCleanly() async throws {
        let mac = try await TestNode.launch(name: "Mac2", deviceClass: .desktop)
        let phone = try await TestNode.launch(name: "Phone2", deviceClass: .phone)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        await phone.node.setPairingAcceptance(true)
        let confirmA = autoConfirmPairing(mac)
        let confirmB = autoConfirmPairing(phone)
        await mac.node.beginPairing(host: "127.0.0.1", port: phone.port)
        _ = try await mac.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await confirmA.value
        _ = await confirmB.value

        await mac.node.connect(toDevice: phone.deviceID, host: "127.0.0.1", port: phone.port)
        _ = try await mac.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == phone.deviceID }
            return false
        }

        let fileURL = mac.root.appendingPathComponent("unwanted.bin")
        _ = try writeRandomFile(at: fileURL, megabytes: 1)
        await mac.node.sendFile(url: fileURL, to: phone.deviceID)
        let offerEvent = try await phone.hub.waitFor { if case .incomingFileOffer = $0 { return true }; return false }
        guard case .incomingFileOffer(_, let offer) = offerEvent else { return }
        await phone.node.respondToFileOffer(fileID: offer.fileID, accept: false)

        let failed = try await mac.hub.waitFor {
            if case .transferFailed(let id, _) = $0 { return id == offer.fileID }
            return false
        }
        if case .transferFailed(_, let reason) = failed {
            #expect(reason.contains("declined"))
        }
    }
}

import Foundation
import CryptoKit
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Cross-implementation interop (spec §9 Phase 4 acceptance): a real Go
/// `conduit-core` node pairs with the Swift node over loopback TLS and receives
/// a file, proving the two independent implementations speak the same protocol.
/// This is the phase's headline claim made executable.
///
/// The test builds and drives the Go `interop` binary in core/cmd/interop. If
/// Go isn't installed it skips (CI installs Go so the conformance invariant
/// still holds).

/// Reads a subprocess's stdout line by line and lets tests await lines.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var waiters: [(check: (String) -> Bool, cont: CheckedContinuation<String, Never>)] = []

    func attach(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            lines.append(line)
            waiters.removeAll { w in
                if w.check(line) { w.cont.resume(returning: line); return true }
                return false
            }
        }
        lock.unlock()
    }

    func waitFor(timeout: Double = 30, _ check: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await withTimeout(seconds: timeout) {
            await withCheckedContinuation { cont in
                self.register(check: check, cont: cont)
            }
        }
    }

    private func register(check: @escaping (String) -> Bool, cont: CheckedContinuation<String, Never>) {
        lock.lock()
        if let existing = lines.first(where: check) {
            lock.unlock()
            cont.resume(returning: existing)
            return
        }
        waiters.append((check, cont))
        lock.unlock()
    }
}

enum GoToolchain {
    static var goPath: String? {
        for candidate in ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var coreDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConduitE2ETests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ConduitKit
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // conduit
            .appendingPathComponent("core")
    }

    /// Builds the interop binary; returns its path, or nil to skip.
    static func buildInterop() throws -> String? {
        guard let go = goPath else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-interop-\(UUID().uuidString)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: go)
        proc.arguments = ["build", "-o", out.path, "./cmd/interop"]
        proc.currentDirectoryURL = coreDir
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["HOME": NSHomeDirectory()], uniquingKeysWith: { a, _ in a })
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "interop", code: 1, userInfo: [NSLocalizedDescriptionKey: "go build failed: \(msg)"])
        }
        return out.path
    }
}

@Suite(.serialized) struct GoInteropTests {
    /// Swift pairs with a Go node and sends it a file; Go verifies the SHA-256.
    @Test(.timeLimit(.minutes(3))) func swiftPairsAndSendsFileToGo() async throws {
        guard let interopBin = try GoToolchain.buildInterop() else {
            // Go toolchain absent: skip (the CI conformance job requires it).
            print("SKIP: Go toolchain not found")
            return
        }

        let goState = FileManager.default.temporaryDirectory.appendingPathComponent("go-\(UUID().uuidString)")
        let goRecv = goState.appendingPathComponent("recv")
        try FileManager.default.createDirectory(at: goRecv, withIntermediateDirectories: true)

        // Launch the Go node: listen + accept pairing.
        let go = Process()
        go.executableURL = URL(fileURLWithPath: interopBin)
        go.arguments = ["listen", "--state", goState.path, "--receive", goRecv.path, "--pair"]
        let goOut = Pipe(), goIn = Pipe()
        go.standardOutput = goOut
        go.standardInput = goIn
        let reader = LineReader()
        reader.attach(goOut.fileHandleForReading)
        try go.run()
        defer {
            goIn.fileHandleForWriting.closeFile() // ends the Go process
            go.terminationHandler = nil
        }

        // Parse "LISTEN <port> <deviceID> <tlsHex>".
        let listenLine = try await reader.waitFor { $0.hasPrefix("LISTEN ") }
        let parts = listenLine.split(separator: " ")
        let goPort = try #require(UInt16(parts[1]))
        let goDeviceID = String(parts[2])

        // Launch the Swift node and pair with Go (Swift initiates).
        let swift = try await TestNode.launch(name: "Swift Mac", deviceClass: .desktop)
        defer { Task { await swift.cleanup() } }

        let confirm = Task { await autoConfirm(swift) }
        await swift.node.beginPairing(host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await confirm.value
        // Go announces it pinned the Swift device.
        _ = try await reader.waitFor { $0.hasPrefix("PAIRED ") }

        // Connect Swift → Go and send a file.
        await swift.node.connect(toDevice: goDeviceID, host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == goDeviceID }
            return false
        }

        let fileURL = swift.root.appendingPathComponent("interop-payload.bin")
        let payload = Data((0..<(2 * 1024 * 1024)).map { _ in UInt8.random(in: .min ... .max) })
        try payload.write(to: fileURL)
        let expectedSHA = Data(SHA256.hash(data: payload)).hexString

        await swift.node.sendFile(url: fileURL, to: goDeviceID)

        // Go prints "RECEIVED <name> <size> <sha>" after verifying the hash.
        let receivedLine = try await reader.waitFor(timeout: 60) { $0.hasPrefix("RECEIVED ") }
        let rparts = receivedLine.split(separator: " ")
        #expect(String(rparts[1]) == "interop-payload.bin")
        #expect(UInt64(rparts[2]) == UInt64(payload.count))
        #expect(String(rparts[3]) == expectedSHA, "Go must reconstruct the exact bytes Swift sent")

        // The Swift sender also saw completion.
        _ = try await swift.hub.waitFor { if case .transferCompleted = $0 { return true }; return false }

        // And the file physically landed in Go's receive dir with the right bytes.
        let landed = goRecv.appendingPathComponent("interop-payload.bin")
        let landedData = try Data(contentsOf: landed)
        #expect(Data(SHA256.hash(data: landedData)).hexString == expectedSHA)
    }

    /// Swift sends clipboard text to Go over the live session.
    @Test(.timeLimit(.minutes(3))) func swiftSendsClipboardToGo() async throws {
        guard let interopBin = try GoToolchain.buildInterop() else {
            print("SKIP: Go toolchain not found")
            return
        }
        let goState = FileManager.default.temporaryDirectory.appendingPathComponent("go-\(UUID().uuidString)")
        let go = Process()
        go.executableURL = URL(fileURLWithPath: interopBin)
        go.arguments = ["listen", "--state", goState.path, "--receive", goState.appendingPathComponent("recv").path, "--pair"]
        let goOut = Pipe(), goIn = Pipe()
        go.standardOutput = goOut
        go.standardInput = goIn
        let reader = LineReader()
        reader.attach(goOut.fileHandleForReading)
        try go.run()
        defer { goIn.fileHandleForWriting.closeFile() }

        let listenLine = try await reader.waitFor { $0.hasPrefix("LISTEN ") }
        let parts = listenLine.split(separator: " ")
        let goPort = try #require(UInt16(parts[1]))
        let goDeviceID = String(parts[2])

        let swift = try await TestNode.launch(name: "Swift Mac", deviceClass: .desktop)
        defer { Task { await swift.cleanup() } }
        let confirm = Task { await autoConfirm(swift) }
        await swift.node.beginPairing(host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await confirm.value

        await swift.node.connect(toDevice: goDeviceID, host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == goDeviceID }
            return false
        }

        await swift.node.sendClipboard(.text("interop clipboard ✓"), to: goDeviceID)
        let clipLine = try await reader.waitFor { $0.hasPrefix("CLIPBOARD ") }
        #expect(clipLine == "CLIPBOARD interop clipboard ✓")
    }

    /// A Go node sources a notification and the Swift node receives it for
    /// display (spec §9 Phase 4 step 5, in the direction Apple platforms allow).
    @Test(.timeLimit(.minutes(3))) func goMirrorsNotificationToSwift() async throws {
        guard let interopBin = try GoToolchain.buildInterop() else {
            print("SKIP: Go toolchain not found")
            return
        }
        let goState = FileManager.default.temporaryDirectory.appendingPathComponent("go-\(UUID().uuidString)")
        let go = Process()
        go.executableURL = URL(fileURLWithPath: interopBin)
        go.arguments = ["listen", "--state", goState.path,
                        "--receive", goState.appendingPathComponent("recv").path, "--pair", "--notify"]
        let goOut = Pipe(), goIn = Pipe()
        go.standardOutput = goOut
        go.standardInput = goIn
        let reader = LineReader()
        reader.attach(goOut.fileHandleForReading)
        try go.run()
        defer { goIn.fileHandleForWriting.closeFile() }

        let listenLine = try await reader.waitFor { $0.hasPrefix("LISTEN ") }
        let parts = listenLine.split(separator: " ")
        let goPort = try #require(UInt16(parts[1]))
        let goDeviceID = String(parts[2])

        let swift = try await TestNode.launch(name: "Swift Mac", deviceClass: .desktop)
        defer { Task { await swift.cleanup() } }
        let confirm = Task { await autoConfirm(swift) }
        await swift.node.beginPairing(host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await confirm.value

        await swift.node.connect(toDevice: goDeviceID, host: "127.0.0.1", port: goPort)
        _ = try await swift.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == goDeviceID }
            return false
        }

        // Go sends NOTIFICATION on session ready; Swift surfaces it.
        let event = try await swift.hub.waitFor {
            if case .notificationReceived = $0 { return true }; return false
        }
        guard case .notificationReceived(let from, let body) = event else { return }
        #expect(from == goDeviceID)
        #expect(body.appName == "Mail")
        #expect(body.title == "New message")
        #expect(body.body == "from the Go daemon")
    }
}

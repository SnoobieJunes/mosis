import Foundation
import CoreMedia
import CoreVideo
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Probes whether this environment can perform an `NSFileProtectionComplete`
/// (class A) atomic write — i.e. the keybag is unlocked. Returns false on a
/// locked developer Mac, where such writes fail with EPERM, so the broadcast
/// suite skips rather than failing red for an environmental reason. See the
/// note on `BroadcastE2ETests`.
func broadcastKeybagIsUnlocked() -> Bool {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mosis-keybag-probe-\(UUID().uuidString)")
    guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
    else { return false }
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try Data("probe".utf8).write(to: dir.appendingPathComponent("p"),
                                     options: [.atomic, .completeFileProtection])
        return true
    } catch {
        return false
    }
}

/// The iPhone→viewer broadcast path (spec §9 Phase 3 step 4) exercised
/// same-process over real TLS sockets: `prepareIOSScreenBroadcast` writes the
/// shared config (App Group stood in by a temp directory), and a real
/// `BroadcastStreamer` — the exact code the ReplayKit extension runs — dials
/// the viewer's listener and streams frames.
///
/// These tests exist because every failure here shipped as "the phone just
/// keeps recording": the streamer never noticed a rejected attach, never died
/// with its viewer, and the viewer killed live broadcasts when the phone app's
/// control link dropped (the extension's lane is a different process!).
///
/// Environmental gate: the broadcast config carries the node's TLS **private
/// key**, so `BroadcastSharedStore.write` uses `NSFileProtectionComplete`. That
/// data-protection class is only writable while the device's keybag is unlocked.
/// On a headless/unlocked CI runner that is always true, so the suite runs; on a
/// developer Mac whose screen has auto-locked, a class-A write fails with EPERM
/// and these tests would go red for a reason that has nothing to do with the
/// code under test. The gate makes that an honest SKIP with a reason, exactly
/// like `RealNetworkE2ETests` skips without a LAN IP. Unlock the screen to run
/// them. The protection class is a deliberate security choice and is not
/// weakened to make the test convenient.
@Suite(.serialized, .enabled(if: broadcastKeybagIsUnlocked(),
                             "requires an unlocked keybag for NSFileProtectionComplete writes — unlock the screen"))
struct BroadcastE2ETests {

    /// Launches a phone-role node whose broadcast store points at its temp root.
    private static func launchPhone() async throws -> TestNode {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-bcast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        BroadcastSharedStore.containerOverride.set(root)
        let config = NodeConfiguration(
            deviceName: "iPhone", deviceClass: .phone, appVersion: "e2e",
            receiveDirectory: root.appendingPathComponent("received"),
            stateDirectory: root.appendingPathComponent("state"),
            appGroupID: "group.test.broadcast"
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

    /// Pair + connect phone → viewer, and return the announced broadcast config.
    private static func announceBroadcast(
        phone: TestNode, viewer: TestNode
    ) async throws -> BroadcastConfig {
        await viewer.node.setPairingAcceptance(true)
        let cv = Task { await autoConfirm(viewer) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: viewer.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cv.value; _ = await cp.value
        await viewer.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: viewer.deviceID, host: "127.0.0.1", port: viewer.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == viewer.deviceID }
            return false
        }
        // Wait for HELLO capabilities, not just for the session to go .ready.
        // `prepareIOSScreenBroadcast` gates on `remoteAdvertises(screenView)`,
        // which is only populated once the peer's HELLO has been processed —
        // a strictly later event than .ready. Without this the test raced the
        // handshake and failed with a bare "config → nil", blaming the broadcast
        // path for what was really the test starting too early.
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == viewer.deviceID }
            return false
        }

        let config = await phone.node.prepareIOSScreenBroadcast(
            to: viewer.deviceID, width: 320, height: 240, fps: 30
        )
        return try #require(config, "broadcast config must be prepared")
    }

    /// Feeds synthetic frames to the streamer at ~30 fps until cancelled.
    private static func feedFrames(_ streamer: BroadcastStreamer, width: Int, height: Int) -> Task<Void, Never> {
        Task {
            var tick = 0
            while !Task.isCancelled {
                if let pb = FakeScreenCapturer.makePixelBuffer(width: width, height: height, tick: tick) {
                    streamer.handleSampleBuffer(pb, pts: CMTime(value: CMTimeValue(tick), timescale: 30))
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Happy path + the app-suspension regression: frames reach the viewer's
    /// render target, and KEEP reaching it after the phone's control link drops
    /// — the broadcast lane belongs to the extension process, not the app.
    @Test(.timeLimit(.minutes(3))) func broadcastStreamsAndSurvivesControlDrop() async throws {
        let phone = try await Self.launchPhone()
        let viewer = try await TestNode.launch(name: "Mac", deviceClass: .desktop)
        defer { Task { await phone.cleanup(); await viewer.cleanup() } }

        let config = try await Self.announceBroadcast(phone: phone, viewer: viewer)
        #expect(config.viewerName == "Mac")
        #expect(BroadcastSharedStore.read(appGroupID: "group.test.broadcast") != nil)

        // The unsolicited offer opened a (pending) viewer session.
        let started = try await viewer.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(let fromID, let offer, let render) = started else { return }
        #expect(fromID == phone.deviceID)
        #expect(offer.sourceName == "iPhone")

        let status = Locked<[BroadcastStatus.Phase]>([])
        let streamer = BroadcastStreamer(
            config: config,
            onStatus: { phase, _, _ in status.withValue { $0.append(phase) } }
        )
        try await streamer.start()
        let feeder = Self.feedFrames(streamer, width: config.width, height: config.height)
        defer { feeder.cancel() }

        try await pollUntil(timeout: 25) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5, "decoded broadcast frames must reach the render target")
        #expect(status.get().contains(.streaming))

        // The regression: the phone app "suspends" — its control link dies.
        // The attached broadcast must keep streaming.
        await phone.node.disconnect(deviceID: viewer.deviceID)
        _ = try await viewer.hub.waitFor {
            if case .sessionStateChanged(let id, .closed, _) = $0 { return id == phone.deviceID }
            return false
        }
        let countAtDrop = render.enqueuedCount
        try await pollUntil(timeout: 25) { render.enqueuedCount >= countAtDrop + 5 }
        #expect(render.enqueuedCount >= countAtDrop + 5,
                "an attached broadcast must survive the phone app's control link dropping")

        feeder.cancel()
        await streamer.finish()
    }

    /// A viewer that already gave up (watchdog fired / user closed) silently
    /// closes the attach lane — the streamer must turn that into a thrown,
    /// named error so the extension ends instead of recording forever.
    @Test(.timeLimit(.minutes(3))) func rejectedAttachThrowsInsteadOfRecordingForever() async throws {
        let phone = try await Self.launchPhone()
        let viewer = try await TestNode.launch(name: "Mac", deviceClass: .desktop)
        defer { Task { await phone.cleanup(); await viewer.cleanup() } }

        let config = try await Self.announceBroadcast(phone: phone, viewer: viewer)
        let started = try await viewer.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, _) = started else { return }

        // Viewer stops waiting before the "extension" dials (the watchdog path).
        await viewer.node.stopViewingScreen(screenSessionID: offer.screenSessionID)
        _ = try await viewer.hub.waitFor {
            if case .screenViewerEnded = $0 { return true }; return false
        }

        let streamer = BroadcastStreamer(config: config)
        await #expect(throws: (any Error).self, "a rejected attach must throw, not stream into the void") {
            try await streamer.start()
        }
        await streamer.finish()
    }

    /// The viewer stopping mid-broadcast must end the broadcast (onEnded →
    /// finishBroadcastWithError in the extension), not leave it sending
    /// frames into a closed lane.
    @Test(.timeLimit(.minutes(3))) func viewerStoppingEndsTheBroadcast() async throws {
        let phone = try await Self.launchPhone()
        let viewer = try await TestNode.launch(name: "Mac", deviceClass: .desktop)
        defer { Task { await phone.cleanup(); await viewer.cleanup() } }

        let config = try await Self.announceBroadcast(phone: phone, viewer: viewer)
        let started = try await viewer.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else { return }

        let ended = Locked<(String, Bool)?>(nil)
        let streamer = BroadcastStreamer(
            config: config,
            onEnded: { reason, clean in ended.set((reason, clean)) }
        )
        try await streamer.start()
        let feeder = Self.feedFrames(streamer, width: config.width, height: config.height)
        defer { feeder.cancel() }
        try await pollUntil(timeout: 25) { render.enqueuedCount >= 3 }

        await viewer.node.stopViewingScreen(screenSessionID: offer.screenSessionID)

        try await pollUntil(timeout: 15) { ended.get() != nil }
        let result = try #require(ended.get())
        #expect(result.1, "a viewer that stops watching is a clean end: \(result.0)")

        feeder.cancel()
        await streamer.finish()
    }

    /// Cancelling a prepared-but-unstarted share must close the viewer's
    /// "Connecting…" session over the control link — not leave it to the
    /// watchdog.
    @Test(.timeLimit(.minutes(3))) func cancellingPendingShareClosesViewerPromptly() async throws {
        let phone = try await Self.launchPhone()
        let viewer = try await TestNode.launch(name: "Mac", deviceClass: .desktop)
        defer { Task { await phone.cleanup(); await viewer.cleanup() } }

        _ = try await Self.announceBroadcast(phone: phone, viewer: viewer)
        _ = try await viewer.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }

        await phone.node.endIOSScreenBroadcast()

        _ = try await viewer.hub.waitFor {
            if case .screenViewerEnded = $0 { return true }; return false
        }
        #expect(BroadcastSharedStore.read(appGroupID: "group.test.broadcast") == nil,
                "cancelling must clear the shared config")
    }
}

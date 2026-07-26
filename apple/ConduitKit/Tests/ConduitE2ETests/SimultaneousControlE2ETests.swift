import Foundation
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Watching a screen and driving it **at the same time** (plan 07, Track A).
///
/// Every screen test before this one streamed with no input; every input test
/// drove with no video. The transport was believed to interleave them fine and
/// the UI was believed to be the only gap — but "believed" is the word that put
/// three broken features under a green suite, so these run the two together and
/// assert both halves keep flowing.
@Suite(.serialized) struct SimultaneousControlE2ETests {
    /// One session, both capabilities: the tablet requests the Mac's screen AND
    /// control of it, then keeps sending pointer/click/key events while frames
    /// decode. Asserts video keeps arriving *after* input starts (a share the
    /// input traffic quietly killed would still have passed a frames-arrived
    /// check taken before the input began) and that input lands while video is
    /// running.
    @Test(.timeLimit(.minutes(4))) func screenAndInputRunTogetherInOneSession() async throws {
        let injector = FakeInjector()
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchControllable(
            name: "Mac", deviceClass: .desktop, injector: injector, capturer: capturer
        )
        let tablet = try await TestNode.launchControllable(
            name: "iPad", deviceClass: .tablet, injector: nil, capturer: nil
        )
        defer { Task { await mac.cleanup(); await tablet.cleanup() } }

        try await pairAndReady(controller: tablet, receiver: mac)

        // Both halves, together — the "Take control" action.
        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        let consent = Task {
            let event = try? await mac.hub.waitFor {
                if case .inputConsentRequested = $0 { return true }; return false
            }
            if case .inputConsentRequested(let peerID, _) = event {
                await mac.node.resolveInputConsent(peerDeviceID: peerID, accept: true)
            }
        }
        await tablet.node.requestScreen(from: mac.deviceID)
        await tablet.node.requestInputControl(of: mac.deviceID)
        _ = await pick.value
        _ = await consent.value

        let started = try await tablet.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else { return }
        _ = try await tablet.hub.waitFor { if case .inputControlStarted = $0 { return true }; return false }

        // Video is live before input starts.
        try await pollUntil(timeout: 30) { render.enqueuedCount >= 3 }
        let framesBeforeInput = render.enqueuedCount

        // Now drive it while it streams: motion, a click, a keystroke.
        for _ in 0..<20 {
            await tablet.node.sendPointerMove(dx: 5, dy: 3)
            try await Task.sleep(for: .milliseconds(10))
        }
        await tablet.node.sendClick(.left, action: .tap)
        await tablet.node.sendSpecialKey("return")

        try await pollUntil(timeout: 20) {
            injector.snapshot().contains { $0.kind == .move }
                && injector.snapshot().contains { $0.kind == .click }
                && injector.snapshot().contains { $0.kind == .key }
        }
        #expect(injector.snapshot().contains { $0.kind == .move }, "pointer motion must land while video streams")
        #expect(injector.snapshot().contains { $0.kind == .click })
        #expect(injector.snapshot().contains { $0.kind == .key })

        // …and the stream did not stop because input showed up. This is the
        // assertion that would catch a lane the input traffic tore down.
        try await pollUntil(timeout: 30) { render.enqueuedCount > framesBeforeInput + 5 }
        #expect(render.enqueuedCount > framesBeforeInput + 5,
                "video must keep flowing while input is being driven")

        // Both halves are still healthy at the end, on the same session.
        let sourcing = await mac.node.inputReceiveActivePeer()
        #expect(sourcing == tablet.deviceID)
        #expect(offer.width == 640)
    }

    /// The same thing on the DEGRADED path: the source cannot reverse-dial, so
    /// video shares the session link with the input events. This is the common
    /// real-device configuration (macOS Local Network prompt unanswered, AP
    /// client isolation) and the one where input can queue behind video.
    @Test(.timeLimit(.minutes(4))) func screenAndInputCoexistOnTheControlLaneFallback() async throws {
        let injector = FakeInjector()
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchControllable(
            name: "Mac", deviceClass: .desktop, injector: injector, capturer: capturer
        )
        let tablet = try await TestNode.launchControllable(
            name: "iPad", deviceClass: .tablet, injector: nil, capturer: nil
        )
        defer { Task { await mac.cleanup(); await tablet.cleanup() } }

        // The viewer advertises a listener nothing answers on, so the source's
        // dedicated-lane dial cannot land and frames fall back to the session.
        await tablet.node.simulateUnreachableListenerForTesting()
        try await pairAndReady(controller: tablet, receiver: mac)

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        let consent = Task {
            let event = try? await mac.hub.waitFor {
                if case .inputConsentRequested = $0 { return true }; return false
            }
            if case .inputConsentRequested(let peerID, _) = event {
                await mac.node.resolveInputConsent(peerDeviceID: peerID, accept: true)
            }
        }
        await tablet.node.requestScreen(from: mac.deviceID)
        await tablet.node.requestInputControl(of: mac.deviceID)
        _ = await pick.value
        _ = await consent.value

        let started = try await tablet.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }
        _ = try await tablet.hub.waitFor { if case .inputControlStarted = $0 { return true }; return false }

        // Confirm we really are on the degraded lane, not silently testing the
        // easy path — the mistake `RealNetworkE2ETests` shipped with.
        _ = try await tablet.hub.waitFor(timeoutSeconds: 40) {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.viewerLane == "control" }
            return false
        }

        try await pollUntil(timeout: 30) { render.enqueuedCount >= 3 }
        let framesBeforeInput = render.enqueuedCount

        // Hammer input while video shares the same TCP connection.
        for _ in 0..<40 {
            await tablet.node.sendPointerMove(dx: 4, dy: 2)
            try await Task.sleep(for: .milliseconds(5))
        }
        await tablet.node.sendClick(.left, action: .tap)

        try await pollUntil(timeout: 25) {
            injector.snapshot().contains { $0.kind == .click }
        }
        #expect(injector.snapshot().contains { $0.kind == .move },
                "input must land even when video shares its connection")
        #expect(injector.snapshot().contains { $0.kind == .click })
        try await pollUntil(timeout: 30) { render.enqueuedCount > framesBeforeInput + 3 }
        #expect(render.enqueuedCount > framesBeforeInput + 3,
                "video must survive a burst of input on the shared lane")
    }

    /// Click-where-you-point end to end (RC-7/RC-9): the viewer sends a
    /// normalized position; the receiver resolves the screen session to the
    /// captured display's bounds and injects there. Also pins the compatibility
    /// rule — an absolute move carries a delta too.
    @Test(.timeLimit(.minutes(4))) func absolutePointingLandsOnTheWatchedDisplay() async throws {
        let injector = FakeInjector()
        // Origin (1920, 0): a second display to the right of the main one. If
        // absolute coordinates were mapped against the desktop union or against
        // (0,0), the click would land on the wrong screen — the failure this
        // whole region mechanism exists to prevent.
        let capturer = FakeScreenCapturer(width: 800, height: 600, originX: 1920, originY: 0)
        let mac = try await TestNode.launchControllable(
            name: "Mac", deviceClass: .desktop, injector: injector, capturer: capturer
        )
        let tablet = try await TestNode.launchControllable(
            name: "iPad", deviceClass: .tablet, injector: nil, capturer: nil
        )
        defer { Task { await mac.cleanup(); await tablet.cleanup() } }

        try await pairAndReady(controller: tablet, receiver: mac)

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        let consent = Task {
            let event = try? await mac.hub.waitFor {
                if case .inputConsentRequested = $0 { return true }; return false
            }
            if case .inputConsentRequested(let peerID, _) = event {
                await mac.node.resolveInputConsent(peerDeviceID: peerID, accept: true)
            }
        }
        await tablet.node.requestScreen(from: mac.deviceID)
        await tablet.node.requestInputControl(of: mac.deviceID)
        _ = await pick.value
        _ = await consent.value

        let started = try await tablet.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, _) = started else { return }
        _ = try await tablet.hub.waitFor { if case .inputControlStarted = $0 { return true }; return false }

        await tablet.node.sendPointerMoveAbsolute(
            nx: 0.25, ny: 0.5, dx: 12, dy: -4, screenSessionID: offer.screenSessionID
        )

        try await pollUntil(timeout: 20) {
            injector.snapshot().contains { $0.kind == .move && $0.nx != nil }
        }
        let move = try #require(injector.snapshot().first { $0.kind == .move && $0.nx != nil })
        #expect(move.nx == 0.25)
        #expect(move.ny == 0.5)
        #expect(move.screenSessionID == offer.screenSessionID)
        // The delta rides along so a receiver that ignores nx/ny still tracks.
        #expect(move.dx == 12 && move.dy == -4)

        // The receiver resolved the session to the captured display's bounds,
        // not to the origin and not to the desktop union.
        try await pollUntil(timeout: 10) { injector.regionSnapshot() != nil }
        let region = try #require(injector.regionSnapshot())
        #expect(region == InjectionRegion(x: 1920, y: 0, width: 800, height: 600))
        let landed = region.point(nx: move.nx ?? 0, ny: move.ny ?? 0)
        #expect(landed.x == 1920 + 200, "a quarter across the SECOND display, not the first")
        #expect(landed.y == 300)
    }
}

// MARK: - Helpers

private extension TestNode {
    /// A node that can both be driven and share its screen — the combination no
    /// previous test harness could build, because `launchWithInjector` and
    /// `launchWithScreen` each hard-coded the other capability to nil.
    static func launchControllable(
        name: String, deviceClass: DeviceClass,
        injector: FakeInjector?, capturer: FakeScreenCapturer?
    ) async throws -> TestNode {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-simul-\(UUID().uuidString)")
        let config = NodeConfiguration(
            deviceName: name, deviceClass: deviceClass, appVersion: "e2e",
            receiveDirectory: root.appendingPathComponent("received"),
            stateDirectory: root.appendingPathComponent("state")
        )
        let store = FileIdentityStore(fileURL: root.appendingPathComponent("identity.json"))
        let node = try ConduitNode(
            config: config, identityStore: store,
            inputInjector: injector, screenCapturer: capturer
        )
        let hub = EventHub()
        await hub.attach(to: node)
        try await node.start()
        let deviceID = await node.localDeviceID
        let port = try #require(await node.localListenPort)
        return TestNode(node: node, hub: hub, root: root, deviceID: deviceID, port: port)
    }
}

private func pairAndReady(controller: TestNode, receiver: TestNode) async throws {
    await receiver.node.setPairingAcceptance(true)
    let c1 = Task { await autoConfirm(receiver) }
    let c2 = Task { await autoConfirm(controller) }
    await controller.node.beginPairing(host: "127.0.0.1", port: receiver.port)
    _ = try await controller.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
    _ = await c1.value; _ = await c2.value
    await receiver.node.setPairingAcceptance(false)

    await controller.node.connect(toDevice: receiver.deviceID, host: "127.0.0.1", port: receiver.port)
    _ = try await controller.hub.waitFor {
        if case .sessionStateChanged(let id, .ready, _) = $0 { return id == receiver.deviceID }
        return false
    }
    let caps = try await controller.hub.waitFor {
        if case .remoteCapabilities(let id, _) = $0 { return id == receiver.deviceID }
        return false
    }
    if case .remoteCapabilities(_, let list) = caps {
        #expect(list.contains(CapabilityID.inputInject))
        #expect(list.contains(CapabilityID.screenSource))
    }
}

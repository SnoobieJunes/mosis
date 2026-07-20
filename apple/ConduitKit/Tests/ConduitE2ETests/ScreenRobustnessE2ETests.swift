import Foundation
import Testing
@testable import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Regression tests for failures found by adversarial review of the loop-1..4
/// screen-lane re-architecture. Each one corresponds to a defect that a fully
/// green suite did not catch, and each fails if its fix is reverted.
@Suite(.serialized) struct ScreenRobustnessE2ETests {

    /// A stream that goes silent while its connection stays open must be
    /// surfaced, not left frozen forever.
    ///
    /// Every other liveness path in the viewer is driven by EOF: the attach
    /// watchdog is cancelled at attach, and `laneLostGrace` is only armed from
    /// `handleBulkLaneLost`, which runs when the read loop *ends*. The common
    /// real-hardware failure produces no EOF at all — Wi-Fi roams or the radio
    /// sleeps, the socket is black-holed, `nextFrame()` parks forever, and the
    /// session link stays healthy so nothing else notices either. TCP
    /// retransmission would take 10-15 minutes to surface it.
    ///
    /// Before `frameStallTimeout` the user saw a frozen last frame indefinitely:
    /// no error, no Retry, and a HUD still cheerfully reporting the lane as up.
    @Test(.timeLimit(.minutes(3))) func frozenStreamIsSurfacedInsteadOfHangingForever() async throws {
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        try await pairAndConnect(viewer: phone, source: mac)
        let (offer, render) = try await startShare(viewer: phone, source: mac)

        // Stream is genuinely alive first, so what we assert below is a stall and
        // not a share that never started.
        try await pollUntil(timeout: 40) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5, "the stream must be live before we freeze it")

        // Go silent with every connection still open.
        capturer.freeze()

        // The viewer must give up and say so. Without the stall watchdog this
        // wait times out and the viewer sits on a frozen frame forever.
        let failure = try await phone.hub.waitFor(timeoutSeconds: 40) {
            if case .screenViewerFailed = $0 { return true }; return false
        }
        guard case .screenViewerFailed(_, _, let reason) = failure else {
            Issue.record("a stalled stream must surface a failure the user can act on")
            return
        }
        #expect(!reason.isEmpty, "the failure must carry a reason for the UI to show")

        _ = offer
    }

    /// Two screen requests arriving while the source picker is open must not
    /// start two shares.
    ///
    /// `sharing` is not assigned until the very end of `beginSharing`, and the
    /// path there awaits the picker — a sheet that stays up as long as the user
    /// takes. The "already sharing" guard therefore did not cover that window,
    /// and the node dispatches each request into its own Task so nothing
    /// serialized them. Two pickers opened; the second `beginSharing` overwrote
    /// `sharing` with no teardown, orphaning the first encoder, sender task, feed
    /// continuation and upgrade task. The first viewer had a valid SCREEN_OFFER
    /// and sat blank until its 45s watchdog blamed the network for a local race.
    ///
    /// A double-tap on "View Screen" is enough to trigger it.
    @Test(.timeLimit(.minutes(3))) func duplicateRequestDoesNotStartASecondShare() async throws {
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        try await pairAndConnect(viewer: phone, source: mac)

        // Hold the picker open across BOTH requests — this is the race window.
        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            // Give the second request time to land while the picker is still up.
            try? await Task.sleep(for: .milliseconds(600))
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }

        await phone.node.requestScreen(from: mac.deviceID)
        try? await Task.sleep(for: .milliseconds(150))
        await phone.node.requestScreen(from: mac.deviceID)   // the double-tap
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else {
            Issue.record("no screenViewerStarted"); return
        }

        // Exactly one picker prompt. Two means the reservation didn't hold and a
        // second share was being built behind the first.
        let macEvents = await mac.hub.allEvents()
        let pickCount = macEvents.filter {
            if case .screenSourcePickRequested = $0 { return true }; return false
        }.count
        #expect(pickCount == 1, "a duplicate request must not open a second source picker (got \(pickCount))")

        // And the surviving share must actually work — the orphaned-encoder bug
        // left the viewer with an offer and no frames.
        try await pollUntil(timeout: 40) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5, "the first viewer must receive frames, not be orphaned by the second request")

        let phoneEvents = await phone.hub.allEvents()
        #expect(!phoneEvents.contains { if case .screenViewerFailed = $0 { return true }; return false },
                "a duplicate request must not fail the share")

        await phone.node.stopViewingScreen(screenSessionID: offer.screenSessionID)
    }

    // MARK: Shared setup

    private func pairAndConnect(viewer: TestNode, source: TestNode) async throws {
        await source.node.setPairingAcceptance(true)
        let cs = Task { await autoConfirm(source) }
        let cv = Task { await autoConfirm(viewer) }
        await viewer.node.beginPairing(host: "127.0.0.1", port: source.port)
        _ = try await viewer.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cs.value; _ = await cv.value
        await source.node.setPairingAcceptance(false)

        await viewer.node.connect(toDevice: source.deviceID, host: "127.0.0.1", port: source.port)
        _ = try await viewer.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == source.deviceID }
            return false
        }
        _ = try await viewer.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == source.deviceID }
            return false
        }
    }

    private func startShare(
        viewer: TestNode, source: TestNode
    ) async throws -> (ScreenOfferBody, ScreenRenderTarget) {
        let pick = Task {
            let event = try? await source.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await source.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await viewer.node.requestScreen(from: source.deviceID)
        _ = await pick.value

        let started = try await viewer.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else {
            struct NoShare: Error {}
            throw NoShare()
        }
        return (offer, render)
    }
}

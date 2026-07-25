import Foundation
import Testing
@testable import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// The half of the spec §8 verb pair that macOS never had: **Share** — the
/// source volunteering its screen instead of waiting to be pulled.
///
/// Until this existed, the only way a Mac's screen reached anything was for the
/// far end to send SCREEN_REQUEST, which meant there was no way to put the Mac
/// on a TV or a tablet *from the Mac*, and the Mac's display/window picker only
/// ever appeared reactively, unprompted, in response to a remote request.
///
/// These tests run over real sockets with the reverse-dial deliberately
/// impossible in the multi-viewer case, because "cast to my TV **and** my
/// tablet" is the scenario that used to fail: extra viewers had no control-lane
/// fallback, so every viewer after the first died wherever the reverse dial did.
@Suite(.serialized) struct PushShareE2ETests {

    /// Pairs `joiner` to `host` and connects `host → joiner`.
    ///
    /// Everything here is `waitFor(since:)`-scoped. `EventHub.waitFor` scans the
    /// whole buffer including past events, so a node pairing for the SECOND time
    /// re-matches its first pairing prompt, answers a dead flow id, and the live
    /// prompt is never confirmed — the multi-viewer test needs two pairings on
    /// the same source node, so it would deadlock on exactly that.
    /// Generous on purpose. Pairing does two real TLS handshakes plus a PKCS#12
    /// import, and under full-suite load these suites compete with the
    /// deliberately expensive crypto tests. The repo has been bitten by tight
    /// deadlines before (TESTING_PLAN §3): the behaviour was fine, the deadline
    /// wasn't. Nothing here is measuring latency.
    private static let waitBudget: Double = 120

    /// Names the step that timed out. A bare `TimeoutError` reported against the
    /// `@Test` line tells you nothing about which of four waits died.
    private func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            Issue.record("pairAndConnect step '\(name)' failed: \(error)")
            throw error
        }
    }

    private func pairAndConnect(host: TestNode, joiner: TestNode) async throws {
        let hostMark = await host.hub.mark()
        let joinerMark = await joiner.hub.mark()
        await host.node.setPairingAcceptance(true)
        let ch = Task { await confirmNextPairing(host, since: hostMark) }
        let cj = Task { await confirmNextPairing(joiner, since: joinerMark) }
        await joiner.node.beginPairing(host: "127.0.0.1", port: host.port)
        _ = try await step("pairingCompleted") {
            try await joiner.hub.waitFor(since: joinerMark, timeoutSeconds: Self.waitBudget) {
                if case .pairingCompleted = $0 { return true }; return false
            }
        }
        _ = await ch.value; _ = await cj.value
        await host.node.setPairingAcceptance(false)

        // The SOURCE connects outward — a push starts from this side.
        let readyMark = await host.hub.mark()
        await host.node.connect(toDevice: joiner.deviceID, host: "127.0.0.1", port: joiner.port)
        _ = try await step("sessionReady") {
            try await host.hub.waitFor(since: readyMark, timeoutSeconds: Self.waitBudget) {
                if case .sessionStateChanged(let id, .ready, _) = $0 { return id == joiner.deviceID }
                return false
            }
        }
        _ = try await step("remoteCapabilities") {
            try await host.hub.waitFor(since: readyMark, timeoutSeconds: Self.waitBudget) {
                if case .remoteCapabilities(let id, _) = $0 { return id == joiner.deviceID }
                return false
            }
        }
    }

    private func confirmNextPairing(_ node: TestNode, since mark: Int) async {
        guard case .pairingPrompt(let prompt) = try? await node.hub.waitFor(
            since: mark, timeoutSeconds: Self.waitBudget,
            { if case .pairingPrompt = $0 { return true }; return false }
        ) else { return }
        await node.node.resolvePairingPrompt(flowID: prompt.flowID, accept: true)
    }

    /// Pair + connect two nodes, returning once both are ready and capabilities
    /// have been exchanged. `viewerReachable == false` makes every reverse-dial
    /// candidate a dead end.
    private func connectedPair(
        sourceName: String, viewerName: String,
        capturer: FakeScreenCapturer?, viewerReachable: Bool = true
    ) async throws -> (source: TestNode, viewer: TestNode) {
        let source = try await TestNode.launchWithScreen(
            name: sourceName, deviceClass: .desktop, capturer: capturer
        )
        let viewer = try await TestNode.launchWithScreen(
            name: viewerName, deviceClass: .tv, capturer: nil
        )
        if !viewerReachable {
            await viewer.node.simulateUnreachableListenerForTesting()
        }
        try await pairAndConnect(host: source, joiner: viewer)
        return (source, viewer)
    }

    /// The headline: the Mac decides, with no request from the far end, and the
    /// far end starts rendering.
    @Test(.timeLimit(.minutes(3))) func sourceCanPushItsScreenWithoutBeingAsked() async throws {
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let (mac, tv) = try await connectedPair(
            sourceName: "Mac", viewerName: "Apple TV", capturer: capturer
        )
        defer { Task { await mac.cleanup(); await tv.cleanup() } }

        let sources = await mac.node.localScreenSources()
        let chosen = try #require(sources.first, "the fake capturer must offer a source")

        let failure = await mac.node.shareScreen(source: chosen, with: tv.deviceID)
        #expect(failure == nil, "push share reported: \(failure ?? "")")

        // The viewer never sent SCREEN_REQUEST — it just receives an offer.
        let started = try await tv.hub.waitFor(timeoutSeconds: Self.waitBudget) {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else {
            Issue.record("no screenViewerStarted"); return
        }
        #expect(offer.sourceName == chosen.name)

        try await pollUntil(timeout: 40) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5, "a pushed share must actually stream frames")

        let events = await tv.hub.allEvents()
        #expect(!events.contains { if case .screenViewerFailed = $0 { return true }; return false })

        // And the source never opened its own picker: the user already chose.
        let sourceEvents = await mac.hub.allEvents()
        #expect(!sourceEvents.contains {
            if case .screenSourcePickRequested = $0 { return true }; return false
        }, "a push must not prompt the source user a second time")
    }

    /// "Put my Mac on the TV **and** my tablet." One capture, two viewers — and
    /// the second one must survive an impossible reverse-dial, which is exactly
    /// what it could not do before: extra viewers used a blocking dial with no
    /// control-lane fallback, so in the environment this whole architecture was
    /// rebuilt for, only the first destination ever worked.
    @Test(.timeLimit(.minutes(4))) func pushingToASecondViewerWorksWithoutAReverseDial() async throws {
        let capturer = FakeScreenCapturer(width: 480, height: 320)
        let (mac, tv) = try await connectedPair(
            sourceName: "Mac", viewerName: "Apple TV", capturer: capturer, viewerReachable: false
        )
        let tablet = try await TestNode.launchWithScreen(name: "iPad", deviceClass: .tablet, capturer: nil)
        defer { Task { await mac.cleanup(); await tv.cleanup(); await tablet.cleanup() } }

        await tablet.node.simulateUnreachableListenerForTesting()
        try await pairAndConnect(host: mac, joiner: tablet)

        let chosen = try #require(await mac.node.localScreenSources().first)
        #expect(await mac.node.shareScreen(source: chosen, with: tv.deviceID) == nil)

        let tvStarted = try await tv.hub.waitFor(timeoutSeconds: Self.waitBudget) {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let tvRender) = tvStarted else { return }
        try await pollUntil(timeout: 40) { tvRender.enqueuedCount >= 3 }

        // Second destination, same live capture.
        #expect(await mac.node.shareScreen(source: chosen, with: tablet.deviceID) == nil)

        let tabletStarted = try await tablet.hub.waitFor(timeoutSeconds: Self.waitBudget) {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let tabletRender) = tabletStarted else {
            Issue.record("second viewer never started"); return
        }
        try await pollUntil(timeout: 40) { tabletRender.enqueuedCount >= 5 }
        #expect(tabletRender.enqueuedCount >= 5,
                "the second destination must stream even when it can't be reverse-dialed")

        // The first destination must not have been disturbed by the second.
        let before = tvRender.enqueuedCount
        try await pollUntil(timeout: 30) { tvRender.enqueuedCount >= before + 3 }
        #expect(tvRender.enqueuedCount >= before + 3,
                "adding a viewer must not interrupt the one already watching")

        let scopes = await mac.node.screenViewerScopes()
        #expect(scopes.count == 2, "both destinations should be listed as viewers")
    }

    /// Pushing to a peer that is already watching is a no-op, not a second
    /// share: a double-click on "Show" must not restart the capture.
    @Test(.timeLimit(.minutes(3))) func pushingTwiceToTheSamePeerIsIdempotent() async throws {
        let capturer = FakeScreenCapturer(width: 320, height: 240)
        let (mac, tv) = try await connectedPair(
            sourceName: "Mac", viewerName: "Apple TV", capturer: capturer
        )
        defer { Task { await mac.cleanup(); await tv.cleanup() } }

        let chosen = try #require(await mac.node.localScreenSources().first)
        #expect(await mac.node.shareScreen(source: chosen, with: tv.deviceID) == nil)
        let started = try await tv.hub.waitFor(timeoutSeconds: Self.waitBudget) {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }
        try await pollUntil(timeout: 40) { render.enqueuedCount >= 3 }

        #expect(await mac.node.shareScreen(source: chosen, with: tv.deviceID) == nil,
                "a repeat push to the same peer must succeed quietly")

        let before = render.enqueuedCount
        try await pollUntil(timeout: 30) { render.enqueuedCount >= before + 3 }

        let tvEvents = await tv.hub.allEvents()
        let starts = tvEvents.filter { if case .screenViewerStarted = $0 { return true }; return false }
        #expect(starts.count == 1, "a repeat push must not open a second viewer session")
    }

    /// A source with no capturer must say so rather than appearing to work.
    @Test(.timeLimit(.minutes(2))) func pushFromADeviceThatCannotCaptureIsNamed() async throws {
        let (phone, tv) = try await connectedPair(
            sourceName: "iPhone", viewerName: "Apple TV", capturer: nil
        )
        defer { Task { await phone.cleanup(); await tv.cleanup() } }

        #expect(await phone.node.localScreenSources().isEmpty)
        let descriptor = CaptureSourceDescriptor(
            id: "display:1", kind: .display, name: "Display", width: 320, height: 240
        )
        let failure = await phone.node.shareScreen(source: descriptor, with: tv.deviceID)
        #expect(failure != nil, "a device with no capturer must explain itself, not silently no-op")
    }
}

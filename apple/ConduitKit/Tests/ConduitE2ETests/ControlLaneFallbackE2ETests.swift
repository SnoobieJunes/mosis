import Foundation
import Testing
@testable import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// The device failure this whole feature exists for: screen sharing used to
/// require the SOURCE to open a second connection *back* to the viewer. On a
/// desk that always works; on real devices it is the most fragile seam in the
/// product — macOS asks for Local Network permission at exactly that moment,
/// access points isolate clients from each other, and an iOS listener is not
/// always reachable from the Mac. When it failed, the viewer got nothing.
///
/// Now the source falls back to the session link, which is already established
/// and already carrying the request and the offer. These tests make the
/// reverse-dial impossible and require the stream to work anyway.
@Suite(.serialized) struct ControlLaneFallbackE2ETests {

    /// Viewer cannot be reverse-dialed → frames must still arrive, over the
    /// session link, without any user-visible failure.
    @Test(.timeLimit(.minutes(3))) func screenStreamsOverControlLaneWhenReverseDialFails() async throws {
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        // The phone becomes unreachable as a server BEFORE it pairs, so every
        // reverse-dial candidate the Mac can build is a dead end.
        await phone.node.simulateUnreachableListenerForTesting()

        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await cp.value
        await mac.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await phone.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else {
            Issue.record("no screenViewerStarted"); return
        }

        // The payoff: video despite an impossible reverse-dial.
        try await pollUntil(timeout: 40) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5,
                "frames must arrive over the session link when no bulk lane can be opened")

        // And it must not have surfaced a failure to the user.
        let events = await phone.hub.allEvents()
        #expect(!events.contains { if case .screenViewerFailed = $0 { return true }; return false },
                "a working fallback must not report failure")

        await phone.node.stopViewingScreen(screenSessionID: offer.screenSessionID)
    }

    /// The fallback must be *labelled*, not silent: both ends report which lane
    /// is carrying video, so a degraded-but-working stream is diagnosable.
    @Test(.timeLimit(.minutes(3))) func fallbackIsReportedAsControlLaneOnBothEnds() async throws {
        let capturer = FakeScreenCapturer(width: 320, height: 240)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        await phone.node.simulateUnreachableListenerForTesting()

        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await cp.value
        await mac.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await phone.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }
        try await pollUntil(timeout: 40) { render.enqueuedCount >= 3 }

        let viewerLane = try await phone.hub.waitFor {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.viewerLane != nil }
            return false
        }
        if case .diagnosticsSnapshot(let snapshot) = viewerLane {
            #expect(snapshot.viewerLane == "control", "viewer must report the fallback lane")
        }
        let sourceLane = try await mac.hub.waitFor {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.sourceLane != nil }
            return false
        }
        if case .diagnosticsSnapshot(let snapshot) = sourceLane {
            #expect(snapshot.sourceLane == "control", "source must report the fallback lane")
        }
    }

    /// The fast path must not regress: a reachable viewer starts on the session
    /// link (so video is immediate) and then *upgrades* to the dedicated lane.
    @Test(.timeLimit(.minutes(3))) func reachableViewerUpgradesToBulkLane() async throws {
        let capturer = FakeScreenCapturer(width: 320, height: 240)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await cp.value
        await mac.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await phone.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }
        try await pollUntil(timeout: 30) { render.enqueuedCount >= 3 }

        // The upgrade lands shortly after the stream starts.
        let laneEvent = try await phone.hub.waitFor {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.viewerLane == "bulk" }
            return false
        }
        if case .diagnosticsSnapshot(let snapshot) = laneEvent {
            #expect(snapshot.viewerLane == "bulk", "a reachable viewer must end up on the dedicated lane")
        }
        let sourceLane = try await mac.hub.waitFor {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.sourceLane == "bulk" }
            return false
        }
        if case .diagnosticsSnapshot(let snapshot) = sourceLane {
            #expect(snapshot.sourceLane == "bulk", "the source must promote frames onto the dedicated lane")
        }
    }

    /// A dedicated lane that dies mid-stream must demote back to the session
    /// link, not end the share. Wi-Fi drops one connection and not another all
    /// the time; the viewer should see a quality dip, not a dead screen.
    @Test(.timeLimit(.minutes(3))) func laneFailingMidStreamDemotesInsteadOfEnding() async throws {
        let capturer = FakeScreenCapturer(width: 320, height: 240)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await cp.value
        await mac.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await phone.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }

        // Wait until the upgrade has actually happened.
        _ = try await phone.hub.waitFor {
            if case .diagnosticsSnapshot(let snapshot) = $0 { return snapshot.viewerLane == "bulk" }
            return false
        }
        try await pollUntil(timeout: 20) { render.enqueuedCount >= 5 }

        // Kill the dedicated lane out from under the live stream.
        await phone.node.dropScreenBulkLaneForTesting()
        let countAtDrop = render.enqueuedCount

        // Frames must resume on the session link.
        try await pollUntil(timeout: 30) { render.enqueuedCount >= countAtDrop + 5 }
        #expect(render.enqueuedCount >= countAtDrop + 5,
                "the stream must survive losing its dedicated lane")

        let events = await phone.hub.allEvents()
        #expect(!events.contains { if case .screenViewerFailed = $0 { return true }; return false },
                "a demotion is not a failure")
    }

    /// Video must be flowing well before the reverse-dial budget could expire —
    /// that is the whole point of starting on the session link.
    @Test(.timeLimit(.minutes(3))) func videoStartsWithoutWaitingForTheDial() async throws {
        let capturer = FakeScreenCapturer(width: 320, height: 240)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone = try await TestNode.launchWithScreen(name: "iPhone", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        // Unreachable: the dial will burn its whole budget before giving up.
        await phone.node.simulateUnreachableListenerForTesting()

        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let cp = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await cp.value
        await mac.node.setPairingAcceptance(false)

        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        let requestedAt = Date()
        await phone.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await phone.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, _, let render) = started else { return }
        try await pollUntil(timeout: 30) { render.enqueuedCount >= 2 }

        let elapsed = Date().timeIntervalSince(requestedAt)
        #expect(elapsed < ScreenSourceEngine.bulkDialBudget,
                "video must not wait for the reverse-dial budget (took \(elapsed)s)")
    }
}

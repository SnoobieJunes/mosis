import Foundation
import Testing
@testable import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// A prompt is a *user* round-trip that can sit unanswered for minutes. It must
/// never be awaited inside `PeerLink.runReadLoop`.
///
/// It used to be. `.screenRequest`, `.inputRequest` and `.permissionRequest`
/// were each awaited inline, so while a sheet was on screen that peer's read
/// loop stopped reading: inbound PINGs were never dequeued so no PONG went out,
/// and the peer's own pongs could never be read either. Six unanswered pings at
/// 5 s intervals (~35 s) and both ends closed a completely healthy session.
///
/// That is exactly the "peer <name> unresponsive; closing" observed on device
/// while the user sat looking at the share picker — the picker itself was what
/// killed the session.
@Suite(.serialized) struct ReadLoopLivenessE2ETests {

    /// With a source-pick prompt open and deliberately unanswered, the session
    /// must keep servicing ordinary traffic from that same peer.
    @Test(.timeLimit(.minutes(2))) func pendingSourcePickDoesNotStallTheReadLoop() async throws {
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

        // Raise the Mac's picker, and deliberately DO NOT answer it.
        await phone.node.requestScreen(from: mac.deviceID)
        let pickEvent = try await mac.hub.waitFor {
            if case .screenSourcePickRequested = $0 { return true }; return false
        }
        guard case .screenSourcePickRequested(let pickPeerID, _) = pickEvent else {
            Issue.record("no screenSourcePickRequested"); return
        }

        // The payoff: with that sheet still open, ordinary traffic from the same
        // peer must still be read. Before the fix this never arrived — the Mac's
        // read loop was parked inside awaitScreenPick.
        //
        // Deliberately a cancellable poll rather than hub.waitFor: waitFor races
        // a parked withCheckedContinuation against withTimeout, and a parked
        // continuation ignores cancellation, so the losing child can never drain
        // and the task group deadlocks. Against pre-fix code that wedged this
        // test for 78 minutes -- .timeLimit could not interrupt it either. A
        // guard that hangs CI instead of reddening it is not a guard.
        let marker = Data("read-loop-alive".utf8)
        await phone.node.sendClipboard(
            ClipboardPushBody(mime: "text/plain;charset=utf-8", data: marker),
            to: mac.deviceID
        )
        var arrived = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let seen = await mac.hub.allEvents().contains {
                if case .clipboardReceived(_, let body) = $0 { return body.data == marker }
                return false
            }
            if seen { arrived = true; break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Always resolve the pending prompt -- on the failure path too, or the
        // node is torn down with a parked continuation and cleanup deadlocks.
        await mac.node.resolveScreenPick(peerDeviceID: pickPeerID, sourceID: nil)

        #expect(arrived, "a peer with an open prompt must still have its traffic read")
    }
}

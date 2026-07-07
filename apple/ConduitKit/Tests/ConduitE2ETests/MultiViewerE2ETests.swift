import Foundation
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Phase 7 acceptance (spec §9 Phase 7 step 4): a source shares its screen to a
/// primary viewer, a second person's device is granted **view-only** on the same
/// share, receives frames, and is **revoked live**. Uses the synthetic capturer
/// from the Phase 3 harness so it runs without Screen Recording or a display.
@Suite(.serialized) struct MultiViewerE2ETests {
    @Test(.timeLimit(.minutes(3))) func secondViewerGrantedViewOnlyThenRevoked() async throws {
        let capturer = FakeScreenCapturer(width: 480, height: 320)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let phone1 = try await TestNode.launchWithScreen(name: "Phone1", deviceClass: .phone, capturer: nil)
        let phone2 = try await TestNode.launchWithScreen(name: "Phone2", deviceClass: .phone, capturer: nil)
        defer { Task { await mac.cleanup(); await phone1.cleanup(); await phone2.cleanup() } }
        // Pair both phones with the Mac. Use a `since` mark so the second
        // pairing's prompt doesn't match the first's stale buffered event.
        for phone in [phone1, phone2] {
            await mac.node.setPairingAcceptance(true)
            let macMark = await mac.hub.mark()
            let cm = Task {
                if case .pairingPrompt(let p)? = try? await mac.hub.waitFor(since: macMark, { if case .pairingPrompt = $0 { return true }; return false }) {
                    await mac.node.resolvePairingPrompt(flowID: p.flowID, accept: true)
                }
            }
            let cp = Task { await autoConfirm(phone) }
            await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
            _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
            _ = await cm.value; _ = await cp.value
            await mac.node.setPairingAcceptance(false)
        }

        // Primary viewer (phone1) connects and starts viewing the Mac's screen.
        await phone1.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone1.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }; return false
        }
        _ = try await phone1.hub.waitFor { if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }; return false }

        let pick = Task {
            if case .screenSourcePickRequested(let peerID, let sources)? = try? await mac.hub.waitFor({
                if case .screenSourcePickRequested = $0 { return true }; return false
            }) {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }
        await phone1.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started1 = try await phone1.hub.waitFor { if case .screenViewerStarted = $0 { return true }; return false }
        guard case .screenViewerStarted(_, let offer1, let render1) = started1 else { return }
        try await pollUntil(timeout: 25) { render1.enqueuedCount >= 3 }

        // Second viewer (phone2) connects and asks to JOIN. The Mac auto-grants
        // view-only via the permission prompt.
        await phone2.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone2.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }; return false
        }
        let grant = Task {
            if case .permissionRequested(let peerID, _, _, _)? = try? await mac.hub.waitFor({
                if case .permissionRequested = $0 { return true }; return false
            }) {
                #expect(peerID == phone2.deviceID)
                await mac.node.resolveViewerGrant(peerDeviceID: peerID, scope: .viewOnly)
            }
        }
        await phone2.node.requestScreenJoin(from: mac.deviceID)
        _ = await grant.value

        // The Mac reports the second viewer joined view-only.
        let joined = try await mac.hub.waitFor { if case .viewerJoined = $0 { return true }; return false }
        guard case .viewerJoined(let joinedID, let scope) = joined else { return }
        #expect(joinedID == phone2.deviceID)
        #expect(scope == "view-only")

        // Phone2 actually receives and decodes frames from the SAME capture.
        let started2 = try await phone2.hub.waitFor { if case .screenViewerStarted = $0 { return true }; return false }
        guard case .screenViewerStarted(_, _, let render2) = started2 else { return }
        try await pollUntil(timeout: 25) { render2.enqueuedCount >= 3 }
        #expect(render2.enqueuedCount >= 3, "the second viewer must receive frames")

        // Both scopes are visible to the source: phone1 control, phone2 view-only.
        let scopes = await mac.node.screenViewerScopes()
        #expect(scopes[phone2.deviceID] == "view-only")

        // Revoke phone2 LIVE. It ends; phone1 keeps viewing.
        await mac.node.revokeViewer(deviceID: phone2.deviceID)
        _ = try await mac.hub.waitFor { if case .viewerRevoked = $0 { return true }; return false }
        _ = try await phone2.hub.waitFor { if case .screenViewerEnded = $0 { return true }; return false }

        // Phone1 is still receiving after phone2's revoke.
        let beforeCount = render1.enqueuedCount
        try await pollUntil(timeout: 15) { render1.enqueuedCount > beforeCount }
        #expect(render1.enqueuedCount > beforeCount, "the primary viewer keeps streaming after a revoke")
        _ = offer1
    }
}

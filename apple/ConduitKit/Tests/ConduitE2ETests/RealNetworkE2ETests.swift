import Foundation
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport
#if canImport(Darwin)
import Darwin
#endif

/// The reverse-dial bug (blank screen) lived OFF loopback: to stream, the source
/// opens a NEW bulk connection *back* to the viewer using the viewer's address —
/// which the old code stringified from the session path (fragile, and never
/// exercised off 127.0.0.1). These tests run the pair → connect → view-screen
/// path over the Mac's real LAN IP, so a broken reverse-dial reproduces here and
/// the M3 candidate-chain opener is proven to land off-loopback.
///
/// Env-gated: skipped unless `CONDUIT_LAN_E2E` is set AND the runner has a
/// routable LAN IPv4 — LAN/mDNS is unreliable inside CI sandboxes, so this is an
/// opt-in local/hardware check, not part of the default gate.
@Suite(.serialized) struct RealNetworkE2ETests {
    @Test(.timeLimit(.minutes(3))) func viewScreenOverLANReverseDial() async throws {
        guard ProcessInfo.processInfo.environment["CONDUIT_LAN_E2E"] != nil,
              let lanIP = Self.localLANIPv4() else {
            return  // env-gated: nothing to assert without an opt-in + a LAN IP
        }

        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let ipad = try await TestNode.launchWithScreen(name: "iPad", deviceClass: .tablet, capturer: nil)
        defer { Task { await mac.cleanup(); await ipad.cleanup() } }

        // Pair + connect the iPad → Mac over the REAL LAN IP (not 127.0.0.1).
        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let ci = Task { await autoConfirm(ipad) }
        await ipad.node.beginPairing(host: lanIP, port: mac.port)
        _ = try await ipad.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await ci.value
        await mac.node.setPairingAcceptance(false)

        await ipad.node.connect(toDevice: mac.deviceID, host: lanIP, port: mac.port)
        _ = try await ipad.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        _ = try await ipad.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }

        // Mac auto-picks the fake display when the request arrives.
        let pick = Task {
            let event = try? await mac.hub.waitFor {
                if case .screenSourcePickRequested = $0 { return true }; return false
            }
            if case .screenSourcePickRequested(let peerID, let sources) = event {
                await mac.node.resolveScreenPick(peerDeviceID: peerID, sourceID: sources.first?.id)
            }
        }

        await ipad.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        let started = try await ipad.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(_, let offer, let render) = started else {
            Issue.record("no screenViewerStarted"); return
        }

        // The payoff: frames actually reach the render target — proving the source
        // reverse-dialed the viewer's listener over the LAN IP (candidate chain),
        // not just that a control-lane offer arrived.
        try await pollUntil(timeout: 30) { render.enqueuedCount >= 3 }
        #expect(render.enqueuedCount >= 3, "frames must arrive via the LAN-IP reverse dial")

        // And it must NOT have blank-screen-failed with a reason.
        let events = await ipad.hub.allEvents()
        #expect(!events.contains { if case .screenViewerFailed = $0 { return true }; return false })

        await ipad.node.stopViewingScreen(screenSessionID: offer.screenSessionID)
    }

    /// The primary LAN IPv4 (Wi-Fi/Ethernet `en*`), skipping loopback and
    /// link-local. Nil when the host has no routable LAN address.
    static func localLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let addr = current.pointee.ifa_addr,
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }  // skip awdl/utun/bridge
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254") { return ip }  // skip link-local
        }
        return nil
    }
}

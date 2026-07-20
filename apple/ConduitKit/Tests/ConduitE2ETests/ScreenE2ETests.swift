import Foundation
import CoreVideo
import CoreMedia
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// A capturer that emits synthetic gradient frames on a timer, standing in for
/// ScreenCaptureKit so the node→node screen path can be tested without Screen
/// Recording permission or a display. The frames are real (encodable) pixels.
final class FakeScreenCapturer: ScreenCapturer, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    let width: Int
    let height: Int

    init(width: Int = 640, height: Int = 480) {
        self.width = width
        self.height = height
    }

    func isPermitted() async -> Bool { true }
    func requestPermission() async {}

    func availableSources() async throws -> [CaptureSourceDescriptor] {
        [CaptureSourceDescriptor(id: "display:fake", kind: .display,
                                 name: "Fake Display", width: width, height: height)]
    }

    func start(
        source: CaptureSourceDescriptor,
        configuration: CaptureConfiguration,
        onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void
    ) async throws {
        let w = configuration.width, h = configuration.height
        timer = Task {
            var tick = 0
            while !Task.isCancelled {
                if let pb = Self.makePixelBuffer(width: w, height: h, tick: tick) {
                    onFrame(pb, CMTime(value: CMTimeValue(tick), timescale: 30))
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    /// Stops producing frames WITHOUT ending the share or closing anything —
    /// the stream simply goes quiet while every connection stays open.
    ///
    /// This is the viewer-side signature of the black-holed-lane failure: on real
    /// Wi-Fi (radio sleep, AP dropping the flow, a roam) the socket is neither
    /// reset nor closed, so no EOF ever arrives. From the viewer's position that
    /// is indistinguishable from the source going silent, which is what this
    /// reproduces. Used by `frozenStreamIsSurfacedInsteadOfHangingForever`.
    func freeze() {
        timer?.cancel()
        timer = nil
    }

    static func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bpr + x * 4
                ptr[o + 0] = UInt8((x + tick * 6) & 0xFF)
                ptr[o + 1] = UInt8((y + tick * 4) & 0xFF)
                ptr[o + 2] = UInt8((x + y + tick * 2) & 0xFF)
                ptr[o + 3] = 255
            }
        }
        return buffer
    }
}

extension TestNode {
    static func launchWithScreen(
        name: String, deviceClass: DeviceClass, capturer: FakeScreenCapturer?
    ) async throws -> TestNode {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-screen-\(UUID().uuidString)")
        let config = NodeConfiguration(
            deviceName: name, deviceClass: deviceClass, appVersion: "e2e",
            receiveDirectory: root.appendingPathComponent("received"),
            stateDirectory: root.appendingPathComponent("state")
        )
        let store = FileIdentityStore(fileURL: root.appendingPathComponent("identity.json"))
        let node = try ConduitNode(config: config, identityStore: store,
                                   inputInjector: nil, screenCapturer: capturer)
        let hub = EventHub()
        await hub.attach(to: node)
        try await node.start()
        let deviceID = await node.localDeviceID
        let port = try #require(await node.localListenPort)
        return TestNode(node: node, hub: hub, root: root, deviceID: deviceID, port: port)
    }
}

@Suite(.serialized) struct ScreenE2ETests {
    /// The Phase 3 headline path without hardware: a source (fake capturer)
    /// shares to a viewer over the real transport. Proves offer → pick →
    /// dedicated bulk lane → HEVC/H.264 encode → wire → decode → render-target
    /// enqueue, plus the viewer's ack feedback reaching the source.
    @Test(.timeLimit(.minutes(3))) func viewMacScreenEndToEnd() async throws {
        let capturer = FakeScreenCapturer(width: 640, height: 480)
        let mac = try await TestNode.launchWithScreen(name: "Mac", deviceClass: .desktop, capturer: capturer)
        let ipad = try await TestNode.launchWithScreen(name: "iPad", deviceClass: .tablet, capturer: nil)
        defer { Task { await mac.cleanup(); await ipad.cleanup() } }

        // Pair + connect iPad → Mac.
        await mac.node.setPairingAcceptance(true)
        let cm = Task { await autoConfirm(mac) }
        let ci = Task { await autoConfirm(ipad) }
        await ipad.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await ipad.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await cm.value; _ = await ci.value
        await mac.node.setPairingAcceptance(false)

        await ipad.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await ipad.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }
        // iPad learns the Mac can source its screen.
        let caps = try await ipad.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }
        if case .remoteCapabilities(_, let list) = caps {
            #expect(list.contains(CapabilityID.screenSource))
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

        // iPad requests the screen ("Connect to screen").
        await ipad.node.requestScreen(from: mac.deviceID)
        _ = await pick.value

        // Viewer receives the offer with a render target.
        let started = try await ipad.hub.waitFor {
            if case .screenViewerStarted = $0 { return true }; return false
        }
        guard case .screenViewerStarted(let fromID, let offer, let render) = started else { return }
        #expect(fromID == mac.deviceID)
        #expect(offer.width == 640 && offer.height == 480)
        #expect(offer.captureKind == .display)

        // Frames flow and actually decode into displayable sample buffers.
        try await pollUntil(timeout: 25) { render.enqueuedCount >= 5 }
        #expect(render.enqueuedCount >= 5, "decoded frames must reach the render target")

        // Viewer stats confirm a live stream; source saw sharing start.
        _ = try await ipad.hub.waitFor {
            if case .screenViewerStats(_, let fps, _) = $0 { return fps > 0 }; return false
        }
        _ = try await mac.hub.waitFor {
            if case .screenSourceStarted = $0 { return true }; return false
        }

        // Stop from the viewer; the source tears down its capture + encode.
        await ipad.node.stopViewingScreen(screenSessionID: offer.screenSessionID)
        _ = try await ipad.hub.waitFor {
            if case .screenViewerEnded = $0 { return true }; return false
        }
    }

    /// A viewer can't request a screen from a peer that can't source one.
    @Test(.timeLimit(.minutes(2))) func cannotViewNonSource() async throws {
        // Two tablets, neither with a capturer.
        let a = try await TestNode.launchWithScreen(name: "TabA", deviceClass: .tablet, capturer: nil)
        let b = try await TestNode.launchWithScreen(name: "TabB", deviceClass: .tablet, capturer: nil)
        defer { Task { await a.cleanup(); await b.cleanup() } }

        await b.node.setPairingAcceptance(true)
        let ca = Task { await autoConfirm(a) }
        let cb = Task { await autoConfirm(b) }
        await a.node.beginPairing(host: "127.0.0.1", port: b.port)
        _ = try await a.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await ca.value; _ = await cb.value

        await a.node.connect(toDevice: b.deviceID, host: "127.0.0.1", port: b.port)
        _ = try await a.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == b.deviceID }
            return false
        }
        _ = try await a.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == b.deviceID }
            return false
        }

        await a.node.requestScreen(from: b.deviceID)
        let failed = try await a.hub.waitFor {
            if case .screenFailed = $0 { return true }; return false
        }
        if case .screenFailed(let reason) = failed {
            #expect(reason.lowercased().contains("can't share"))
        }
    }
}

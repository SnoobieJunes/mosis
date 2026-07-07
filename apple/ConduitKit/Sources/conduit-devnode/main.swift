import Foundation
import CoreMedia
import CoreVideo
import ConduitProtocol
import ConduitSession
import ConduitTransport
import ConduitCapabilities

/// Headless Conduit node for **cross-process, real-network** testing — the seam
/// the in-process E2E suites cannot reach. Two of these (or one plus the real
/// Mac app) reproduce the device topology: separate processes, separate
/// identities, real Bonjour, real TLS over the LAN IP, real reverse-dial.
///
/// Roles:
///   source  — advertises, accepts pairing, auto-picks the first display when a
///             viewer asks for the screen. `--real-capture` uses ScreenCaptureKit
///             (needs Screen Recording for THIS process), else synthetic frames.
///   viewer  — pairs to --host/--port, connects, requests the screen, and reports
///             how many frames actually decoded.
///
/// Example:
///   conduit-devnode --role source --name Mac --state /tmp/a
///   conduit-devnode --role viewer --name Phone --state /tmp/b --host 192.168.1.5 --port 51234
struct Options {
    var role = "source"
    var name = "DevNode"
    var stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-devnode")
    var host: String?
    var port: UInt16?
    var realCapture = false
    var seconds: Double = 45
    var deviceClass: DeviceClass = .desktop
    /// Rehearse the device failure: make this node unreachable as a server so
    /// the peer's reverse-dial cannot land and video must use the fallback.
    var noInbound = false

    static func parse() -> Options {
        var options = Options()
        var arguments = Array(CommandLine.arguments.dropFirst())
        while let flag = arguments.first {
            arguments.removeFirst()
            func value() -> String? {
                guard let next = arguments.first, !next.hasPrefix("--") else { return nil }
                arguments.removeFirst()
                return next
            }
            switch flag {
            case "--role": options.role = value() ?? options.role
            case "--name": options.name = value() ?? options.name
            case "--state": options.stateDir = URL(fileURLWithPath: value() ?? options.stateDir.path)
            case "--host": options.host = value()
            case "--port": options.port = value().flatMap { UInt16($0) }
            case "--seconds": options.seconds = value().flatMap { Double($0) } ?? options.seconds
            case "--real-capture": options.realCapture = true
            case "--no-inbound": options.noInbound = true
            case "--phone": options.deviceClass = .phone
            default: break
            }
        }
        return options
    }
}

/// Synthetic capturer (same shape as the test fake) so a source node works
/// without Screen Recording permission.
final class SyntheticCapturer: ScreenCapturer, @unchecked Sendable {
    private var timer: Task<Void, Never>?

    func isPermitted() async -> Bool { true }
    func requestPermission() async {}
    func availableSources() async throws -> [CaptureSourceDescriptor] {
        [CaptureSourceDescriptor(id: "display:synthetic", kind: .display,
                                 name: "Synthetic Display", width: 640, height: 480)]
    }
    func start(source: CaptureSourceDescriptor, configuration: CaptureConfiguration,
               onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) async throws {
        let width = configuration.width, height = configuration.height
        timer = Task {
            var tick = 0
            while !Task.isCancelled {
                if let buffer = Self.makePixelBuffer(width: width, height: height, tick: tick) {
                    onFrame(buffer, CMTime(value: CMTimeValue(tick), timescale: 30))
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
    func stop() async { timer?.cancel(); timer = nil }

    static func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pointer[offset + 0] = UInt8((x &+ tick &* 6) & 0xFF)
                pointer[offset + 1] = UInt8((y &+ tick &* 4) & 0xFF)
                pointer[offset + 2] = UInt8((x &+ y &+ tick &* 2) & 0xFF)
                pointer[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

@main
struct DevNode {
    static func main() async throws {
        let options = Options.parse()
        try? FileManager.default.createDirectory(at: options.stateDir, withIntermediateDirectories: true)

        let capturer: (any ScreenCapturer)?
        if options.role == "source" {
            capturer = options.realCapture ? ConduitNode.defaultScreenCapturer() : SyntheticCapturer()
        } else {
            capturer = nil
        }

        let config = NodeConfiguration(
            deviceName: options.name,
            deviceClass: options.deviceClass,
            appVersion: "devnode",
            receiveDirectory: options.stateDir.appendingPathComponent("received"),
            stateDirectory: options.stateDir
        )
        let store = FileIdentityStore(fileURL: options.stateDir.appendingPathComponent("identity.json"))
        let node = try ConduitNode(config: config, identityStore: store,
                                   inputInjector: nil, screenCapturer: capturer)

        let frames = Locked(0)
        let failures = Locked<[String]>([])

        // Event pump: auto-confirm pairing, auto-pick the source, count frames.
        let events = Task {
            for await event in node.events {
                switch event {
                case .listenerReady(let port):
                    log("listening on port \(port)")
                case .pairingPrompt(let prompt):
                    log("pairing prompt \(prompt.code) \(prompt.wordA)·\(prompt.wordB) → auto-accept")
                    await node.resolvePairingPrompt(flowID: prompt.flowID, accept: true)
                case .pairingCompleted(let peer):
                    log("PAIRED with \(peer.name) [\(peer.deviceID.prefix(8))]")
                case .pairingFailed(let reason):
                    log("PAIRING FAILED: \(reason)"); failures.withValue { $0.append("pairing: \(reason)") }
                case .sessionStateChanged(let id, let state, let backend):
                    log("session \(id.prefix(8)) → \(state) \(backend.map { "\($0)" } ?? "")")
                case .remoteCapabilities(let id, let caps):
                    log("caps from \(id.prefix(8)): \(caps.joined(separator: ","))")
                case .screenSourcePickRequested(let peerID, let sources):
                    let chosen = sources.first { $0.kind == .display } ?? sources.first
                    log("pick requested → \(chosen?.name ?? "none")")
                    await node.resolveScreenPick(peerDeviceID: peerID, sourceID: chosen?.id)
                case .screenSourceStarted(_, let name):
                    log("SOURCE STARTED: \(name)")
                case .screenViewerStarted(_, let offer, _):
                    log("VIEWER STARTED: \(offer.sourceName) \(offer.width)×\(offer.height) \(offer.codec.rawValue)")
                case .screenViewerStats(_, let fps, let kbps):
                    log(String(format: "stats: %.0f fps, %.0f kbps", fps, kbps))
                case .screenViewerFailed(_, _, let reason):
                    log("VIEWER FAILED: \(reason)"); failures.withValue { $0.append("viewer: \(reason)") }
                case .screenFailed(let reason):
                    log("SCREEN FAILED: \(reason)"); failures.withValue { $0.append("screen: \(reason)") }
                case .diagnosticsSnapshot(let snapshot):
                    frames.set(snapshot.viewerFramesDecoded)
                    if snapshot.lastDialTarget != nil {
                        log("dial: \(snapshot.lastDialTarget ?? "") → \(snapshot.lastDialResult ?? "")")
                    }
                case .nodeLog(let line):
                    log("node: \(line)")
                default:
                    break
                }
            }
        }

        try await node.start()
        if options.noInbound {
            await node.simulateUnreachableListenerForTesting()
            log("unreachable-as-server mode: peers cannot reverse-dial this node")
        }
        let deviceID = await node.localDeviceID
        let port = await node.localListenPort ?? 0
        log("role=\(options.role) name=\(options.name) deviceID=\(deviceID) port=\(port)")
        print("DEVNODE_READY deviceID=\(deviceID) port=\(port)")
        fflush(stdout)

        if options.role == "source" {
            await node.setPairingAcceptance(true)
            log("accepting pairing; waiting \(Int(options.seconds))s")
            try? await Task.sleep(for: .seconds(options.seconds))
        } else {
            guard let host = options.host, let remotePort = options.port else {
                log("viewer needs --host and --port"); exit(2)
            }
            log("pairing to \(host):\(remotePort)")
            await node.beginPairing(host: host, port: remotePort)
            // Wait for a pinned peer to appear.
            var peer: PinnedPeer?
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                peer = await node.pinnedPeers().first
                if peer != nil { break }
            }
            guard let peer else { log("FAILED: never paired"); exit(1) }

            log("connecting to \(peer.name)")
            await node.connect(toDevice: peer.deviceID, host: host, port: remotePort)
            try? await Task.sleep(for: .seconds(2))

            log("requesting screen")
            await node.requestScreen(from: peer.deviceID)

            // Let frames flow, then report.
            let deadline = Date().addingTimeInterval(options.seconds)
            while Date() < deadline, frames.get() < 30 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            let decoded = frames.get()
            log("RESULT decodedFrames=\(decoded) failures=\(failures.get())")
            print(decoded >= 5 ? "DEVNODE_PASS frames=\(decoded)" : "DEVNODE_FAIL frames=\(decoded) \(failures.get())")
            fflush(stdout)
            events.cancel()
            await node.stop()
            exit(decoded >= 5 ? 0 : 1)
        }
        events.cancel()
        await node.stop()
    }
}

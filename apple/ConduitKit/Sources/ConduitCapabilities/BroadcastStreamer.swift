import Foundation
import CoreMedia
import CoreVideo
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// Runs inside the ReplayKit broadcast extension (spec §9 Phase 3 step 4):
/// opens a direct pinned TLS connection to the viewer, then encodes each
/// captured frame and ships it as a SCREEN_FRAME. Reuses the same VideoEncoder,
/// LANBackend, and wire format proven by the node E2E test — the extension is
/// just the macOS source engine's streaming half in a separate process.
///
/// Memory discipline (spec pitfall: extensions are ~50 MB capped): encode
/// immediately in the sample callback and never buffer raw frames.
public actor BroadcastStreamer {
    private let config: BroadcastConfig
    private var backend: LANBackend?
    private var bulk: FramedConnection?
    private var encoder: VideoEncoder?
    private var ackTask: Task<Void, Never>?
    private var sentSeq: UInt32 = 0
    private var started = false
    private let onLog: @Sendable (String) -> Void

    public init(config: BroadcastConfig, onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.onLog = onLog
    }

    public func start() async throws {
        guard !started else { return }
        started = true

        // Client-only LANBackend: never listens, so a rejectAll policy is fine.
        let backend = try LANBackend(material: config.tlsMaterial, listenerPolicyProvider: { .rejectAll })
        self.backend = backend
        let connection = try await backend.connect(
            host: config.viewerHost, port: config.viewerPort,
            policy: .pinned([config.viewerTLSKeySHA256])
        )
        let framed = FramedConnection(connection)
        await framed.adoptSessionID(UUID().uuidString)
        try await framed.send(.screenAttach(ScreenAttachBody(
            screenSessionID: config.screenSessionID, bulkToken: config.bulkToken
        )))
        self.bulk = framed

        let wireSessionID = config.wireSessionID
        let encoder = VideoEncoder(
            config: .init(width: config.width, height: config.height,
                          fps: config.fps, bitrate: config.bitrate, codec: config.codec)
        ) { [weak self] frame, pts in
            guard let self else { return }
            Task { await self.sendFrame(frame, pts: pts, wireSessionID: wireSessionID) }
        }
        try encoder.start()
        encoder.requestKeyframe()
        self.encoder = encoder

        ackTask = Task { [weak self] in await self?.readAcks(framed) }
        onLog("broadcast streaming to \(config.viewerHost):\(config.viewerPort)")
    }

    /// Called from the broadcast SampleHandler for each video sample buffer.
    /// Nonisolated so the extension can call it directly with a non-Sendable
    /// CVPixelBuffer; boxing/hop happens here, inside the module.
    public nonisolated func handleSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let box = SendableBox(pixelBuffer)
        Task { await self.encode(box, pts: pts) }
    }

    private func encode(_ box: SendableBox<CVPixelBuffer>, pts: CMTime) {
        try? encoder?.encode(box.value, pts: pts)
    }

    private func sendFrame(_ frame: EncodedVideoFrame, pts: CMTime, wireSessionID: UInt16) async {
        guard let bulk else { return }
        let seq = sentSeq; sentSeq &+= 1
        let ptsMillis = UInt64(max(0, CMTimeGetSeconds(pts) * 1000))
        let screenFrame = ScreenFrame(
            sessionID: wireSessionID, seq: seq, isKeyframe: frame.isKeyframe,
            ptsMillis: ptsMillis, data: ScreenFramePacking.pack(frame)
        )
        do {
            try await bulk.sendScreenFrame(screenFrame)
        } catch {
            onLog("frame send failed: \(error)")
        }
    }

    private func readAcks(_ framed: FramedConnection) async {
        do {
            while let frame = try await framed.nextFrame() {
                guard case .control(let payload) = frame else { continue }
                let (_, message) = try MessageCodec.decode(payload)
                if case .screenAck(let ack) = message, ack.requestKeyframe {
                    encoder?.requestKeyframe()
                }
            }
        } catch {
            onLog("ack loop ended: \(error)")
        }
    }

    public func finish() async {
        ackTask?.cancel()
        encoder?.stop()
        if let bulk {
            try? await bulk.send(.screenEnd(ScreenEndBody(screenSessionID: config.screenSessionID)))
            bulk.closeUnderlying()
        }
        backend?.shutdown()
        onLog("broadcast finished")
    }
}

import Foundation
import CoreMedia
import CoreVideo
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// Source side of screen sharing (spec §9 Phase 3 step 2). On a viewer's
/// request it prompts for a display/window, then captures → encodes (HEVC,
/// H.264 fallback) → streams SCREEN_FRAMEs over a dedicated bulk connection,
/// adapting bitrate and issuing keyframes from the viewer's SCREEN_ACK feedback.
public actor ScreenSourceEngine {
    static let defaultFps = 30
    static let initialBitrate = 8_000_000   // 8 Mbps for 1080p-ish
    static let minBitrate = 1_000_000
    static let maxLagFrames: UInt32 = 45     // ~1.5s at 30fps → back off
    static let goodLagFrames: UInt32 = 6

    struct Sharing {
        let screenSessionID: String
        let wireSessionID: UInt16
        let peerDeviceID: String
        let offer: ScreenOfferBody
        var bulk: FramedConnection?
        var encoder: VideoEncoder?
        var senderTask: Task<Void, Never>?
        var ackTask: Task<Void, Never>?
        var frameFeed: AsyncStream<(EncodedVideoFrame, CMTime)>.Continuation?
        var sentSeq: UInt32 = 0
        var currentBitrate = initialBitrate
    }

    private let capturer: (any ScreenCapturer)?
    private let emit: @Sendable (ConduitEvent) -> Void
    /// Opens a pinned bulk connection to the viewer's listener.
    private let bulkOpener: @Sendable (PinnedPeer, String, UInt16) async throws -> FramedConnection
    /// Asks the source UI to choose a display/window; nil = user cancelled.
    private let pickSource: @Sendable (String, [CaptureSourceDescriptor]) async -> CaptureSourceDescriptor?

    private var sharing: Sharing?
    private var nextWireSession: UInt16 = 1

    public init(
        capturer: (any ScreenCapturer)?,
        emit: @escaping @Sendable (ConduitEvent) -> Void,
        bulkOpener: @escaping @Sendable (PinnedPeer, String, UInt16) async throws -> FramedConnection,
        pickSource: @escaping @Sendable (String, [CaptureSourceDescriptor]) async -> CaptureSourceDescriptor?
    ) {
        self.capturer = capturer
        self.emit = emit
        self.bulkOpener = bulkOpener
        self.pickSource = pickSource
    }

    public var canSource: Bool { capturer != nil }
    public var isSharing: Bool { sharing != nil }

    // MARK: Request handling

    public func handleRequest(_ request: ScreenRequestBody, from link: PeerLink) async {
        guard let capturer else { return }
        guard sharing == nil else {
            try? await link.send(.screenReject(ScreenRejectBody(reason: "already sharing a screen")))
            return
        }
        guard await capturer.isPermitted() else {
            await capturer.requestPermission()
            try? await link.send(.screenReject(ScreenRejectBody(
                reason: "Screen Recording permission is off on the source"
            )))
            emit(.screenPermissionNeeded)
            return
        }
        let sources: [CaptureSourceDescriptor]
        do {
            sources = try await capturer.availableSources()
        } catch {
            try? await link.send(.screenReject(ScreenRejectBody(reason: "cannot enumerate screens")))
            return
        }
        guard let chosen = await pickSource(link.peer.deviceID, sources) else {
            try? await link.send(.screenReject(ScreenRejectBody(reason: "declined")))
            return
        }
        await beginSharing(source: chosen, to: link, request: request)
    }

    private func beginSharing(source: CaptureSourceDescriptor, to link: PeerLink, request: ScreenRequestBody) async {
        guard let capturer else { return }
        // Clamp to the viewer's limits and even dimensions (codec requirement).
        let maxW = request.maxWidth ?? source.width
        let maxH = request.maxHeight ?? source.height
        let (width, height) = Self.fit(sourceW: source.width, sourceH: source.height, maxW: maxW, maxH: maxH)
        let fps = min(request.maxFps ?? Self.defaultFps, Self.defaultFps)
        let codec: ScreenVideoCodec = request.codecs.contains(.hevc) && VideoEncoder.isHEVCAvailable()
            ? .hevc : .h264

        let screenSessionID = UUID().uuidString
        let wireSessionID = nextWireSession; nextWireSession &+= 1
        let bulkToken = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
        let offer = ScreenOfferBody(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID, codec: codec,
            width: width, height: height, fps: fps, captureKind: source.kind,
            sourceName: source.name, bulkToken: bulkToken
        )

        // Frame feed: encoder callback → sender task (bounded, drops under load).
        let (feed, continuation) = AsyncStream.makeStream(
            of: (EncodedVideoFrame, CMTime).self, bufferingPolicy: .bufferingNewest(4)
        )
        var session = Sharing(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID,
            peerDeviceID: link.peer.deviceID, offer: offer
        )
        session.frameFeed = continuation

        let encoder = VideoEncoder(
            config: .init(width: width, height: height, fps: fps, bitrate: Self.initialBitrate, codec: codec)
        ) { frame, pts in
            continuation.yield((frame, pts))
        }
        do {
            try encoder.start()
        } catch {
            try? await link.send(.screenReject(ScreenRejectBody(reason: "encoder init failed")))
            return
        }
        encoder.requestKeyframe()
        session.encoder = encoder
        sharing = session

        // Tell the viewer, then open the bulk lane and start capturing.
        do {
            try await link.send(.screenOffer(offer))
        } catch {
            await stopSharing(reason: "offer send failed")
            return
        }

        guard let host = link.framed.remoteHost, let port = await link.remoteHello?.listenPort else {
            await stopSharing(reason: "viewer has no reachable listener")
            return
        }
        do {
            let bulk = try await bulkOpener(link.peer, host, port)
            await bulk.adoptSessionID(UUID().uuidString)
            try await bulk.send(.screenAttach(ScreenAttachBody(
                screenSessionID: screenSessionID, bulkToken: bulkToken
            )))
            sharing?.bulk = bulk
            sharing?.ackTask = Task { await self.readAcks(bulk, screenSessionID: screenSessionID) }
        } catch {
            await stopSharing(reason: "bulk connect failed: \(error)")
            return
        }

        // Sender drains the feed to the bulk lane.
        sharing?.senderTask = Task { await self.runSender(feed: feed, screenSessionID: screenSessionID) }

        // Start capture, funneling pixel buffers into the encoder.
        do {
            try await capturer.start(
                source: source,
                configuration: .init(width: width, height: height, fps: fps)
            ) { [weak self] pixelBuffer, pts in
                self?.feedEncoder(SendableBox(pixelBuffer), pts: pts, screenSessionID: screenSessionID)
            }
        } catch {
            await stopSharing(reason: "capture start failed: \(error)")
            return
        }
        emit(.screenSourceStarted(peerDeviceID: link.peer.deviceID, sourceName: source.name))
    }

    /// Called from the capturer's queue; hands the pixel buffer to the encoder.
    private nonisolated func feedEncoder(_ box: SendableBox<CVPixelBuffer>, pts: CMTime, screenSessionID: String) {
        Task { await self.encode(box, pts: pts, screenSessionID: screenSessionID) }
    }

    private func encode(_ box: SendableBox<CVPixelBuffer>, pts: CMTime, screenSessionID: String) async {
        guard let encoder = sharing?.encoder, sharing?.screenSessionID == screenSessionID else { return }
        try? encoder.encode(box.value, pts: pts)
    }

    private func runSender(feed: AsyncStream<(EncodedVideoFrame, CMTime)>, screenSessionID: String) async {
        for await (frame, pts) in feed {
            guard var session = sharing, session.screenSessionID == screenSessionID, let bulk = session.bulk else {
                continue
            }
            let seq = session.sentSeq
            session.sentSeq &+= 1
            sharing = session
            let ptsMillis = UInt64(max(0, CMTimeGetSeconds(pts) * 1000))
            let screenFrame = ScreenFrame(
                sessionID: session.wireSessionID, seq: seq,
                isKeyframe: frame.isKeyframe, ptsMillis: ptsMillis,
                data: ScreenFramePacking.pack(frame)
            )
            do {
                try await bulk.sendScreenFrame(screenFrame)
            } catch {
                await stopSharing(reason: "frame send failed")
                return
            }
        }
    }

    // MARK: Ack feedback → adaptive bitrate + keyframe

    private func readAcks(_ bulk: FramedConnection, screenSessionID: String) async {
        do {
            while let frame = try await bulk.nextFrame() {
                guard case .control(let payload) = frame else { continue }
                let (_, message) = try MessageCodec.decode(payload)
                if case .screenAck(let ack) = message {
                    await handleAck(ack, screenSessionID: screenSessionID)
                }
            }
        } catch {
            screenLog.info("screen ack loop ended: \(error)")
        }
    }

    private func handleAck(_ ack: ScreenAckBody, screenSessionID: String) async {
        guard var session = sharing, session.screenSessionID == screenSessionID else { return }
        if ack.requestKeyframe {
            session.encoder?.requestKeyframe()
        }
        // Adaptive bitrate from ack lag (sent vs. decoded).
        let lag = session.sentSeq > ack.ackedSeq ? session.sentSeq - ack.ackedSeq : 0
        if lag > Self.maxLagFrames {
            session.currentBitrate = max(Self.minBitrate, session.currentBitrate * 3 / 4)
            session.encoder?.setBitrate(session.currentBitrate)
            session.encoder?.requestKeyframe() // recover cleanly after a drop
        } else if lag < Self.goodLagFrames, session.currentBitrate < Self.initialBitrate {
            session.currentBitrate = min(Self.initialBitrate, session.currentBitrate * 11 / 10)
            session.encoder?.setBitrate(session.currentBitrate)
        }
        sharing = session
    }

    // MARK: Stop

    public func stopSharing(reason: String? = nil) async {
        guard let session = sharing else { return }
        sharing = nil
        session.frameFeed?.finish()
        session.senderTask?.cancel()
        session.ackTask?.cancel()
        session.encoder?.stop()
        await capturer?.stop()
        if let bulk = session.bulk {
            try? await bulk.send(.screenEnd(ScreenEndBody(screenSessionID: session.screenSessionID, reason: reason)))
            bulk.closeUnderlying()
        }
        emit(.screenSourceEnded(peerDeviceID: session.peerDeviceID))
        if let reason { emit(.nodeLog("screen share ended: \(reason)")) }
    }

    public func handleSessionClosed(peerDeviceID: String) async {
        if sharing?.peerDeviceID == peerDeviceID {
            await stopSharing(reason: "viewer disconnected")
        }
    }

    // MARK: Helpers

    static func fit(sourceW: Int, sourceH: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        let scale = min(1.0, min(Double(maxW) / Double(sourceW), Double(maxH) / Double(sourceH)))
        // Round to even dimensions (H.264/HEVC require it).
        let w = max(2, Int((Double(sourceW) * scale / 2).rounded()) * 2)
        let h = max(2, Int((Double(sourceH) * scale / 2).rounded()) * 2)
        return (w, h)
    }
}

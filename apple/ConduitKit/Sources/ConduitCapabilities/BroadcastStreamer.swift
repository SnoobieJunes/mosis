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
///
/// Truthfulness discipline (the "phone records forever" bug): every way this
/// can stop working ends the broadcast with a named reason via `onEnded` —
/// attach never confirmed, viewer closed the lane, frames stop being accepted.
/// A broadcast must never outlive its viewer silently.
public actor BroadcastStreamer {
    /// The viewer acks immediately on a successful attach; if nothing arrives
    /// within this window but the lane is still open, keep going (a non-Swift
    /// viewer may not ack until the first keyframe) — but say so in the status.
    static let attachConfirmSeconds: Double = 10
    /// Consecutive frame-send failures tolerated before ending the broadcast.
    static let maxSendFailures = 30
    /// Report progress every N sent frames.
    static let statusEveryFrames: UInt64 = 30
    /// How many *raw* captured frames may be waiting for the encoder.
    ///
    /// One. A full-resolution iPhone frame is 10–14 MB and this process is
    /// jetsammed at roughly 50 MB, so a queue of four is a kill. Dropping a
    /// stale frame is always better than dying: the encoder catches up on the
    /// next one, whereas a jetsam kills the extension without running
    /// `broadcastFinished()`, which leaves the phone's banner claiming to
    /// stream forever and the red recording pill on with nothing behind it.
    static let rawFrameQueueDepth = 1
    /// How many *encoded* frames may be waiting for the socket. Small, so it's
    /// cheap, but deep enough to ride out a brief write stall.
    static let encodedFrameQueueDepth = 4

    private let config: BroadcastConfig
    private var backend: LANBackend?
    private var bulk: FramedConnection?
    private var encoder: VideoEncoder?
    private var readTask: Task<Void, Never>?
    private var sentSeq: UInt32 = 0
    private var framesSent: UInt64 = 0
    private var sendFailures = 0
    private var started = false
    private var finishing = false
    private var endedReported = false
    private var attachContinuation: CheckedContinuation<Bool, Never>?
    private var encodeFailures = 0

    /// Capture → encoder, and encoder → socket, are both single-consumer
    /// pipelines rather than a Task per frame.
    ///
    /// The Task-per-frame version had two defects that a loopback test with
    /// synthetic 320×240 frames cannot show. First, independently created Tasks
    /// are not delivered to an actor in FIFO order, so frames could be *encoded*
    /// out of PTS order and stamped with out-of-order `sentSeq` — the viewer's
    /// decoder and sequence logic both assume order, and the result is stutter
    /// and artefacts with no error anywhere. Second, every queued Task pinned a
    /// full-resolution `CVPixelBuffer` alive, which is precisely the unbounded
    /// raw-frame buffering the memory cap forbids.
    private var rawFeed: AsyncStream<(SendableBox<CVPixelBuffer>, CMTime)>.Continuation?
    private var encodedFeed: AsyncStream<(EncodedVideoFrame, CMTime)>.Continuation?
    private var encodeTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// Raw frames dropped because the encoder was still busy — reported in the
    /// status line so a struggling broadcast is visible rather than mysterious.
    private var framesDropped: UInt64 = 0

    private let onLog: @Sendable (String) -> Void
    /// Status heartbeat for the container app's UI (phase, detail, frames).
    private let onStatus: @Sendable (BroadcastStatus.Phase, String, UInt64) -> Void
    /// The broadcast must stop (viewer gone / lane dead). The handler calls
    /// `finishBroadcastWithError` so the system actually ends the recording.
    /// `clean` distinguishes "the viewer stopped watching" from a failure.
    private let onEnded: @Sendable (_ reason: String, _ clean: Bool) -> Void

    public init(
        config: BroadcastConfig,
        onLog: @escaping @Sendable (String) -> Void = { _ in },
        onStatus: @escaping @Sendable (BroadcastStatus.Phase, String, UInt64) -> Void = { _, _, _ in },
        onEnded: @escaping @Sendable (_ reason: String, _ clean: Bool) -> Void = { _, _ in }
    ) {
        self.config = config
        self.onLog = onLog
        self.onStatus = onStatus
        self.onEnded = onEnded
    }

    /// True once the encoder is up and frames are shipping (or would ship).
    public var isStreaming: Bool { encoder != nil }

    public func start() async throws {
        guard !started else { return }
        started = true

        // Client-only LANBackend: never listens, so a rejectAll policy is fine.
        onStatus(.connecting, "starting (loading identity)", 0)
        let backend = try LANBackend(material: config.tlsMaterial, listenerPolicyProvider: { .rejectAll })
        self.backend = backend
        // Try each pre-computed host candidate in order (session, then manual) so a
        // single stale address doesn't strand the broadcast; name every failure.
        let hosts = config.viewerHostCandidates.isEmpty ? [config.viewerHost] : config.viewerHostCandidates
        onStatus(.connecting, "dialing \(hosts.joined(separator: ", ")):\(config.viewerPort)", 0)
        var connection: (any ByteStreamConnection)?
        var errors: [String] = []
        var connectedHost = config.viewerHost
        for host in hosts {
            do {
                connection = try await backend.connect(
                    host: host, port: config.viewerPort, policy: .pinned([config.viewerTLSKeySHA256])
                )
                connectedHost = host
                onLog("broadcast connected via \(host):\(config.viewerPort)")
                break
            } catch {
                errors.append("\(host):\(config.viewerPort): \(error)")
            }
        }
        guard let connection else {
            throw TransportError.connectFailed("no viewer host reachable — tried \(errors.joined(separator: " | "))")
        }
        let framed = FramedConnection(connection)
        await framed.adoptSessionID(UUID().uuidString)
        try await framed.send(.screenAttach(ScreenAttachBody(
            screenSessionID: config.screenSessionID, bulkToken: config.bulkToken
        )))
        self.bulk = framed

        // The viewer acks the attach immediately (requesting a keyframe). Wait
        // for that first inbound frame before declaring victory: a viewer that
        // already gave up (attach watchdog fired, token expired) just closes the
        // lane, which the old code never noticed — it "recorded" forever.
        readTask = Task { [weak self] in await self?.runReadLoop(framed) }
        let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            attachContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.attachConfirmSeconds))
                await self?.resolveAttach(confirmed: false)
            }
        }
        if bulk == nil {
            // The lane closed before anything arrived: the viewer rejected the
            // attach — almost always because it stopped waiting for us.
            throw TransportError.connectFailed(
                "\(viewerLabel) didn't accept the stream — it likely stopped waiting. "
                + "Reopen the share sheet and start the broadcast right away."
            )
        }
        if !confirmed {
            onLog("attach unconfirmed after \(Int(Self.attachConfirmSeconds))s; continuing (lane still open)")
        }

        let wireSessionID = config.wireSessionID
        // Encoded frames go onto a bounded stream drained by ONE task, so
        // sequence numbers are stamped in encode order.
        let (encodedStream, encodedContinuation) = AsyncStream.makeStream(
            of: (EncodedVideoFrame, CMTime).self,
            bufferingPolicy: .bufferingNewest(Self.encodedFrameQueueDepth)
        )
        self.encodedFeed = encodedContinuation
        let encoder = VideoEncoder(
            config: .init(width: config.width, height: config.height,
                          fps: config.fps, bitrate: config.bitrate, codec: config.codec)
        ) { frame, pts in
            encodedContinuation.yield((frame, pts))
        }
        try encoder.start()
        encoder.requestKeyframe()
        self.encoder = encoder
        sendTask = Task { [weak self] in
            for await (frame, pts) in encodedStream {
                await self?.sendFrame(frame, pts: pts, wireSessionID: wireSessionID)
            }
        }

        // Raw capture → encoder, likewise single-consumer and depth-1, so at
        // most one full-resolution pixel buffer is ever held waiting.
        let (rawStream, rawContinuation) = AsyncStream.makeStream(
            of: (SendableBox<CVPixelBuffer>, CMTime).self,
            bufferingPolicy: .bufferingNewest(Self.rawFrameQueueDepth)
        )
        self.rawFeed = rawContinuation
        encodeTask = Task { [weak self] in
            for await (box, pts) in rawStream {
                await self?.encode(box, pts: pts)
            }
        }

        onStatus(.streaming, "connected to \(viewerLabel) via \(connectedHost):\(config.viewerPort)", 0)
        onLog("broadcast streaming to \(connectedHost):\(config.viewerPort)")
    }

    private var viewerLabel: String {
        config.viewerName.isEmpty ? "the viewer" : config.viewerName
    }

    private func resolveAttach(confirmed: Bool) {
        guard let cont = attachContinuation else { return }
        attachContinuation = nil
        cont.resume(returning: confirmed)
    }

    /// Called from the broadcast SampleHandler for each video sample buffer.
    /// Nonisolated so the extension can call it directly with a non-Sendable
    /// CVPixelBuffer; boxing happens here, inside the module.
    ///
    /// Yields onto a depth-1 bounded stream. Under load the *older* frame is
    /// dropped, which is the only correct behaviour in a 50 MB process: the
    /// alternative is queueing 14 MB buffers until the OS kills the extension.
    public nonisolated func handleSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let box = SendableBox(pixelBuffer)
        Task { await self.enqueueRaw(box, pts: pts) }
    }

    private func enqueueRaw(_ box: SendableBox<CVPixelBuffer>, pts: CMTime) {
        guard let rawFeed, !finishing else { return }
        if case .dropped = rawFeed.yield((box, pts)) {
            framesDropped &+= 1
        }
    }

    private func encode(_ box: SendableBox<CVPixelBuffer>, pts: CMTime) {
        guard let encoder else { return }
        do {
            try encoder.encode(box.value, pts: pts)
            encodeFailures = 0
        } catch {
            // Swallowing this meant a dead encoder looked exactly like a frozen
            // phone screen: the recording pill stayed red and the viewer sat on
            // its last frame until a watchdog blamed the network.
            encodeFailures += 1
            if encodeFailures >= Self.maxSendFailures {
                endBroadcast(reason: "this iPhone's video encoder stopped working: \(error)", clean: false)
            }
        }
    }

    private func sendFrame(_ frame: EncodedVideoFrame, pts: CMTime, wireSessionID: UInt16) async {
        guard let bulk, !finishing else { return }
        let seq = sentSeq; sentSeq &+= 1
        let ptsMillis = UInt64(max(0, CMTimeGetSeconds(pts) * 1000))
        let screenFrame = ScreenFrame(
            sessionID: wireSessionID, seq: seq, isKeyframe: frame.isKeyframe,
            ptsMillis: ptsMillis, data: ScreenFramePacking.pack(frame)
        )
        do {
            try await bulk.sendScreenFrame(screenFrame)
            sendFailures = 0
            framesSent &+= 1
            if framesSent % Self.statusEveryFrames == 0 {
                let detail = framesDropped > 0
                    ? "streaming to \(viewerLabel) · \(framesDropped) frames dropped keeping up"
                    : "streaming to \(viewerLabel)"
                onStatus(.streaming, detail, framesSent)
            }
        } catch {
            onLog("frame send failed: \(error)")
            sendFailures += 1
            if sendFailures >= Self.maxSendFailures {
                endBroadcast(reason: "frames stopped reaching \(viewerLabel): \(error)", clean: false)
            }
        }
    }

    private func runReadLoop(_ framed: FramedConnection) async {
        var endError: Error?
        do {
            while let frame = try await framed.nextFrame() {
                resolveAttach(confirmed: true)
                guard case .control(let payload) = frame else { continue }
                let (_, message) = try MessageCodec.decode(payload)
                if case .screenAck(let ack) = message, ack.requestKeyframe {
                    encoder?.requestKeyframe()
                }
            }
        } catch {
            endError = error
        }
        // Lane over. Before the attach resolved: rejection (start() throws the
        // explanation). After: the viewer stopped watching or the link died —
        // end the broadcast now instead of recording into the void.
        let wasAwaitingAttach = attachContinuation != nil
        bulk = nil
        resolveAttach(confirmed: false)
        if wasAwaitingAttach || finishing { return }
        if let endError {
            endBroadcast(reason: "connection to \(viewerLabel) was lost: \(endError)", clean: false)
        } else {
            endBroadcast(reason: "\(viewerLabel) stopped watching — broadcast ended.", clean: true)
        }
    }

    private func endBroadcast(reason: String, clean: Bool) {
        guard !finishing, !endedReported else { return }
        endedReported = true
        onLog("broadcast ending: \(reason)")
        onEnded(reason, clean)
    }

    public func finish() async {
        finishing = true
        readTask?.cancel()
        // Close the pipelines before stopping the encoder so nothing is left
        // yielding into a torn-down session.
        rawFeed?.finish(); rawFeed = nil
        encodedFeed?.finish(); encodedFeed = nil
        encodeTask?.cancel(); encodeTask = nil
        sendTask?.cancel(); sendTask = nil
        encoder?.stop()
        if let bulk {
            try? await bulk.send(.screenEnd(ScreenEndBody(screenSessionID: config.screenSessionID)))
            bulk.closeUnderlying()
        }
        bulk = nil
        backend?.shutdown()
        onStatus(.ended, "broadcast stopped", framesSent)
        onLog("broadcast finished after \(framesSent) frames")
    }
}

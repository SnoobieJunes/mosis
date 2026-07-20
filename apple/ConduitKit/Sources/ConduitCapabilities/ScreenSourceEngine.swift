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
    /// Consecutive encode failures tolerated before ending the share with a
    /// reason instead of silently dropping every frame (was a `try?`).
    static let maxEncodeFailures = 30
    /// Total time allowed for the reverse-dial candidate chain before falling
    /// back to the session link. Short on purpose: a working-but-degraded
    /// stream beats a long wait followed by an error.
    static let bulkDialBudget: Double = 6
    /// Bitrate ceiling while video shares the session link. Deliberately well
    /// under `initialBitrate`: that connection also carries keepalive pings,
    /// and a link saturated with frames delays pongs — six unanswered pings
    /// close the session, which would kill the very stream we fell back to.
    static let controlLaneBitrate = 2_500_000

    /// An additional viewer of the SAME capture (spec §9 Phase 7 step 4:
    /// multi-viewer). Reference type so the sender can bump its seq without
    /// rewriting the whole Sharing each frame.
    final class SecondaryViewer {
        let deviceID: String
        let screenSessionID: String
        let wireSessionID: UInt16
        let bulk: FramedConnection
        let scope: PermissionScope
        var sentSeq: UInt32 = 0
        var ackTask: Task<Void, Never>?
        init(deviceID: String, screenSessionID: String, wireSessionID: UInt16,
             bulk: FramedConnection, scope: PermissionScope) {
            self.deviceID = deviceID
            self.screenSessionID = screenSessionID
            self.wireSessionID = wireSessionID
            self.bulk = bulk
            self.scope = scope
        }
    }

    struct Sharing {
        let screenSessionID: String
        let wireSessionID: UInt16
        let peerDeviceID: String
        /// The reliable session link. `stopSharing` signals SCREEN_END over this
        /// even when `bulk` is nil — the reverse-dial-failed path where the
        /// viewer would otherwise wait on a blank screen forever.
        let controlLink: PeerLink
        let offer: ScreenOfferBody
        /// Dimensions/codec of the live capture, so additional viewers reuse them.
        let width: Int
        let height: Int
        let fps: Int
        let codec: ScreenVideoCodec
        var bulk: FramedConnection?
        /// A dedicated lane that dialed and attached successfully but isn't
        /// carrying frames yet: the switch happens on the next keyframe so the
        /// viewer never has to decode across two connections mid-GOP.
        var pendingBulk: FramedConnection?
        /// True while frames ride `controlLink` rather than a dedicated lane.
        /// Screen sharing then degrades in quality, not in function.
        var usesControlLane = false
        var encoder: VideoEncoder?
        var senderTask: Task<Void, Never>?
        var ackTask: Task<Void, Never>?
        var frameFeed: AsyncStream<(EncodedVideoFrame, CMTime)>.Continuation?
        var sentSeq: UInt32 = 0
        var currentBitrate = initialBitrate
        /// Consecutive encode failures; reset on any success.
        var encodeFailures = 0
        /// Additional viewers watching the same capture (view-only or control).
        var secondaries: [String: SecondaryViewer] = [:]
    }

    private let capturer: (any ScreenCapturer)?
    private let emit: @Sendable (ConduitEvent) -> Void
    private let diagnostics: Diagnostics
    /// Opens a pinned bulk connection to the viewer's listener.
    private let bulkOpener: @Sendable (PinnedPeer, UInt16) async throws -> FramedConnection
    /// Asks the source UI to choose a display/window; nil = user cancelled.
    private let pickSource: @Sendable (String, [CaptureSourceDescriptor]) async -> CaptureSourceDescriptor?
    /// Asks the source user to grant a second viewer a scope; nil = deny
    /// (spec §9 Phase 7 step 4 social permissions).
    private let grantViewer: @Sendable (String, String) async -> PermissionScope?

    private var sharing: Sharing?
    private var nextWireSession: UInt16 = 1

    public init(
        capturer: (any ScreenCapturer)?,
        emit: @escaping @Sendable (ConduitEvent) -> Void,
        diagnostics: Diagnostics,
        bulkOpener: @escaping @Sendable (PinnedPeer, UInt16) async throws -> FramedConnection,
        pickSource: @escaping @Sendable (String, [CaptureSourceDescriptor]) async -> CaptureSourceDescriptor?,
        grantViewer: @escaping @Sendable (String, String) async -> PermissionScope? = { _, _ in nil }
    ) {
        self.capturer = capturer
        self.emit = emit
        self.diagnostics = diagnostics
        self.bulkOpener = bulkOpener
        self.pickSource = pickSource
        self.grantViewer = grantViewer
    }

    public var canSource: Bool { capturer != nil }
    public var isSharing: Bool { sharing != nil }

    // MARK: Request handling

    public func handleRequest(_ request: ScreenRequestBody, from link: PeerLink) async {
        guard let capturer else { return }
        // Already sharing → this is a request to JOIN the live screen. Prompt the
        // source user to grant a scope (multi-viewer social permission), rather
        // than rejecting outright.
        if sharing != nil {
            if sharing?.peerDeviceID == link.peer.deviceID || sharing?.secondaries[link.peer.deviceID] != nil {
                return   // already a viewer
            }
            if let scope = await grantViewer(link.peer.deviceID, CapabilityID.screenView) {
                await addViewer(to: link, scope: scope)
            } else {
                try? await link.send(.screenReject(ScreenRejectBody(reason: "not granted")))
            }
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
        // An empty list is not an error from ScreenCaptureKit's point of view, so
        // it used to sail straight through to the picker — which rendered a
        // segmented filter above a blank list, with no empty state and nothing
        // reported on either end. That is the "I click the options and nothing
        // happens" report. The usual cause is a Screen Recording grant that has
        // not been followed by a relaunch.
        guard !sources.isEmpty else {
            let reason = "no displays or windows available to share — grant Screen Recording, then quit and reopen MOSIS"
            try? await link.send(.screenReject(ScreenRejectBody(reason: reason)))
            emit(.screenFailed(reason: reason))
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
        let preferredCodec: ScreenVideoCodec = request.codecs.contains(.hevc) && VideoEncoder.isHEVCAvailable()
            ? .hevc : .h264

        // Frame feed: encoder callback → sender task (bounded, drops under load).
        let (feed, continuation) = AsyncStream.makeStream(
            of: (EncodedVideoFrame, CMTime).self, bufferingPolicy: .bufferingNewest(4)
        )

        // Build the encoder BEFORE the offer: an HEVC session that can't start on
        // this hardware falls back to H.264 here, so the viewer is offered the
        // codec we can actually produce rather than one we'll fail to encode.
        guard let (encoder, codec) = Self.makeStartedEncoder(
            width: width, height: height, fps: fps, preferred: preferredCodec, continuation: continuation
        ) else {
            continuation.finish()
            try? await link.send(.screenReject(ScreenRejectBody(reason: "encoder init failed")))
            return
        }
        encoder.requestKeyframe()

        let screenSessionID = UUID().uuidString
        let wireSessionID = nextWireSession; nextWireSession &+= 1
        let bulkToken = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
        let offer = ScreenOfferBody(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID, codec: codec,
            width: width, height: height, fps: fps, captureKind: source.kind,
            sourceName: source.name, bulkToken: bulkToken
        )

        var session = Sharing(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID,
            peerDeviceID: link.peer.deviceID, controlLink: link, offer: offer,
            width: width, height: height, fps: fps, codec: codec
        )
        session.frameFeed = continuation
        session.encoder = encoder
        sharing = session

        // Tell the viewer, then open the bulk lane and start capturing.
        do {
            try await link.send(.screenOffer(offer))
        } catch {
            await stopSharing(reason: "offer send failed")
            return
        }

        guard let port = await link.remoteHello?.listenPort else {
            await stopSharing(reason: "viewer has no reachable listener")
            return
        }
        // Start on the session link *immediately*: it is already established and
        // already proved itself carrying the request and this offer. Video
        // therefore never waits on the reverse-dial, which is the seam that
        // fails on real devices and can stall for its whole timeout before
        // admitting it. Same shape as the input lane (M4): take the reliable
        // path now, upgrade in the background only once the better one is
        // proven. Costs a lower bitrate until the upgrade lands.
        sharing?.usesControlLane = true
        sharing?.currentBitrate = Self.controlLaneBitrate
        sharing?.encoder?.setBitrate(Self.controlLaneBitrate)
        diagnostics.sourceLane("control")
        Task {
            await self.attemptBulkUpgrade(
                screenSessionID: screenSessionID, peer: link.peer,
                peerName: link.peer.name, port: port, bulkToken: bulkToken
            )
        }

        // Sender drains the feed to the bulk lane.
        sharing?.senderTask = Task { await self.runSender(feed: feed, screenSessionID: screenSessionID) }

        // If the capture dies on its own (display unplugged, permission revoked
        // mid-stream), end the share with a reason instead of freezing the viewer.
        capturer.setStreamStoppedHandler { [weak self] error in
            Task { await self?.handleCaptureStopped(screenSessionID: screenSessionID, error: error) }
        }

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
        diagnostics.sourceStarted(peer: link.peer.deviceID, codec: "\(codec)")
    }

    /// The dedicated lane failed mid-stream: fall back to the session link and
    /// send a keyframe so the viewer can pick up straight away.
    private func demoteToControlLane(screenSessionID: String, reason: String) async {
        guard var session = sharing, session.screenSessionID == screenSessionID, session.bulk != nil else { return }
        screenLog.warning("direct lane failed mid-stream (\(reason)); falling back to the session link")
        session.bulk?.closeUnderlying()
        session.bulk = nil
        session.ackTask?.cancel()
        session.ackTask = nil
        session.usesControlLane = true
        session.currentBitrate = Self.controlLaneBitrate
        session.encoder?.setBitrate(Self.controlLaneBitrate)
        session.encoder?.requestKeyframe()
        sharing = session
        diagnostics.sourceLane("control")
    }

    /// Background attempt at the dedicated lane. Success is an *upgrade* —
    /// frames are already flowing over the session link, so a failure here
    /// costs quality, never the stream.
    private func attemptBulkUpgrade(
        screenSessionID: String, peer: PinnedPeer, peerName: String, port: UInt16, bulkToken: String
    ) async {
        do {
            let bulk = try await withTimeout(seconds: Self.bulkDialBudget) {
                try await self.bulkOpener(peer, port)
            }
            await bulk.adoptSessionID(UUID().uuidString)
            try await bulk.send(.screenAttach(ScreenAttachBody(
                screenSessionID: screenSessionID, bulkToken: bulkToken
            )))
            // The share may have ended (or been replaced) while we dialed.
            guard sharing?.screenSessionID == screenSessionID else {
                bulk.closeUnderlying()
                return
            }
            sharing?.pendingBulk = bulk
            sharing?.ackTask = Task { await self.readAcks(bulk, screenSessionID: screenSessionID) }
            // Ask for a keyframe so the switch happens at a clean boundary.
            sharing?.encoder?.requestKeyframe()
            screenLog.info("direct screen lane up; switching at the next keyframe")
        } catch {
            screenLog.warning("no direct lane (\(error)); staying on the session link")
            emit(.nodeLog("Sharing over the session link — couldn't open a direct lane to \(peerName)."))
        }
    }

    /// Called from the capturer's queue; hands the pixel buffer to the encoder.
    private nonisolated func feedEncoder(_ box: SendableBox<CVPixelBuffer>, pts: CMTime, screenSessionID: String) {
        Task { await self.encode(box, pts: pts, screenSessionID: screenSessionID) }
    }

    private func encode(_ box: SendableBox<CVPixelBuffer>, pts: CMTime, screenSessionID: String) async {
        guard let encoder = sharing?.encoder, sharing?.screenSessionID == screenSessionID else { return }
        do {
            try encoder.encode(box.value, pts: pts)
            if sharing?.encodeFailures != 0 { sharing?.encodeFailures = 0 }
            diagnostics.sourceEncoded()
        } catch {
            // Don't swallow: a persistently failing encoder means the viewer gets
            // nothing. Count consecutive failures and end the share with a reason.
            guard var session = sharing, session.screenSessionID == screenSessionID else { return }
            session.encodeFailures += 1
            let count = session.encodeFailures
            sharing = session
            if count >= Self.maxEncodeFailures {
                await stopSharing(reason: "encoder failing (\(count)× consecutive): \(error)")
            }
        }
    }

    private func runSender(feed: AsyncStream<(EncodedVideoFrame, CMTime)>, screenSessionID: String) async {
        for await (frame, pts) in feed {
            guard var session = sharing, session.screenSessionID == screenSessionID,
                  session.bulk != nil || session.usesControlLane else {
                continue
            }
            // Promote a dialed-and-attached lane at a keyframe: from here the
            // viewer can decode the new connection standalone, so nothing is
            // stranded mid-GOP on the old one.
            if let pending = session.pendingBulk, frame.isKeyframe {
                session.bulk = pending
                session.pendingBulk = nil
                session.usesControlLane = false
                session.currentBitrate = Self.initialBitrate
                session.encoder?.setBitrate(Self.initialBitrate)
                diagnostics.sourceLane("bulk")
                screenLog.info("screen frames now on the direct lane")
            }
            let seq = session.sentSeq
            session.sentSeq &+= 1
            sharing = session
            let ptsMillis = UInt64(max(0, CMTimeGetSeconds(pts) * 1000))
            let packed = ScreenFramePacking.pack(frame)
            let screenFrame = ScreenFrame(
                sessionID: session.wireSessionID, seq: seq,
                isKeyframe: frame.isKeyframe, ptsMillis: ptsMillis, data: packed
            )
            do {
                if let bulk = session.bulk {
                    try await bulk.sendScreenFrame(screenFrame)
                } else {
                    try await session.controlLink.sendScreenFrame(screenFrame)
                }
                diagnostics.sourceSent(bitrateKbps: session.currentBitrate / 1000)
            } catch {
                if session.bulk != nil {
                    // The dedicated lane died. The session link is still there
                    // (it is how we'd report the failure anyway), so demote
                    // instead of ending a share the user is watching.
                    await demoteToControlLane(screenSessionID: screenSessionID, reason: "\(error)")
                } else {
                    // The session link itself failed — nothing left to try.
                    await stopSharing(reason: "frame send failed: \(error)")
                    return
                }
            }
            // Fan the same encoded frame out to every additional viewer.
            for viewer in session.secondaries.values {
                let vSeq = viewer.sentSeq
                viewer.sentSeq &+= 1
                let vFrame = ScreenFrame(
                    sessionID: viewer.wireSessionID, seq: vSeq,
                    isKeyframe: frame.isKeyframe, ptsMillis: ptsMillis, data: packed
                )
                do {
                    try await viewer.bulk.sendScreenFrame(vFrame)
                } catch {
                    await revokeViewer(deviceID: viewer.deviceID, reason: "send failed")
                }
            }
        }
    }

    // MARK: Multi-viewer (spec §9 Phase 7 step 4)

    /// Whether a screen share is live that another viewer could join.
    public var isSharingActive: Bool { sharing != nil }
    public var sharingSourceName: String? { sharing?.offer.sourceName }

    /// Adds an additional viewer to the live capture with the given scope. Sends
    /// it its own offer, opens its bulk lane, and requests a keyframe so it
    /// starts promptly. The viewer side is unchanged — it just gets an offer +
    /// stream like any Phase 3 viewer.
    public func addViewer(to link: PeerLink, scope: PermissionScope) async {
        guard let sharing else {
            try? await link.send(.screenReject(ScreenRejectBody(reason: "no active screen share")))
            return
        }
        let screenSessionID = UUID().uuidString
        let wireSessionID = nextWireSession; nextWireSession &+= 1
        let bulkToken = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
        let offer = ScreenOfferBody(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID, codec: sharing.codec,
            width: sharing.width, height: sharing.height, fps: sharing.fps,
            captureKind: sharing.offer.captureKind, sourceName: sharing.offer.sourceName, bulkToken: bulkToken
        )
        do {
            try await link.send(.screenOffer(offer))
        } catch {
            return
        }
        guard let port = await link.remoteHello?.listenPort else {
            try? await link.send(.screenEnd(ScreenEndBody(screenSessionID: screenSessionID, reason: "no reachable listener")))
            return
        }
        do {
            let bulk = try await bulkOpener(link.peer, port)
            await bulk.adoptSessionID(UUID().uuidString)
            try await bulk.send(.screenAttach(ScreenAttachBody(screenSessionID: screenSessionID, bulkToken: bulkToken)))
            let viewer = SecondaryViewer(
                deviceID: link.peer.deviceID, screenSessionID: screenSessionID,
                wireSessionID: wireSessionID, bulk: bulk, scope: scope
            )
            self.sharing?.secondaries[link.peer.deviceID] = viewer
            self.sharing?.encoder?.requestKeyframe()   // so the new viewer starts now
            emit(.viewerJoined(peerDeviceID: link.peer.deviceID, scope: scope.rawValue))
        } catch {
            try? await link.send(.screenEnd(ScreenEndBody(screenSessionID: screenSessionID, reason: "bulk connect failed")))
        }
    }

    /// Revokes an additional viewer live (spec: revoked live). No-op for the
    /// primary viewer (stop the whole share instead).
    public func revokeViewer(deviceID: String, reason: String = "revoked") async {
        guard let viewer = sharing?.secondaries[deviceID] else { return }
        viewer.ackTask?.cancel()
        // Clean end from the revoked viewer's POV: a deliberate revoke (or a dead
        // lane) isn't a retryable failure — don't send a reason that would prompt
        // them to Retry into a wall. `reason` stays for our own emit below.
        try? await viewer.bulk.send(.screenEnd(ScreenEndBody(screenSessionID: viewer.screenSessionID, reason: nil)))
        viewer.bulk.closeUnderlying()
        sharing?.secondaries.removeValue(forKey: deviceID)
        emit(.viewerRevoked(peerDeviceID: deviceID))
    }

    public func activeViewerScopes() -> [String: String] {
        guard let sharing else { return [:] }
        var out: [String: String] = [sharing.peerDeviceID: PermissionScope.control.rawValue]
        for (id, v) in sharing.secondaries { out[id] = v.scope.rawValue }
        return out
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
        await discardLaneIfPending(bulk, screenSessionID: screenSessionID)
    }

    /// This lane died. If it was still waiting to be promoted, drop it — the
    /// viewer refuses an attach it doesn't recognise by simply closing, and
    /// promoting a dead connection at the next keyframe would kill a stream
    /// that is currently working perfectly well over the session link.
    private func discardLaneIfPending(_ lane: FramedConnection, screenSessionID: String) async {
        guard var session = sharing, session.screenSessionID == screenSessionID,
              session.pendingBulk === lane else { return }
        session.pendingBulk = nil
        sharing = session
        lane.closeUnderlying()
        screenLog.warning("direct lane closed before it carried frames; staying on the session link")
    }

    /// Ack that came back over the SESSION link (control-lane fallback: the
    /// viewer has no bulk connection to ack on). Same adaptive-bitrate and
    /// keyframe handling as the bulk path.
    public func handleControlLaneAck(_ ack: ScreenAckBody) async {
        await handleAck(ack, screenSessionID: ack.screenSessionID)
    }

    private func handleAck(_ ack: ScreenAckBody, screenSessionID: String) async {
        guard var session = sharing, session.screenSessionID == screenSessionID else { return }
        if ack.requestKeyframe {
            session.encoder?.requestKeyframe()
        }
        // Adaptive bitrate from ack lag (sent vs. decoded).
        let lag = session.sentSeq > ack.ackedSeq ? session.sentSeq - ack.ackedSeq : 0
        // Never climb back above the lane's ceiling — on the shared session link
        // that ceiling protects the keepalives.
        let ceiling = session.usesControlLane ? Self.controlLaneBitrate : Self.initialBitrate
        if lag > Self.maxLagFrames {
            session.currentBitrate = max(Self.minBitrate, session.currentBitrate * 3 / 4)
            session.encoder?.setBitrate(session.currentBitrate)
            session.encoder?.requestKeyframe() // recover cleanly after a drop
        } else if lag < Self.goodLagFrames, session.currentBitrate < ceiling {
            session.currentBitrate = min(ceiling, session.currentBitrate * 11 / 10)
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
        // Signal the primary viewer over the reliable CONTROL lane. This is the
        // connection that survives when the bulk reverse-dial never landed — the
        // blank-screen bug — so the viewer learns the reason instead of waiting
        // forever. Idempotent with the bulk SCREEN_END below (viewer de-dups by
        // session id). A nil reason means a clean stop; a non-nil one is a
        // failure the viewer surfaces with a Retry.
        try? await session.controlLink.send(.screenEnd(ScreenEndBody(
            screenSessionID: session.screenSessionID, reason: reason)))
        if let bulk = session.bulk {
            try? await bulk.send(.screenEnd(ScreenEndBody(screenSessionID: session.screenSessionID, reason: reason)))
            bulk.closeUnderlying()
        }
        // A lane that came up but never carried frames still has to be closed,
        // or the viewer keeps a half-open connection for a dead share.
        session.pendingBulk?.closeUnderlying()
        // Tear down every additional viewer too.
        for viewer in session.secondaries.values {
            viewer.ackTask?.cancel()
            try? await viewer.bulk.send(.screenEnd(ScreenEndBody(screenSessionID: viewer.screenSessionID, reason: reason)))
            viewer.bulk.closeUnderlying()
        }
        emit(.screenSourceEnded(peerDeviceID: session.peerDeviceID))
        diagnostics.sourceStopped()
        if let reason { emit(.nodeLog("screen share ended: \(reason)")) }
    }

    public func handleSessionClosed(peerDeviceID: String) async {
        if sharing?.peerDeviceID == peerDeviceID {
            await stopSharing(reason: "viewer disconnected")
        } else if sharing?.secondaries[peerDeviceID] != nil {
            await revokeViewer(deviceID: peerDeviceID, reason: "viewer disconnected")
        }
    }

    /// The capturer reported that the OS stopped the capture out from under us.
    private func handleCaptureStopped(screenSessionID: String, error: Error?) async {
        guard sharing?.screenSessionID == screenSessionID else { return }
        let detail = error.map { "\($0)" } ?? "capture ended"
        await stopSharing(reason: "capture stopped: \(detail)")
    }

    // MARK: Helpers

    /// Builds and starts a `VideoEncoder`, falling back to H.264 when an HEVC
    /// session can't be created/started on this hardware. Returns the running
    /// encoder and the codec actually in use, or nil if even H.264 failed.
    private static func makeStartedEncoder(
        width: Int, height: Int, fps: Int, preferred: ScreenVideoCodec,
        continuation: AsyncStream<(EncodedVideoFrame, CMTime)>.Continuation
    ) -> (VideoEncoder, ScreenVideoCodec)? {
        func attempt(_ codec: ScreenVideoCodec) -> VideoEncoder? {
            let encoder = VideoEncoder(
                config: .init(width: width, height: height, fps: fps, bitrate: initialBitrate, codec: codec)
            ) { frame, pts in continuation.yield((frame, pts)) }
            do {
                try encoder.start()
                return encoder
            } catch {
                let codecName = "\(codec)"
                screenLog.warning("encoder start failed for \(codecName, privacy: .public): \(error)")
                return nil
            }
        }
        if preferred == .hevc, let encoder = attempt(.hevc) { return (encoder, .hevc) }
        if let encoder = attempt(.h264) { return (encoder, .h264) }
        return nil
    }

    static func fit(sourceW: Int, sourceH: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        let scale = min(1.0, min(Double(maxW) / Double(sourceW), Double(maxH) / Double(sourceH)))
        // Round to even dimensions (H.264/HEVC require it).
        let w = max(2, Int((Double(sourceW) * scale / 2).rounded()) * 2)
        let h = max(2, Int((Double(sourceH) * scale / 2).rounded()) * 2)
        return (w, h)
    }
}

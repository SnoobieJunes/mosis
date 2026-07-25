import Foundation
import CoreMedia
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

let screenLog = Logger(subsystem: "org.mosis", category: "screen")

/// Viewer side of screen sharing (spec §9 Phase 3 step 3). Receives an offer,
/// prepares a render target, then binds the source's inbound bulk connection,
/// decodes frames straight into an AVSampleBufferDisplayLayer, and feeds back
/// SCREEN_ACK for adaptive bitrate + keyframe recovery.
public actor ScreenViewerEngine {
    static let ackInterval = 30 // send an ack every N frames
    /// Backstop for when the source goes silent (crash, or a non-Swift source
    /// that doesn't send SCREEN_END on failure): if nothing attaches within this
    /// window the share is presumed dead and surfaced with a reason + Retry.
    /// Generous on purpose — a real reverse-dial (first-run macOS Local Network
    /// permission prompt + the candidate chain) can take many seconds, and a
    /// *failed* dial already surfaces fast via the source's control-lane
    /// SCREEN_END, so this only needs to outlast a slow-but-succeeding attach.
    /// Sized for the slowest legit attach: an iPhone broadcast offer arrives
    /// when the share sheet opens, and the user still has to tap through the
    /// system picker + 3-2-1 countdown before the extension even dials.
    static let attachTimeout: TimeInterval = 45
    /// How long to wait for frames to resume after a lane drops without a
    /// SCREEN_END, before calling the share dead. Covers the source demoting
    /// from a failed dedicated lane back to the session link.
    static let laneLostGrace: TimeInterval = 8
    /// How long an *attached* stream may go without a decodable frame before it
    /// is declared dead.
    ///
    /// This is the backstop for the failure every other watchdog here misses. The
    /// attach watchdog and `laneLostGrace` are both driven by EOF — they need the
    /// lane to *close*. The common real-world Wi-Fi failure produces no close at
    /// all: the phone's radio sleeps, or the AP drops the flow, and the socket is
    /// black-holed. No RST, so `nextFrame()` parks forever, `handleBulkLaneLost`
    /// never runs, and the session link stays healthy (separate socket, pings
    /// answered) so nothing else notices either. TCP retransmission would take
    /// 10-15 minutes to surface it. Before this watchdog the viewer showed a
    /// frozen last frame indefinitely with no error and no Retry.
    ///
    /// Must exceed `laneLostGrace` so a legitimate demote-and-resume isn't killed
    /// mid-recovery.
    static let frameStallTimeout: TimeInterval = 12
    /// How often the stall watchdog samples. Coarse on purpose: this is a
    /// liveness backstop, not a latency measurement, and re-arming a Task per
    /// frame at 60fps would cost more than the check is worth.
    static let stallCheckInterval: TimeInterval = 2

    struct Session {
        /// The peer sourcing this stream — lets a single peer's disconnect end
        /// only its own sessions, not every viewer session (teardown bug).
        let peerDeviceID: String
        let offer: ScreenOfferBody
        let render: ScreenRenderTarget
        /// The bound bulk connection (set at attach); used to ack keyframe
        /// requests and closed on teardown.
        var bulk: FramedConnection?
        /// The session link, remembered when frames arrive over the control-lane
        /// fallback. Without it, keyframe recovery was impossible on that lane:
        /// `layerNeedsKeyframe` required `bulk`, which is nil precisely when the
        /// fallback is in use, so a failed decode layer could not ask for the
        /// keyframe it needs to resume.
        var controlFramed: FramedConnection?
        var formatDescription: CMFormatDescription?
        var readTask: Task<Void, Never>?
        /// Fires if no bulk attaches within `attachTimeout`; cancelled on attach.
        var watchdogTask: Task<Void, Never>?
        /// Post-attach liveness backstop; see `frameStallTimeout`.
        var stallTask: Task<Void, Never>?
        /// When the last decodable frame arrived, on any lane.
        var lastFrameAt = Date()
        var attached = false
        /// True when frames are arriving on the peer's SESSION link because the
        /// source couldn't dial a dedicated lane. Surfaced in stats so a
        /// degraded-but-working stream is visible rather than mysterious.
        var usesControlLane = false
        var highestSeq: UInt32 = 0
        var framesSinceAck = 0
        var decodedCount = 0
        var needKeyframe = true
        // Rolling stats for the overlay.
        var statsWindowStart = Date()
        var statsFrames = 0
        var statsBytes = 0
    }

    private var sessions: [String: Session] = [:]
    /// Maps a peer's wire (uint16) session id → screen session id.
    ///
    /// Keyed by peer, not by wire id alone. Every source allocates its wire ids
    /// from 1, so two peers sharing to this viewer at once both pick 1: a flat
    /// map let the second offer overwrite the first, and control-lane frames
    /// resolved by wire id alone were then decoded against the wrong session's
    /// format description (garbage output), while the displaced session silently
    /// never attached and died at the attach timeout blaming the network.
    /// Ending either session also deleted the other's mapping. The bulk lane was
    /// never exposed to this because its attach is authenticated by a 128-bit
    /// bulkToken; the control lane has no such gate, so an unscoped map also let
    /// any paired peer inject frames into another peer's viewer session.
    private struct WireKey: Hashable {
        let peerDeviceID: String
        let wireSessionID: UInt16
    }
    private var wireToSession: [WireKey: String] = [:]
    private let emit: @Sendable (ConduitEvent) -> Void
    private let diagnostics: Diagnostics

    public init(emit: @escaping @Sendable (ConduitEvent) -> Void, diagnostics: Diagnostics) {
        self.emit = emit
        self.diagnostics = diagnostics
    }

    // MARK: Offer

    public func handleOffer(_ offer: ScreenOfferBody, from peerDeviceID: String) {
        // A repeat of an offer we're already waiting on is a keep-alive, not a
        // new share: re-arm the attach watchdog and leave the existing session
        // (and the UI showing it) alone.
        //
        // This is what makes an iPhone broadcast survivable. The offer is sent
        // when the share sheet opens, but the user still has to tap the picker,
        // wait for the system sheet, find MOSIS, tap Start Broadcast and sit
        // through a 3-2-1 countdown before the extension so much as dials. Any
        // hesitation burned the whole 45 s budget and the Mac gave up before
        // the phone had begun — which is indistinguishable, from the phone,
        // from the feature being broken.
        if let existing = sessions[offer.screenSessionID], !existing.attached,
           existing.peerDeviceID == peerDeviceID {
            sessions[offer.screenSessionID]?.watchdogTask?.cancel()
            let screenSessionID = offer.screenSessionID
            sessions[offer.screenSessionID]?.watchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.attachTimeout))
                await self?.attachWatchdogFired(screenSessionID: screenSessionID)
            }
            screenLog.info("re-armed attach watchdog for a repeated offer")
            return
        }
        let render = ScreenRenderTarget(
            screenSessionID: offer.screenSessionID,
            width: offer.width, height: offer.height, sourceName: offer.sourceName
        )
        // When the decode layer dies and flushes, it can only resume from a
        // keyframe — ask the source for one.
        render.setNeedsKeyframeHandler { [weak self] in
            Task { await self?.layerNeedsKeyframe(screenSessionID: offer.screenSessionID) }
        }
        var session = Session(peerDeviceID: peerDeviceID, offer: offer, render: render)
        let screenSessionID = offer.screenSessionID
        session.watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.attachTimeout))
            await self?.attachWatchdogFired(screenSessionID: screenSessionID)
        }
        sessions[screenSessionID] = session
        wireToSession[WireKey(peerDeviceID: peerDeviceID, wireSessionID: offer.wireSessionID)] = screenSessionID
        emit(.screenViewerStarted(peerDeviceID: peerDeviceID, offer: offer, render: render))
    }

    /// No bulk lane attached in time: the source's reverse-dial never reached us.
    /// Surface it (with Retry) rather than leaving the viewer blank forever.
    private func attachWatchdogFired(screenSessionID: String) async {
        guard let session = sessions[screenSessionID], !session.attached else { return }
        await end(
            screenSessionID: screenSessionID,
            reason: "No video from \(session.offer.sourceName) within \(Int(Self.attachTimeout))s — the sharer couldn't open a connection back to this device."
        )
    }

    // MARK: Bulk stream

    /// Binds an inbound bulk connection whose first frame was SCREEN_ATTACH.
    /// Returns false (caller closes) if the token/session doesn't match.
    public func attachStream(_ framed: FramedConnection, attach: ScreenAttachBody) -> Bool {
        guard let session = sessions[attach.screenSessionID],
              session.offer.bulkToken == attach.bulkToken else {
            return false
        }
        let screenSessionID = attach.screenSessionID
        // Attached: the reverse-dial landed. Cancel the blank-screen watchdog and
        // remember the lane so we can ack keyframe requests on it.
        sessions[screenSessionID]?.attached = true
        sessions[screenSessionID]?.bulk = framed
        sessions[screenSessionID]?.usesControlLane = false
        diagnostics.viewerAttached(true)
        diagnostics.viewerLane("bulk")
        sessions[screenSessionID]?.watchdogTask?.cancel()
        sessions[screenSessionID]?.watchdogTask = nil
        startStallWatchdog(screenSessionID: screenSessionID)
        let task = Task { await self.runReadLoop(framed, screenSessionID: screenSessionID) }
        sessions[screenSessionID]?.readTask = task
        // Ask for a keyframe immediately so the first displayable frame is soon.
        Task { await self.sendAck(framed, screenSessionID: screenSessionID, requestKeyframe: true) }
        return true
    }

    /// A screen frame arrived on the peer's SESSION link: the source could not
    /// open a dedicated bulk lane back to us and fell back to the connection
    /// that already works. First such frame counts as the attach — it cancels
    /// the blank-screen watchdog exactly like a real bulk attach would.
    ///
    /// `framed` is the session connection, used only to ack (SCREEN_ACK is a
    /// control message, so it routes back to the source normally).
    public func handleControlLaneFrame(
        _ frame: ScreenFrame, framed: FramedConnection, from peerDeviceID: String
    ) async {
        let key = WireKey(peerDeviceID: peerDeviceID, wireSessionID: frame.sessionID)
        guard let screenSessionID = wireToSession[key],
              var session = sessions[screenSessionID],
              // Belt and braces: the map is already peer-scoped, but this lane
              // carries no bulkToken, so the frame's origin is asserted against
              // the session's owner before a byte of it is decoded.
              session.peerDeviceID == peerDeviceID else { return }
        session.controlFramed = framed
        if !session.attached {
            session.attached = true
            session.usesControlLane = true
            session.watchdogTask?.cancel()
            session.watchdogTask = nil
            sessions[screenSessionID] = session
            diagnostics.viewerAttached(true)
            diagnostics.viewerLane("control")
            screenLog.info("screen stream arriving on the session link (no direct lane)")
            startStallWatchdog(screenSessionID: screenSessionID)
            await sendAck(framed, screenSessionID: screenSessionID, requestKeyframe: true)
        } else {
            sessions[screenSessionID] = session
        }
        await handleFrame(frame, framed: framed, screenSessionID: screenSessionID)
    }

    // MARK: Stall detection

    /// Arms the post-attach liveness backstop. Idempotent: re-arming (on a
    /// re-attach after a demote) replaces the previous task.
    private func startStallWatchdog(screenSessionID: String) {
        sessions[screenSessionID]?.stallTask?.cancel()
        sessions[screenSessionID]?.lastFrameAt = Date()
        sessions[screenSessionID]?.stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.stallCheckInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.stallCheckShouldEnd(screenSessionID: screenSessionID) {
                    await self.endStalled(screenSessionID: screenSessionID)
                    return
                }
            }
        }
    }

    /// True when an attached session has gone quiet past `frameStallTimeout`.
    /// Sessions that are mid-demote (`attached == false`) are left to
    /// `laneLostGrace`, which owns that window.
    private func stallCheckShouldEnd(screenSessionID: String) -> Bool {
        guard let session = sessions[screenSessionID], session.attached else { return false }
        return Date().timeIntervalSince(session.lastFrameAt) > Self.frameStallTimeout
    }

    private func endStalled(screenSessionID: String) async {
        guard let session = sessions[screenSessionID] else { return }
        screenLog.warning("screen stream stalled with no frames for \(Int(Self.frameStallTimeout))s; ending")
        await end(
            screenSessionID: screenSessionID,
            reason: "Video from \(session.offer.sourceName) stopped arriving. The connection may have dropped without closing — check both devices are on the same Wi-Fi network."
        )
    }

    private func runReadLoop(_ framed: FramedConnection, screenSessionID: String) async {
        var endReason: String?
        var sawExplicitEnd = false
        do {
            readLoop: while let frame = try await framed.nextFrame() {
                switch frame {
                case .screenFrame(let screenFrame):
                    await handleFrame(screenFrame, framed: framed, screenSessionID: screenSessionID)
                case .control(let payload):
                    let (_, message) = try MessageCodec.decode(payload)
                    if case .screenEnd(let body) = message {
                        // Break the READ LOOP, not just the switch (the old `break`
                        // fell through and kept looping on a dead lane). Carry the
                        // source's reason so the viewer can show it.
                        endReason = body.reason
                        sawExplicitEnd = true
                        break readLoop
                    }
                case .fileChunk:
                    break // not expected on a screen lane
                }
            }
        } catch {
            screenLog.info("screen viewer read loop ended: \(error)")
        }
        if sawExplicitEnd {
            await end(screenSessionID: screenSessionID, reason: endReason)
        } else {
            // The lane dropped without the source saying the share was over. It
            // may simply have lost the dedicated connection and be about to
            // resume on the session link — don't tear down a share that is
            // still coming. A grace window decides.
            await handleBulkLaneLost(screenSessionID: screenSessionID)
        }
    }

    /// The dedicated lane vanished with no SCREEN_END. Wait briefly for frames
    /// to resume on the session link (the source demotes on lane failure); if
    /// nothing arrives, the share really is dead and is surfaced as such.
    private func handleBulkLaneLost(screenSessionID: String) async {
        guard var session = sessions[screenSessionID] else { return }
        session.bulk = nil
        session.attached = false      // a resumed control-lane frame re-attaches
        session.usesControlLane = false
        session.watchdogTask?.cancel()
        session.watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.laneLostGrace))
            await self?.laneLostWatchdogFired(screenSessionID: screenSessionID)
        }
        sessions[screenSessionID] = session
        diagnostics.viewerAttached(false)
        diagnostics.viewerLane(nil)
        screenLog.info("screen lane lost; waiting \(Int(Self.laneLostGrace))s for the source to resume")
    }

    private func laneLostWatchdogFired(screenSessionID: String) async {
        guard let session = sessions[screenSessionID], !session.attached else { return }
        await end(
            screenSessionID: screenSessionID,
            reason: "The stream from \(session.offer.sourceName) stopped unexpectedly."
        )
    }

    private func handleFrame(_ frame: ScreenFrame, framed: FramedConnection, screenSessionID: String) async {
        guard var session = sessions[screenSessionID] else { return }
        diagnostics.viewerReceived()
        do {
            let encoded = try ScreenFramePacking.unpack(frame.data, isKeyframe: frame.isKeyframe)
            if frame.isKeyframe, !encoded.parameterSets.isEmpty {
                session.formatDescription = VideoSampleConversion.makeFormatDescription(
                    parameterSets: encoded.parameterSets, codec: session.offer.codec
                )
                session.needKeyframe = false
            }
            guard let format = session.formatDescription else {
                // Still waiting for the first keyframe; drop deltas.
                sessions[screenSessionID] = session
                return
            }
            let pts = CMTime(value: CMTimeValue(frame.ptsMillis), timescale: 1000)
            if let sampleBuffer = VideoSampleConversion.makeSampleBuffer(
                sampleData: encoded.sampleData, format: format, pts: pts
            ) {
                session.render.enqueue(sampleBuffer)
                session.decodedCount += 1
                // Liveness: any frame we could actually decode proves the lane
                // is alive, whichever lane it came in on.
                session.lastFrameAt = Date()
                diagnostics.viewerDecoded()
            }
            session.highestSeq = max(session.highestSeq, frame.seq)
            session.framesSinceAck += 1
            session.statsFrames += 1
            session.statsBytes += frame.data.count
            sessions[screenSessionID] = session

            if session.framesSinceAck >= Self.ackInterval {
                sessions[screenSessionID]?.framesSinceAck = 0
                await sendAck(framed, screenSessionID: screenSessionID, requestKeyframe: false)
            }
            emitStatsIfDue(screenSessionID: screenSessionID)
        } catch {
            screenLog.warning("bad screen frame: \(error)")
        }
    }

    private func sendAck(_ framed: FramedConnection, screenSessionID: String, requestKeyframe: Bool) async {
        guard let session = sessions[screenSessionID] else { return }
        let ack = ScreenAckBody(
            screenSessionID: screenSessionID,
            ackedSeq: session.highestSeq,
            requestKeyframe: requestKeyframe
        )
        try? await framed.send(.screenAck(ack))
    }

    private func emitStatsIfDue(screenSessionID: String) {
        guard var session = sessions[screenSessionID] else { return }
        let elapsed = Date().timeIntervalSince(session.statsWindowStart)
        guard elapsed >= 1.0 else { return }
        let fps = Double(session.statsFrames) / elapsed
        let kbps = Double(session.statsBytes) * 8 / 1000 / elapsed
        session.statsWindowStart = Date()
        session.statsFrames = 0
        session.statsBytes = 0
        sessions[screenSessionID] = session
        emit(.screenViewerStats(screenSessionID: screenSessionID, fps: fps, kbps: kbps))
        diagnostics.viewerStats(fps: fps, kbps: kbps, layerFailures: session.render.layerFailureCount)
    }

    // MARK: Keyframe recovery

    /// The render layer failed and flushed; ask the source for a fresh keyframe
    /// on the bound lane so it has something decodable to resume from.
    private func layerNeedsKeyframe(screenSessionID: String) async {
        guard let session = sessions[screenSessionID] else { return }
        // Ack on whichever lane is actually carrying this stream. Previously this
        // required `bulk`, so on the control-lane fallback the request was
        // dropped and a flushed layer had no way to ask for the keyframe it
        // needs — it stayed black until the encoder's next scheduled one.
        guard let lane = session.bulk ?? session.controlFramed else { return }
        sessions[screenSessionID]?.needKeyframe = true
        await sendAck(lane, screenSessionID: screenSessionID, requestKeyframe: true)
    }

    // MARK: Teardown

    public func stopViewing(screenSessionID: String, reason: String? = nil) async {
        await end(screenSessionID: screenSessionID, reason: reason)
    }

    /// Diagnostic/testing: kill the dedicated lane without ending the share, to
    /// rehearse a mid-stream lane failure. The source should notice its next
    /// send fail, demote to the session link, and the stream should survive.
    public func dropBulkLaneForTesting() {
        for session in sessions.values where session.bulk != nil {
            session.bulk?.closeUnderlying()
        }
    }

    public func handleSessionClosed(peerDeviceID: String) async {
        // A disconnect used to tear down every viewer session regardless of who
        // actually dropped. End only this peer's, and among those only the ones
        // that genuinely cannot outlive the session link:
        //  - not attached yet → nothing is coming;
        //  - riding the control-lane fallback → its frames came over the very
        //    connection that just closed.
        // A session attached to its own dedicated lane survives: for an iPhone
        // broadcast that lane belongs to the ReplayKit extension, a different
        // process from the control link, so the phone app suspending (the whole
        // point of broadcasting) must not kill the live stream.
        // A dropped session is a clean end, not a retryable failure; a proper
        // reconnect prompt is later (M8).
        let affected = sessions.filter {
            $0.value.peerDeviceID == peerDeviceID
                && (!$0.value.attached || $0.value.usesControlLane)
        }.map(\.key)
        for id in affected {
            await end(screenSessionID: id, reason: nil)
        }
    }

    /// Ends a viewer session. A non-nil `reason` is a failure the UI surfaces
    /// (reason + Retry); nil is a clean end.
    private func end(screenSessionID: String, reason: String? = nil) async {
        guard let session = sessions.removeValue(forKey: screenSessionID) else { return }
        session.watchdogTask?.cancel()
        session.stallTask?.cancel()
        session.readTask?.cancel()
        session.bulk?.closeUnderlying()
        session.render.flush()
        wireToSession.removeValue(forKey: WireKey(peerDeviceID: session.peerDeviceID,
                                                  wireSessionID: session.offer.wireSessionID))
        diagnostics.viewerEnded()
        if let reason {
            emit(.screenViewerFailed(peerDeviceID: session.peerDeviceID,
                                     screenSessionID: screenSessionID, reason: reason))
        } else {
            emit(.screenViewerEnded(screenSessionID: screenSessionID))
        }
    }
}

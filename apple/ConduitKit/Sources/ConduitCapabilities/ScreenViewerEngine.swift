import Foundation
import CoreMedia
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

let screenLog = Logger(subsystem: "org.conduit", category: "screen")

/// Viewer side of screen sharing (spec §9 Phase 3 step 3). Receives an offer,
/// prepares a render target, then binds the source's inbound bulk connection,
/// decodes frames straight into an AVSampleBufferDisplayLayer, and feeds back
/// SCREEN_ACK for adaptive bitrate + keyframe recovery.
public actor ScreenViewerEngine {
    static let ackInterval = 30 // send an ack every N frames

    struct Session {
        let offer: ScreenOfferBody
        let render: ScreenRenderTarget
        var formatDescription: CMFormatDescription?
        var readTask: Task<Void, Never>?
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
    /// Maps the wire (uint16) session id → screen session id, for attach.
    private var wireToSession: [UInt16: String] = [:]
    private let emit: @Sendable (ConduitEvent) -> Void

    public init(emit: @escaping @Sendable (ConduitEvent) -> Void) {
        self.emit = emit
    }

    // MARK: Offer

    public func handleOffer(_ offer: ScreenOfferBody, from peerDeviceID: String) {
        let render = ScreenRenderTarget(
            screenSessionID: offer.screenSessionID,
            width: offer.width, height: offer.height, sourceName: offer.sourceName
        )
        sessions[offer.screenSessionID] = Session(offer: offer, render: render)
        wireToSession[offer.wireSessionID] = offer.screenSessionID
        emit(.screenViewerStarted(peerDeviceID: peerDeviceID, offer: offer, render: render))
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
        let task = Task { await self.runReadLoop(framed, screenSessionID: screenSessionID) }
        sessions[screenSessionID]?.readTask = task
        // Ask for a keyframe immediately so the first displayable frame is soon.
        Task { await self.sendAck(framed, screenSessionID: screenSessionID, requestKeyframe: true) }
        return true
    }

    private func runReadLoop(_ framed: FramedConnection, screenSessionID: String) async {
        do {
            while let frame = try await framed.nextFrame() {
                switch frame {
                case .screenFrame(let screenFrame):
                    await handleFrame(screenFrame, framed: framed, screenSessionID: screenSessionID)
                case .control(let payload):
                    let (_, message) = try MessageCodec.decode(payload)
                    if case .screenEnd = message {
                        break
                    }
                case .fileChunk:
                    break // not expected on a screen lane
                }
            }
        } catch {
            screenLog.info("screen viewer read loop ended: \(error)")
        }
        await end(screenSessionID: screenSessionID)
    }

    private func handleFrame(_ frame: ScreenFrame, framed: FramedConnection, screenSessionID: String) async {
        guard var session = sessions[screenSessionID] else { return }
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
    }

    // MARK: Teardown

    public func stopViewing(screenSessionID: String) async {
        await end(screenSessionID: screenSessionID)
    }

    public func handleSessionClosed(peerDeviceID: String) async {
        // End any viewer sessions we opened from this peer.
        for (id, session) in sessions where session.offer.wireSessionID != 0 {
            _ = session
            await end(screenSessionID: id)
        }
    }

    private func end(screenSessionID: String) async {
        guard let session = sessions.removeValue(forKey: screenSessionID) else { return }
        session.readTask?.cancel()
        session.render.flush()
        wireToSession.removeValue(forKey: session.offer.wireSessionID)
        emit(.screenViewerEnded(screenSessionID: screenSessionID))
    }
}

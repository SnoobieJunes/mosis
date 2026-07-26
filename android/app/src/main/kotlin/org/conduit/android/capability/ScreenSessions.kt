package org.conduit.android.capability

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.conduit.core.session.FramedConnection
import org.conduit.core.wire.*
import java.util.UUID

/**
 * Both halves of screen sharing on Android, in one place: viewing a peer's
 * screen (AND-1) and serving this device's own (AND-2).
 *
 * The wire work is identical in both directions and the two milestones were
 * separated only by which end starts it, so the `SCREEN_*` message handling
 * lives here once rather than twice.
 *
 * **Lanes.** A source may stream over a dedicated connection it dials back to
 * the viewer, or over the session link when it cannot. Android supports both as
 * a viewer (`attachInboundLane` binds the dedicated one; control-lane frames
 * arrive through the session read loop) and, as a source, always uses the
 * session link. That is deliberate: the reverse dial is the seam that fails on
 * real devices — a Local Network prompt on macOS, client isolation on the AP —
 * and the Apple side already proved the session link carries video acceptably
 * at a lower bitrate. A phone gains nothing by re-introducing the one step most
 * likely to fail.
 */
class ScreenSessions(
    private val scope: CoroutineScope,
    private val sendTo: (peerId: String, type: String, payload: Json) -> Unit,
    private val sendFrameTo: (peerId: String, frame: ScreenFrame) -> Unit,
    private val toast: (String) -> Unit,
) {
    /** A stream this device is watching. */
    data class Viewing(
        val peerId: String,
        val screenSessionId: String,
        val wireSessionId: Int,
        val codec: String,
        val width: Int,
        val height: Int,
        val sourceName: String,
        val bulkToken: String,
    )

    /** A stream this device is serving. */
    data class Sourcing(
        val peerId: String,
        val screenSessionId: String,
        val wireSessionId: Int,
        val width: Int,
        val height: Int,
    )

    val viewing = MutableStateFlow<Viewing?>(null)
    val sourcing = MutableStateFlow<Sourcing?>(null)
    /** Set when a peer asks to see this screen; the UI turns it into the system
     *  MediaProjection consent dialog, which only an Activity can raise. */
    val screenRequestFrom = MutableStateFlow<String?>(null)
    /** Frames the viewer has decoded, for an honest "connecting…" state. */
    val decodedFrames = MutableStateFlow(0L)

    private var decoder: ScreenDecoder? = null
    private var projectionSource: ScreenProjectionSource? = null
    private var bulkLane: FramedConnection? = null
    private var sentSeq = 0L
    private var receivedSeq = 0L
    private var framesSinceAck = 0
    private var nextWireSession = 1

    // ---- Viewer ------------------------------------------------------------

    /** Ask a peer to share its screen. */
    fun requestFrom(peerId: String) {
        sendTo(peerId, MessageType.SCREEN_REQUEST, Bodies.screenRequest(
            maxWidth = 1920, maxHeight = 1080, maxFps = 30, codecs = listOf("h264", "hevc"),
        ))
    }

    /** SCREEN_OFFER: the source accepted (or pushed unsolicited, which the
     *  Apple broadcast path does). Prepare to decode. */
    fun handleOffer(peerId: String, payload: Json) {
        val o = payload.asObj()
        val session = Viewing(
            peerId = peerId,
            screenSessionId = o.getValue("screen_session_id").str(),
            wireSessionId = o.getValue("wire_session_id").int(),
            codec = o.getValue("codec").str(),
            width = o.getValue("width").int(),
            height = o.getValue("height").int(),
            sourceName = o.getValue("source_name").str(),
            bulkToken = o.getValue("bulk_token").str(),
        )
        // A repeated offer for a session already up is a keep-alive, not a new
        // share (the iPhone broadcast path re-sends every 20 s while the user
        // works through the system picker). Don't tear down a live decoder.
        if (viewing.value?.screenSessionId == session.screenSessionId) return
        stopViewing(sendEnd = false)
        decoder = ScreenDecoder(session.codec, session.width, session.height)
        receivedSeq = 0
        framesSinceAck = 0
        decodedFrames.value = 0
        viewing.value = session
        // Ask for a keyframe now: without one the decoder has no parameter sets
        // and cannot configure, so the surface would stay black until the
        // encoder's next scheduled one.
        ack(requestKeyframe = true)
    }

    /** The UI hands over the SurfaceView's surface once it exists. */
    fun attachSurface(surface: android.view.Surface) {
        decoder?.attach(surface)
        ack(requestKeyframe = true)
    }

    /** A frame on the session link (the source could not dial a dedicated one). */
    fun handleControlLaneFrame(peerId: String, frame: ScreenFrame) {
        val session = viewing.value ?: return
        // Assert the frame's origin before decoding it. Every source numbers its
        // wire sessions from 1, so an unscoped match would let one peer's frames
        // decode against another peer's format description.
        if (session.peerId != peerId || session.wireSessionId != frame.sessionId) return
        decode(frame)
    }

    /** Binds a dedicated inbound lane whose first frame was SCREEN_ATTACH. */
    fun attachInboundLane(conn: FramedConnection, payload: Json) {
        val a = payload.asObj()
        val session = viewing.value
        if (session == null ||
            session.screenSessionId != a.getValue("screen_session_id").str() ||
            session.bulkToken != a.getValue("bulk_token").str()
        ) {
            conn.close()
            return
        }
        bulkLane = conn
        conn.setSessionId(UUID.randomUUID().toString())
        conn.send(MessageType.SCREEN_ACK, Bodies.screenAck(session.screenSessionId, 0, true))
        scope.launch(Dispatchers.IO) { runLaneLoop(conn, session.screenSessionId) }
    }

    private fun runLaneLoop(conn: FramedConnection, screenSessionId: String) {
        try {
            while (true) {
                when (val frame = conn.nextFrame() ?: break) {
                    is Frame.Screen -> decode(frame.frame, lane = conn)
                    is Frame.Control -> {
                        val (_, msg) = MessageCodec.decode(frame.payload)
                        if (msg.type == MessageType.SCREEN_END) break
                    }
                    else -> {}
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "screen lane ended: ${e.message}")
        }
        conn.close()
        if (bulkLane === conn) bulkLane = null
        // The lane dying is not necessarily the share dying — the source may
        // demote to the session link — so the session is left alone here and
        // ends on SCREEN_END or when the user leaves.
        if (viewing.value?.screenSessionId == screenSessionId && decodedFrames.value == 0L) {
            toast("The screen stream from ${viewing.value?.sourceName} stopped before any video arrived.")
        }
    }

    private fun decode(frame: ScreenFrame, lane: FramedConnection? = null) {
        val decoder = this.decoder ?: return
        if (decoder.submit(frame.data, frame.isKeyframe, frame.ptsMillis)) {
            decodedFrames.value = decoder.decodedFrames
        }
        receivedSeq = maxOf(receivedSeq, frame.seq)
        framesSinceAck++
        if (framesSinceAck >= ACK_INTERVAL) {
            framesSinceAck = 0
            ack(requestKeyframe = false, lane = lane)
        }
    }

    private fun ack(requestKeyframe: Boolean, lane: FramedConnection? = bulkLane) {
        val session = viewing.value ?: return
        val body = Bodies.screenAck(session.screenSessionId, receivedSeq, requestKeyframe)
        // Ack on whichever lane is carrying the stream: a control-lane fallback
        // has no dedicated connection to answer on, and a dropped keyframe
        // request there means a glitched picture never recovers.
        if (lane != null) lane.send(MessageType.SCREEN_ACK, body)
        else sendTo(session.peerId, MessageType.SCREEN_ACK, body)
    }

    fun handleEnd(peerId: String, payload: Json) {
        val id = payload.asObj().getValue("screen_session_id").str()
        if (viewing.value?.screenSessionId == id) {
            payload.asObj().opt("reason")?.let { toast("Screen share ended: ${it.str()}") }
            stopViewing(sendEnd = false)
        }
        if (sourcing.value?.screenSessionId == id) stopSourcing(sendEnd = false)
    }

    fun handleReject(payload: Json) {
        toast("Couldn't view that screen: ${payload.asObj().getValue("reason").str()}")
        stopViewing(sendEnd = false)
    }

    fun stopViewing(sendEnd: Boolean = true) {
        val session = viewing.value
        viewing.value = null
        decoder?.stop()
        decoder = null
        bulkLane?.close()
        bulkLane = null
        decodedFrames.value = 0
        if (sendEnd && session != null) {
            sendTo(session.peerId, MessageType.SCREEN_END, Bodies.screenEnd(session.screenSessionId))
        }
    }

    // ---- Source ------------------------------------------------------------

    /** SCREEN_REQUEST from a peer. The consent dialog is an Activity's job, so
     *  this only records who asked; the UI calls [startSourcing] on approval. */
    fun handleRequest(peerId: String) {
        if (sourcing.value != null) {
            sendTo(peerId, MessageType.SCREEN_REJECT, Bodies.screenReject("already sharing"))
            return
        }
        screenRequestFrom.value = peerId
    }

    fun declineRequest(peerId: String, reason: String = "declined") {
        screenRequestFrom.value = null
        sendTo(peerId, MessageType.SCREEN_REJECT, Bodies.screenReject(reason))
    }

    /**
     * Starts serving this device's screen to [peerId] from an already-granted
     * [ScreenProjectionSource]. Frames go over the session link — see the note
     * on the class about why there is no reverse dial here.
     */
    fun startSourcing(
        peerId: String, source: ScreenProjectionSource,
        width: Int, height: Int, fps: Int, deviceName: String, useHevc: Boolean,
    ) {
        screenRequestFrom.value = null
        val screenSessionId = UUID.randomUUID().toString()
        val wireSessionId = nextWireSession++
        sentSeq = 0
        projectionSource = source
        sourcing.value = Sourcing(peerId, screenSessionId, wireSessionId, width, height)

        sendTo(peerId, MessageType.SCREEN_OFFER, Bodies.screenOffer(
            screenSessionId = screenSessionId, wireSessionId = wireSessionId,
            codec = if (useHevc) "hevc" else "h264",
            width = width, height = height, fps = fps, captureKind = "display",
            sourceName = deviceName,
            // No dedicated lane is offered, so no token has anything to bind.
            // A viewer that dials anyway is refused by attachInboundLane.
            bulkToken = "",
        ))

        val startedAt = System.currentTimeMillis()
        source.start { isKeyframe, packed ->
            val current = sourcing.value ?: return@start
            val seq = sentSeq++
            sendFrameTo(current.peerId, ScreenFrame(
                sessionId = current.wireSessionId, seq = seq, isKeyframe = isKeyframe,
                ptsMillis = System.currentTimeMillis() - startedAt, data = packed,
            ))
        }
    }

    /** SCREEN_ACK from the viewer: honour keyframe requests. Bitrate adaptation
     *  is the encoder's business and MediaCodec exposes far less control than
     *  VideoToolbox, so this deliberately does the one thing that matters for
     *  a viewer recovering from a glitch. */
    fun handleAck(payload: Json) {
        val a = payload.asObj()
        if (sourcing.value?.screenSessionId != a.getValue("screen_session_id").str()) return
        if (a.getValue("request_keyframe").bool()) projectionSource?.requestKeyframe()
    }

    fun stopSourcing(sendEnd: Boolean = true) {
        val current = sourcing.value
        sourcing.value = null
        projectionSource?.stop()
        projectionSource = null
        if (sendEnd && current != null) {
            sendTo(current.peerId, MessageType.SCREEN_END, Bodies.screenEnd(current.screenSessionId))
        }
    }

    /** A peer's session dropped: end whatever it was involved in. */
    fun handleSessionClosed(peerId: String) {
        if (viewing.value?.peerId == peerId) stopViewing(sendEnd = false)
        if (sourcing.value?.peerId == peerId) stopSourcing(sendEnd = false)
        if (screenRequestFrom.value == peerId) screenRequestFrom.value = null
    }

    companion object {
        private const val TAG = "ScreenSessions"
        /** Ack every N frames — often enough for keyframe recovery to feel
         *  immediate, rare enough not to chatter at 30 fps. */
        private const val ACK_INTERVAL = 10
    }
}

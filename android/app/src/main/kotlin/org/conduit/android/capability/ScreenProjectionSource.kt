package org.conduit.android.capability

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import org.conduit.core.wire.EncodedVideoFrame
import org.conduit.core.wire.ScreenPacking
import java.nio.ByteBuffer

/**
 * Screen SOURCE via MediaProjection (spec §9 Phase 5 step 5): capture the
 * display into a virtual display, encode with MediaCodec (H.264/HEVC), and hand
 * each frame to a sink that packs it into the shared SCREEN_FRAME wire format —
 * so a Mac/iPad views the Android screen through the same viewer the Phase 3
 * work built. MediaProjection requires the system consent dialog every session
 * by design (spec pitfall); the caller obtains the projection first.
 */
class ScreenProjectionSource(
    private val projection: MediaProjection,
    private val displayManager: DisplayManager,
    private val width: Int,
    private val height: Int,
    private val dpi: Int,
    private val fps: Int = 30,
    private val useHevc: Boolean = false,
) {
    fun interface FrameSink {
        /** seq/pts/keyframe are assigned by the streaming layer; this delivers
         *  the packed frame data (parameter sets + sample). */
        fun onFrame(isKeyframe: Boolean, packed: ByteArray)
    }

    private var codec: MediaCodec? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private var parameterSets: List<ByteArray> = emptyList()

    fun start(sink: FrameSink) {
        val mime = if (useHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            // Low-latency where supported.
            setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        val enc = MediaCodec.createEncoderByType(mime)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = enc.createInputSurface()
        enc.start()
        codec = enc

        virtualDisplay = projection.createVirtualDisplay(
            "conduit-screen", width, height, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
        )

        running = true
        thread = Thread { drainLoop(enc, sink) }.apply { isDaemon = true; start() }
    }

    private fun drainLoop(enc: MediaCodec, sink: FrameSink) {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val index = enc.dequeueOutputBuffer(info, 10_000)
            if (index < 0) continue
            val buf: ByteBuffer = enc.getOutputBuffer(index) ?: continue
            val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
            val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            val bytes = ByteArray(info.size).also { buf.get(it) }
            if (isConfig) {
                // Codec config holds the parameter sets (SPS/PPS[/VPS]); split on
                // Annex-B start codes and remember them for every keyframe.
                parameterSets = splitAnnexB(bytes)
            } else {
                val frame = if (isKey)
                    EncodedVideoFrame(true, parameterSets, toLengthPrefixed(bytes))
                else
                    EncodedVideoFrame(false, emptyList(), toLengthPrefixed(bytes))
                sink.onFrame(isKey, ScreenPacking.pack(frame))
            }
            enc.releaseOutputBuffer(index, false)
        }
    }

    fun stop() {
        running = false
        thread?.join(500)
        virtualDisplay?.release()
        codec?.let { runCatching { it.stop() }; it.release() }
        projection.stop()
    }

    /** Splits an Annex-B stream (00 00 00 01 / 00 00 01 delimited) into NAL units. */
    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val nals = ArrayList<ByteArray>()
        var i = 0; var start = -1
        while (i < data.size - 3) {
            val sc = data[i].toInt() == 0 && data[i + 1].toInt() == 0 &&
                ((data[i + 2].toInt() == 1) || (data[i + 2].toInt() == 0 && i + 3 < data.size && data[i + 3].toInt() == 1))
            if (sc) {
                val scLen = if (data[i + 2].toInt() == 1) 3 else 4
                if (start >= 0) nals.add(data.copyOfRange(start, i))
                start = i + scLen; i += scLen
            } else i++
        }
        if (start in 0 until data.size) nals.add(data.copyOfRange(start, data.size))
        return nals
    }

    /** Annex-B (start-code) → AVCC (4-byte length prefix), matching the wire format. */
    private fun toLengthPrefixed(data: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (nal in splitAnnexB(data)) {
            val len = nal.size
            out.write(len ushr 24 and 0xFF); out.write(len ushr 16 and 0xFF)
            out.write(len ushr 8 and 0xFF); out.write(len and 0xFF)
            out.write(nal)
        }
        return out.toByteArray()
    }
}

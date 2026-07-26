package org.conduit.android.capability

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import org.conduit.core.wire.ScreenPacking
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Decodes an inbound `SCREEN_FRAME` stream onto a [Surface] — the piece the
 * Android app never had, and the reason it could not view a Mac's screen at all
 * (`android/README.md`: "no decoder, no SurfaceView; inbound screen frames are
 * dropped"). With it, "cast my Mac to a tablet" works natively instead of only
 * through the browser watch page.
 *
 * The wire carries AVCC — 4-byte-length-prefixed NAL units, with the parameter
 * sets travelling as raw NALs alongside every keyframe (docs/protocol.md
 * §"Screen sharing"). MediaCodec wants an Annex-B byte stream and its parameter
 * sets as `csd-0`/`csd-1`, so both are converted here. Getting that wrong
 * produces a permanently black surface with no error anywhere, which is why the
 * conversion is small, explicit, and unit-testable in isolation.
 *
 * Configuration waits for the first keyframe: only it carries the parameter
 * sets, and there is no side channel that would supply them earlier. Deltas
 * arriving before then are dropped rather than fed to an unconfigured codec.
 */
class ScreenDecoder(
    private val codecName: String,
    private val width: Int,
    private val height: Int,
) {
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    @Volatile private var running = false
    private var outputThread: Thread? = null
    /** Frames decoded, so the UI can tell "connecting" from "black screen". */
    @Volatile var decodedFrames: Long = 0
        private set
    @Volatile var lastError: String? = null
        private set

    private val mime: String
        get() = if (codecName.equals("hevc", ignoreCase = true)) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }

    fun attach(surface: Surface) {
        this.surface = surface
    }

    /**
     * Feeds one wire frame. Returns true if it was submitted to the codec.
     * Safe to call before a surface exists — frames are dropped until there is
     * somewhere to draw, which is what happens for the moment between the offer
     * arriving and the SurfaceView being laid out.
     */
    fun submit(packed: ByteArray, isKeyframe: Boolean, ptsMillis: Long): Boolean {
        val surface = this.surface ?: return false
        val frame = try {
            ScreenPacking.unpack(packed, isKeyframe)
        } catch (e: Exception) {
            lastError = "bad frame: ${e.message}"
            return false
        }
        if (codec == null) {
            if (!isKeyframe || frame.parameterSets.isEmpty()) return false
            if (!configure(frame.parameterSets, surface)) return false
        }
        val c = codec ?: return false
        // A keyframe repeats its parameter sets; prepend them so the decoder can
        // resynchronise after a glitch without a new configure.
        val payload = if (isKeyframe && frame.parameterSets.isNotEmpty()) {
            annexB(frame.parameterSets) + avccToAnnexB(frame.sampleData)
        } else {
            avccToAnnexB(frame.sampleData)
        }
        return try {
            val index = c.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (index < 0) return false     // codec busy; dropping is correct for live video
            val buffer: ByteBuffer = c.getInputBuffer(index) ?: return false
            buffer.clear()
            buffer.put(payload)
            val flags = if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            c.queueInputBuffer(index, 0, payload.size, ptsMillis * 1000, flags)
            true
        } catch (e: Exception) {
            lastError = "decode failed: ${e.message}"
            false
        }
    }

    private fun configure(parameterSets: List<ByteArray>, surface: Surface): Boolean {
        return try {
            val format = MediaFormat.createVideoFormat(mime, width, height).apply {
                // H.264 splits SPS and PPS across csd-0/csd-1; HEVC puts
                // VPS+SPS+PPS together in csd-0. Both want Annex-B start codes.
                if (mime == MediaFormat.MIMETYPE_VIDEO_AVC && parameterSets.size >= 2) {
                    setByteBuffer("csd-0", ByteBuffer.wrap(annexB(listOf(parameterSets[0]))))
                    setByteBuffer("csd-1", ByteBuffer.wrap(annexB(parameterSets.drop(1))))
                } else {
                    setByteBuffer("csd-0", ByteBuffer.wrap(annexB(parameterSets)))
                }
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            val c = MediaCodec.createDecoderByType(mime)
            c.configure(format, surface, null, 0)
            c.start()
            codec = c
            running = true
            outputThread = Thread { drainOutput(c) }.apply { isDaemon = true; start() }
            true
        } catch (e: Exception) {
            lastError = "no decoder for $mime: ${e.message}"
            Log.w(TAG, "decoder configure failed", e)
            false
        }
    }

    /** Releasing an output buffer with `render = true` draws it on the surface. */
    private fun drainOutput(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val index = try {
                c.dequeueOutputBuffer(info, OUTPUT_TIMEOUT_US)
            } catch (e: IllegalStateException) {
                return      // stopped underneath us
            }
            if (index >= 0) {
                try {
                    c.releaseOutputBuffer(index, true)
                    decodedFrames++
                } catch (_: IllegalStateException) {
                    return
                }
            }
        }
    }

    fun stop() {
        running = false
        outputThread?.join(500)
        outputThread = null
        codec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
        surface = null
    }

    companion object {
        private const val TAG = "ScreenDecoder"
        private const val INPUT_TIMEOUT_US = 10_000L
        private const val OUTPUT_TIMEOUT_US = 10_000L
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        /** Raw NAL units → an Annex-B byte stream. */
        fun annexB(nals: List<ByteArray>): ByteArray =
            ByteArrayOutputStream().apply {
                for (nal in nals) { write(START_CODE); write(nal) }
            }.toByteArray()

        /**
         * AVCC (4-byte big-endian length prefixes) → Annex-B (start codes).
         *
         * Returns the input unchanged if it does not parse as AVCC, so a source
         * that ever sends a raw Annex-B stream still plays rather than showing
         * black. Malformed input is truncated at the last valid NAL instead of
         * throwing: one corrupt frame should cost one frame.
         */
        fun avccToAnnexB(data: ByteArray): ByteArray {
            if (data.size < 4) return data
            val out = ByteArrayOutputStream(data.size + 16)
            var offset = 0
            while (offset + 4 <= data.size) {
                val length = ((data[offset].toInt() and 0xFF) shl 24) or
                    ((data[offset + 1].toInt() and 0xFF) shl 16) or
                    ((data[offset + 2].toInt() and 0xFF) shl 8) or
                    (data[offset + 3].toInt() and 0xFF)
                if (length <= 0 || offset + 4 + length > data.size) {
                    // Not length-prefixed (or truncated). If nothing has been
                    // converted yet, assume it was already Annex-B.
                    return if (out.size() == 0) data else out.toByteArray()
                }
                out.write(START_CODE)
                out.write(data, offset + 4, length)
                offset += 4 + length
            }
            return out.toByteArray()
        }
    }
}

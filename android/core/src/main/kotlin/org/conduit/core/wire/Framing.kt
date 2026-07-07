package org.conduit.core.wire

import java.io.ByteArrayOutputStream

/** TLV framing (spec §5.4): kind u8, length u32be, payload. Matches Swift + Go. */
object FrameKind {
    const val CONTROL: Int = 0x01
    const val FILE_CHUNK: Int = 0x02
    const val SCREEN_FRAME: Int = 0x03
}

const val CHUNK_HEADER_SIZE = 25          // uuid(16) + seq(8) + flags(1)
const val SCREEN_HEADER_SIZE = 15         // sessionId(2) + seq(4) + flags(1) + pts(8)
const val MAX_CONTROL = 1 shl 20
const val MAX_CHUNK_DATA = 2 shl 20
const val MAX_SCREEN_DATA = 4 shl 20

data class ChunkFrame(val fileId: ByteArray, val seq: Long, val isLast: Boolean, val data: ByteArray) {
    override fun equals(other: Any?) = other is ChunkFrame &&
        fileId.contentEquals(other.fileId) && seq == other.seq && isLast == other.isLast && data.contentEquals(other.data)
    override fun hashCode() = fileId.contentHashCode() * 31 + seq.hashCode()
}

data class ScreenFrame(val sessionId: Int, val seq: Long, val isKeyframe: Boolean, val ptsMillis: Long, val data: ByteArray) {
    override fun equals(other: Any?) = other is ScreenFrame &&
        sessionId == other.sessionId && seq == other.seq && isKeyframe == other.isKeyframe &&
        ptsMillis == other.ptsMillis && data.contentEquals(other.data)
    override fun hashCode() = sessionId * 31 + seq.hashCode()
}

sealed interface Frame {
    data class Control(val payload: ByteArray) : Frame
    data class Chunk(val frame: ChunkFrame) : Frame
    data class Screen(val frame: ScreenFrame) : Frame
}

object FrameCodec {
    fun encodeControl(json: ByteArray): ByteArray = ByteArrayOutputStream(5 + json.size).apply {
        write(FrameKind.CONTROL)
        writeU32(json.size)
        write(json)
    }.toByteArray()

    fun encodeChunk(c: ChunkFrame): ByteArray = ByteArrayOutputStream().apply {
        val len = CHUNK_HEADER_SIZE + c.data.size
        write(FrameKind.FILE_CHUNK); writeU32(len)
        write(c.fileId, 0, 16); writeU64(c.seq); write(if (c.isLast) 1 else 0); write(c.data)
    }.toByteArray()

    fun encodeScreen(s: ScreenFrame): ByteArray = ByteArrayOutputStream().apply {
        val len = SCREEN_HEADER_SIZE + s.data.size
        write(FrameKind.SCREEN_FRAME); writeU32(len)
        writeU16(s.sessionId); writeU32(s.seq.toInt()); write(if (s.isKeyframe) 1 else 0); writeU64(s.ptsMillis); write(s.data)
    }.toByteArray()

    private fun ByteArrayOutputStream.writeU16(v: Int) { write(v ushr 8 and 0xFF); write(v and 0xFF) }
    private fun ByteArrayOutputStream.writeU32(v: Int) {
        write(v ushr 24 and 0xFF); write(v ushr 16 and 0xFF); write(v ushr 8 and 0xFF); write(v and 0xFF)
    }
    private fun ByteArrayOutputStream.writeU64(v: Long) {
        for (shift in 56 downTo 0 step 8) write((v ushr shift and 0xFF).toInt())
    }
}

/** Incremental frame parser; skips unknown kinds (forward compatibility). */
class FrameReader {
    private var buf = ByteArray(0)
    var skippedUnknown = 0; private set

    fun append(data: ByteArray): List<Frame> {
        buf += data
        val out = ArrayList<Frame>()
        val maxAllowed = maxOf(MAX_CONTROL, MAX_CHUNK_DATA + CHUNK_HEADER_SIZE, MAX_SCREEN_DATA + SCREEN_HEADER_SIZE)
        while (buf.size >= 5) {
            val kind = buf[0].toInt() and 0xFF
            val len = u32(buf, 1)
            require(len <= maxAllowed) { "oversized frame ($len)" }
            if (buf.size < 5 + len) break
            val payload = buf.copyOfRange(5, 5 + len)
            buf = buf.copyOfRange(5 + len, buf.size)
            when (kind) {
                FrameKind.CONTROL -> out.add(Frame.Control(payload))
                FrameKind.FILE_CHUNK -> out.add(Frame.Chunk(decodeChunk(payload)))
                FrameKind.SCREEN_FRAME -> out.add(Frame.Screen(decodeScreen(payload)))
                else -> skippedUnknown++
            }
        }
        return out
    }

    private fun decodeChunk(p: ByteArray): ChunkFrame {
        require(p.size >= CHUNK_HEADER_SIZE) { "malformed chunk" }
        return ChunkFrame(p.copyOfRange(0, 16), u64(p, 16), p[24].toInt() != 0, p.copyOfRange(CHUNK_HEADER_SIZE, p.size))
    }

    private fun decodeScreen(p: ByteArray): ScreenFrame {
        require(p.size >= SCREEN_HEADER_SIZE) { "malformed screen frame" }
        val sid = (p[0].toInt() and 0xFF shl 8) or (p[1].toInt() and 0xFF)
        return ScreenFrame(sid, u32(p, 2).toLong(), p[6].toInt() != 0, u64(p, 7), p.copyOfRange(SCREEN_HEADER_SIZE, p.size))
    }

    private fun u32(b: ByteArray, off: Int): Int {
        var v = 0; for (i in 0 until 4) v = v shl 8 or (b[off + i].toInt() and 0xFF); return v
    }
    private fun u64(b: ByteArray, off: Int): Long {
        var v = 0L; for (i in 0 until 8) v = v shl 8 or (b[off + i].toLong() and 0xFF); return v
    }
}

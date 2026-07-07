package org.conduit.core.session

import org.conduit.core.identity.toHex
import org.conduit.core.wire.*
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/** HELLO negotiation (spec §5.4). Returns the remote's advertised capabilities. */
object HelloFlow {
    fun initiate(conn: FramedConnection, local: LocalIdentity, caps: List<String>, listenPort: Int?): Json {
        conn.setSessionId(UUID.randomUUID().toString())
        conn.send(MessageType.HELLO, local.helloBody(caps, listenPort))
        while (true) {
            val f = conn.nextFrame() as? Frame.Control ?: error("connection lost in hello")
            val (_, msg) = MessageCodec.decode(f.payload)
            if (msg.type == MessageType.HELLO_ACK) return msg.payload
        }
    }

    fun respond(conn: FramedConnection, hello: Json, sessionId: String, local: LocalIdentity, caps: List<String>, listenPort: Int?): Json {
        conn.setSessionId(sessionId)
        conn.send(MessageType.HELLO_ACK, local.helloBody(caps, listenPort))
        return hello
    }
}

/** Sender half of the file capability: offer, then pump chunks after accept. */
object FileSend {
    /** Sends a file over the connection's control lane and blocks until the
     *  receiver acks complete (or fails). The receiver must be pumped by the
     *  caller's read loop feeding [FileReceive]. Returns the file id. */
    fun offer(conn: FramedConnection, path: File): String {
        val (sha, size) = sha256AndSize(path)
        val chunkSize = Proto.DEFAULT_CHUNK_SIZE
        val chunkCount = if (size == 0L) 1L else (size + chunkSize - 1) / chunkSize
        val fileId = UUID.randomUUID().toString()
        conn.send(MessageType.FILE_OFFER, Bodies.fileOffer(fileId, path.name, size, "application/octet-stream", sha, chunkSize, chunkCount))
        return fileId
    }

    fun pump(conn: FramedConnection, path: File, fileId: String, resumeFrom: Long) {
        val uuid = uuidBytes(fileId)
        val chunkSize = Proto.DEFAULT_CHUNK_SIZE
        val size = path.length()
        val chunkCount = if (size == 0L) 1L else (size + chunkSize - 1) / chunkSize
        RandomAccessFile(path, "r").use { raf ->
            raf.seek(resumeFrom * chunkSize)
            var seq = resumeFrom
            val buf = ByteArray(chunkSize)
            while (seq < chunkCount) {
                val n = raf.read(buf).coerceAtLeast(0)
                val isLast = seq == chunkCount - 1
                conn.sendChunk(ChunkFrame(uuid, seq, isLast, buf.copyOfRange(0, n)))
                seq++
            }
        }
    }
}

/** Receiver half: accept an offer, write chunks, verify the SHA-256. */
class FileReceive(private val receiveDir: File) {
    private data class Incoming(val offer: FileOfferInfo, val out: RandomAccessFile, var received: Long = 0, val md: java.security.MessageDigest, val token: String)
    data class FileOfferInfo(val fileId: String, val name: String, val size: Long, val sha256: String, val chunkSize: Int, val chunkCount: Long)

    private val byId = HashMap<String, Incoming>()
    private val byUuid = HashMap<String, String>()
    var onComplete: ((File, FileOfferInfo) -> Unit)? = null

    fun handleOffer(conn: FramedConnection, payload: Json) {
        val o = payload.asObj()
        val info = FileOfferInfo(
            o.getValue("file_id").str(), o.getValue("name").str(), o.getValue("size").long(),
            o.getValue("sha256").str(), o.getValue("chunk_size").int(), o.getValue("chunk_count").long(),
        )
        receiveDir.mkdirs()
        val partial = File(receiveDir, info.sha256 + ".part")
        val raf = RandomAccessFile(partial, "rw").apply { setLength(0) }
        val token = UUID.randomUUID().toString().replace("-", "")
        byId[info.fileId] = Incoming(info, raf, 0, java.security.MessageDigest.getInstance("SHA-256"), token)
        byUuid[uuidBytes(info.fileId).toHex()] = info.fileId
        conn.send(MessageType.FILE_ACCEPT, Bodies.fileAccept(info.fileId, 0, token))
    }

    /** Feed each chunk frame; returns true when a transfer finished. */
    fun handleChunk(conn: FramedConnection, chunk: ChunkFrame): Boolean {
        val fileId = byUuid[chunk.fileId.toHex()] ?: return false
        val t = byId[fileId] ?: return false
        if (chunk.seq != t.received) { fail(conn, fileId, "out-of-order"); return true }
        t.out.write(chunk.data)
        t.md.update(chunk.data)
        t.received++
        val isFinal = chunk.isLast || t.received == t.offer.chunkCount
        if (t.received % 16 == 0L && !isFinal)
            conn.send(MessageType.FILE_ACK, Bodies.fileAck(fileId, "progress", t.received))
        if (isFinal) { finalize(conn, fileId); return true }
        return false
    }

    private fun finalize(conn: FramedConnection, fileId: String) {
        val t = byId.remove(fileId)!!
        byUuid.remove(uuidBytes(fileId).toHex())
        t.out.close()
        val digest = t.md.digest().toHex()
        val partial = File(receiveDir, t.offer.sha256 + ".part")
        if (digest != t.offer.sha256) {
            partial.delete()
            conn.send(MessageType.FILE_ACK, Bodies.fileAck(fileId, "hash_mismatch", t.received, "sha256 mismatch"))
            return
        }
        val dest = uniqueDest(receiveDir, t.offer.name)
        partial.renameTo(dest)
        conn.send(MessageType.FILE_ACK, Bodies.fileAck(fileId, "complete", t.received))
        onComplete?.invoke(dest, t.offer)
    }

    private fun fail(conn: FramedConnection, fileId: String, reason: String) {
        byId.remove(fileId)?.out?.close()
        conn.send(MessageType.FILE_ACK, Bodies.fileAck(fileId, "error", 0, reason))
    }
}

// --- helpers ---

fun sha256AndSize(path: File): Pair<String, Long> {
    val md = java.security.MessageDigest.getInstance("SHA-256")
    var size = 0L
    path.inputStream().use { s ->
        val buf = ByteArray(1 shl 20)
        while (true) { val n = s.read(buf); if (n < 0) break; md.update(buf, 0, n); size += n }
    }
    return md.digest().toHex() to size
}

fun uuidBytes(id: String): ByteArray {
    val u = UUID.fromString(id)
    return ByteArray(16).also {
        var hi = u.mostSignificantBits; var lo = u.leastSignificantBits
        for (i in 7 downTo 0) { it[i] = (hi and 0xFF).toByte(); hi = hi ushr 8 }
        for (i in 15 downTo 8) { it[i] = (lo and 0xFF).toByte(); lo = lo ushr 8 }
    }
}

private fun uniqueDest(dir: File, name: String): File {
    val base = File(dir, name)
    if (!base.exists()) return base
    val dot = name.lastIndexOf('.')
    val stem = if (dot > 0) name.substring(0, dot) else name
    val ext = if (dot > 0) name.substring(dot) else ""
    for (i in 2..9999) { val c = File(dir, "$stem ($i)$ext"); if (!c.exists()) return c }
    return base
}

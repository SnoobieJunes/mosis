package org.conduit.core

import org.conduit.core.identity.Identity
import org.conduit.core.session.*
import org.conduit.core.wire.*
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Kotlin↔Kotlin, in-process, real crypto: two nodes pair (real Ed25519 binding
 * + pairing-code cross-check), run HELLO, transfer a 2 MiB file with SHA-256
 * verification, and exchange clipboard. Proves the Kotlin session/pairing/file
 * logic works end-to-end; wire compatibility with Swift + Go is proven
 * separately by conformance. Runnable with a bare JVM (no test framework):
 *
 *   java -cp conduit-core.jar org.conduit.core.SessionSmoke
 */
object SessionSmoke {
    /** Thread-agnostic in-memory pipe (unlike java.io.Piped*, it doesn't die
     *  when the writing thread exits). One writer end feeds one reader end. */
    private class Pipe {
        private val buf = ArrayDeque<Byte>()
        private val lock = Object()
        private var closed = false
        val sink = object : OutputStream() {
            override fun write(b: Int) = synchronized(lock) { buf.addLast(b.toByte()); lock.notifyAll() }
            override fun write(b: ByteArray, off: Int, len: Int) = synchronized(lock) {
                for (i in off until off + len) buf.addLast(b[i]); lock.notifyAll()
            }
        }
        val source = object : InputStream() {
            override fun read(): Int = synchronized(lock) {
                while (buf.isEmpty()) { if (closed) return -1; lock.wait() }
                buf.removeFirst().toInt() and 0xFF
            }
            override fun read(b: ByteArray, off: Int, len: Int): Int = synchronized(lock) {
                while (buf.isEmpty()) { if (closed) return -1; lock.wait() }
                var n = 0
                while (n < len && buf.isNotEmpty()) { b[off + n] = buf.removeFirst(); n++ }
                n
            }
        }
        fun close() = synchronized(lock) { closed = true; lock.notifyAll() }
    }

    private class MemoryStream(
        override val input: InputStream,
        override val output: OutputStream,
        override val peerTlsKeyHash: ByteArray?,
        private val onClose: () -> Unit,
    ) : ByteStream {
        override fun close() = onClose()
        companion object {
            fun pair(hashA: ByteArray, hashB: ByteArray): Pair<MemoryStream, MemoryStream> {
                val aToB = Pipe(); val bToA = Pipe()  // A writes aToB, reads bToA
                val a = MemoryStream(bToA.source, aToB.sink, hashB) { aToB.close(); bToA.close() }
                val b = MemoryStream(aToB.source, bToA.sink, hashA) { aToB.close(); bToA.close() }
                return a to b
            }
        }
    }

    private fun local(name: String): LocalIdentity {
        val id = Identity.generate()
        return LocalIdentity(id, name, "desktop", sha256(id.publicKeyRaw + name.toByteArray()))
    }

    private fun check(cond: Boolean, msg: String) { if (!cond) throw AssertionError("FAIL: $msg") }

    @JvmStatic
    fun main(args: Array<String>) {
        val a = local("Pixel")
        val b = local("Mac")
        val (sa, sb) = MemoryStream.pair(a.tlsKeyHash, b.tlsKeyHash)
        val connA = FramedConnection(sa)
        val connB = FramedConnection(sb)

        // Pairing (B responds, A initiates).
        var outcomeB: PairOutcome? = null
        val tB = thread {
            val first = connB.nextFrame() as Frame.Control
            val (env, msg) = MessageCodec.decode(first.payload)
            check(msg.type == MessageType.PAIR_REQUEST, "expected PAIR_REQUEST")
            outcomeB = PairingFlow.respond(connB, msg.payload, env.sessionId, b) { true }
        }
        val outcomeA = PairingFlow.initiate(connA, a) { true }
        tB.join()
        val pa = (outcomeA as PairOutcome.Paired).peer
        val pb = (outcomeB as PairOutcome.Paired).peer
        check(pa.deviceId == b.identity.deviceId, "A pinned wrong device")
        check(pb.deviceId == a.identity.deviceId, "B pinned wrong device")
        check(pa.tlsPubkeySha256.contentEquals(b.tlsKeyHash), "A pinned wrong TLS hash")
        println("  ok   pairing (both sides pinned, codes matched)")

        // HELLO.
        val caps = listOf(Proto.CAP_FILE, Proto.CAP_CLIPBOARD)
        val tHello = thread {
            val first = connB.nextFrame() as Frame.Control
            val (env, msg) = MessageCodec.decode(first.payload)
            check(msg.type == MessageType.HELLO, "expected HELLO")
            HelloFlow.respond(connB, msg.payload, env.sessionId, b, caps, null)
        }
        val remoteOnA = HelloFlow.initiate(connA, a, caps, null)
        tHello.join()
        check(remoteOnA.asObj().getValue("identity").str() == b.identity.deviceId, "HELLO identity mismatch")
        println("  ok   HELLO negotiation")

        // File A→B + clipboard, driven by B's read loop.
        val recvDir = Files.createTempDirectory("conduit-kt").toFile()
        val receiver = FileReceive(recvDir)
        val completed = CountDownLatch(1)
        var saved: File? = null
        receiver.onComplete = { f, _ -> saved = f; completed.countDown() }
        val gotClip = CountDownLatch(1)
        var clip: String? = null
        thread {
            while (true) {
                when (val frame = connB.nextFrame() ?: break) {
                    is Frame.Control -> {
                        val (_, msg) = MessageCodec.decode(frame.payload)
                        when (msg.type) {
                            MessageType.FILE_OFFER -> receiver.handleOffer(connB, msg.payload)
                            MessageType.CLIPBOARD_PUSH -> {
                                clip = String(msg.payload.asObj().getValue("data").bytes(), Charsets.UTF_8); gotClip.countDown()
                            }
                        }
                    }
                    is Frame.Chunk -> receiver.handleChunk(connB, frame.frame)
                    else -> {}
                }
            }
        }

        val src = File.createTempFile("payload", ".bin")
        val payload = ByteArray(2 * 1024 * 1024).also { java.util.Random(42).nextBytes(it) }
        src.writeBytes(payload)
        val wantSha = sha256AndSize(src).first

        val fileId = FileSend.offer(connA, src)
        val doneAck = CountDownLatch(1)
        thread {
            while (true) {
                val f = connA.nextFrame() as? Frame.Control ?: break
                val (_, msg) = MessageCodec.decode(f.payload)
                when (msg.type) {
                    MessageType.FILE_ACCEPT -> FileSend.pump(connA, src, fileId, msg.payload.asObj().getValue("resume_from_chunk").long())
                    MessageType.FILE_ACK -> if (msg.payload.asObj().getValue("status").str() == "complete") doneAck.countDown()
                }
            }
        }
        check(completed.await(20, TimeUnit.SECONDS), "file not received")
        check(doneAck.await(5, TimeUnit.SECONDS), "sender saw no complete ack")
        check(saved!!.readBytes().contentEquals(payload), "received bytes differ")
        check(sha256AndSize(saved!!).first == wantSha, "received hash mismatch")
        println("  ok   2 MiB file transfer (hash verified)")

        connA.send(MessageType.CLIPBOARD_PUSH, Bodies.clipboardText("hello from kotlin ✓"))
        check(gotClip.await(5, TimeUnit.SECONDS), "clipboard not received")
        check(clip == "hello from kotlin ✓", "clipboard mismatch")
        println("  ok   clipboard round-trip")

        connA.close(); connB.close()
        println("\nKotlin session smoke: PASS")
    }
}

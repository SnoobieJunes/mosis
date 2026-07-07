package org.conduit.core.session

import org.conduit.core.identity.Identity
import org.conduit.core.identity.Pairing
import org.conduit.core.identity.fromHex
import org.conduit.core.identity.toHex
import org.conduit.core.wire.*
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * Transport-agnostic session layer in Kotlin: pairing ceremony, HELLO
 * negotiation, and the file/clipboard capabilities over any bidirectional byte
 * stream. The Android app plugs in TLS sockets; tests plug in an in-process
 * pipe. The wire is identical to Swift + Go (proven by conformance), so a Kotlin
 * node interoperates with them.
 */

/** A bidirectional byte stream (a TLS socket in the app, a pipe in tests). */
interface ByteStream {
    val input: InputStream
    val output: OutputStream
    /** SHA-256 of the peer's TLS public key (X9.63); null in plaintext tests. */
    val peerTlsKeyHash: ByteArray?
    fun close()
}

/** A paired device (spec §7): identity pinned at pairing. */
data class PinnedPeer(
    val deviceId: String,
    val name: String,
    val deviceClass: String,
    val ed25519Pubkey: ByteArray,
    val tlsPubkeySha256: ByteArray,
)

data class PairPrompt(val code: String, val wordA: String, val wordB: String, val remoteName: String)

class LocalIdentity(
    val identity: Identity,
    val name: String,
    val deviceClass: String,
    /** SHA-256 of this device's TLS public key; matched by the peer's pinning. */
    val tlsKeyHash: ByteArray,
) {
    fun pairBody(): Json = Bodies.pair(
        identity = identity.deviceId, name = name, deviceClass = deviceClass,
        pubkey = identity.publicKeyRaw, tlsHashHex = tlsKeyHash.toHex(),
        bindingSig = identity.signTlsBinding(tlsKeyHash),
    )
    fun helloBody(caps: List<String>, listenPort: Int?): Json = Bodies.hello(
        identity = identity.deviceId, name = name, deviceClass = deviceClass, appVersion = "conduit-kt",
        pubkey = identity.publicKeyRaw, capabilities = caps, platformWalls = emptyList(), listenPort = listenPort,
    )
}

/** Adds Conduit TLV framing + envelope sequencing to a byte stream. */
class FramedConnection(val stream: ByteStream) {
    private val reader = FrameReader()
    private val pending = ArrayDeque<Frame>()
    private var sessionId = ""
    private val seq = AtomicLong(0)
    private val buf = ByteArray(64 * 1024)

    fun setSessionId(id: String) { sessionId = id }

    fun nextFrame(): Frame? {
        while (pending.isEmpty()) {
            val n = stream.input.read(buf)
            if (n < 0) return null
            if (n > 0) reader.append(buf.copyOfRange(0, n)).forEach { pending.addLast(it) }
        }
        return pending.removeFirst()
    }

    @Synchronized
    fun send(type: String, payload: Json) {
        val bytes = MessageCodec.encode(sessionId, seq.getAndIncrement(), type, payload)
        stream.output.write(FrameCodec.encodeControl(bytes))
        stream.output.flush()
    }

    @Synchronized
    fun sendChunk(chunk: ChunkFrame) {
        stream.output.write(FrameCodec.encodeChunk(chunk))
        stream.output.flush()
    }

    fun close() = stream.close()
}

sealed class PairOutcome {
    data class Paired(val peer: PinnedPeer) : PairOutcome()
    data class Failed(val reason: String) : PairOutcome()
    object Declined : PairOutcome()
}

object PairingFlow {
    /** Initiator: send PAIR_REQUEST, await PAIR_RESPONSE, confirm, exchange PAIR_CONFIRM. */
    fun initiate(conn: FramedConnection, local: LocalIdentity, confirm: (PairPrompt) -> Boolean): PairOutcome {
        conn.setSessionId(UUID.randomUUID().toString())
        conn.send(MessageType.PAIR_REQUEST, local.pairBody())
        val remote = expectPair(conn, MessageType.PAIR_RESPONSE) ?: return PairOutcome.Failed("no response")
        return complete(conn, local, remote, confirm)
    }

    /** Responder: caller already read PAIR_REQUEST; reply PAIR_RESPONSE, confirm. */
    fun respond(conn: FramedConnection, request: Json, requestSession: String, local: LocalIdentity, confirm: (PairPrompt) -> Boolean): PairOutcome {
        conn.setSessionId(requestSession)
        conn.send(MessageType.PAIR_RESPONSE, local.pairBody())
        return complete(conn, local, request, confirm)
    }

    private fun complete(conn: FramedConnection, local: LocalIdentity, remote: Json, confirm: (PairPrompt) -> Boolean): PairOutcome {
        val r = remote.asObj()
        val remotePub = r.getValue("pubkey").bytes()
        val remoteIdentity = r.getValue("identity").str()
        val remoteName = r.getValue("name").str()
        val tlsHashHex = r.getValue("tls_pubkey_sha256").str()
        val bindingSig = r.getValue("binding_sig").bytes()

        // Validate: identity==hash(pubkey), binding signature, and the presented
        // TLS key matches the signed one (defeats a TLS-terminating MITM).
        if (Identity.deviceId(remotePub) != remoteIdentity)
            return reject(conn, "identity mismatch")
        if (!Identity.verifyTlsBinding(bindingSig, tlsHashHex.fromHex(), remotePub))
            return reject(conn, "invalid binding")
        val presented = conn.stream.peerTlsKeyHash
        if (presented != null && presented.toHex() != tlsHashHex)
            return reject(conn, "tls key substituted")

        val code = Pairing.verificationCode(local.identity.publicKeyRaw, remotePub)
        val (wA, wB) = Pairing.verificationWords(local.identity.publicKeyRaw, remotePub)
        if (!confirm(PairPrompt(code, wA, wB, remoteName))) {
            conn.send(MessageType.PAIR_REJECT, Bodies.pairReject("declined"))
            return PairOutcome.Declined
        }
        conn.send(MessageType.PAIR_CONFIRM, Bodies.empty())
        if (!expectConfirm(conn)) return PairOutcome.Failed("peer rejected")
        return PairOutcome.Paired(PinnedPeer(remoteIdentity, remoteName, r.getValue("device_class").str(), remotePub, tlsHashHex.fromHex()))
    }

    private fun reject(conn: FramedConnection, reason: String): PairOutcome {
        conn.send(MessageType.PAIR_REJECT, Bodies.pairReject(reason))
        return PairOutcome.Failed(reason)
    }

    private fun expectPair(conn: FramedConnection, want: String): Json? {
        while (true) {
            val frame = conn.nextFrame() as? Frame.Control ?: return null
            val (_, msg) = MessageCodec.decode(frame.payload)
            when (msg.type) {
                want -> return msg.payload
                MessageType.PAIR_REJECT -> return null
                else -> {}
            }
        }
    }

    private fun expectConfirm(conn: FramedConnection): Boolean {
        while (true) {
            val frame = conn.nextFrame() as? Frame.Control ?: return false
            val (_, msg) = MessageCodec.decode(frame.payload)
            when (msg.type) {
                MessageType.PAIR_CONFIRM -> return true
                MessageType.PAIR_REJECT -> return false
                else -> {}
            }
        }
    }
}

/** SHA-256 helper for TLS key hashes / file hashes. */
fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

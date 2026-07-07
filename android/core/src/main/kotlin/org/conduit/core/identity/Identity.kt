package org.conduit.core.identity

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.EdECPrivateKeySpec
import java.security.spec.NamedParameterSpec
import java.security.spec.X509EncodedKeySpec

/**
 * Device identity in Kotlin/JVM, matching Swift + Go byte-for-byte (spec §5.2,
 * docs/protocol.md §Security). Ed25519 via the JDK (Java 15+); the device ID is
 * lowercase-hex SHA-256 of the raw 32-byte public key.
 */
class Identity(val privateSeed: ByteArray, val publicKeyRaw: ByteArray) {

    val deviceId: String get() = deviceId(publicKeyRaw)

    /** Ed25519 signature over "conduit-tls-binding-v1" || tlsKeyHash (docs/adr/0002). */
    fun signTlsBinding(tlsKeyHash: ByteArray): ByteArray = sign(TLS_BINDING_CONTEXT + tlsKeyHash)

    private fun sign(message: ByteArray): ByteArray {
        val kf = KeyFactory.getInstance("Ed25519")
        val priv = kf.generatePrivate(EdECPrivateKeySpec(NamedParameterSpec.ED25519, privateSeed))
        return Signature.getInstance("Ed25519").run { initSign(priv); update(message); sign() }
    }

    companion object {
        val TLS_BINDING_CONTEXT = "conduit-tls-binding-v1".toByteArray(Charsets.UTF_8)

        fun generate(): Identity {
            val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return fromSeed(seed)
        }

        /**
         * Deterministic identity from a 32-byte Ed25519 seed (used by vectors).
         * The public key is derived by seeding the JDK generator's RNG with the
         * seed — the Ed25519 generator consumes exactly 32 bytes as its private
         * seed — then reading the raw point from the SPKI encoding. No
         * hand-rolled curve arithmetic.
         */
        fun fromSeed(seed: ByteArray): Identity {
            require(seed.size == 32) { "Ed25519 seed must be 32 bytes" }
            val fixedRng = object : SecureRandom() {
                override fun nextBytes(bytes: ByteArray) {
                    require(bytes.size == 32) { "unexpected RNG draw of ${bytes.size}" }
                    seed.copyInto(bytes)
                }
            }
            val kpg = KeyPairGenerator.getInstance("Ed25519")
            kpg.initialize(NamedParameterSpec.ED25519, fixedRng)
            val kp = kpg.generateKeyPair()
            val enc = kp.public.encoded            // X.509 SPKI; last 32 bytes = raw point
            val pubRaw = enc.copyOfRange(enc.size - 32, enc.size)
            return Identity(seed, pubRaw)
        }

        fun deviceId(publicKeyRaw: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(publicKeyRaw).toHex()

        fun verifyTlsBinding(sig: ByteArray, tlsKeyHash: ByteArray, publicKeyRaw: ByteArray): Boolean {
            return try {
                val pub = publicKeyFromRaw(publicKeyRaw)
                Signature.getInstance("Ed25519").run {
                    initVerify(pub); update(TLS_BINDING_CONTEXT + tlsKeyHash); verify(sig)
                }
            } catch (_: Exception) {
                false
            }
        }

        // --- JDK key <-> raw-bytes plumbing ---

        private fun publicKeyFromRaw(raw: ByteArray): java.security.PublicKey {
            // Wrap the raw 32-byte point in an X.509 SubjectPublicKeyInfo for the
            // JDK KeyFactory: SEQ { SEQ { OID 1.3.101.112 } BIT STRING(raw) }.
            val spki = ED25519_SPKI_PREFIX + raw
            return KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(spki))
        }

        // DER prefix for an Ed25519 SubjectPublicKeyInfo (12 bytes) + 32-byte key.
        private val ED25519_SPKI_PREFIX = byteArrayOf(
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        )
    }
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
fun String.fromHex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

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

    /**
     * Proves the seed and the public key are actually a pair, by signing with
     * one and verifying with the other.
     *
     * Every peer verifies our TLS binding signature against the public key we
     * advertise. A mismatched pair therefore fails at the far end, during
     * pairing, as an opaque rejection — the kind of bug that reads as "the
     * network is broken". One signature at startup turns that into an
     * immediate, local, named failure.
     */
    fun assertConsistent() {
        val probe = ByteArray(32) { it.toByte() }
        val ok = try {
            verifyTlsBinding(signTlsBinding(probe), probe, publicKeyRaw)
        } catch (e: Exception) {
            throw IllegalStateException("Ed25519 identity is unusable on this platform: $e", e)
        }
        check(ok) {
            "Ed25519 seed and public key do not match — this platform's key generator " +
                "does not derive the public key from the supplied seed."
        }
    }

    private fun sign(message: ByteArray): ByteArray {
        val kf = KeyFactory.getInstance("Ed25519")
        val priv = kf.generatePrivate(EdECPrivateKeySpec(NamedParameterSpec.ED25519, privateSeed))
        return Signature.getInstance("Ed25519").run { initSign(priv); update(message); sign() }
    }

    companion object {
        val TLS_BINDING_CONTEXT = "conduit-tls-binding-v1".toByteArray(Charsets.UTF_8)

        /**
         * Mints a fresh identity using the platform's own Ed25519 generator, and
         * reads BOTH halves out of the standard RFC 8410 encodings:
         * the raw point is the last 32 bytes of the X.509 SPKI, and the seed is
         * the last 32 bytes of the PKCS#8 `CurvePrivateKey` OCTET STRING.
         *
         * It deliberately does not go through [fromSeed]. That path assumes the
         * generator draws its private seed as a single 32-byte read from the
         * `SecureRandom` it is handed — true of OpenJDK's SunEC, false of
         * Android's BoringSSL-backed Conscrypt, which generates the key
         * internally and ignores the supplied RNG. On a phone that produced a
         * public key unrelated to the stored seed, so the TLS binding signature
         * never verified and **pairing with a Mac could not succeed** — while the
         * JVM conformance suite stayed green, because it runs on OpenJDK.
         */
        fun generate(): Identity {
            val kpg = KeyPairGenerator.getInstance("Ed25519")
            kpg.initialize(NamedParameterSpec.ED25519, SecureRandom())
            val kp = kpg.generateKeyPair()
            val spki = kp.public.encoded
            val pkcs8 = kp.private.encoded
            require(spki.size >= 32 && pkcs8.size >= 32) { "unexpected Ed25519 key encoding" }
            val pubRaw = spki.copyOfRange(spki.size - 32, spki.size)
            val seed = pkcs8.copyOfRange(pkcs8.size - 32, pkcs8.size)
            return Identity(seed, pubRaw).also { it.assertConsistent() }
        }

        /**
         * Deterministic identity from a 32-byte Ed25519 seed — the golden
         * vectors need this, and they run on the JVM.
         *
         * On platforms whose generator ignores the supplied RNG (Android's
         * Conscrypt) the derived public key is wrong. Rather than mint a
         * silently-broken identity that fails every handshake later, the result
         * is verified here and the failure is named at the point of derivation.
         * Android does not depend on this path: [generate] takes both halves
         * from the platform, and both are persisted (see `ConduitRuntime`).
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
            return Identity(seed, pubRaw).also { it.assertConsistent() }
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

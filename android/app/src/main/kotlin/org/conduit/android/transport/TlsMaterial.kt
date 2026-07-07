package org.conduit.android.transport

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Date

/**
 * The TLS half of a device's identity: a P-256 key in a long-lived self-signed
 * certificate. The pinned value is SHA-256 over the public key in X9.63
 * uncompressed form (0x04‖X‖Y) — identical to what Apple's Security framework
 * and the Go core compute, so all four implementations pin the same hash
 * (docs/adr/0002). BouncyCastle only for the cert builder Android's stdlib lacks.
 */
class TlsMaterial(
    val certificate: X509Certificate,
    val privateKey: PrivateKey,
    val publicKeyHash: ByteArray,
) {
    companion object {
        fun generate(commonName: String): TlsMaterial {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            val kp = kpg.generateKeyPair()
            val now = System.currentTimeMillis()
            val name = X500Name("CN=$commonName")
            val builder = JcaX509v3CertificateBuilder(
                name, BigInteger.valueOf(now), Date(now - 86_400_000L),
                Date(now + 20L * 365 * 86_400_000L), name, kp.public,
            )
            val signer = JcaContentSignerBuilder("SHA256withECDSA").build(kp.private)
            val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
            return TlsMaterial(cert, kp.private, publicKeyHashX963(kp.public as ECPublicKey))
        }

        /** SHA-256 over the X9.63 uncompressed EC point (0x04 ‖ X ‖ Y). */
        fun publicKeyHashX963(pub: ECPublicKey): ByteArray {
            val fieldSize = 32
            val x = toFixed(pub.w.affineX, fieldSize)
            val y = toFixed(pub.w.affineY, fieldSize)
            val point = ByteArray(1 + 2 * fieldSize)
            point[0] = 0x04
            x.copyInto(point, 1)
            y.copyInto(point, 1 + fieldSize)
            return MessageDigest.getInstance("SHA-256").digest(point)
        }

        private fun toFixed(v: BigInteger, size: Int): ByteArray {
            var b = v.toByteArray()
            if (b.size > size) b = b.copyOfRange(b.size - size, b.size)   // strip sign byte
            if (b.size < size) b = ByteArray(size - b.size) + b            // left-pad
            return b
        }
    }
}

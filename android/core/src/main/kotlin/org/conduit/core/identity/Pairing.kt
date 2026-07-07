package org.conduit.core.identity

import java.security.MessageDigest

/** Pairing fingerprint derivation, byte-identical to Swift + Go (docs/adr/0004). */
object Pairing {
    private val CONTEXT = "conduit-pairing-v1".toByteArray(Charsets.UTF_8)

    private fun material(pubA: ByteArray, pubB: ByteArray): ByteArray {
        val cmp = compareBytes(pubA, pubB)
        val (low, high) = if (cmp <= 0) pubA to pubB else pubB to pubA
        return MessageDigest.getInstance("SHA-256").run { update(CONTEXT); update(low); update(high); digest() }
    }

    /** Six-digit confirmation code, zero-padded. */
    fun verificationCode(pubA: ByteArray, pubB: ByteArray): String {
        val m = material(pubA, pubB)
        val v = ((m[0].toLong() and 0xFF) shl 24) or ((m[1].toLong() and 0xFF) shl 16) or
            ((m[2].toLong() and 0xFF) shl 8) or (m[3].toLong() and 0xFF)
        return (v % 1_000_000).toString().padStart(6, '0')
    }

    /** Word pair from bytes 4 and 5 of the material. */
    fun verificationWords(pubA: ByteArray, pubB: ByteArray): Pair<String, String> {
        val m = material(pubA, pubB)
        return WORDLIST[m[4].toInt() and 0xFF] to WORDLIST[m[5].toInt() and 0xFF]
    }

    private fun compareBytes(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val d = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (d != 0) return d
        }
        return a.size - b.size
    }
}

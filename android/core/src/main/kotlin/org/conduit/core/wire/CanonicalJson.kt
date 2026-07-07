package org.conduit.core.wire

/**
 * Conduit's canonical JSON, byte-for-byte identical to the Swift and Go
 * implementations (docs/protocol.md): keys sorted at every level, no inserted
 * whitespace, forward slashes and non-ASCII left unescaped, integers left as
 * integers, byte arrays as base64.
 *
 * Hand-rolled with zero dependencies so the core compiles with a bare kotlinc
 * and runs on any JVM (and, unchanged, inside the Android app). A tiny JSON
 * value model plus a deterministic serializer is all it takes; the serializer
 * IS the canonical form, so there is no "parse then re-canonicalize" step.
 */
sealed interface Json {
    data class Obj(val entries: Map<String, Json>) : Json
    data class Arr(val items: List<Json>) : Json
    data class Str(val value: String) : Json
    /** Integer kept as text so 64-bit values never round-trip through a double. */
    data class Num(val literal: String) : Json
    data class Bool(val value: Boolean) : Json
    data object Null : Json

    companion object {
        fun obj(vararg pairs: Pair<String, Json>) = Obj(pairs.toMap())
        fun of(n: Long) = Num(n.toString())
        fun of(n: Int) = Num(n.toString())
        fun of(b: Boolean) = Bool(b)
        fun of(s: String) = Str(s)
        fun bytes(b: ByteArray) = Str(Base64.encode(b))
    }
}

object CanonicalJson {
    /** Serializes to the canonical byte sequence (UTF-8). */
    fun encode(value: Json): ByteArray {
        val sb = StringBuilder()
        write(value, sb)
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    private fun write(value: Json, sb: StringBuilder) {
        when (value) {
            is Json.Obj -> {
                sb.append('{')
                var first = true
                // Keys sorted by UTF-16 code unit — matches Swift's .sortedKeys
                // and Go's map-key ordering for the ASCII keys the protocol uses.
                for (key in value.entries.keys.sorted()) {
                    if (!first) sb.append(',')
                    first = false
                    writeString(key, sb)
                    sb.append(':')
                    write(value.entries.getValue(key), sb)
                }
                sb.append('}')
            }
            is Json.Arr -> {
                sb.append('[')
                value.items.forEachIndexed { i, item ->
                    if (i > 0) sb.append(',')
                    write(item, sb)
                }
                sb.append(']')
            }
            is Json.Str -> writeString(value.value, sb)
            is Json.Num -> sb.append(value.literal)
            is Json.Bool -> sb.append(if (value.value) "true" else "false")
            Json.Null -> sb.append("null")
        }
    }

    /**
     * String escaping matching Swift's JSONEncoder(.withoutEscapingSlashes) and
     * Go's SetEscapeHTML(false): escape only the JSON-mandatory control set and
     * the two required characters (" and \\). Slashes, <, >, &, and non-ASCII
     * are emitted raw as UTF-8.
     */
    private fun writeString(s: String, sb: StringBuilder) {
        sb.append('"')
        for (ch in s) {
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (ch < ' ') {
                    sb.append("\\u").append(ch.code.toString(16).padStart(4, '0'))
                } else {
                    sb.append(ch)
                }
            }
        }
        sb.append('"')
    }
}

/** Base64 (standard alphabet, padded) matching Swift Data / Go []byte encoding. */
object Base64 {
    private val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray()
    private val INVERSE = IntArray(128) { -1 }.also { inv ->
        ALPHABET.forEachIndexed { i, c -> inv[c.code] = i }
    }

    fun encode(data: ByteArray): String {
        val sb = StringBuilder((data.size + 2) / 3 * 4)
        var i = 0
        while (i + 3 <= data.size) {
            val n = (data[i].toInt() and 0xFF shl 16) or (data[i + 1].toInt() and 0xFF shl 8) or (data[i + 2].toInt() and 0xFF)
            sb.append(ALPHABET[n ushr 18 and 63]).append(ALPHABET[n ushr 12 and 63])
                .append(ALPHABET[n ushr 6 and 63]).append(ALPHABET[n and 63])
            i += 3
        }
        when (data.size - i) {
            1 -> {
                val n = data[i].toInt() and 0xFF shl 16
                sb.append(ALPHABET[n ushr 18 and 63]).append(ALPHABET[n ushr 12 and 63]).append("==")
            }
            2 -> {
                val n = (data[i].toInt() and 0xFF shl 16) or (data[i + 1].toInt() and 0xFF shl 8)
                sb.append(ALPHABET[n ushr 18 and 63]).append(ALPHABET[n ushr 12 and 63]).append(ALPHABET[n ushr 6 and 63]).append('=')
            }
        }
        return sb.toString()
    }

    fun decode(s: String): ByteArray {
        val clean = s.filter { it != '\n' && it != '\r' }
        val out = ArrayList<Byte>(clean.length / 4 * 3)
        var buffer = 0
        var bits = 0
        for (c in clean) {
            if (c == '=') break
            val v = if (c.code < 128) INVERSE[c.code] else -1
            require(v >= 0) { "invalid base64 char" }
            buffer = buffer shl 6 or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.add((buffer ushr bits and 0xFF).toByte())
            }
        }
        return out.toByteArray()
    }
}

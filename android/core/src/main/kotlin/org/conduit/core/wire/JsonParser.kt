package org.conduit.core.wire

/** Minimal recursive-descent JSON parser → the [Json] value model. Accepts any
 *  valid JSON (key order not significant on decode), matching the other
 *  implementations' "decoders accept any valid JSON" rule. */
object JsonParser {
    fun parse(bytes: ByteArray): Json = parse(String(bytes, Charsets.UTF_8))

    fun parse(text: String): Json {
        val p = State(text)
        p.skipWs()
        val v = p.value()
        p.skipWs()
        require(p.pos == text.length) { "trailing data at ${p.pos}" }
        return v
    }

    private class State(val s: String) {
        var pos = 0

        fun skipWs() {
            while (pos < s.length && s[pos].let { it == ' ' || it == '\n' || it == '\r' || it == '\t' }) pos++
        }

        fun value(): Json {
            skipWs()
            return when (val c = s[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> Json.Str(string())
                't' -> { expect("true"); Json.Bool(true) }
                'f' -> { expect("false"); Json.Bool(false) }
                'n' -> { expect("null"); Json.Null }
                else -> if (c == '-' || c in '0'..'9') number() else error("unexpected '$c' at $pos")
            }
        }

        fun obj(): Json.Obj {
            pos++ // {
            val map = LinkedHashMap<String, Json>()
            skipWs()
            if (s[pos] == '}') { pos++; return Json.Obj(map) }
            while (true) {
                skipWs()
                val key = string()
                skipWs(); require(s[pos] == ':'); pos++
                map[key] = value()
                skipWs()
                when (s[pos]) {
                    ',' -> pos++
                    '}' -> { pos++; return Json.Obj(map) }
                    else -> error("expected , or } at $pos")
                }
            }
        }

        fun arr(): Json.Arr {
            pos++ // [
            val items = ArrayList<Json>()
            skipWs()
            if (s[pos] == ']') { pos++; return Json.Arr(items) }
            while (true) {
                items.add(value())
                skipWs()
                when (s[pos]) {
                    ',' -> pos++
                    ']' -> { pos++; return Json.Arr(items) }
                    else -> error("expected , or ] at $pos")
                }
            }
        }

        fun string(): String {
            require(s[pos] == '"'); pos++
            val sb = StringBuilder()
            while (true) {
                when (val c = s[pos++]) {
                    '"' -> return sb.toString()
                    '\\' -> when (val e = s[pos++]) {
                        '"' -> sb.append('"'); '\\' -> sb.append('\\'); '/' -> sb.append('/')
                        'b' -> sb.append('\b'); 'f' -> sb.append('\u000C'); 'n' -> sb.append('\n')
                        'r' -> sb.append('\r'); 't' -> sb.append('\t')
                        'u' -> { sb.append(s.substring(pos, pos + 4).toInt(16).toChar()); pos += 4 }
                        else -> error("bad escape \\$e")
                    }
                    else -> sb.append(c)
                }
            }
        }

        fun number(): Json.Num {
            val start = pos
            if (s[pos] == '-') pos++
            while (pos < s.length && (s[pos] in '0'..'9' || s[pos] == '.' || s[pos] == 'e' || s[pos] == 'E' || s[pos] == '+' || s[pos] == '-')) pos++
            return Json.Num(s.substring(start, pos))
        }

        fun expect(word: String) {
            require(s.startsWith(word, pos)) { "expected $word at $pos" }
            pos += word.length
        }
    }
}

// Convenience accessors for pulling typed fields off a parsed object.
fun Json.asObj(): Map<String, Json> = (this as Json.Obj).entries
fun Json.str(): String = (this as Json.Str).value
fun Json.long(): Long = (this as Json.Num).literal.toLong()
fun Json.int(): Int = (this as Json.Num).literal.toInt()
fun Json.bool(): Boolean = (this as Json.Bool).value
fun Json.bytes(): ByteArray = Base64.decode((this as Json.Str).value)
fun Json.arr(): List<Json> = (this as Json.Arr).items
fun Map<String, Json>.opt(key: String): Json? = this[key]?.takeIf { it !is Json.Null }

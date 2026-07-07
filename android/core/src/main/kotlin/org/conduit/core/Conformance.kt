package org.conduit.core

import org.conduit.core.identity.Identity
import org.conduit.core.identity.Pairing
import org.conduit.core.identity.WORDLIST
import org.conduit.core.identity.fromHex
import org.conduit.core.identity.toHex
import org.conduit.core.wire.*
import java.io.File
import java.security.MessageDigest

/**
 * Runs the Kotlin implementation against the shared golden vectors in
 * proto/vectors and reports pass/fail (spec §9 Phase 5: "conformance vectors
 * keep it honest"). A third implementation now agrees with Swift + Go
 * byte-for-byte.
 *
 * Usage: Conformance <proto/vectors dir>
 */
object Conformance {
    private data class Result(val name: String, val ok: Boolean, val msg: String = "")

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.size != 1) { System.err.println("usage: Conformance <proto/vectors dir>"); kotlin.system.exitProcess(2) }
        val dir = args[0]
        val results = buildList {
            addAll(checkMessages(File(dir, "messages.json")))
            addAll(checkChunkFrames(File(dir, "chunk_frames.json")))
            addAll(checkScreenFrames(File(dir, "screen_frames.json")))
            addAll(checkPairing(File(dir, "pairing.json")))
        }
        var failed = 0
        for (r in results) {
            if (r.ok) println("  ok   ${r.name}")
            else { failed++; println("  FAIL ${r.name}: ${r.msg}") }
        }
        println("\n${results.size} vectors, $failed failed")
        if (failed > 0) kotlin.system.exitProcess(1)
        println("Kotlin conformance: PASS")
    }

    private fun loadVectors(file: File): List<Map<String, Json>> {
        val root = JsonParser.parse(file.readBytes()).asObj()
        return root.getValue("vectors").arr().map { it.asObj() }
    }

    /** Decode each frame → typed message → re-encode canonically → must equal
     *  the golden canonical_json AND re-frame to the same bytes. */
    private fun checkMessages(file: File): List<Result> = loadVectors(file).map { vec ->
        val name = "message:" + vec.getValue("name").str()
        try {
            val frameHex = vec.getValue("frame_hex").str()
            val wantCanonical = vec.getValue("canonical_json").str()
            val frames = FrameReader().append(frameHex.fromHex())
            val control = (frames.single() as Frame.Control).payload
            val (env, msg) = MessageCodec.decode(control)
            // Re-encode the parsed payload canonically; the payload Json was
            // parsed from arbitrary order, so this re-sorts and proves stability.
            val reencoded = MessageCodec.encodeMessage(env.sessionId, env.seq, msg)
            if (String(reencoded, Charsets.UTF_8) != wantCanonical)
                return@map Result(name, false, "canonical mismatch\n   want: $wantCanonical\n   got:  ${String(reencoded, Charsets.UTF_8)}")
            if (FrameCodec.encodeControl(reencoded).toHex() != frameHex)
                return@map Result(name, false, "reframed bytes differ")
            Result(name, true)
        } catch (e: Exception) {
            Result(name, false, e.message ?: e.toString())
        }
    }

    private fun checkChunkFrames(file: File): List<Result> = loadVectors(file).map { vec ->
        val name = "chunk:" + vec.getValue("name").str()
        try {
            val frameHex = vec.getValue("frame_hex").str()
            val frame = (FrameReader().append(frameHex.fromHex()).single() as Frame.Chunk).frame
            if (FrameCodec.encodeChunk(frame).toHex() != frameHex) Result(name, false, "re-encode differs")
            else Result(name, true)
        } catch (e: Exception) { Result(name, false, e.message ?: e.toString()) }
    }

    private fun checkScreenFrames(file: File): List<Result> = loadVectors(file).map { vec ->
        val name = "screen:" + vec.getValue("name").str()
        try {
            val frameHex = vec.getValue("frame_hex").str()
            val frame = (FrameReader().append(frameHex.fromHex()).single() as Frame.Screen).frame
            if (FrameCodec.encodeScreen(frame).toHex() != frameHex)
                return@map Result(name, false, "re-encode differs")
            val unpacked = ScreenPacking.unpack(frame.data, frame.isKeyframe)
            val wantSets = vec.getValue("parameter_sets_hex").arr().map { it.str() }
            if (unpacked.parameterSets.size != wantSets.size) return@map Result(name, false, "param set count")
            unpacked.parameterSets.forEachIndexed { i, s ->
                if (s.toHex() != wantSets[i]) return@map Result(name, false, "param set bytes differ")
            }
            Result(name, true)
        } catch (e: Exception) { Result(name, false, e.message ?: e.toString()) }
    }

    private fun checkPairing(file: File): List<Result> {
        val root = JsonParser.parse(file.readBytes()).asObj()
        val out = ArrayList<Result>()

        val wantHash = root.getValue("wordlist_sha256").str()
        val joined = WORDLIST.joinToString("\n")
        val gotHash = MessageDigest.getInstance("SHA-256").digest(joined.toByteArray(Charsets.UTF_8)).toHex()
        out.add(Result("pairing:wordlist_frozen", gotHash == wantHash, if (gotHash == wantHash) "" else "wordlist hash drift"))

        for (v in root.getValue("vectors").arr().map { it.asObj() }) {
            val name = "pairing:" + v.getValue("name").str()
            when (v.getValue("name").str()) {
                "pairing_basic" -> {
                    val a = v.getValue("pub_a_hex").str().fromHex()
                    val b = v.getValue("pub_b_hex").str().fromHex()
                    val code = Pairing.verificationCode(a, b)
                    val (wA, wB) = Pairing.verificationWords(a, b)
                    val ok = code == v.getValue("code").str() && wA == v.getValue("word_a").str() && wB == v.getValue("word_b").str()
                    out.add(Result(name, ok, if (ok) "" else "code/words mismatch (got $code $wA/$wB)"))
                }
                "identity_derivation" -> {
                    val pub = v.getValue("ed25519_pub_hex").str().fromHex()
                    val ok = Identity.deviceId(pub) == v.getValue("device_id").str()
                    out.add(Result(name, ok, if (ok) "" else "device id mismatch"))
                }
                "tls_binding" -> {
                    val pub = v.getValue("ed25519_pub_hex").str().fromHex()
                    val hash = v.getValue("tls_key_hash_hex").str().fromHex()
                    val sig = v.getValue("signature_hex").str().fromHex()
                    // Two proofs at once: the signature verifies, AND fromSeed
                    // derives the same public key the vector records.
                    val seed = v.getValue("ed25519_seed_hex").str().fromHex()
                    val derived = Identity.fromSeed(seed).publicKeyRaw.toHex()
                    val ok = Identity.verifyTlsBinding(sig, hash, pub) && derived == v.getValue("ed25519_pub_hex").str()
                    out.add(Result(name, ok, if (ok) "" else "binding/derivation failed (derived $derived)"))
                }
            }
        }
        return out
    }
}

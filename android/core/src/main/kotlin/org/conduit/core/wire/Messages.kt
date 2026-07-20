package org.conduit.core.wire

/** Protocol constants shared with Swift + Go (docs/protocol.md). */
object Proto {
    const val VERSION = "0.2"
    const val SERVICE_TYPE = "_mosis-app._tcp"
    const val DEFAULT_CHUNK_SIZE = 512 * 1024

    // Capability identifiers (feature-flag strings; peers use the intersection).
    const val CAP_FILE = "file"
    const val CAP_CLIPBOARD = "clipboard"
    const val CAP_INPUT_INJECT = "input-inject"
    const val CAP_MEDIA_TARGET = "media-target"
    const val CAP_SCREEN_SOURCE = "screen-source"
    const val CAP_SCREEN_VIEW = "screen-view"
    const val CAP_NOTIFY_SOURCE = "notify-source"
    const val CAP_NOTIFY_SHOW = "notify-show"
}

/** The frozen envelope shape (spec §6): version, type, session_id, seq, payload. */
data class Envelope(val version: String, val type: String, val sessionId: String, val seq: Long)

/**
 * A decoded control message: a type string plus the payload as a [Json] value.
 * Keeping the payload as [Json] (rather than one sealed class per body) keeps
 * the core small; capability code reads the fields it needs. Encoding is fully
 * typed via the builders below, which is what the golden vectors pin.
 */
data class Message(val type: String, val payload: Json)

object MessageType {
    const val HELLO = "HELLO"; const val HELLO_ACK = "HELLO_ACK"
    const val PING = "PING"; const val PONG = "PONG"
    const val CLIPBOARD_PUSH = "CLIPBOARD_PUSH"
    const val FILE_OFFER = "FILE_OFFER"; const val FILE_ACCEPT = "FILE_ACCEPT"
    const val FILE_REJECT = "FILE_REJECT"; const val FILE_ACK = "FILE_ACK"
    const val PAIR_REQUEST = "PAIR_REQUEST"; const val PAIR_RESPONSE = "PAIR_RESPONSE"
    const val PAIR_CONFIRM = "PAIR_CONFIRM"; const val PAIR_REJECT = "PAIR_REJECT"
    const val BULK_ATTACH = "BULK_ATTACH"
    const val INPUT_REQUEST = "INPUT_REQUEST"; const val INPUT_STATUS = "INPUT_STATUS"
    const val INPUT_EVENT = "INPUT_EVENT"; const val INPUT_ATTACH = "INPUT_ATTACH"
    const val MEDIA_CONTROL = "MEDIA_CONTROL"
    const val SCREEN_REQUEST = "SCREEN_REQUEST"; const val SCREEN_OFFER = "SCREEN_OFFER"
    const val SCREEN_REJECT = "SCREEN_REJECT"; const val SCREEN_ATTACH = "SCREEN_ATTACH"
    const val SCREEN_ACK = "SCREEN_ACK"; const val SCREEN_END = "SCREEN_END"
    const val NOTIFICATION = "NOTIFICATION"
    // Phase 7: device state + social permissions.
    const val DEVICE_STATE = "DEVICE_STATE"
    const val PERMISSION_REQUEST = "PERMISSION_REQUEST"
    const val PERMISSION_GRANT = "PERMISSION_GRANT"
    const val PERMISSION_REVOKE = "PERMISSION_REVOKE"
}

/** Encodes/decodes control-message envelopes to/from canonical JSON. */
object MessageCodec {
    fun encode(sessionId: String, seq: Long, type: String, payload: Json): ByteArray {
        val env = Json.obj(
            "version" to Json.of(Proto.VERSION),
            "type" to Json.of(type),
            "session_id" to Json.of(sessionId),
            "seq" to Json.of(seq),
            "payload" to payload,
        )
        return CanonicalJson.encode(env)
    }

    /** Re-encodes a payload already in [Json] form (used by conformance to
     *  prove decode→encode is byte-stable). */
    fun encodeMessage(sessionId: String, seq: Long, msg: Message): ByteArray =
        encode(sessionId, seq, msg.type, msg.payload)

    fun decode(data: ByteArray): Pair<Envelope, Message> {
        val root = JsonParser.parse(data).asObj()
        val env = Envelope(
            version = root.getValue("version").str(),
            type = root.getValue("type").str(),
            sessionId = root.getValue("session_id").str(),
            seq = root.getValue("seq").long(),
        )
        return env to Message(env.type, root.getValue("payload"))
    }
}

// ---- Typed payload builders (the wire shapes the golden vectors pin) ----

object Bodies {
    fun hello(
        identity: String, name: String, deviceClass: String, appVersion: String,
        pubkey: ByteArray, capabilities: List<String>, platformWalls: List<String>, listenPort: Int?,
    ): Json {
        val m = linkedMapOf<String, Json>(
            "identity" to Json.of(identity),
            "name" to Json.of(name),
            "device_class" to Json.of(deviceClass),
            "app_version" to Json.of(appVersion),
            "pubkey" to Json.bytes(pubkey),
            "capabilities" to Json.Arr(capabilities.map { Json.of(it) }),
            "platform_walls" to Json.Arr(platformWalls.map { Json.of(it) }),
        )
        if (listenPort != null) m["listen_port"] = Json.of(listenPort)
        return Json.Obj(m)
    }

    fun ping(nonce: String, t: Long): Json = Json.obj("nonce" to Json.of(nonce), "t" to Json.of(t))

    fun clipboard(mime: String, data: ByteArray): Json =
        Json.obj("mime" to Json.of(mime), "data" to Json.bytes(data))

    fun clipboardText(text: String): Json = clipboard("text/plain;charset=utf-8", text.toByteArray(Charsets.UTF_8))

    fun fileOffer(fileId: String, name: String, size: Long, mime: String, sha256: String, chunkSize: Int, chunkCount: Long): Json =
        Json.obj(
            "file_id" to Json.of(fileId), "name" to Json.of(name), "size" to Json.of(size),
            "mime" to Json.of(mime), "sha256" to Json.of(sha256),
            "chunk_size" to Json.of(chunkSize), "chunk_count" to Json.of(chunkCount),
        )

    fun fileAccept(fileId: String, resumeFromChunk: Long, bulkToken: String): Json =
        Json.obj("file_id" to Json.of(fileId), "resume_from_chunk" to Json.of(resumeFromChunk), "bulk_token" to Json.of(bulkToken))

    fun fileReject(fileId: String, reason: String): Json =
        Json.obj("file_id" to Json.of(fileId), "reason" to Json.of(reason))

    fun fileAck(fileId: String, status: String, ackedThrough: Long, message: String? = null): Json {
        val m = linkedMapOf<String, Json>(
            "file_id" to Json.of(fileId), "status" to Json.of(status), "acked_through" to Json.of(ackedThrough),
        )
        if (message != null) m["message"] = Json.of(message)
        return Json.Obj(m)
    }

    fun pair(identity: String, name: String, deviceClass: String, pubkey: ByteArray, tlsHashHex: String, bindingSig: ByteArray): Json =
        Json.obj(
            "identity" to Json.of(identity), "name" to Json.of(name), "device_class" to Json.of(deviceClass),
            "pubkey" to Json.bytes(pubkey), "tls_pubkey_sha256" to Json.of(tlsHashHex), "binding_sig" to Json.bytes(bindingSig),
        )

    fun pairReject(reason: String): Json = Json.obj("reason" to Json.of(reason))
    fun empty(): Json = Json.Obj(emptyMap())
    fun bulkAttach(fileId: String, bulkToken: String): Json =
        Json.obj("file_id" to Json.of(fileId), "bulk_token" to Json.of(bulkToken))

    fun inputEventMove(dx: Double, dy: Double): Json =
        Json.obj("kind" to Json.of("move"), "dx" to Json.Num(numLit(dx)), "dy" to Json.Num(numLit(dy)))

    fun mediaControl(action: String, value: Double? = null): Json {
        val m = linkedMapOf<String, Json>("action" to Json.of(action))
        if (value != null) m["value"] = Json.Num(numLit(value))
        return Json.Obj(m)
    }

    fun notification(appName: String, title: String, body: String, id: String, actions: List<String>? = null): Json {
        val m = linkedMapOf<String, Json>(
            "app_name" to Json.of(appName), "title" to Json.of(title), "body" to Json.of(body), "id" to Json.of(id),
        )
        if (actions != null) m["actions"] = Json.Arr(actions.map { Json.of(it) })
        return Json.Obj(m)
    }

    /** Formats a double the way Swift/Go JSON does: integral values as integers. */
    private fun numLit(d: Double): String =
        if (d == d.toLong().toDouble()) d.toLong().toString() else d.toString()
}

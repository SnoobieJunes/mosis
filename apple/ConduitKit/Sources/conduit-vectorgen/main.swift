import Foundation
import CryptoKit
import ConduitProtocol
import ConduitSession

/// Generates the golden vectors in proto/vectors (spec §9 Phase 1 step 2).
/// Vectors are APPEND-ONLY: once committed, an entry never changes; new
/// protocol additions append new entries. Every implementation (Swift now,
/// Go in Phase 4, Kotlin in Phase 5) must pass all of them.
///
/// Usage: conduit-vectorgen <output-directory>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: conduit-vectorgen <output-directory>")
    exit(2)
}
let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func hex(_ data: Data) -> String { data.hexString }

func writeJSON(_ object: [String: Any], to name: String, skipIfExists: Bool = false) throws {
    let url = outputDir.appendingPathComponent(name)
    // Some vectors carry non-deterministic material (Ed25519 signatures are
    // randomized by CryptoKit). Regenerating them would churn a committed,
    // append-only vector even though it still verifies — so leave it in place.
    if skipIfExists, FileManager.default.fileExists(atPath: url.path) {
        print("kept \(name) (append-only; contains non-deterministic material)")
        return
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
    print("wrote \(name)")
}

// MARK: - Message vectors

let meta = EnvelopeMeta(sessionID: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", seq: 7)

let helloBody = HelloBody(
    identity: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    name: "Vector Phone",
    deviceClass: .phone,
    appVersion: "0.1.0",
    pubkey: Data(repeating: 0xAB, count: 32),
    capabilities: ["file", "clipboard"],
    platformWalls: ["clipboard-ambient", "input-inject", "notification-source"],
    listenPort: 52_113
)
let pairBody = PairBody(
    identity: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    name: "Vector Mac",
    deviceClass: .desktop,
    pubkey: Data(repeating: 0x01, count: 32),
    tlsPubkeySHA256: String(repeating: "cd", count: 32),
    bindingSig: Data(repeating: 0x02, count: 64)
)

let messages: [(String, Message)] = [
    ("hello", .hello(helloBody)),
    ("hello_ack", .helloAck(helloBody)),
    ("ping", .ping(PingBody(nonce: "a1b2c3d4e5f60718", t: 1_751_000_000_123))),
    ("pong", .pong(PingBody(nonce: "a1b2c3d4e5f60718", t: 1_751_000_000_456))),
    ("clipboard_push", .clipboardPush(.text("The quick brown fox — καλημέρα — 🦊"))),
    ("file_offer", .fileOffer(FileOfferBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", name: "talk.key",
        size: 1_073_741_824, mime: "application/octet-stream",
        sha256: String(repeating: "ab", count: 32), chunkSize: 524_288, chunkCount: 2048))),
    ("file_accept", .fileAccept(FileAcceptBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", resumeFromChunk: 42,
        bulkToken: "746f6b656e2d746f6b656e"))),
    ("file_reject", .fileReject(FileRejectBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", reason: "declined"))),
    ("file_ack_progress", .fileAck(FileAckBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", status: .progress, ackedThrough: 128))),
    ("file_ack_complete", .fileAck(FileAckBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", status: .complete, ackedThrough: 2048))),
    ("file_ack_hash_mismatch", .fileAck(FileAckBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", status: .hashMismatch,
        ackedThrough: 2048, message: "sha256 mismatch"))),
    ("pair_request", .pairRequest(pairBody)),
    ("pair_response", .pairResponse(pairBody)),
    ("pair_confirm", .pairConfirm),
    ("pair_reject", .pairReject(PairRejectBody(reason: "code mismatch"))),
    ("bulk_attach", .bulkAttach(BulkAttachBody(
        fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", bulkToken: "746f6b656e2d746f6b656e"))),
    // Phase 2 — remote input + media control.
    ("input_request", .inputRequest),
    ("input_status_active", .inputStatus(InputStatusBody(
        active: true, udpPort: 52_114, datagramToken: "746f6b656e", secureInput: false))),
    ("input_status_denied", .inputStatus(InputStatusBody(active: false, reason: "declined"))),
    ("input_move", .inputEvent(.move(dx: 12.5, dy: -3.25))),
    ("input_scroll", .inputEvent(.scroll(dx: 0, dy: -40))),
    ("input_click", .inputEvent(.click(.right, action: .tap, clickCount: 1))),
    ("input_key_text", .inputEvent(.text("Hi", modifiers: [.command]))),
    ("input_key_special", .inputEvent(.specialKey("return", modifiers: []))),
    ("input_attach", .inputAttach(InputAttachBody(token: "746f6b656e"))),
    ("media_toggle", .mediaControl(MediaControlBody(action: .toggle))),
    ("media_volume", .mediaControl(MediaControlBody(action: .volume, value: -1))),
    // Phase 3 — screen sharing.
    ("screen_request", .screenRequest(ScreenRequestBody(
        maxWidth: 1920, maxHeight: 1200, maxFps: 30, codecs: [.hevc, .h264]))),
    ("screen_offer", .screenOffer(ScreenOfferBody(
        screenSessionID: "7C3E5A90-1234-4bcd-9876-0123456789AB", wireSessionID: 1,
        codec: .hevc, width: 1920, height: 1080, fps: 30, captureKind: .window,
        sourceName: "Safari — Conduit", bulkToken: "746f6b656e"))),
    ("screen_reject", .screenReject(ScreenRejectBody(reason: "declined"))),
    ("screen_attach", .screenAttach(ScreenAttachBody(
        screenSessionID: "7C3E5A90-1234-4bcd-9876-0123456789AB", bulkToken: "746f6b656e"))),
    ("screen_ack", .screenAck(ScreenAckBody(
        screenSessionID: "7C3E5A90-1234-4bcd-9876-0123456789AB", ackedSeq: 128, requestKeyframe: false))),
    ("screen_ack_keyframe", .screenAck(ScreenAckBody(
        screenSessionID: "7C3E5A90-1234-4bcd-9876-0123456789AB", ackedSeq: 0, requestKeyframe: true))),
    ("screen_end", .screenEnd(ScreenEndBody(
        screenSessionID: "7C3E5A90-1234-4bcd-9876-0123456789AB", reason: "stopped"))),
]

var messageVectors: [[String: Any]] = []
for (name, message) in messages {
    let payload = try MessageCodec.encode(meta: meta, message: message)
    let frame = FrameCodec.encodeControl(payload)
    messageVectors.append([
        "name": name,
        "type": message.typeString,
        "frame_hex": hex(frame),
        "canonical_json": String(decoding: payload, as: UTF8.self),
    ])
}
try writeJSON([
    "description": "Control-frame vectors: TLV kind 0x01, canonical JSON payload (sorted keys, no whitespace). Decode frame_hex, re-encode canonically, expect identical bytes. APPEND-ONLY.",
    "envelope": ["version": meta.version, "session_id": meta.sessionID, "seq": 7],
    "vectors": messageVectors,
], to: "messages.json")

// MARK: - Chunk frame vector

let chunk = ChunkFrame(
    fileID: UUID(uuidString: "0E984725-C51C-4BF4-9960-E1C80E27ABA0")!,
    seq: 513,
    isLast: true,
    data: Data((0..<64).map { UInt8($0) })
)
try writeJSON([
    "description": "Binary file-chunk frame: TLV kind 0x02, payload = uuid(16) | seq u64 BE | flags u8 (bit0 last) | data. APPEND-ONLY.",
    "vectors": [[
        "name": "chunk_basic",
        "file_id": "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
        "seq": 513,
        "is_last": true,
        "data_hex": hex(chunk.data),
        "frame_hex": hex(FrameCodec.encode(chunk)),
    ]],
], to: "chunk_frames.json")

// MARK: - Screen frame vector (binary kind 0x03) + inner packing

let encodedKeyframe = EncodedVideoFrame(
    isKeyframe: true,
    parameterSets: [Data([0x40, 0x01, 0x0c, 0x01]), Data([0x42, 0x01, 0x03]), Data([0x44, 0x01, 0xc0])],
    sampleData: Data((0..<48).map { UInt8($0 & 0xFF) })
)
let packedKeyframe = ScreenFramePacking.pack(encodedKeyframe)
let screenFrameVec = ScreenFrame(
    sessionID: 1, seq: 7, isKeyframe: true, ptsMillis: 33, data: packedKeyframe
)
try writeJSON([
    "description": "Binary screen frame: TLV kind 0x03, payload = sessionId u16 BE | seq u32 BE | flags u8 (bit0 keyframe) | ptsMillis u64 BE | data. `data` inner packing = paramCount u8 | [len u32 BE | bytes]... | sampleData. APPEND-ONLY.",
    "vectors": [[
        "name": "screen_keyframe",
        "wire_session_id": 1,
        "seq": 7,
        "is_keyframe": true,
        "pts_millis": 33,
        "parameter_sets_hex": encodedKeyframe.parameterSets.map(hex),
        "sample_data_hex": hex(encodedKeyframe.sampleData),
        "packed_data_hex": hex(packedKeyframe),
        "frame_hex": hex(FrameCodec.encode(screenFrameVec)),
    ]],
], to: "screen_frames.json")

// MARK: - Pairing and identity vectors

let pubA = Data((0..<32).map { UInt8($0) })
let pubB = Data((0..<32).map { UInt8(255 - $0) })
let words = PairingMath.verificationWords(pubA: pubA, pubB: pubB)

let seedC = Data(repeating: 0x11, count: 32)
let identityC = DeviceIdentity(privateKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: seedC))
let tlsHash = Data(repeating: 0x42, count: 32)
let bindingSig = try identityC.signTLSBinding(tlsPublicKeyHash: tlsHash)

try writeJSON([
    "description": "Pairing math vectors. material = SHA256('conduit-pairing-v1' | min(pubA,pubB) | max(pubA,pubB)); code = BE_u32(material[0..4]) % 1e6 zero-padded to 6; words = wordlist[material[4]], wordlist[material[5]] over the frozen 256-word list. Binding sig = Ed25519('conduit-tls-binding-v1' | tls_key_hash); verification must succeed forever (only verification stability is required of implementations). APPEND-ONLY.",
    "wordlist_sha256": hex(Data(SHA256.hash(data: Data(PairingWordlist.words.joined(separator: "\n").utf8)))),
    "vectors": [
        [
            "name": "pairing_basic",
            "pub_a_hex": hex(pubA),
            "pub_b_hex": hex(pubB),
            "code": PairingMath.verificationCode(pubA: pubA, pubB: pubB),
            "word_a": words.0,
            "word_b": words.1,
        ],
        [
            "name": "identity_derivation",
            "ed25519_pub_hex": hex(identityC.publicKeyRaw),
            "device_id": identityC.deviceID,
        ],
        [
            "name": "tls_binding",
            "ed25519_seed_hex": hex(seedC),
            "ed25519_pub_hex": hex(identityC.publicKeyRaw),
            "tls_key_hash_hex": hex(tlsHash),
            "signature_hex": hex(bindingSig),
        ],
    ],
], to: "pairing.json", skipIfExists: true)

print("done")

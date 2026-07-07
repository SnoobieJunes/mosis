import Foundation
import Testing
@testable import ConduitProtocol

private func fixtureHello() -> HelloBody {
    HelloBody(
        identity: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        name: "Leroy's iPhone",
        deviceClass: .phone,
        appVersion: "0.1.0",
        pubkey: Data(repeating: 0xAB, count: 32),
        capabilities: [CapabilityID.file, CapabilityID.clipboard],
        platformWalls: ["clipboard-ambient", "input-inject", "notification-source"],
        listenPort: 52_113
    )
}

@Suite struct MessageCodecTests {
    let meta = EnvelopeMeta(sessionID: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", seq: 7)

    @Test func helloRoundTrip() throws {
        let encoded = try MessageCodec.encode(meta: meta, message: .hello(fixtureHello()))
        let (decodedMeta, decoded) = try MessageCodec.decode(encoded)
        #expect(decodedMeta == meta)
        #expect(decoded == .hello(fixtureHello()))
    }

    @Test func allPhaseOneTypesRoundTrip() throws {
        let messages: [Message] = [
            .hello(fixtureHello()),
            .helloAck(fixtureHello()),
            .ping(PingBody(nonce: "a1b2c3d4e5f60718", t: 1_751_000_000_123)),
            .pong(PingBody(nonce: "a1b2c3d4e5f60718", t: 1_751_000_000_456)),
            .clipboardPush(.text("hello from the other side")),
            .fileOffer(FileOfferBody(
                fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", name: "talk.key",
                size: 1_073_741_824, mime: "application/octet-stream",
                sha256: String(repeating: "ab", count: 32),
                chunkSize: 524_288, chunkCount: 2048)),
            .fileAccept(FileAcceptBody(
                fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
                resumeFromChunk: 42, bulkToken: "dGVzdC10b2tlbg")),
            .fileReject(FileRejectBody(fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", reason: "declined")),
            .fileAck(FileAckBody(fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", status: .progress, ackedThrough: 128)),
            .fileAck(FileAckBody(fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", status: .complete, ackedThrough: 2048)),
            .pairRequest(PairBody(
                identity: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                name: "Studio Mac", deviceClass: .desktop,
                pubkey: Data(repeating: 0x01, count: 32),
                tlsPubkeySHA256: String(repeating: "cd", count: 32),
                bindingSig: Data(repeating: 0x02, count: 64))),
            .pairResponse(PairBody(
                identity: "1f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                name: "Leroy's iPhone", deviceClass: .phone,
                pubkey: Data(repeating: 0x03, count: 32),
                tlsPubkeySHA256: String(repeating: "ef", count: 32),
                bindingSig: Data(repeating: 0x04, count: 64))),
            .pairConfirm,
            .pairReject(PairRejectBody(reason: "code mismatch")),
            .bulkAttach(BulkAttachBody(fileID: "0E984725-C51C-4BF4-9960-E1C80E27ABA0", bulkToken: "dGVzdC10b2tlbg")),
        ]
        for message in messages {
            let encoded = try MessageCodec.encode(meta: meta, message: message)
            let (decodedMeta, decoded) = try MessageCodec.decode(encoded)
            #expect(decodedMeta == meta, "meta mismatch for \(message.typeString)")
            #expect(decoded == message, "round-trip mismatch for \(message.typeString)")
        }
    }

    @Test func canonicalEncodingIsDeterministic() throws {
        let first = try MessageCodec.encode(meta: meta, message: .hello(fixtureHello()))
        let second = try MessageCodec.encode(meta: meta, message: .hello(fixtureHello()))
        #expect(first == second)
    }

    @Test func canonicalEncodingSortsEnvelopeKeys() throws {
        let encoded = try MessageCodec.encode(meta: meta, message: .ping(PingBody(nonce: "00", t: 5)))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text == #"{"payload":{"nonce":"00","t":5},"seq":7,"session_id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","type":"PING","version":"0.2"}"#)
    }

    @Test func unknownTypeIsIgnoredNotFatal() throws {
        let json = #"{"version":"0.9","type":"SCREEN_FRAME","session_id":"s","seq":1,"payload":{"whatever":true}}"#
        let (decodedMeta, message) = try MessageCodec.decode(Data(json.utf8))
        #expect(decodedMeta.version == "0.9")
        #expect(message == .unknown(type: "SCREEN_FRAME"))
    }

    @Test func decoderAcceptsUnsortedKeys() throws {
        let json = #"{"seq":3,"payload":{"t":9,"nonce":"ff"},"type":"PONG","session_id":"x","version":"0.2"}"#
        let (_, message) = try MessageCodec.decode(Data(json.utf8))
        #expect(message == .pong(PingBody(nonce: "ff", t: 9)))
    }

    @Test func nonJSONThrows() {
        #expect(throws: MessageCodecError.notJSON) {
            _ = try MessageCodec.decode(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
    }
}

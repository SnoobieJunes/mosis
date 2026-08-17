import Foundation
import Testing
@testable import ConduitProtocol

@Suite struct ScreenMessageCodecTests {
    let meta = EnvelopeMeta(sessionID: "S", seq: 4)

    @Test func screenControlMessagesRoundTrip() throws {
        let sid = "7C3E5A90-1234-4bcd-9876-0123456789AB"
        let messages: [Message] = [
            .screenRequest(ScreenRequestBody(maxWidth: 1920, maxHeight: 1200, maxFps: 30, codecs: [.hevc, .h264])),
            .screenRequest(ScreenRequestBody()),
            .screenOffer(ScreenOfferBody(
                screenSessionID: sid, wireSessionID: 3, codec: .hevc, width: 1920, height: 1080,
                fps: 30, captureKind: .display, sourceName: "Display 1", bulkToken: "tok")),
            .screenReject(ScreenRejectBody(reason: "busy")),
            .screenAttach(ScreenAttachBody(screenSessionID: sid, bulkToken: "tok")),
            .screenAck(ScreenAckBody(screenSessionID: sid, ackedSeq: 42, requestKeyframe: false)),
            .screenAck(ScreenAckBody(screenSessionID: sid, ackedSeq: 0, requestKeyframe: true)),
            .screenEnd(ScreenEndBody(screenSessionID: sid, reason: "done")),
            .screenEnd(ScreenEndBody(screenSessionID: sid)),
        ]
        for message in messages {
            let encoded = try MessageCodec.encode(meta: meta, message: message)
            let (_, decoded) = try MessageCodec.decode(encoded)
            #expect(decoded == message, "round-trip mismatch for \(message.typeString)")
        }
    }
}

@Suite struct ScreenFrameFramingTests {
    @Test func screenFrameRoundTripsThroughReader() throws {
        let frame = ScreenFrame(
            sessionID: 0xABCD, seq: 0x0102_0304, isKeyframe: true,
            ptsMillis: 0x0011_2233_4455_6677, data: Data((0..<100).map { UInt8($0 & 0xFF) })
        )
        var reader = FrameReader()
        let frames = try reader.append(FrameCodec.encode(frame))
        #expect(frames == [.screenFrame(frame)])
    }

    @Test func screenFrameInterleavesWithControlAndChunks() throws {
        let screen = ScreenFrame(sessionID: 1, seq: 1, isKeyframe: false, ptsMillis: 10, data: Data([9, 9]))
        let control = FrameCodec.encodeControl(Data("{}".utf8))
        let wire = control + FrameCodec.encode(screen) + control
        var reader = FrameReader()
        let frames = try reader.append(wire)
        #expect(frames.count == 3)
        #expect(frames[1] == .screenFrame(screen))
    }

    @Test func truncatedScreenHeaderRejected() {
        var wire = Data([FrameKind.screenFrame.rawValue])
        wire.appendBigEndian(UInt32(5))
        wire.append(Data(repeating: 0, count: 5)) // < 15-byte header
        var reader = FrameReader()
        #expect(throws: FramingError.malformedScreenFrame) {
            _ = try reader.append(wire)
        }
    }

    @Test func bigEndianFieldsMatchManualLayout() {
        let frame = ScreenFrame(sessionID: 0x0102, seq: 0x0304_0506,
                                isKeyframe: true, ptsMillis: 0x0708_090A_0B0C_0D0E, data: Data())
        let wire = FrameCodec.encode(frame)
        // kind(1) len(4) then header.
        let header = [UInt8](wire[5...])
        #expect(header[0] == 0x01 && header[1] == 0x02)           // sessionID
        #expect(Array(header[2..<6]) == [0x03, 0x04, 0x05, 0x06]) // seq
        #expect(header[6] == 1)                                    // keyframe flag
        #expect(Array(header[7..<15]) == [0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E]) // pts
    }
}

@Suite struct ScreenFramePackingTests {
    @Test func multipleParameterSetsRoundTrip() throws {
        let frame = EncodedVideoFrame(
            isKeyframe: true,
            parameterSets: [Data([1]), Data([2, 2]), Data([3, 3, 3])],
            sampleData: Data(repeating: 0x7F, count: 300)
        )
        let unpacked = try ScreenFramePacking.unpack(try ScreenFramePacking.pack(frame), isKeyframe: true)
        #expect(unpacked == frame)
    }

    @Test func deltaFrameHasNoParameterSets() throws {
        let frame = EncodedVideoFrame(isKeyframe: false, parameterSets: [], sampleData: Data([1, 2, 3]))
        let packed = try ScreenFramePacking.pack(frame)
        #expect(packed.first == 0) // zero parameter sets
        #expect(try ScreenFramePacking.unpack(packed, isKeyframe: false) == frame)
    }

    @Test func tooManyParameterSetsRejected() {
        // Byte says 9 sets (> max 8).
        #expect(throws: ScreenFrameCodecError.tooManyParameterSets) {
            _ = try ScreenFramePacking.unpack(Data([9]), isKeyframe: true)
        }
    }
}

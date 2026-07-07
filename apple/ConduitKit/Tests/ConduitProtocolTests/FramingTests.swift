import Foundation
import Testing
@testable import ConduitProtocol

@Suite struct FramingTests {
    let uuid = UUID(uuidString: "0E984725-C51C-4BF4-9960-E1C80E27ABA0")!

    @Test func controlFrameRoundTrip() throws {
        let payload = Data(#"{"hello":true}"#.utf8)
        var reader = FrameReader()
        let frames = try reader.append(FrameCodec.encodeControl(payload))
        #expect(frames == [.control(payload)])
    }

    @Test func chunkFrameRoundTrip() throws {
        let chunk = ChunkFrame(fileID: uuid, seq: 513, isLast: true, data: Data(repeating: 0x5A, count: 1000))
        var reader = FrameReader()
        let frames = try reader.append(FrameCodec.encode(chunk))
        #expect(frames == [.fileChunk(chunk)])
    }

    @Test func dribbledDeliveryOneByteAtATime() throws {
        let chunk = ChunkFrame(fileID: uuid, seq: 1, isLast: false, data: Data([1, 2, 3]))
        let wire = FrameCodec.encode(chunk) + FrameCodec.encodeControl(Data("{}".utf8))
        var reader = FrameReader()
        var collected: [Frame] = []
        for byte in wire {
            collected.append(contentsOf: try reader.append(Data([byte])))
        }
        #expect(collected == [.fileChunk(chunk), .control(Data("{}".utf8))])
    }

    @Test func multipleFramesInOneSegment() throws {
        let a = FrameCodec.encodeControl(Data("{\"a\":1}".utf8))
        let b = FrameCodec.encodeControl(Data("{\"b\":2}".utf8))
        var reader = FrameReader()
        let frames = try reader.append(a + b)
        #expect(frames.count == 2)
    }

    @Test func unknownKindIsSkipped() throws {
        var wire = Data([0x7F])
        wire.appendBigEndian(UInt32(3))
        wire.append(contentsOf: [9, 9, 9])
        wire.append(FrameCodec.encodeControl(Data("{}".utf8)))
        var reader = FrameReader()
        let frames = try reader.append(wire)
        #expect(frames == [.control(Data("{}".utf8))])
        #expect(reader.skippedUnknownFrames == 1)
    }

    @Test func oversizedFrameRejected() {
        var wire = Data([FrameKind.control.rawValue])
        wire.appendBigEndian(UInt32(64 * 1024 * 1024))
        var reader = FrameReader()
        #expect(throws: FramingError.self) {
            _ = try reader.append(wire)
        }
    }

    @Test func truncatedChunkHeaderRejected() {
        var wire = Data([FrameKind.fileChunk.rawValue])
        wire.appendBigEndian(UInt32(10))
        wire.append(Data(repeating: 0, count: 10))
        var reader = FrameReader()
        #expect(throws: FramingError.malformedChunk) {
            _ = try reader.append(wire)
        }
    }

    @Test func sequenceNumberBigEndianAgreesWithManualEncoding() throws {
        let chunk = ChunkFrame(fileID: uuid, seq: 0x0102_0304_0506_0708, isLast: false, data: Data())
        let wire = FrameCodec.encode(chunk)
        let seqBytes = [UInt8](wire[(5 + 16)..<(5 + 24)])
        #expect(seqBytes == [1, 2, 3, 4, 5, 6, 7, 8])
    }
}

import Foundation
import Testing
@testable import ConduitProtocol

/// Golden-vector conformance (spec §9 Phase 1 step 2). Vectors live in
/// proto/vectors and are append-only; this suite is what keeps the Swift
/// implementation honest, and its Go/Kotlin equivalents arrive in Phases 4-5.
enum VectorPaths {
    /// …/conduit/apple/ConduitKit/Tests/ConduitProtocolTests/VectorConformanceTests.swift → …/conduit
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConduitProtocolTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ConduitKit
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // conduit
    }

    static var vectorsDir: URL {
        repoRoot.appendingPathComponent("proto/vectors")
    }

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: vectorsDir.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite struct MessageVectorConformance {
    @Test func everyVectorDecodesAndReencodesByteExact() throws {
        let file = try VectorPaths.load("messages.json")
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        #expect(!vectors.isEmpty)
        var reader = FrameReader()
        for vector in vectors {
            let name = try #require(vector["name"] as? String)
            let frameHex = try #require(vector["frame_hex"] as? String)
            let maybeFrameData = Data(hexString: frameHex)
            let frameData = try #require(maybeFrameData, "bad hex in \(name)")

            let frames = try reader.append(frameData)
            guard case .control(let payload) = try #require(frames.first, "\(name) yielded no frame") else {
                Issue.record("\(name): expected a control frame")
                continue
            }
            let (meta, message) = try MessageCodec.decode(payload)
            if case .unknown(let type) = message {
                Issue.record("\(name): decoded as unknown type \(type)")
                continue
            }
            let reencoded = FrameCodec.encodeControl(try MessageCodec.encode(meta: meta, message: message))
            #expect(reencoded == frameData, "\(name): re-encoded frame differs from golden bytes")
        }
    }

    @Test func vectorsCoverEveryPhaseOneMessageType() throws {
        let file = try VectorPaths.load("messages.json")
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        let covered = Set(vectors.compactMap { $0["type"] as? String })
        for type in MessageType.allCases {
            #expect(covered.contains(type.rawValue), "no vector covers \(type.rawValue)")
        }
    }

    @Test func chunkFrameVectorRoundTrips() throws {
        let file = try VectorPaths.load("chunk_frames.json")
        let vectors = try #require(file["vectors"] as? [[String: Any]])
        for vector in vectors {
            let name = try #require(vector["name"] as? String)
            let frameHex = try #require(vector["frame_hex"] as? String)
            let maybeFrameData = Data(hexString: frameHex)
            let frameData = try #require(maybeFrameData)
            var reader = FrameReader()
            let frames = try reader.append(frameData)
            guard case .fileChunk(let chunk) = try #require(frames.first) else {
                Issue.record("\(name): expected a chunk frame")
                continue
            }
            let expectedSeq = try #require(vector["seq"] as? Int)
            let dataHex = try #require(vector["data_hex"] as? String)
            #expect(chunk.fileID.uuidString == (vector["file_id"] as? String ?? ""))
            #expect(chunk.seq == UInt64(expectedSeq))
            #expect(chunk.isLast == (vector["is_last"] as? Bool ?? false))
            #expect(chunk.data == Data(hexString: dataHex))
            #expect(FrameCodec.encode(chunk) == frameData)
        }
    }
}

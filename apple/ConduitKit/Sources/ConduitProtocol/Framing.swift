import Foundation

/// TLV framing over the byte stream (spec §5.4): 1-byte kind, 4-byte big-endian
/// length, payload. Control frames carry canonical JSON; file-chunk frames carry
/// a fixed 25-byte binary header plus raw data (bulk side-channel, spec §6).
public enum FrameKind: UInt8, Sendable {
    case control = 0x01
    case fileChunk = 0x02
}

public struct ChunkFrame: Sendable, Equatable {
    public var fileID: UUID
    public var seq: UInt64
    public var isLast: Bool
    public var data: Data

    public init(fileID: UUID, seq: UInt64, isLast: Bool, data: Data) {
        self.fileID = fileID
        self.seq = seq
        self.isLast = isLast
        self.data = data
    }
}

public enum Frame: Sendable, Equatable {
    case control(Data)
    case fileChunk(ChunkFrame)
}

public enum FramingError: Error, Equatable {
    case oversizedFrame(kind: UInt8, length: Int)
    case malformedChunk
}

public enum FrameCodec {
    public static func encodeControl(_ json: Data) -> Data {
        var out = Data(capacity: 5 + json.count)
        out.append(FrameKind.control.rawValue)
        out.appendBigEndian(UInt32(json.count))
        out.append(json)
        return out
    }

    public static func encode(_ chunk: ChunkFrame) -> Data {
        var out = Data(capacity: 5 + ProtocolConstants.chunkHeaderSize + chunk.data.count)
        out.append(FrameKind.fileChunk.rawValue)
        out.appendBigEndian(UInt32(ProtocolConstants.chunkHeaderSize + chunk.data.count))
        withUnsafeBytes(of: chunk.fileID.uuid) { out.append(contentsOf: $0) }
        out.appendBigEndian(chunk.seq)
        out.append(chunk.isLast ? 1 : 0)
        out.append(chunk.data)
        return out
    }

    static func decodeChunkPayload(_ payload: Data) throws -> ChunkFrame {
        guard payload.count >= ProtocolConstants.chunkHeaderSize else {
            throw FramingError.malformedChunk
        }
        let bytes = [UInt8](payload)
        let uuid = NSUUID(uuidBytes: bytes) as UUID
        var seq: UInt64 = 0
        for i in 16..<24 {
            seq = (seq << 8) | UInt64(bytes[i])
        }
        let isLast = bytes[24] != 0
        let data = Data(bytes[ProtocolConstants.chunkHeaderSize...])
        return ChunkFrame(fileID: uuid, seq: seq, isLast: isLast, data: data)
    }
}

/// Incremental frame parser. Feed it arbitrary byte segments from the stream;
/// it yields complete frames. Frames with an unknown kind byte are skipped
/// (forward compatibility), matching the unknown-type rule for messages.
public struct FrameReader: Sendable {
    private var buffer = Data()
    /// Count of skipped unknown-kind frames, surfaced for the debug HUD/logs.
    public private(set) var skippedUnknownFrames = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while true {
            guard buffer.count >= 5 else { break }
            let bytes = buffer.prefix(5)
            let kindByte = bytes[bytes.startIndex]
            var length: UInt32 = 0
            for i in 1...4 {
                length = (length << 8) | UInt32(bytes[bytes.startIndex + i])
            }
            let payloadLength = Int(length)
            let maxAllowed = max(
                ProtocolConstants.maxControlPayload,
                ProtocolConstants.maxChunkData + ProtocolConstants.chunkHeaderSize
            )
            guard payloadLength <= maxAllowed else {
                throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
            }
            guard buffer.count >= 5 + payloadLength else { break }
            let payload = Data(buffer.dropFirst(5).prefix(payloadLength))
            buffer = Data(buffer.dropFirst(5 + payloadLength))

            switch FrameKind(rawValue: kindByte) {
            case .control:
                guard payload.count <= ProtocolConstants.maxControlPayload else {
                    throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
                }
                frames.append(.control(payload))
            case .fileChunk:
                frames.append(.fileChunk(try FrameCodec.decodeChunkPayload(payload)))
            case nil:
                skippedUnknownFrames += 1
            }
        }
        return frames
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

import Foundation

/// TLV framing over the byte stream (spec §5.4): 1-byte kind, 4-byte big-endian
/// length, payload. Control frames carry canonical JSON; file-chunk frames carry
/// a fixed 25-byte binary header plus raw data (bulk side-channel, spec §6).
public enum FrameKind: UInt8, Sendable {
    case control = 0x01
    case fileChunk = 0x02
    case screenFrame = 0x03
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

/// A single encoded video frame on the wire (spec §6 SCREEN_FRAME, Phase 3).
/// Binary bulk data on the dedicated screen connection, parallel to ChunkFrame.
/// `sessionID` is a small per-connection id (multiple screen sessions never
/// share one bulk connection in v1, but the field keeps the format future-proof).
public struct ScreenFrame: Sendable, Equatable {
    public var sessionID: UInt16
    public var seq: UInt32
    public var isKeyframe: Bool
    /// Presentation timestamp, milliseconds; monotonic per session.
    public var ptsMillis: UInt64
    /// Packed encoded frame (parameter sets + sample data); see ScreenFrameCodec.
    public var data: Data

    public init(sessionID: UInt16, seq: UInt32, isKeyframe: Bool, ptsMillis: UInt64, data: Data) {
        self.sessionID = sessionID
        self.seq = seq
        self.isKeyframe = isKeyframe
        self.ptsMillis = ptsMillis
        self.data = data
    }
}

public enum Frame: Sendable, Equatable {
    case control(Data)
    case fileChunk(ChunkFrame)
    case screenFrame(ScreenFrame)
}

public enum FramingError: Error, Equatable {
    case oversizedFrame(kind: UInt8, length: Int)
    case malformedChunk
    case malformedScreenFrame
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

    public static func encode(_ frame: ScreenFrame) -> Data {
        var out = Data(capacity: 5 + ProtocolConstants.screenFrameHeaderSize + frame.data.count)
        out.append(FrameKind.screenFrame.rawValue)
        out.appendBigEndian(UInt32(ProtocolConstants.screenFrameHeaderSize + frame.data.count))
        out.appendBigEndian(frame.sessionID)
        out.appendBigEndian(frame.seq)
        out.append(frame.isKeyframe ? 1 : 0)
        out.appendBigEndian(frame.ptsMillis)
        out.append(frame.data)
        return out
    }

    static func decodeScreenPayload(_ payload: Data) throws -> ScreenFrame {
        guard payload.count >= ProtocolConstants.screenFrameHeaderSize else {
            throw FramingError.malformedScreenFrame
        }
        let bytes = [UInt8](payload)
        let sessionID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        var seq: UInt32 = 0
        for i in 2..<6 { seq = (seq << 8) | UInt32(bytes[i]) }
        let isKeyframe = bytes[6] != 0
        var pts: UInt64 = 0
        for i in 7..<15 { pts = (pts << 8) | UInt64(bytes[i]) }
        let data = Data(bytes[ProtocolConstants.screenFrameHeaderSize...])
        return ScreenFrame(sessionID: sessionID, seq: seq, isKeyframe: isKeyframe, ptsMillis: pts, data: data)
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
                max(
                    ProtocolConstants.maxChunkData + ProtocolConstants.chunkHeaderSize,
                    ProtocolConstants.maxScreenFrameData + ProtocolConstants.screenFrameHeaderSize
                )
            )
            guard payloadLength <= maxAllowed else {
                throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
            }
            guard buffer.count >= 5 + payloadLength else { break }
            let payload = Data(buffer.dropFirst(5).prefix(payloadLength))
            buffer = Data(buffer.dropFirst(5 + payloadLength))

            // The `maxAllowed` check above is only the shared ceiling — it lets a
            // file chunk ride in at the *screen* frame's 4 MiB limit, twice the
            // 2 MiB cap the protocol documents for chunks. Each kind is held to
            // its own cap here (2026-08-17; Go and Kotlin do the same).
            switch FrameKind(rawValue: kindByte) {
            case .control:
                guard payload.count <= ProtocolConstants.maxControlPayload else {
                    throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
                }
                frames.append(.control(payload))
            case .fileChunk:
                guard payloadLength <= ProtocolConstants.maxChunkData + ProtocolConstants.chunkHeaderSize else {
                    throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
                }
                frames.append(.fileChunk(try FrameCodec.decodeChunkPayload(payload)))
            case .screenFrame:
                guard payloadLength <= ProtocolConstants.maxScreenFrameData + ProtocolConstants.screenFrameHeaderSize else {
                    throw FramingError.oversizedFrame(kind: kindByte, length: payloadLength)
                }
                frames.append(.screenFrame(try FrameCodec.decodeScreenPayload(payload)))
            case nil:
                skippedUnknownFrames += 1
            }
        }
        return frames
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

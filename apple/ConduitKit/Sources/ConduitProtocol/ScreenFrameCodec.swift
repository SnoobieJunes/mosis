import Foundation

/// A decoded-from-the-wire video frame: the codec parameter sets (VPS/SPS/PPS
/// for HEVC, SPS/PPS for H.264) travel with every keyframe so a viewer that
/// joins or reconnects mid-stream can build its decoder without a side channel.
public struct EncodedVideoFrame: Sendable, Equatable {
    public var isKeyframe: Bool
    /// Codec parameter sets, in order. Present on keyframes; empty on deltas.
    public var parameterSets: [Data]
    /// The elementary-stream sample data (length-prefixed NAL units, AVCC/HVCC).
    public var sampleData: Data

    public init(isKeyframe: Bool, parameterSets: [Data], sampleData: Data) {
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.sampleData = sampleData
    }
}

public enum ScreenFrameCodecError: Error, Equatable {
    case truncated
    case tooManyParameterSets
}

/// Packs/unpacks an EncodedVideoFrame into the `data` blob of a ScreenFrame.
///
/// Layout: `paramСount u8 | [len u32be | bytes]... | sampleData (rest)`.
/// Deterministic and platform-neutral — the golden vectors pin it, and the
/// Go/Kotlin viewers of later phases decode the same bytes.
public enum ScreenFramePacking {
    static let maxParameterSets = 8

    public static func pack(_ frame: EncodedVideoFrame) -> Data {
        var out = Data()
        out.append(UInt8(min(frame.parameterSets.count, maxParameterSets)))
        for set in frame.parameterSets.prefix(maxParameterSets) {
            out.appendBigEndian(UInt32(set.count))
            out.append(set)
        }
        out.append(frame.sampleData)
        return out
    }

    public static func unpack(_ data: Data, isKeyframe: Bool) throws -> EncodedVideoFrame {
        var cursor = data.startIndex
        func need(_ n: Int) throws {
            guard data.distance(from: cursor, to: data.endIndex) >= n else {
                throw ScreenFrameCodecError.truncated
            }
        }
        try need(1)
        let count = Int(data[cursor]); cursor = data.index(after: cursor)
        guard count <= maxParameterSets else { throw ScreenFrameCodecError.tooManyParameterSets }

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for _ in 0..<count {
            try need(4)
            var len: UInt32 = 0
            for _ in 0..<4 {
                len = (len << 8) | UInt32(data[cursor])
                cursor = data.index(after: cursor)
            }
            try need(Int(len))
            let end = data.index(cursor, offsetBy: Int(len))
            sets.append(Data(data[cursor..<end]))
            cursor = end
        }
        let sampleData = Data(data[cursor...])
        return EncodedVideoFrame(isKeyframe: isKeyframe, parameterSets: sets, sampleData: sampleData)
    }
}

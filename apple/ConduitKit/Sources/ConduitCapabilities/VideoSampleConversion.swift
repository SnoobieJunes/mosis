import Foundation
import CoreMedia
import VideoToolbox
import ConduitProtocol

/// Bridges VideoToolbox's `CMSampleBuffer` to the wire `EncodedVideoFrame` and
/// back. Parameter sets (VPS/SPS/PPS) are pulled off the format description and
/// shipped with every keyframe; on decode they rebuild the format description
/// so a viewer joining mid-stream needs no side channel.
public enum VideoSampleConversion {
    /// NAL length prefix VideoToolbox uses in its AVCC/HVCC elementary streams.
    static let nalLengthHeaderSize: Int32 = 4

    // MARK: Encode side — CMSampleBuffer → EncodedVideoFrame

    public static func encodedFrame(from sampleBuffer: CMSampleBuffer) -> EncodedVideoFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var sampleData = Data()
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }
        sampleData = Data(bytes: dataPointer, count: totalLength)

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(from: format)
        }
        return EncodedVideoFrame(isKeyframe: isKeyframe, parameterSets: parameterSets, sampleData: sampleData)
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else {
            return true // no attachments → treat as sync
        }
        // A frame is a keyframe unless explicitly marked NotSync.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    static func parameterSets(from format: CMFormatDescription) -> [Data] {
        let subType = CMFormatDescriptionGetMediaSubType(format)
        var count = 0
        // First call to learn the count.
        if subType == kCMVideoCodecType_HEVC {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if subType == kCMVideoCodecType_HEVC {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            }
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }

    // MARK: Decode side — EncodedVideoFrame → CMSampleBuffer

    /// Builds a format description from a keyframe's parameter sets.
    public static func makeFormatDescription(
        parameterSets: [Data], codec: ScreenVideoCodec
    ) -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        // The parameter-set pointers must all stay valid across the CM call, so
        // enter every Data's withUnsafeBytes and only call at the innermost level.
        return withParameterSetPointers(parameterSets) { pointers, sizes in
            var format: CMFormatDescription?
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: nalLengthHeaderSize,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            } else {
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: nalLengthHeaderSize,
                    formatDescriptionOut: &format
                )
            }
            return status == noErr ? format : nil
        }
    }

    /// Recursively binds each parameter set, collecting stable pointers that
    /// stay valid for the duration of `body`.
    private static func withParameterSetPointers<R>(
        _ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R
    ) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func recurse(_ index: Int) -> R {
            if index == sets.count {
                return body(pointers, sizes)
            }
            return sets[index].withUnsafeBytes { raw in
                pointers.append(raw.bindMemory(to: UInt8.self).baseAddress!)
                sizes.append(raw.count)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }

    /// Wraps sample data in a CMSampleBuffer ready for VTDecompressionSession.
    /// CoreMedia allocates and owns the block memory (we copy into it), so the
    /// buffer's lifetime is self-contained — no associated-object retain games.
    public static func makeSampleBuffer(
        sampleData: Data, format: CMFormatDescription, pts: CMTime
    ) -> CMSampleBuffer? {
        let length = sampleData.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = sampleData.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: length
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import ConduitProtocol

/// Hardware video decoder wrapping VTDecompressionSession (spec §9 Phase 3
/// step 3). Fed `EncodedVideoFrame`s; emits decoded `CVPixelBuffer`s to render.
/// Builds (and rebuilds, on resolution change) its format description from the
/// parameter sets carried by keyframes, so it self-heals across reconnects.
public final class VideoDecoder: @unchecked Sendable {
    public enum DecoderError: Error {
        case noKeyframeYet
        case formatDescriptionFailed
        case sessionCreationFailed(OSStatus)
        case sampleBufferFailed
    }

    private let codec: ScreenVideoCodec
    private let onPixelBuffer: @Sendable (CVPixelBuffer, CMTime) -> Void
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var lastParameterSets: [Data] = []
    private var hasKeyframe = false

    public init(codec: ScreenVideoCodec, onPixelBuffer: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
        self.codec = codec
        self.onPixelBuffer = onPixelBuffer
    }

    /// Decodes one frame. Delta frames before the first keyframe are dropped
    /// (the caller should have requested a keyframe on join). Returns whether
    /// the frame was submitted for decode.
    @discardableResult
    public func decode(_ frame: EncodedVideoFrame, pts: CMTime) throws -> Bool {
        try lock.withLock {
            if frame.isKeyframe, !frame.parameterSets.isEmpty {
                try ensureSession(parameterSets: frame.parameterSets)
                hasKeyframe = true
            }
            guard hasKeyframe, let session, let formatDescription else {
                return false
            }
            guard let sampleBuffer = VideoSampleConversion.makeSampleBuffer(
                sampleData: frame.sampleData, format: formatDescription, pts: pts
            ) else {
                throw DecoderError.sampleBufferFailed
            }
            let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sampleBuffer, flags: flags,
                infoFlagsOut: &infoFlags
            ) { [weak self] status, _, imageBuffer, presentationTime, _ in
                guard status == noErr, let imageBuffer, let self else { return }
                self.onPixelBuffer(imageBuffer, presentationTime)
            }
            return status == noErr
        }
    }

    private func ensureSession(parameterSets: [Data]) throws {
        // Reuse the session while the parameter sets are unchanged.
        if session != nil, parameterSets == lastParameterSets {
            return
        }
        teardown()

        guard let format = VideoSampleConversion.makeFormatDescription(
            parameterSets: parameterSets, codec: codec
        ) else {
            throw DecoderError.formatDescriptionFailed
        }
        formatDescription = format
        lastParameterSets = parameterSets

        // Prefer a display-friendly pixel format; NV12 keeps zero-copy paths open.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw DecoderError.sessionCreationFailed(status)
        }
        session = created
    }

    private func teardown() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    public func stop() {
        lock.withLock {
            teardown()
            hasKeyframe = false
            formatDescription = nil
            lastParameterSets = []
        }
    }

    deinit { stop() }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock(); defer { unlock() }; return try body()
    }
}

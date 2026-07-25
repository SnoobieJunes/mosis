import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import ConduitProtocol

/// Hardware video encoder wrapping VTCompressionSession (spec §9 Phase 3 step 2):
/// HEVC with low-latency rate control, H.264 fallback, keyframe on demand,
/// runtime bitrate changes for adaptive streaming. Emits `EncodedVideoFrame`s
/// with parameter sets attached to every keyframe so a joining viewer is
/// self-sufficient.
public final class VideoEncoder: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrate: Int
        public var codec: ScreenVideoCodec
        /// Seconds between forced keyframes. Two for the interactive peer
        /// stream (spec §9 Phase 3: late joiners recover without asking); one
        /// for the HLS re-publish path, whose segmenter can only cut a new
        /// segment on a keyframe — a longer interval there produces segments
        /// that overshoot `EXT-X-TARGETDURATION` and stall players.
        public var keyframeIntervalSeconds: Int

        public init(width: Int, height: Int, fps: Int, bitrate: Int, codec: ScreenVideoCodec,
                    keyframeIntervalSeconds: Int = 2) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.codec = codec
            self.keyframeIntervalSeconds = keyframeIntervalSeconds
        }
    }

    public enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
        case notReady
        case encodeFailed(OSStatus)
    }

    private var session: VTCompressionSession?
    private let config: Configuration
    private let onFrame: @Sendable (EncodedVideoFrame, CMTime) -> Void
    private let lock = NSLock()
    private var forceKeyframeNext = false

    public init(config: Configuration, onFrame: @escaping @Sendable (EncodedVideoFrame, CMTime) -> Void) {
        self.config = config
        self.onFrame = onFrame
    }

    /// Whether HEVC hardware ENCODE is available; callers fall back to H.264.
    /// Probes encode (not decode) by attempting a throwaway compression session —
    /// `VTIsHardwareDecodeSupported` answers the wrong question for choosing an
    /// encoder, and a decode-only device would pick HEVC and then fail to encode.
    public static func isHEVCAvailable() -> Bool {
        var probe: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 640, height: 480,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &probe
        )
        if let probe { VTCompressionSessionInvalidate(probe) }
        return status == noErr && probe != nil
    }

    public func start() throws {
        let codecType: CMVideoCodecType = config.codec == .hevc
            ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = session

        // Low-latency, real-time streaming profile (spec §9 Phase 3 step 2).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if config.codec == .hevc {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
        }
        // Low-latency rate control where the OS supports the key.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        setBitrate(config.bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: config.fps))
        // Keyframe on a fixed cadence so late joiners recover without asking.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: config.fps * max(1, config.keyframeIntervalSeconds)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: max(1, config.keyframeIntervalSeconds)))
        // Pin BT.709 to avoid the HDR/wide-color washout pitfall (spec §9 Phase 3).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    public func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        // Hard data cap over a 1s window keeps latency bounded on drops.
        let limits = [bitrate / 8, 1] as [NSNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limits as CFArray)
    }

    public func requestKeyframe() {
        lock.lock(); forceKeyframeNext = true; lock.unlock()
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) throws {
        guard let session else { throw EncoderError.notReady }
        let forceKey = lock.withLock { () -> Bool in
            let v = forceKeyframeNext
            forceKeyframeNext = false
            return v
        }
        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handleEncoded(sampleBuffer)
        }
        guard status == noErr else { throw EncoderError.encodeFailed(status) }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let frame = VideoSampleConversion.encodedFrame(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame(frame, pts)
    }

    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { stop() }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock(); defer { unlock() }; return body()
    }
}

import Foundation
import CoreVideo
import CoreMedia
import Testing
@testable import ConduitCapabilities
import ConduitProtocol

/// Builds a synthetic pixel buffer with a moving gradient so successive frames
/// actually differ (delta frames carry data; the encoder produces real output).
private func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            ptr[offset + 0] = UInt8((x + tick * 7) & 0xFF)     // B
            ptr[offset + 1] = UInt8((y + tick * 3) & 0xFF)     // G
            ptr[offset + 2] = UInt8((x + y + tick * 5) & 0xFF) // R
            ptr[offset + 3] = 255                               // A
        }
    }
    return buffer
}

/// Thread-safe collector for encoder/decoder callbacks.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var encodedFrames: [(EncodedVideoFrame, CMTime)] = []
    private(set) var decodedSizes: [(Int, Int)] = []

    func addEncoded(_ frame: EncodedVideoFrame, _ pts: CMTime) {
        lock.lock(); encodedFrames.append((frame, pts)); lock.unlock()
    }
    func addDecoded(_ pb: CVPixelBuffer) {
        lock.lock()
        decodedSizes.append((CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)))
        lock.unlock()
    }
    var encoded: [(EncodedVideoFrame, CMTime)] { lock.lock(); defer { lock.unlock() }; return encodedFrames }
    var decoded: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return decodedSizes }
}

@Suite(.serialized) struct VideoPipelineTests {
    /// Full path: encode synthetic frames → CMSampleBuffer→EncodedVideoFrame →
    /// pack to the wire blob → parse back → decode → CVPixelBuffer. This proves
    /// the codec pipeline end to end with no screen-recording permission and no
    /// second device — the parts that DO need hardware are capture and render.
    @Test(.timeLimit(.minutes(2)))
    func hevcEncodeToDecodeRoundTrip() async throws {
        try await runRoundTrip(codec: .hevc)
    }

    @Test(.timeLimit(.minutes(2)))
    func h264EncodeToDecodeRoundTrip() async throws {
        try await runRoundTrip(codec: .h264)
    }

    private func runRoundTrip(codec: ScreenVideoCodec) async throws {
        let width = 640, height = 480, frameCount = 20
        let collector = Collector()

        let encoder = VideoEncoder(
            config: .init(width: width, height: height, fps: 30, bitrate: 4_000_000, codec: codec)
        ) { frame, pts in
            collector.addEncoded(frame, pts)
        }
        try encoder.start()

        // Force a keyframe on the first frame (the join behavior).
        encoder.requestKeyframe()
        for tick in 0..<frameCount {
            let pb = makePixelBuffer(width: width, height: height, tick: tick)
            let pts = CMTime(value: CMTimeValue(tick), timescale: 30)
            try encoder.encode(pb, pts: pts)
        }
        // Drain the async encoder.
        try await pollUntilVideo(timeout: 20) { collector.encoded.count >= frameCount / 2 }
        encoder.stop()
        try await pollUntilVideo(timeout: 5) { collector.encoded.count >= 1 }

        let encoded = collector.encoded
        #expect(!encoded.isEmpty, "encoder produced no frames")
        // The first emitted frame must be a keyframe carrying parameter sets.
        let firstKey = try #require(encoded.first { $0.0.isKeyframe })
        #expect(!firstKey.0.parameterSets.isEmpty, "keyframe must carry parameter sets")
        // HEVC has 3 parameter sets (VPS/SPS/PPS); H.264 has 2 (SPS/PPS).
        #expect(firstKey.0.parameterSets.count == (codec == .hevc ? 3 : 2))

        // Round-trip each frame through the wire packing + ScreenFrame framing.
        let decoder = VideoDecoder(codec: codec) { pb, _ in collector.addDecoded(pb) }
        var wireSeq: UInt32 = 0
        for (frame, pts) in encoded {
            let packed = try ScreenFramePacking.pack(frame)
            let screenFrame = ScreenFrame(
                sessionID: 1, seq: wireSeq, isKeyframe: frame.isKeyframe,
                ptsMillis: UInt64(wireSeq), data: packed
            )
            wireSeq += 1
            // Serialize + parse the binary frame exactly as the transport would.
            let wireBytes = FrameCodec.encode(screenFrame)
            var reader = FrameReader()
            let frames = try reader.append(wireBytes)
            guard case .screenFrame(let parsed) = try #require(frames.first) else {
                Issue.record("expected a screen frame"); continue
            }
            let unpacked = try ScreenFramePacking.unpack(parsed.data, isKeyframe: parsed.isKeyframe)
            #expect(unpacked == frame, "wire round-trip changed the encoded frame")
            _ = try decoder.decode(unpacked, pts: pts)
        }

        try await pollUntilVideo(timeout: 15) { collector.decoded.count >= 1 }
        decoder.stop()

        let decoded = collector.decoded
        #expect(!decoded.isEmpty, "decoder produced no pixel buffers")
        // Decoded frames must match the source dimensions.
        #expect(decoded.allSatisfy { $0 == (width, height) })
    }

    @Test func packingRoundTripPreservesFrame() throws {
        let keyframe = EncodedVideoFrame(
            isKeyframe: true,
            parameterSets: [Data([0x40, 0x01, 0x0c]), Data([0x42, 0x01]), Data([0x44, 0x01])],
            sampleData: Data((0..<200).map { UInt8($0 & 0xFF) })
        )
        let delta = EncodedVideoFrame(
            isKeyframe: false, parameterSets: [], sampleData: Data(repeating: 0xAB, count: 500)
        )
        for frame in [keyframe, delta] {
            let packed = try ScreenFramePacking.pack(frame)
            let unpacked = try ScreenFramePacking.unpack(packed, isKeyframe: frame.isKeyframe)
            #expect(unpacked == frame)
        }
    }

    @Test func truncatedPackedFrameThrows() {
        #expect(throws: ScreenFrameCodecError.self) {
            // Claims one parameter set of length 100 but supplies no bytes.
            _ = try ScreenFramePacking.unpack(Data([1, 0, 0, 0, 100]), isKeyframe: true)
        }
    }
}

func pollUntilVideo(timeout: Double, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

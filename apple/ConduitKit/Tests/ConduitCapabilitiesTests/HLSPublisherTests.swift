import Foundation
import CoreVideo
import CoreMedia
import Testing
@testable import ConduitCapabilities
import ConduitProtocol

/// Verifies the convenience-sender mechanism locally: the HLS re-publisher that
/// AirPlay / Google Cast / Matter Casting all point a TV at. We encode synthetic
/// frames (as in the Phase 3 pipeline), feed the decoded sample buffers to the
/// publisher, and confirm it produces a live HLS playlist + fMP4 segments and
/// serves them over its local HTTP server. The cast endpoints themselves need a
/// real TV; this proves the stream they'd load is real.
private func makePixelBuffer(width: Int, height: Int, tick: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let o = y * bpr + x * 4
            ptr[o] = UInt8((x + tick * 5) & 0xFF); ptr[o + 1] = UInt8((y + tick * 3) & 0xFF)
            ptr[o + 2] = UInt8((x + y + tick) & 0xFF); ptr[o + 3] = 255
        }
    }
    return buffer
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(EncodedVideoFrame, CMTime)] = []
    func add(_ f: EncodedVideoFrame, _ t: CMTime) { lock.lock(); frames.append((f, t)); lock.unlock() }
    var all: [(EncodedVideoFrame, CMTime)] { lock.lock(); defer { lock.unlock() }; return frames }
}

@Suite(.serialized) struct HLSPublisherTests {
    @Test(.timeLimit(.minutes(2))) func republishesAsServedHLS() async throws {
        let width = 640, height = 480
        let collector = FrameCollector()
        let encoder = VideoEncoder(config: .init(width: width, height: height, fps: 30, bitrate: 4_000_000, codec: .h264)) { frame, pts in
            collector.add(frame, pts)
        }
        try encoder.start()
        // Force periodic keyframes so the segmenter can cut multiple segments.
        for tick in 0..<48 {
            if tick % 12 == 0 { encoder.requestKeyframe() }
            let pb = makePixelBuffer(width: width, height: height, tick: tick)
            try encoder.encode(pb, pts: CMTime(value: CMTimeValue(tick), timescale: 30))
        }
        try await pollUntilVideo(timeout: 15) { collector.all.count >= 40 }
        encoder.stop()

        let encoded = collector.all
        let firstKey = try #require(encoded.first { $0.0.isKeyframe })
        let format = try #require(VideoSampleConversion.makeFormatDescription(parameterSets: firstKey.0.parameterSets, codec: .h264))

        // Feed the reconstructed sample buffers to the publisher.
        let publisher = HLSPublisher()
        let url = try publisher.start(formatHint: format)
        #expect(url.absoluteString.contains("/stream.m3u8"))
        defer { publisher.stop() }

        for (frame, pts) in encoded {
            if let sb = VideoSampleConversion.makeSampleBuffer(sampleData: frame.sampleData, format: format, pts: pts) {
                publisher.append(sb)
            }
        }

        // AVAssetWriter segments asynchronously; wait for an init + media segment.
        try await pollUntilVideo(timeout: 20) {
            publisher.initSegment() != nil && publisher.playlist().contains("seg")
        }
        let playlist = publisher.playlist()
        #expect(playlist.contains("#EXTM3U"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(playlist.contains(".m4s"))
        #expect(publisher.initSegment()?.isEmpty == false)

        // The local HTTP server actually serves the playlist + init segment.
        let host = url.host!, port = url.port!
        let m3u8 = try await httpGet("http://\(host):\(port)/stream.m3u8")
        #expect(String(decoding: m3u8, as: UTF8.self).contains("#EXTM3U"))
        let initSeg = try await httpGet("http://\(host):\(port)/init.mp4")
        #expect(!initSeg.isEmpty)

        // The zero-install viewer: the same server serves a page any browser on
        // the LAN can open. This is the only cast target that works when the TV
        // is neither an Apple TV nor a Chromecast.
        let page = try await httpGet("http://\(host):\(port)/")
        let html = String(decoding: page, as: UTF8.self)
        #expect(html.contains("<video"))
        #expect(html.contains("stream.m3u8"))
        #expect(publisher.watchPageURL?.path == "/")
    }

    private func httpGet(_ urlString: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: urlString)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return data
    }
}

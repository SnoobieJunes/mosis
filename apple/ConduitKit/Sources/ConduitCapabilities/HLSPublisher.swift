import Foundation
import AVFoundation
import CoreMedia
import Network
import ConduitTransport

/// Re-publishes a received Conduit screen stream as a live HLS URL so the
/// convenience senders (AirPlay / Google Cast / Matter Casting) can point a TV
/// at it (spec §9 Phase 6 step 6 — the hotel-TV scenario).
///
/// Reuses Phase 3's decoded `CMSampleBuffer`s: they're appended to an
/// AVAssetWriter in HLS-segmenting passthrough mode (no re-encode), and the
/// resulting fMP4 init + media segments are served from a tiny local HTTP
/// server. Cast SDKs all load a URL, so one mechanism feeds all three.
public final class HLSPublisher: NSObject, @unchecked Sendable {
    public private(set) var streamURL: URL?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var startTime: CMTime?

    private let state = Locked(Segments())
    private struct Segments {
        var initSegment: Data?
        var media: [(index: Int, data: Data, duration: Double)] = []
        var nextIndex = 0
        var mediaSeq = 0   // EXT-X-MEDIA-SEQUENCE of the first segment in the window
    }
    private let windowSize = 6          // ~ keep the last N segments live
    private var server: LocalHTTPServer?

    /// Begins publishing. `formatHint` is the video format description of the
    /// incoming stream (from the viewer's decoder). Returns the URL, or nil on
    /// failure. Call `append` for each decoded sample buffer thereafter.
    public func start(formatHint: CMFormatDescription, port: UInt16 = 0) -> URL? {
        guard !started else { return streamURL }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.started = true

        let server = LocalHTTPServer(publisher: self)
        guard let boundPort = server.start(port: port) else { return nil }
        self.server = server
        guard let host = Self.primaryLANAddress() else { return nil }
        let url = URL(string: "http://\(host):\(boundPort)/stream.m3u8")
        self.streamURL = url
        return url
    }

    /// Appends one decoded sample buffer (retimed so the first is at zero).
    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard started, let input, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = pts }
        let base = startTime ?? .zero
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeSubtract(pts, base),
            decodeTimeStamp: .invalid
        )
        if let retimed = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing]) {
            input.append(retimed)
        } else {
            _ = timing
            input.append(sampleBuffer)
        }
    }

    public func stop() {
        started = false
        input?.markAsFinished()
        writer?.finishWriting {}
        server?.stop()
        server = nil
        streamURL = nil
    }

    // MARK: HLS playlist + segment access (used by the HTTP server)

    func playlist() -> String {
        state.withValue { segs in
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:2",
                "#EXT-X-MEDIA-SEQUENCE:\(segs.mediaSeq)",
                "#EXT-X-MAP:URI=\"init.mp4\"",
            ]
            for seg in segs.media {
                lines.append(String(format: "#EXTINF:%.3f,", seg.duration))
                lines.append("seg\(seg.index).m4s")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    func initSegment() -> Data? { state.get().initSegment }

    func mediaSegment(index: Int) -> Data? {
        state.withValue { segs in segs.media.first { $0.index == index }?.data }
    }

    private static func primaryLANAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            let family = cur.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: cur.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("wlan") || name.hasPrefix("eth") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(cur.pointee.ifa_addr, socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return address
    }
}

extension HLSPublisher: AVAssetWriterDelegate {
    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        state.withValue { segs in
            switch segmentType {
            case .initialization:
                segs.initSegment = segmentData
            case .separable:
                let duration = segmentReport?.trackReports.first?.duration.seconds ?? 1.0
                segs.media.append((segs.nextIndex, segmentData, duration))
                segs.nextIndex += 1
                while segs.media.count > windowSize {
                    segs.media.removeFirst()
                    segs.mediaSeq += 1
                }
            @unknown default:
                break
            }
        }
    }
}

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os
import ConduitProtocol
import ConduitTransport

let castLog = Logger(subsystem: "org.mosis", category: "cast")

/// Puts this device's own screen on a TV, a browser, or any cast receiver —
/// with **no MOSIS peer on the other end**.
///
/// This is deliberately separate from `ScreenSourceEngine`, which streams to
/// paired MOSIS devices over the pinned-TLS wire and is tuned for interaction
/// (low latency, keyframes on demand, bitrate adapted from viewer acks). A cast
/// receiver wants the opposite: a segmented HLS stream with keyframes on
/// segment boundaries and a steady bitrate. Sharing one encoder would
/// compromise both, and ScreenCaptureKit is happy to run two streams.
///
/// Before this existed, "Cast to TV" was reachable only from inside the *viewer*
/// (`ScreenViewerScreen`), and `AppModel.castCurrentScreen` began with
/// `guard let render = activeScreenView else { return }` — so on a Mac, which is
/// almost never the viewer, the button did nothing at all, silently.
public final class LocalScreenCast: @unchecked Sendable {

    public enum CastError: LocalizedError {
        case noCapturer
        case notPermitted
        case noSources
        case encoderFailed
        case captureFailed(String)
        case publisherFailed(HLSPublisher.StartError)

        public var errorDescription: String? {
            switch self {
            case .noCapturer:
                "This device can't capture its screen."
            case .notPermitted:
                "Screen Recording is off. Grant MOSIS in System Settings → Privacy & Security → "
                    + "Screen Recording, then quit and reopen MOSIS."
            case .noSources:
                "No displays or windows are available to capture. If you just granted Screen "
                    + "Recording, quit and reopen MOSIS — ScreenCaptureKit keeps returning an "
                    + "empty list until the app restarts."
            case .encoderFailed:
                "The video encoder wouldn't start on this Mac."
            case .captureFailed(let detail):
                "Couldn't start screen capture: \(detail)"
            case .publisherFailed(let underlying):
                underlying.errorDescription
            }
        }
    }

    /// Frames per second for the cast stream. Lower than the interactive path:
    /// HLS is a few seconds behind whatever happens, so spending bandwidth on
    /// 60 fps buys nothing a viewer can perceive.
    public static let fps = 30
    public static let bitrate = 6_000_000

    private let capturer: any ScreenCapturer
    private let publisher = HLSPublisher()
    private let state = Locked(State())

    private struct State {
        var encoder: VideoEncoder?
        var format: CMFormatDescription?
        var codec: ScreenVideoCodec = .h264
        var running = false
        var framesPublished = 0
        var sourceName: String?
    }

    public init(capturer: any ScreenCapturer) {
        self.capturer = capturer
    }

    public var isRunning: Bool { state.get().running }
    public var framesPublished: Int { state.get().framesPublished }
    public var sourceName: String? { state.get().sourceName }
    public var streamURL: URL? { publisher.streamURL }

    /// Starts capturing `source` and publishing it as a live HLS stream.
    /// Returns the URL any player — AirPlay, Cast, or a plain browser — loads.
    public func start(source: CaptureSourceDescriptor) async throws -> URL {
        if isRunning {
            if let url = publisher.streamURL { return url }
            stop()   // running but never produced a URL — restart cleanly
        }
        guard await capturer.isPermitted() else {
            await capturer.requestPermission()
            throw CastError.notPermitted
        }

        let (width, height) = ScreenSourceEngine.fit(
            sourceW: source.width, sourceH: source.height, maxW: 1920, maxH: 1200
        )
        let codec: ScreenVideoCodec = VideoEncoder.isHEVCAvailable() ? .hevc : .h264

        // The publisher needs a format description before it can write anything,
        // and the only place that exists is the first keyframe's parameter sets.
        // So the encoder callback starts the publisher on that first keyframe
        // and appends everything after it.
        let publisher = self.publisher
        let state = self.state
        let encoder = VideoEncoder(
            config: .init(width: width, height: height, fps: Self.fps,
                          bitrate: Self.bitrate, codec: codec, keyframeIntervalSeconds: 1)
        ) { frame, pts in
            let format: CMFormatDescription? = state.withValue { current in
                if current.format == nil, frame.isKeyframe, !frame.parameterSets.isEmpty {
                    current.format = VideoSampleConversion.makeFormatDescription(
                        parameterSets: frame.parameterSets, codec: current.codec
                    )
                }
                return current.format
            }
            // Nothing decodable yet: the publisher can't be started from a
            // delta frame, and appending one would produce a stream no player
            // can open.
            guard let format else { return }
            if publisher.streamURL == nil {
                _ = try? publisher.start(formatHint: format)
            }
            guard let sample = VideoSampleConversion.makeSampleBuffer(
                sampleData: frame.sampleData, format: format, pts: pts
            ) else { return }
            publisher.append(sample)
            state.withValue { $0.framesPublished += 1 }
        }

        state.withValue {
            $0.codec = codec
            $0.format = nil
            $0.framesPublished = 0
            $0.encoder = encoder
            $0.sourceName = source.name
        }
        do {
            try encoder.start()
        } catch {
            state.withValue { $0.encoder = nil }
            throw CastError.encoderFailed
        }
        encoder.requestKeyframe()

        capturer.setStreamStoppedHandler { [weak self] error in
            castLog.warning("cast capture stopped: \(error?.localizedDescription ?? "ended")")
            self?.stop()
        }
        do {
            try await capturer.start(
                source: source,
                configuration: .init(width: width, height: height, fps: Self.fps)
            ) { pixelBuffer, pts in
                try? encoder.encode(pixelBuffer, pts: pts)
            }
        } catch {
            encoder.stop()
            state.withValue { $0.encoder = nil }
            throw CastError.captureFailed("\(error)")
        }
        state.withValue { $0.running = true }

        // The publisher only comes up on the first keyframe, which is one
        // capture callback away. Wait for it rather than handing back a URL
        // that 404s — or, as the old cast path did, silently handing back
        // nothing at all.
        for _ in 0..<100 {
            if let url = publisher.streamURL {
                castLog.info("casting \(source.name, privacy: .public) at \(url.absoluteString, privacy: .public)")
                return url
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw CastError.publisherFailed(.noFramesCaptured)
    }

    public func stop() {
        let encoder = state.withValue { current -> VideoEncoder? in
            let e = current.encoder
            current.encoder = nil
            current.format = nil
            current.running = false
            current.sourceName = nil
            return e
        }
        encoder?.stop()
        publisher.stop()
        Task { await capturer.stop() }
    }
}

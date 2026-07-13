#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ConduitProtocol

/// ScreenCaptureKit source (spec §9 Phase 3 step 2). Enumerates displays and
/// windows, captures the chosen one, and delivers CVPixelBuffers to the encoder.
/// Screen Recording (TCC) permission is required and surfaced through a guided
/// flow, mirroring the Accessibility flow from Phase 2.
public final class MacScreenCapturer: NSObject, ScreenCapturer, @unchecked Sendable, SCStreamOutput {
    private let queue = DispatchQueue(label: "org.conduit.screen.capture")
    private var stream: SCStream?
    private var frameHandler: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    public func isPermitted() async -> Bool {
        // Enumerating shareable content succeeds only with Screen Recording granted.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    public func requestPermission() async {
        // Touching SCShareableContent triggers the system permission prompt.
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public func availableSources() async throws -> [CaptureSourceDescriptor] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.notPermitted
        }
        var sources: [CaptureSourceDescriptor] = []
        for display in content.displays {
            sources.append(CaptureSourceDescriptor(
                id: "display:\(display.displayID)", kind: .display,
                name: "Display \(display.displayID) (\(display.width)×\(display.height))",
                width: display.width, height: display.height
            ))
        }
        // Only windows with a title and reasonable size are worth offering.
        for window in content.windows where (window.title?.isEmpty == false) {
            let width = Int(window.frame.width), height = Int(window.frame.height)
            guard width >= 100, height >= 100 else { continue }
            let app = window.owningApplication?.applicationName ?? ""
            sources.append(CaptureSourceDescriptor(
                id: "window:\(window.windowID)", kind: .window,
                name: app.isEmpty ? (window.title ?? "Window") : "\(app) — \(window.title ?? "")",
                width: width, height: height
            ))
        }
        return sources
    }

    public func start(
        source: CaptureSourceDescriptor,
        configuration: CaptureConfiguration,
        onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try makeFilter(for: source, content: content)

        let config = SCStreamConfiguration()
        config.width = configuration.width
        config.height = configuration.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // 3 is SCStream's practical floor for smooth delivery; deeper queues
        // just buffer stale frames (each slot is one frame-time of latency).
        config.queueDepth = 3
        config.showsCursor = true
        // Pin BT.709 to match the encoder and dodge the washout pitfall (spec).
        config.colorSpaceName = CGColorSpace.itur_709

        frameHandler = onFrame
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func makeFilter(for source: CaptureSourceDescriptor, content: SCShareableContent) throws -> SCContentFilter {
        switch source.kind {
        case .display:
            let id = UInt32(source.id.replacingOccurrences(of: "display:", with: "")) ?? 0
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureError.sourceNotFound
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            let id = UInt32(source.id.replacingOccurrences(of: "window:", with: "")) ?? 0
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.sourceNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        frameHandler = nil
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Skip frames the system marks as not "complete" (idle/blank updates).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameHandler?(pixelBuffer, pts)
    }
}
#endif

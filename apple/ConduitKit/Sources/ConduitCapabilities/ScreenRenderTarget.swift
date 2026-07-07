import Foundation
import AVFoundation
import CoreMedia
import ConduitProtocol
import ConduitTransport

/// The viewer's render surface: an AVSampleBufferDisplayLayer that VideoToolbox
/// decodes into and draws (spec §9 Phase 3 step 3, "VideoToolbox decode →
/// Metal/CALayer render" — this layer is exactly that path, lowest-latency).
/// The UI wraps `displayLayer` in a platform view; the viewer engine enqueues
/// rebuilt CMSampleBuffers marked for immediate display.
public final class ScreenRenderTarget: @unchecked Sendable {
    public let screenSessionID: String
    public let width: Int
    public let height: Int
    public let sourceName: String
    public let displayLayer = AVSampleBufferDisplayLayer()

    private let counter = Locked(0)
    /// Number of sample buffers enqueued for display. Lets tests confirm frames
    /// actually decoded and reached the layer without inspecting the GPU.
    public var enqueuedCount: Int { counter.get() }

    public init(screenSessionID: String, width: Int, height: Int, sourceName: String) {
        self.screenSessionID = screenSessionID
        self.width = width
        self.height = height
        self.sourceName = sourceName
        displayLayer.videoGravity = .resizeAspect
    }

    /// Enqueues a decoded-ready sample buffer for immediate display. Safe to
    /// call from any thread; hops to main for the layer.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        Self.markDisplayImmediately(sampleBuffer)
        counter.withValue { $0 += 1 }
        let box = SendableBox(sampleBuffer)
        DispatchQueue.main.async { [displayLayer] in
            let sampleBuffer = box.value
            if #available(iOS 17.0, macOS 14.0, *) {
                if displayLayer.sampleBufferRenderer.status == .failed {
                    displayLayer.sampleBufferRenderer.flush()
                }
                displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                if displayLayer.status == .failed { displayLayer.flush() }
                displayLayer.enqueue(sampleBuffer)
            }
        }
    }

    public func flush() {
        DispatchQueue.main.async { [displayLayer] in
            displayLayer.flushAndRemoveImage()
        }
    }

    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
                as? [NSMutableDictionary], let first = attachments.first else { return }
        first[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
}

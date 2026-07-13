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
    /// Frames go to the layer on a dedicated queue, not main: enqueueing is
    /// thread-safe, and hopping through main made every frame wait behind
    /// arbitrary UI work (layout, animations) — visible jitter at 60fps.
    private let renderQueue = DispatchQueue(label: "org.conduit.screen.render", qos: .userInteractive)
    /// Number of sample buffers enqueued for display. Lets tests confirm frames
    /// actually decoded and reached the layer without inspecting the GPU.
    public var enqueuedCount: Int { counter.get() }

    /// Optional secondary sink for the same decoded sample buffers, used by the
    /// convenience senders (AirPlay / Cast / Matter) to re-publish the received
    /// stream to a TV without disturbing on-screen display (Phase 6 step 6).
    private let tee = Locked<(@Sendable (CMSampleBuffer) -> Void)?>(nil)
    public func setSecondarySink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?) { tee.set(sink) }

    public init(screenSessionID: String, width: Int, height: Int, sourceName: String) {
        self.screenSessionID = screenSessionID
        self.width = width
        self.height = height
        self.sourceName = sourceName
        displayLayer.videoGravity = .resizeAspect
    }

    /// Enqueues a decoded-ready sample buffer for immediate display. Safe to
    /// call from any thread; hops to the render queue for the layer.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        Self.markDisplayImmediately(sampleBuffer)
        counter.withValue { $0 += 1 }
        tee.get()?(sampleBuffer)
        let box = SendableBox(sampleBuffer)
        renderQueue.async { [displayLayer] in
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
        // Same queue as enqueue so a flush can't reorder ahead of in-flight frames.
        renderQueue.async { [displayLayer] in
            displayLayer.flushAndRemoveImage()
        }
    }

    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
                as? [NSMutableDictionary], let first = attachments.first else { return }
        first[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
}

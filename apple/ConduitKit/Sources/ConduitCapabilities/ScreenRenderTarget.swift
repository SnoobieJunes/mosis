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

    private let failureCounter = Locked(0)
    /// How many times the display layer entered a `.failed` state (each one
    /// triggers a flush + keyframe request). Surfaced in the debug HUD; a
    /// climbing count means the decode path keeps dying.
    public var layerFailureCount: Int { failureCounter.get() }

    /// Invoked (on the main queue) when the layer fails and is flushed, so the
    /// viewer engine can ask the source for a fresh keyframe — without one, the
    /// flushed layer has nothing decodable to resume from and stays black.
    private let needsKeyframeHandler = Locked<(@Sendable () -> Void)?>(nil)
    public func setNeedsKeyframeHandler(_ handler: (@Sendable () -> Void)?) {
        needsKeyframeHandler.set(handler)
    }

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
    /// call from any thread; hops to main for the layer.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        Self.markDisplayImmediately(sampleBuffer)
        counter.withValue { $0 += 1 }
        tee.get()?(sampleBuffer)
        let box = SendableBox(sampleBuffer)
        DispatchQueue.main.async { [displayLayer, failureCounter, needsKeyframeHandler] in
            let sampleBuffer = box.value
            var didFail = false
            if #available(iOS 17.0, macOS 14.0, *) {
                if displayLayer.sampleBufferRenderer.status == .failed {
                    didFail = true
                    displayLayer.sampleBufferRenderer.flush()
                }
                displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                if displayLayer.status == .failed {
                    didFail = true
                    displayLayer.flush()
                }
                displayLayer.enqueue(sampleBuffer)
            }
            // A flushed layer resumes only from a keyframe; ask for one and count
            // the failure so the HUD shows a dying decode path instead of a freeze.
            if didFail {
                failureCounter.withValue { $0 += 1 }
                needsKeyframeHandler.get()?()
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

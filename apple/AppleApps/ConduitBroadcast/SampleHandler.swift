import ReplayKit
import CoreMedia
import ConduitCapabilities

/// ReplayKit broadcast upload extension (spec §9 Phase 3 step 4). Reads the
/// config the container app wrote to the shared App Group, opens a direct
/// pinned connection to the viewer, and streams encoded frames. The encoder
/// runs here (in-extension) and frames ship straight out — raw frames are never
/// buffered, respecting the ~50 MB extension memory cap.
class SampleHandler: RPBroadcastSampleHandler {
    private var streamer: BroadcastStreamer?

    /// Sendable weak handle so the async start Task can report errors back
    /// without capturing the (non-Sendable) handler itself.
    private final class HandlerRef: @unchecked Sendable {
        weak var handler: SampleHandler?
        init(_ handler: SampleHandler) { self.handler = handler }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let config = BroadcastSharedStore.read() else {
            finishBroadcastWithError(NSError(
                domain: "org.conduit.broadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Start screen sharing from inside Conduit (pick a Mac first)."]
            ))
            return
        }
        let streamer = BroadcastStreamer(config: config)
        self.streamer = streamer
        let ref = HandlerRef(self)
        Task {
            do {
                try await streamer.start()
            } catch {
                ref.handler?.finishBroadcastWithError(error)
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        streamer?.handleSampleBuffer(pixelBuffer, pts: pts)
    }

    override func broadcastFinished() {
        let streamer = self.streamer
        self.streamer = nil
        BroadcastSharedStore.clear()
        Task { await streamer?.finish() }
    }
}

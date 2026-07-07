import ReplayKit
import CoreMedia
import os
import ConduitCapabilities
import ConduitTransport

private let broadcastLog = Logger(subsystem: "org.conduit", category: "broadcast-ext")

/// ReplayKit broadcast upload extension (spec §9 Phase 3 step 4). Reads the
/// config the container app wrote to the shared App Group, opens a direct
/// pinned connection to the viewer, and streams encoded frames. The encoder
/// runs here (in-extension) and frames ship straight out — raw frames are never
/// buffered, respecting the ~50 MB extension memory cap.
///
/// Everything observable: every phase writes a `BroadcastStatus` into the App
/// Group (the app polls it for its UI), and every failure ends the broadcast
/// with a reason via `finishBroadcastWithError` — the red status-bar pill must
/// never keep "recording" a stream nobody is receiving.
class SampleHandler: RPBroadcastSampleHandler {
    /// If start() hangs past this (identity import or a dial stuck beyond its
    /// own timeouts), end the broadcast with the last known phase detail.
    static let startWatchdogSeconds: Double = 25

    private var streamer: BroadcastStreamer?
    private let lastDetail = Locked<String>("not started")
    private let finished = Locked<Bool>(false)

    /// Sendable weak handle so async tasks can report back without capturing
    /// the (non-Sendable) handler itself.
    private final class HandlerRef: @unchecked Sendable {
        weak var handler: SampleHandler?
        init(_ handler: SampleHandler) { self.handler = handler }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let config = BroadcastSharedStore.read() else {
            BroadcastSharedStore.writeStatus(BroadcastStatus(
                phase: .failed, detail: "no broadcast config — start from inside the app", viewerName: ""
            ))
            finishBroadcastWithError(NSError(
                domain: "org.conduit.broadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Start screen sharing from inside Conduit (pick a Mac first)."]
            ))
            return
        }
        let viewerName = config.viewerName
        let detail = lastDetail
        let ref = HandlerRef(self)
        let streamer = BroadcastStreamer(
            config: config,
            onLog: { line in broadcastLog.info("\(line, privacy: .public)") },
            onStatus: { phase, text, frames in
                detail.set(text)
                BroadcastSharedStore.writeStatus(BroadcastStatus(
                    phase: phase, detail: text, viewerName: viewerName, framesSent: frames
                ))
            },
            onEnded: { reason, clean in
                // Viewer went away / lane died mid-broadcast: stop the recording
                // and tell the user why.
                BroadcastSharedStore.writeStatus(BroadcastStatus(
                    phase: clean ? .ended : .failed, detail: reason, viewerName: viewerName
                ))
                ref.handler?.finishOnce(errorText: reason)
            }
        )
        self.streamer = streamer
        Task {
            do {
                try await streamer.start()
            } catch {
                broadcastLog.error("broadcast start failed: \(error, privacy: .public)")
                BroadcastSharedStore.writeStatus(BroadcastStatus(
                    phase: .failed, detail: "\(error)", viewerName: viewerName
                ))
                ref.handler?.finishOnce(errorText: "\(error)")
            }
        }
        // Watchdog: a start that neither returns nor throws (importer hang, a
        // stuck dial) must still end visibly instead of recording forever.
        let watchdogSeconds = SampleHandler.startWatchdogSeconds
        Task {
            try? await Task.sleep(for: .seconds(watchdogSeconds))
            guard await !streamer.isStreaming else { return }
            let text = "start timed out at: \(detail.get())"
            BroadcastSharedStore.writeStatus(BroadcastStatus(
                phase: .failed, detail: text, viewerName: viewerName
            ))
            ref.handler?.finishOnce(errorText: text)
        }
    }

    /// finishBroadcastWithError is not idempotent-safe to spam; gate it.
    private func finishOnce(errorText: String) {
        guard !finished.withValue({ let was = $0; $0 = true; return was }) else { return }
        finishBroadcastWithError(NSError(
            domain: "org.conduit.broadcast", code: 2,
            userInfo: [NSLocalizedDescriptionKey: errorText]
        ))
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        streamer?.handleSampleBuffer(pixelBuffer, pts: pts)
    }

    override func broadcastFinished() {
        finished.set(true)
        let streamer = self.streamer
        self.streamer = nil
        BroadcastSharedStore.clear()
        Task { await streamer?.finish() }
    }
}

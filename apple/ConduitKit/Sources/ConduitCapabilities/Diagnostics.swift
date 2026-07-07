import Foundation
import ConduitTransport

/// A point-in-time view of the device-critical seams for the debug HUD (spec §8;
/// the stats overlay doubles as the HUD). Everything here is app-internal — it
/// never crosses the wire. The fields are exactly what the device sessions (S1)
/// need to pin a failure to its sub-cause without a debugger: per-stage frame
/// counts, the input lane state, and the last reverse-dial target + outcome.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    // Screen source (this device sharing out).
    public var sourceSharing = false
    public var sourcePeer: String?
    public var sourceCodec: String?
    public var sourceFramesEncoded = 0
    public var sourceFramesSent = 0
    public var sourceBitrateKbps = 0

    /// Which connection screen frames ride: "bulk" (dedicated reverse-dialed
    /// lane) or "control" (fallback over the session link when that dial
    /// couldn't land). nil when not sharing/viewing.
    public var sourceLane: String?
    public var viewerLane: String?

    // Screen viewer (this device receiving).
    public var viewerAttached = false
    public var viewerFramesReceived = 0
    public var viewerFramesDecoded = 0
    public var viewerLayerFailures = 0
    public var viewerFps = 0.0
    public var viewerKbps = 0.0

    // Remote input.
    /// "reliable" | "datagram" | nil (not controlling).
    public var inputControllerLane: String?
    public var inputEventsSent = 0
    public var inputInjected = 0
    public var inputInjectFailures = 0

    // File transfer lane in use ("control" | "bulk").
    public var fileLane: String?

    // Last reverse-dial (files + screen + broadcast all use the same opener).
    public var lastDialTarget: String?
    /// "ok" | "waiting: <reason>" | "failed: <error>".
    public var lastDialResult: String?

    public init() {}
}

/// Thread-safe collector the engines report into from their own actors/queues.
/// One instance per node; `ConduitNode` snapshots it ~1 Hz into a
/// `.diagnosticsSnapshot` event. Lock-guarded (not an actor) so a capture-queue
/// callback or a socket thread can bump a counter without hopping executors.
public final class Diagnostics: @unchecked Sendable {
    private let state = Locked(DiagnosticsSnapshot())

    public init() {}

    public func snapshot() -> DiagnosticsSnapshot { state.get() }

    // MARK: Screen source

    public func sourceStarted(peer: String, codec: String) {
        state.withValue {
            $0.sourceSharing = true
            $0.sourcePeer = peer
            $0.sourceCodec = codec
            $0.sourceFramesEncoded = 0
            $0.sourceFramesSent = 0
        }
    }
    public func sourceEncoded() { state.withValue { $0.sourceFramesEncoded += 1 } }
    public func sourceSent(bitrateKbps: Int) {
        state.withValue { $0.sourceFramesSent += 1; $0.sourceBitrateKbps = bitrateKbps }
    }
    public func sourceStopped() {
        state.withValue {
            $0.sourceSharing = false; $0.sourcePeer = nil; $0.sourceCodec = nil; $0.sourceLane = nil
        }
    }
    public func sourceLane(_ lane: String?) { state.withValue { $0.sourceLane = lane } }

    // MARK: Screen viewer

    public func viewerAttached(_ attached: Bool) { state.withValue { $0.viewerAttached = attached } }
    public func viewerLane(_ lane: String?) { state.withValue { $0.viewerLane = lane } }
    public func viewerReceived() { state.withValue { $0.viewerFramesReceived += 1 } }
    public func viewerDecoded() { state.withValue { $0.viewerFramesDecoded += 1 } }
    public func viewerStats(fps: Double, kbps: Double, layerFailures: Int) {
        state.withValue { $0.viewerFps = fps; $0.viewerKbps = kbps; $0.viewerLayerFailures = layerFailures }
    }
    public func viewerEnded() {
        state.withValue {
            $0.viewerAttached = false; $0.viewerFps = 0; $0.viewerKbps = 0
            $0.viewerFramesReceived = 0; $0.viewerFramesDecoded = 0; $0.viewerLayerFailures = 0
            $0.viewerLane = nil
        }
    }

    // MARK: Input

    public func inputControllerLane(_ lane: String?) { state.withValue { $0.inputControllerLane = lane } }
    public func inputEventSent() { state.withValue { $0.inputEventsSent += 1 } }
    public func inputInjected() { state.withValue { $0.inputInjected += 1 } }
    public func inputInjectFailures(_ count: Int) { state.withValue { $0.inputInjectFailures = count } }

    // MARK: File + dial

    public func fileLane(_ lane: String?) { state.withValue { $0.fileLane = lane } }
    public func dial(target: String, result: String) {
        state.withValue { $0.lastDialTarget = target; $0.lastDialResult = result }
    }
}

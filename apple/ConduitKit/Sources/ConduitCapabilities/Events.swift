import Foundation
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// A peer visible on the network right now, labeled from its TXT record.
public struct DiscoveredPeer: Sendable, Identifiable, Equatable {
    public let endpoint: DiscoveredEndpoint
    public let deviceID: String?
    public let name: String
    public let deviceClassRaw: String
    public let isPaired: Bool

    public var id: String { endpoint.id }

    public init(endpoint: DiscoveredEndpoint, deviceID: String?, name: String, deviceClassRaw: String, isPaired: Bool) {
        self.endpoint = endpoint
        self.deviceID = deviceID
        self.name = name
        self.deviceClassRaw = deviceClassRaw
        self.isPaired = isPaired
    }
}

public struct TransferSnapshot: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable {
        case send, receive
    }

    public let fileID: String
    public let peerDeviceID: String
    public let name: String
    public let direction: Direction
    public let totalBytes: UInt64
    public var transferredBytes: UInt64
    public var bytesPerSecond: Double
    /// "control" or "bulk" — which lane is carrying the chunks (stats overlay).
    public var lane: String

    public var id: String { fileID + "/" + direction.rawValue }

    public var fractionComplete: Double {
        totalBytes == 0 ? 1 : Double(transferredBytes) / Double(totalBytes)
    }
}

/// Everything the UI consumes. One stream, emitted by ConduitNode.
public enum ConduitEvent: Sendable {
    case listenerReady(port: UInt16)
    case discoveredPeersChanged([DiscoveredPeer])
    case pinnedPeersChanged([PinnedPeer])
    case sessionStateChanged(deviceID: String, state: SessionState, backend: TransportBackendKind?)
    /// Repeated connect attempts to a paired peer are failing. Carries a
    /// diagnosed reason so "Connecting…" forever becomes an explanation the
    /// user can act on (the common one: the peer no longer trusts this device's
    /// identity, so the pairing has to be redone).
    case connectFailing(deviceID: String, reason: String, attempts: Int)
    /// The remote peer's advertised capabilities, surfaced when a session
    /// reaches ready so the UI can enable direction-specific actions (e.g.
    /// "control this Mac" only if it advertises input-inject).
    case remoteCapabilities(deviceID: String, capabilities: [String])
    case rttUpdated(deviceID: String, millis: Double)
    case pairingPrompt(PairingPromptInfo)
    case pairingCompleted(PinnedPeer)
    case pairingFailed(reason: String)
    case incomingFileOffer(fromDeviceID: String, offer: FileOfferBody)
    case transferUpdated(TransferSnapshot)
    case transferCompleted(fileID: String, savedTo: URL?)
    case transferFailed(fileID: String, reason: String)
    case clipboardReceived(fromDeviceID: String, body: ClipboardPushBody)
    case clipboardSent(toDeviceID: String)
    // Phase 2 — remote input (spec §9 Phase 2).
    /// Receiver: control by a peer became active/inactive. Drives the
    /// persistent on-screen indicator invariant.
    case inputActiveChanged(peerDeviceID: String, active: Bool)
    /// Receiver: a peer asked for control and the app should prompt the user.
    case inputConsentRequested(peerDeviceID: String, promptID: UUID)
    /// Receiver: injection is blocked because Accessibility is off.
    case inputPermissionNeeded(instructions: String)
    /// Receiver: a key was refused because the focused field is secure input.
    case inputSecureFieldBlocked
    /// Controller: control of a peer started (with its secure-input state).
    case inputControlStarted(peerDeviceID: String, secureInput: Bool)
    /// Controller: control ended cleanly.
    case inputControlEnded(peerDeviceID: String)
    /// Controller: control could not start / was refused.
    case inputControlFailed(reason: String)
    /// Controller: the receiver reported entering/leaving a secure-input field.
    case inputRemoteSecureInput(peerDeviceID: String, active: Bool)
    /// Receiver: injection is failing (rate-limited). A black-holed or broken
    /// injector is otherwise invisible — errors here used to be log-only.
    case inputInjectFailed(reason: String)
    // Phase 3 — screen sharing (spec §9 Phase 3).
    /// Source: a peer asked to view this screen; the UI shows the display/window
    /// picker over these sources and resolves it.
    case screenSourcePickRequested(peerDeviceID: String, sources: [CaptureSourceDescriptor])
    /// Source: this device started sharing its screen to a peer (indicator).
    case screenSourceStarted(peerDeviceID: String, sourceName: String)
    /// Source: sharing to a peer ended.
    case screenSourceEnded(peerDeviceID: String)
    /// Source: Screen Recording permission is needed; guide the user.
    case screenPermissionNeeded
    /// Viewer: a screen stream is starting; the UI should present the render
    /// target's layer.
    case screenViewerStarted(peerDeviceID: String, offer: ScreenOfferBody, render: ScreenRenderTarget)
    /// Viewer: live stats for the overlay (fps, kbps, decoded frames).
    case screenViewerStats(screenSessionID: String, fps: Double, kbps: Double)
    /// Viewer: the stream ended.
    case screenViewerEnded(screenSessionID: String)
    /// Either side: a screen session failed to start or died.
    case screenFailed(reason: String)
    /// Viewer: a screen stream failed to start or died with a reason the user
    /// should see (source-signaled failure, or the attach watchdog firing when
    /// the source's reverse-dial silently never lands). Carries the source peer
    /// so the UI can offer a Retry that re-requests the screen. App-internal,
    /// never on the wire.
    case screenViewerFailed(peerDeviceID: String, screenSessionID: String, reason: String)
    /// Phase 4: a notification mirrored from a source device, to display.
    case notificationReceived(fromDeviceID: String, body: NotificationBody)
    // Phase 7 — social permissions + multi-viewer.
    /// Source: a peer asks to join the live screen share; the UI prompts to grant
    /// view-only or control (or deny).
    case permissionRequested(peerDeviceID: String, capability: String, scope: String, promptID: UUID)
    /// Source: an additional viewer joined the share with a scope.
    case viewerJoined(peerDeviceID: String, scope: String)
    /// Source: an additional viewer was revoked (live).
    case viewerRevoked(peerDeviceID: String)
    /// Controller/viewer: a device-state update arrived from a peer (context).
    case deviceStateReceived(fromDeviceID: String, body: DeviceStateBody)
    /// Contexts: a matching profile is offered for the current context (one-tap).
    case profileOffered(profileID: String, name: String)
    /// Contexts: the suggestion engine surfaced an automation to confirm.
    case suggestionSurfaced(text: String, contextKey: String, actionKey: String)
    /// M2 — periodic (~1 Hz) diagnostics snapshot for the debug HUD. App-internal.
    case diagnosticsSnapshot(DiagnosticsSnapshot)
    case nodeLog(String)
}

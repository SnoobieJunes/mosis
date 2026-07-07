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
    case nodeLog(String)
}

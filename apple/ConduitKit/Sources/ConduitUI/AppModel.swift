import SwiftUI
import Observation
import ConduitProtocol
import ConduitSession
import ConduitTransport
import ConduitCapabilities

#if canImport(UIKit)
import UIKit
#endif

/// UI-facing state, fed by the node's event stream. Apps hold exactly one.
@MainActor
@Observable
public final class AppModel {
    public private(set) var node: ConduitNode?

    public var discovered: [DiscoveredPeer] = []
    public var pinned: [PinnedPeer] = []
    public var sessionStates: [String: SessionState] = [:]
    public var sessionBackends: [String: TransportBackendKind] = [:]
    public var rttMillis: [String: Double] = [:]
    public var transfers: [TransferSnapshot] = []
    public var pairingPrompt: PairingPromptInfo?
    public var incomingOffer: (fromDeviceID: String, offer: FileOfferBody)?
    public var toast: String?
    public var lastError: String?
    public var listenPort: UInt16?
    public var localName = ""
    public var localDeviceID = ""

    // Phase 2 — remote input state.
    /// Remote capabilities learned at session-ready, keyed by device ID.
    public var remoteInputCapable: [String: Bool] = [:]
    /// Receiver: Accessibility permission is off; drives the guided-enable prompt.
    public var inputPermissionPrompt: String?
    /// Receiver: a peer is asking to control this device; drives a consent alert.
    public var inputConsentPeerID: String?
    /// Receiver: which peer currently controls us (nil = none). Drives the
    /// persistent indicator + kill switch (spec invariant).
    public var inputControlledByPeerID: String?
    /// Controller: which peer we're currently driving (nil = none).
    public var controllingPeerID: String?
    /// Controller: the remote reported a secure-input (password) field.
    public var remoteSecureInput = false

    /// Spec §8: the stats overlay doubles as the debug HUD.
    public var showStats = false

    public var acceptPairing = false {
        didSet {
            let node = node
            let value = acceptPairing
            Task { await node?.setPairingAcceptance(value) }
        }
    }

    /// Security-scoped source URLs held for the duration of outgoing transfers.
    private var scopedSendURLs: [String: URL] = [:]
    private var eventTask: Task<Void, Never>?

    public init() {}

    // MARK: Bootstrap

    public func startIfNeeded() async {
        guard node == nil else { return }
        do {
            let config = Self.platformConfiguration()
            let store = FallbackIdentityStore(
                primary: KeychainIdentityStore(),
                fallback: FileIdentityStore(
                    fileURL: config.stateDirectory.appendingPathComponent("identity.json")
                )
            )
            let node = try ConduitNode(
                config: config,
                identityStore: store,
                inputInjector: ConduitNode.defaultInjector()
            )
            self.node = node
            localName = config.deviceName
            eventTask = Task { [weak self] in
                for await event in node.events {
                    self?.apply(event)
                }
            }
            try await node.start()
            localDeviceID = await node.localDeviceID
            pinned = await node.pinnedPeers()
        } catch {
            lastError = "Failed to start: \(error)"
        }
    }

    static func platformConfiguration() -> NodeConfiguration {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit", isDirectory: true)
        #if os(macOS)
        let receive = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit", isDirectory: true)
        let name = Host.current().localizedName ?? "Mac"
        let deviceClass = DeviceClass.desktop
        #else
        let receive = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = UIDevice.current.name
        let deviceClass: DeviceClass = UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #endif
        return NodeConfiguration(
            deviceName: name,
            deviceClass: deviceClass,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
            receiveDirectory: receive,
            stateDirectory: appSupport
        )
    }

    // MARK: Event application

    private func apply(_ event: ConduitEvent) {
        switch event {
        case .listenerReady(let port):
            listenPort = port
        case .discoveredPeersChanged(let peers):
            discovered = peers
        case .pinnedPeersChanged(let peers):
            pinned = peers
        case .sessionStateChanged(let id, let state, let backend):
            sessionStates[id] = state
            if let backend {
                sessionBackends[id] = backend
            }
            if state == .closed {
                sessionBackends.removeValue(forKey: id)
                rttMillis.removeValue(forKey: id)
                if controllingPeerID == id { controllingPeerID = nil }
                if inputControlledByPeerID == id { inputControlledByPeerID = nil }
            }
        case .remoteCapabilities(let id, let capabilities):
            remoteInputCapable[id] = capabilities.contains(CapabilityID.inputInject)
        case .rttUpdated(let id, let millis):
            rttMillis[id] = millis
        case .pairingPrompt(let prompt):
            pairingPrompt = prompt
        case .pairingCompleted(let peer):
            pairingPrompt = nil
            toast = "Paired with \(peer.name)"
        case .pairingFailed(let reason):
            pairingPrompt = nil
            lastError = "Pairing failed: \(reason)"
        case .incomingFileOffer(let from, let offer):
            incomingOffer = (from, offer)
        case .transferUpdated(let snapshot):
            upsertTransfer(snapshot)
        case .transferCompleted(let fileID, let savedTo):
            transfers.removeAll { $0.fileID == fileID }
            releaseScope(fileID: fileID)
            if let savedTo {
                toast = "Saved \(savedTo.lastPathComponent)"
                NotificationBridge.postIfBackgrounded(title: "File received", body: savedTo.lastPathComponent)
            } else {
                toast = "Transfer complete"
            }
        case .transferFailed(let fileID, let reason):
            transfers.removeAll { $0.fileID == fileID }
            releaseScope(fileID: fileID)
            lastError = "Transfer failed: \(reason)"
        case .clipboardReceived(let from, let body):
            if let text = body.textValue {
                PasteboardBridge.writeText(text)
                let sender = pinned.first { $0.deviceID == from }?.name ?? "peer"
                toast = "Clipboard from \(sender)"
                NotificationBridge.postIfBackgrounded(title: "Clipboard received", body: "From \(sender)")
            }
        case .clipboardSent:
            toast = "Clipboard sent"
        case .inputConsentRequested(let peerID, _):
            inputConsentPeerID = peerID
        case .inputActiveChanged(let peerID, let active):
            inputControlledByPeerID = active ? peerID : nil
            if active {
                toast = "\(peerName(peerID)) is controlling this device"
            }
        case .inputPermissionNeeded(let instructions):
            inputPermissionPrompt = instructions
        case .inputSecureFieldBlocked:
            toast = "Keys blocked: a password field is focused"
        case .inputControlStarted(let peerID, let secure):
            controllingPeerID = peerID
            remoteSecureInput = secure
            toast = "Controlling \(peerName(peerID))"
        case .inputControlEnded:
            controllingPeerID = nil
            remoteSecureInput = false
        case .inputControlFailed(let reason):
            controllingPeerID = nil
            toast = "Control ended: \(reason)"
        case .inputRemoteSecureInput(_, let active):
            remoteSecureInput = active
        case .nodeLog(let line):
            toast = line
        }
    }

    private func upsertTransfer(_ snapshot: TransferSnapshot) {
        if let index = transfers.firstIndex(where: { $0.id == snapshot.id }) {
            transfers[index] = snapshot
        } else {
            transfers.append(snapshot)
        }
    }

    private func releaseScope(fileID: String) {
        if let url = scopedSendURLs.removeValue(forKey: fileID) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: Intents (Connect = pull toward me, Share = push from me; spec §8)

    public func pair(with peer: DiscoveredPeer) {
        let node = node
        Task { await node?.beginPairing(withDiscoveredID: peer.id) }
    }

    public func resolvePairing(accept: Bool) {
        guard let prompt = pairingPrompt else { return }
        pairingPrompt = nil
        let node = node
        Task { await node?.resolvePairingPrompt(flowID: prompt.flowID, accept: accept) }
    }

    public func connect(_ peer: PinnedPeer) {
        let node = node
        Task { await node?.connect(toDevice: peer.deviceID) }
    }

    public func disconnect(_ peer: PinnedPeer) {
        let node = node
        Task { await node?.disconnect(deviceID: peer.deviceID) }
    }

    public func unpair(_ peer: PinnedPeer) {
        let node = node
        Task { await node?.unpair(deviceID: peer.deviceID) }
    }

    public func sendClipboard(to peer: PinnedPeer) {
        guard let text = PasteboardBridge.readText(), !text.isEmpty else {
            toast = "Clipboard has no text"
            return
        }
        let node = node
        Task { await node?.sendClipboard(.text(text), to: peer.deviceID) }
    }

    public func sendFile(url: URL, to deviceID: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        let node = node
        Task {
            let fileID = await node?.sendFile(url: url, to: deviceID)
            await MainActor.run {
                if let fileID, scoped {
                    self.scopedSendURLs[fileID] = url
                } else if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    public func respondToOffer(accept: Bool) {
        guard let offer = incomingOffer else { return }
        incomingOffer = nil
        let node = node
        Task { await node?.respondToFileOffer(fileID: offer.offer.fileID, accept: accept) }
    }

    // MARK: Remote input intents (Phase 2)

    public func resolveInputConsent(accept: Bool) {
        guard let peerID = inputConsentPeerID else { return }
        inputConsentPeerID = nil
        let node = node
        Task { await node?.resolveInputConsent(peerDeviceID: peerID, accept: accept) }
    }

    /// Guided Accessibility flow (spec §9 Phase 2 step 2): open the settings
    /// pane, then poll until the OS reports the permission granted.
    public func openInputPermissionSettings() {
        let node = node
        Task {
            await node?.openInputPermissionSettings()
            for _ in 0..<120 { // up to ~60s
                try? await Task.sleep(for: .milliseconds(500))
                if await node?.inputPermissionGranted() == true {
                    await MainActor.run { self.inputPermissionPrompt = nil }
                    return
                }
            }
        }
    }

    public func dismissInputPermissionPrompt() {
        inputPermissionPrompt = nil
    }

    /// Kill switch (spec invariant: instantly revocable on the receiver).
    public func stopBeingControlled() {
        let node = node
        Task { await node?.revokeInputControl() }
    }

    public func startControlling(_ peer: PinnedPeer) {
        let node = node
        Task { await node?.requestInputControl(of: peer.deviceID) }
    }

    public func stopControlling() {
        let node = node
        Task { await node?.stopInputControl() }
    }

    public func canControl(_ peer: PinnedPeer) -> Bool {
        // Advertised in the peer's HELLO; mirrored onto the pinned record's
        // class as a heuristic when we haven't connected yet (desktops/laptops).
        remoteInputCapable[peer.deviceID] ?? (peer.deviceClass == .desktop || peer.deviceClass == .laptop)
    }

    // Pointer/scroll/click/key/media forwarding used by the controller surface.
    public func pointerMove(dx: Double, dy: Double) {
        let node = node
        Task { await node?.sendPointerMove(dx: dx, dy: dy) }
    }

    public func scroll(dx: Double, dy: Double) {
        let node = node
        Task { await node?.sendScroll(dx: dx, dy: dy) }
    }

    public func click(_ button: PointerButton, action: InputAction, clickCount: Int = 1) {
        let node = node
        Task { await node?.sendClick(button, action: action, clickCount: clickCount) }
    }

    public func typeText(_ text: String, modifiers: [InputModifier] = []) {
        let node = node
        Task { await node?.sendText(text, modifiers: modifiers) }
    }

    public func specialKey(_ name: String, modifiers: [InputModifier] = []) {
        let node = node
        Task { await node?.sendSpecialKey(name, modifiers: modifiers) }
    }

    public func media(_ action: MediaAction, value: Double? = nil) {
        let node = node
        Task { await node?.sendMedia(action, value: value) }
    }

    // MARK: Presentation helpers

    public func state(of peer: PinnedPeer) -> SessionState {
        sessionStates[peer.deviceID] ?? .idle
    }

    public func peerName(_ deviceID: String) -> String {
        pinned.first { $0.deviceID == deviceID }?.name ?? String(deviceID.prefix(8))
    }
}

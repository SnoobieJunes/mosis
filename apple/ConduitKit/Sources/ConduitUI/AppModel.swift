import SwiftUI
import Observation
import ConduitProtocol
import ConduitSession
import ConduitTransport
import ConduitCapabilities

#if canImport(UIKit)
import UIKit
#endif

/// A viewer stream that failed or died, surfaced persistently with the source's
/// reason and a Retry that re-requests the same peer's screen — the antidote to
/// a viewer that used to sit blank forever.
public struct ScreenViewerFailure: Identifiable, Equatable, Sendable {
    public let peerDeviceID: String
    public let reason: String
    public var id: String { peerDeviceID + "|" + reason }
}

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

    // Phase 3 — screen sharing state.
    /// Remote screen-source capability learned at session-ready.
    public var remoteScreenCapable: [String: Bool] = [:]
    /// Source: a peer asked to view this screen; drives the display/window picker.
    public var screenPickPeerID: String?
    public var screenPickSources: [CaptureSourceDescriptor] = []
    /// Source: which peer this device is currently sharing its screen to.
    public var screenSourcingToPeerID: String?
    public var screenSourcingName: String?
    /// Viewer: the active stream we're displaying (render target + offer).
    public var activeScreenView: ScreenRenderTarget?
    public var activeScreenOffer: ScreenOfferBody?
    /// Viewer: a stream that failed or died — shown as a persistent, retryable
    /// error instead of a transient toast or (worse) a permanently blank screen.
    public var screenViewerError: ScreenViewerFailure?
    /// Viewer: true after the offer arrives but before the first frame — the
    /// source is dialing the bulk lane back. Drives a "Connecting…" overlay so
    /// the wait isn't an inscrutable black screen.
    public var screenViewerConnecting = false
    /// Viewer stats for the overlay.
    public var screenFps: Double = 0
    public var screenKbps: Double = 0
    /// iOS: the peer we're about to broadcast our screen to (drives the sheet).
    public var broadcastPeer: PinnedPeer?
    /// iOS: whether the shared broadcast config is written and the picker is ready.
    public var broadcastReady = false
    /// iOS: why the share couldn't be announced (offer/config failure) — shown
    /// in the sheet with a retry, instead of an eternal "Preparing…" spinner.
    public var broadcastPrepFailed: String?
    /// iOS: the extension's live status from the App Group (polled ~1 Hz while
    /// a broadcast is pending/active) — the app's only window into the
    /// separate broadcast process. Drives the banner + sheet status line.
    public var broadcastStatus: BroadcastStatus?
    private var broadcastPollTask: Task<Void, Never>?

    /// Phase 6 — convenience senders (AirPlay / Google Cast / Matter Casting):
    /// re-broadcast a screen we're viewing out to a nearby TV.
    public let castManager = CastManager()
    public var showCastSheet = false

    // Phase 7 — social permissions + contexts.
    /// Source: a peer is asking to join the live screen share (drives a grant prompt).
    public var viewerGrantPeerID: String?
    public var viewerGrantScope: String?
    /// Contexts: name of a profile currently offered for the context (one-tap).
    public var offeredProfileName: String?

    /// Why a paired peer won't connect, keyed by device id. Shown on the peer
    /// row so a stuck "Connecting…" explains itself (most often: the peer no
    /// longer trusts this device and the pairing must be redone).
    public var connectFailures: [String: String] = [:]

    /// macOS permission pre-flight (M5). nil = not checked yet / not applicable.
    /// Both are TCC grants tied to the app's signature + bundle id, so they
    /// reset on a bundle rename and silently disable the headline features.
    public var screenRecordingGranted: Bool?
    public var accessibilityGranted: Bool?
    public var showPermissions = false

    /// Spec §8: the stats overlay doubles as the debug HUD.
    public var showStats = false
    /// Latest ≈1 Hz device-seam snapshot behind the debug HUD (M2).
    public var diagnostics = DiagnosticsSnapshot()

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
                inputInjector: ConduitNode.defaultInjector(),
                screenCapturer: ConduitNode.defaultScreenCapturer()
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
        // The "Conduit" path components below are STATE LOCATIONS, not branding.
        // `<appSupport>/Conduit/peers.json` is the pinned-peer database and
        // `<group>/Conduit/` holds the identity the broadcast extension
        // authenticates with. Renaming them to "MOSIS" points the app at an
        // empty directory: every pairing silently disappears and the device
        // looks freshly installed. (The Downloads folder is the one exception —
        // it is genuinely user-facing — but it is left alone for consistency
        // with the migration below.)
        //
        // These move with the other identity-bearing names — the Keychain
        // service in IdentityStore, ProtocolConstants.serviceType, and the
        // frozen crypto domain strings — as one deliberate pre-publication
        // break with a written migration, never piecemeal.
        // See plans/01-rename-to-mosis.md.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit", isDirectory: true)
        #if os(macOS)
        let receive = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit", isDirectory: true)
        let name = Host.current().localizedName ?? "Mac"
        let deviceClass = DeviceClass.desktop
        let appGroupID: String? = nil
        let stateDir = appSupport
        #else
        let receive = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // An iPhone/iPad build can also run *on a Mac* ("Designed for iPad"),
        // where UIDevice reports the Mac's own name — so it appears on the
        // network as a second device with the same name as the real Mac app,
        // except it has no screen capturer and no input injector. That
        // ambiguity is unfixable from the far side, so label it here.
        var name = UIDevice.current.name
        if ProcessInfo.processInfo.isiOSAppOnMac {
            name += " (iPad app)"
        }
        let deviceClass: DeviceClass = UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        // Identity + peers live in the App Group so the broadcast extension can
        // authenticate as this device; falls back to app support if unavailable.
        let appGroupID: String? = BroadcastSharedStore.appGroupID
        let groupDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: BroadcastSharedStore.appGroupID)?
            .appendingPathComponent("Conduit", isDirectory: true)
        let stateDir = groupDir ?? appSupport
        #endif
        return NodeConfiguration(
            deviceName: name,
            deviceClass: deviceClass,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
            receiveDirectory: receive,
            stateDirectory: stateDir,
            appGroupID: appGroupID
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
        case .connectFailing(let id, let reason, _):
            connectFailures[id] = reason
        case .sessionStateChanged(let id, let state, let backend):
            sessionStates[id] = state
            if let backend {
                sessionBackends[id] = backend
            }
            if state == .ready { connectFailures.removeValue(forKey: id) }
            if state == .closed {
                sessionBackends.removeValue(forKey: id)
                rttMillis.removeValue(forKey: id)
                if controllingPeerID == id { controllingPeerID = nil }
                if inputControlledByPeerID == id { inputControlledByPeerID = nil }
            }
        case .remoteCapabilities(let id, let capabilities):
            remoteInputCapable[id] = capabilities.contains(CapabilityID.inputInject)
            remoteScreenCapable[id] = capabilities.contains(CapabilityID.screenSource)
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
        case .screenSourcePickRequested(let peerID, let sources):
            screenPickPeerID = peerID
            screenPickSources = sources
        case .screenSourceStarted(let peerID, let name):
            screenSourcingToPeerID = peerID
            screenSourcingName = name
        case .screenSourceEnded:
            screenSourcingToPeerID = nil
            screenSourcingName = nil
        case .screenPermissionNeeded:
            lastError = "Screen Recording permission is off. Enable MOSIS in System Settings → Privacy & Security → Screen Recording."
        case .screenViewerStarted(_, let offer, let render):
            activeScreenView = render
            activeScreenOffer = offer
            screenViewerError = nil        // a fresh attempt is underway
            screenViewerConnecting = true  // waiting on the bulk lane + first frame
        case .screenViewerStats(_, let fps, let kbps):
            screenFps = fps
            screenKbps = kbps
            screenViewerConnecting = false // frames are flowing
        case .screenViewerEnded:
            activeScreenView = nil
            activeScreenOffer = nil
            screenFps = 0
            screenKbps = 0
            screenViewerConnecting = false
        case .screenViewerFailed(let peerID, _, let reason):
            // The stream never started or died — drop the blank view and show a
            // persistent, actionable error rather than a toast that vanishes.
            activeScreenView = nil
            activeScreenOffer = nil
            screenFps = 0
            screenKbps = 0
            screenViewerConnecting = false
            screenViewerError = ScreenViewerFailure(peerDeviceID: peerID, reason: reason)
        case .screenFailed(let reason):
            // Not a toast: this is the message that explains why nothing
            // happened when the user asked to see a screen, and a toast that
            // vanishes reads exactly like "the button does nothing".
            lastError = reason
        case .inputInjectFailed(let reason):
            // Receiver side: the injector keeps rejecting events (the controller's
            // cursor is dead with no other signal). Surface it, don't just log.
            lastError = "Remote input isn't reaching this Mac: \(reason)"
        case .permissionRequested(let peerID, _, let scope, _):
            viewerGrantPeerID = peerID
            viewerGrantScope = scope
        case .viewerJoined(let peerID, let scope):
            toast = "\(peerName(peerID)) joined your screen (\(scope))"
        case .viewerRevoked(let peerID):
            toast = "Revoked \(peerName(peerID))"
        case .deviceStateReceived:
            break
        case .profileOffered(_, let name):
            offeredProfileName = name
        case .suggestionSurfaced(let text, _, _):
            toast = text
        case .diagnosticsSnapshot(let snapshot):
            diagnostics = snapshot
        case .notificationReceived(let from, let body):
            let sender = peerName(from)
            NotificationBridge.postAlways(
                title: body.title.isEmpty ? body.appName : body.title,
                body: body.body,
                subtitle: "\(body.appName) · \(sender)"
            )
            toast = "🔔 \(body.appName): \(body.title)"
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

    // MARK: Permission pre-flight (macOS; M5)

    /// Re-reads both TCC grants. Cheap enough to call on appear and after the
    /// user comes back from System Settings.
    public func refreshPermissions() async {
        #if os(macOS)
        guard let node else { return }
        screenRecordingGranted = await node.screenPermissionGranted()
        accessibilityGranted = await node.canReceiveInput ? await node.inputPermissionGranted() : nil
        #endif
    }

    public func requestScreenRecordingPermission() {
        let node = node
        Task {
            await node?.requestScreenPermission()
            await refreshPermissions()
        }
    }

    public func requestAccessibilityPermission() {
        let node = node
        Task {
            // Prompting IS the request on macOS (AXIsProcessTrustedWithOptions
            // with the prompt flag), and the injector owns that call.
            await node?.openInputPermissionSettings()
            await refreshPermissions()
        }
    }

    public func openScreenRecordingSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    public func openLocalNetworkSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #endif
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

    // MARK: Screen sharing intents (Phase 3)

    public func canViewScreen(of peer: PinnedPeer) -> Bool {
        remoteScreenCapable[peer.deviceID] ?? (peer.deviceClass == .desktop || peer.deviceClass == .laptop)
    }

    /// Connect = pull: view the peer's screen.
    public func viewScreen(of peer: PinnedPeer) {
        let node = node
        Task { await node?.requestScreen(from: peer.deviceID) }
    }

    public func stopViewingScreen() {
        guard let id = activeScreenOffer?.screenSessionID else { return }
        let node = node
        activeScreenView = nil
        activeScreenOffer = nil
        Task { await node?.stopViewingScreen(screenSessionID: id) }
    }

    /// Retry a failed screen view by re-requesting from the same source peer.
    public func retryScreenView() {
        guard let failure = screenViewerError else { return }
        screenViewerError = nil
        let node = node
        Task { await node?.requestScreen(from: failure.peerDeviceID) }
    }

    public func dismissScreenViewerError() {
        screenViewerError = nil
    }

    public func resolveScreenPick(sourceID: String?) {
        guard let peerID = screenPickPeerID else { return }
        screenPickPeerID = nil
        screenPickSources = []
        let node = node
        Task { await node?.resolveScreenPick(peerDeviceID: peerID, sourceID: sourceID) }
    }

    /// Source: stop sharing this device's screen (kill switch).
    public func stopSourcingScreen() {
        let node = node
        Task { await node?.stopSourcingScreen() }
    }

    // MARK: Convenience senders (Phase 6 step 6)

    /// Open the "cast this screen to a TV" sheet and begin discovering routes
    /// across AirPlay, Google Cast, and Matter Casting.
    public func openCastSheet() {
        castManager.startDiscovery()
        showCastSheet = true
    }

    public func castCurrentScreen(to route: CastRoute) {
        guard let render = activeScreenView else { return }
        castManager.cast(render, to: route)
        showCastSheet = false
        toast = "Casting to \(route.name)"
    }

    public func stopCasting() {
        castManager.stopCasting()
        castManager.stopDiscovery()
    }

    // MARK: Social permissions (Phase 7)

    /// Source: grant a peer view-only / control on the live screen, or deny (nil).
    public func resolveViewerGrant(scope: PermissionScope?) {
        guard let peerID = viewerGrantPeerID else { return }
        viewerGrantPeerID = nil
        viewerGrantScope = nil
        let node = node
        Task { await node?.resolveViewerGrant(peerDeviceID: peerID, scope: scope) }
    }

    /// Source: revoke an additional viewer live.
    public func revokeViewer(_ deviceID: String) {
        let node = node
        Task { await node?.revokeViewer(deviceID: deviceID) }
    }

    /// Viewer: ask to join a peer's live screen share.
    public func requestScreenJoin(from peer: PinnedPeer) {
        let node = node
        Task { await node?.requestScreenJoin(from: peer.deviceID) }
    }

    // iOS screen broadcast (Phase 3 step 4).
    #if os(iOS)
    public func beginScreenBroadcast(to peer: PinnedPeer) {
        broadcastReady = false
        broadcastPrepFailed = nil
        broadcastStatus = nil
        broadcastPeer = peer
        startBroadcastStatusPolling()
    }

    public func prepareBroadcast(to peer: PinnedPeer) async {
        broadcastPrepFailed = nil
        let scale = await UIScreen.main.scale
        let bounds = await UIScreen.main.bounds
        // Cap the long edge so the encoder stays comfortable on-device.
        let rawW = Int(bounds.width * scale)
        let rawH = Int(bounds.height * scale)
        let config = await node?.prepareIOSScreenBroadcast(to: peer.deviceID, width: rawW, height: rawH, fps: 30)
        broadcastReady = (config != nil)
        if config == nil {
            broadcastPrepFailed =
                "Couldn't announce the share to \(peer.name) — make sure it's connected, then try again."
        }
    }

    /// Cancels a pending share, or stops a live broadcast: retiring the offer
    /// makes the viewer close the bulk lane, which ends the extension. The one
    /// path behind the sheet's Cancel and the banner's Stop.
    public func stopIOSBroadcast() {
        broadcastPeer = nil
        broadcastReady = false
        broadcastStatus = nil
        stopBroadcastStatusPolling()
        BroadcastSharedStore.clearStatus()
        let node = node
        Task { await node?.endIOSScreenBroadcast() }
    }

    public func cancelBroadcastPrep() {
        stopIOSBroadcast()
    }

    /// The broadcast extension is a separate process; its only channel back to
    /// this app is the status file in the App Group. Poll it while a broadcast
    /// is pending or running and reflect it into UI state.
    private func startBroadcastStatusPolling() {
        guard broadcastPollTask == nil else { return }
        broadcastPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.applyBroadcastStatus(BroadcastSharedStore.readStatus())
            }
        }
    }

    private func stopBroadcastStatusPolling() {
        broadcastPollTask?.cancel()
        broadcastPollTask = nil
    }

    private func applyBroadcastStatus(_ status: BroadcastStatus?) {
        guard let status, status != broadcastStatus else { return }
        broadcastStatus = status
        switch status.phase {
        case .connecting, .streaming:
            break   // the banner + sheet render these live
        case .ended:
            toast = "Broadcast ended"
            concludeBroadcast()
        case .failed:
            lastError = "Screen broadcast failed: \(status.detail)"
            concludeBroadcast()
        }
    }

    /// The extension reported it's over (either way) — clean up app-side state
    /// and retire the offer so the viewer isn't left waiting.
    private func concludeBroadcast() {
        stopBroadcastStatusPolling()
        BroadcastSharedStore.clearStatus()
        broadcastStatus = nil
        broadcastReady = false
        broadcastPeer = nil
        let node = node
        Task { await node?.endIOSScreenBroadcast() }
    }
    #endif

    // MARK: Presentation helpers

    public func state(of peer: PinnedPeer) -> SessionState {
        sessionStates[peer.deviceID] ?? .idle
    }

    public func peerName(_ deviceID: String) -> String {
        pinned.first { $0.deviceID == deviceID }?.name ?? String(deviceID.prefix(8))
    }
}

import SwiftUI
import AVFoundation
import Combine
import ConduitProtocol
import ConduitSession
import ConduitTransport
import ConduitCapabilities

/// tvOS viewer app (spec §9 Phase 6 step 1): Apple TV as a Conduit screen viewer
/// + media target + notification display. LAN backend only (no Aware on tvOS),
/// pairing via an on-TV code. A thin app over ConduitCapabilities with its own
/// compact tvOS UI — no trackpad, no file transfer, no casting (the TV is the
/// cast target, not a sender). Acceptance: shows a Mac window stream controlled
/// from the phone.
@main
struct ConduitTVApp: App {
    @StateObject private var model = TVModel()
    var body: some Scene {
        WindowGroup {
            TVRootView(model: model)
                .task { await model.start() }
        }
    }
}

/// Compact view model wrapping ConduitNode's event stream for the tvOS viewer.
@MainActor
final class TVModel: ObservableObject {
    @Published var discovered: [DiscoveredPeer] = []
    @Published var pinned: [PinnedPeer] = []
    @Published var acceptPairing = false
    @Published var pairingPrompt: PairingPromptInfo?
    @Published var activeScreen: (render: ScreenRenderTarget, offer: ScreenOfferBody)?
    /// Name of the peer a screen request is in flight to (spinner in the list).
    @Published var pendingPeerName: String?
    /// Transient status line; auto-clears so it can't misreport state later.
    @Published var toast: String? {
        didSet {
            toastTask?.cancel()
            guard toast != nil else { return }
            toastTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.toast = nil
            }
        }
    }

    private var node: ConduitNode?
    private var toastTask: Task<Void, Never>?
    private var screenRequestTimeout: Task<Void, Never>?

    func start() async {
        guard node == nil else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conduit", isDirectory: true)
        let config = NodeConfiguration(
            deviceName: "Apple TV", deviceClass: .tv, appVersion: "0.1",
            receiveDirectory: support.appendingPathComponent("received"),
            stateDirectory: support
        )
        let store = FileIdentityStore(fileURL: support.appendingPathComponent("identity.json"))
        do {
            let node = try ConduitNode(config: config, identityStore: store)
            self.node = node
            Task { for await event in node.events { await apply(event) } }
            try await node.start()
            pinned = await node.pinnedPeers()
        } catch {
            toast = "Failed to start: \(error)"
        }
    }

    func setAcceptPairing(_ on: Bool) {
        acceptPairing = on
        let node = node
        Task { await node?.setPairingAcceptance(on) }
    }

    func resolvePairing(accept: Bool) {
        guard let p = pairingPrompt else { return }
        pairingPrompt = nil
        let node = node
        Task { await node?.resolvePairingPrompt(flowID: p.flowID, accept: accept) }
    }

    /// Connect to view a peer's screen (Connect = pull).
    func viewScreen(of peer: PinnedPeer) {
        let node = node
        pendingPeerName = peer.name
        screenRequestTimeout?.cancel()
        screenRequestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.pendingPeerName != nil else { return }
            self.pendingPeerName = nil
            self.toast = "No answer from \(peer.name) — approve the request on that device"
        }
        Task {
            await node?.connect(toDevice: peer.deviceID)
            await node?.requestScreen(from: peer.deviceID)
        }
    }

    private func apply(_ event: ConduitEvent) {
        switch event {
        case .discoveredPeersChanged(let peers): discovered = peers
        case .pinnedPeersChanged(let peers): pinned = peers
        case .pairingPrompt(let p): pairingPrompt = p
        case .pairingCompleted(let peer): toast = "Paired with \(peer.name)"
        case .screenViewerStarted(_, let offer, let render):
            screenRequestTimeout?.cancel()
            pendingPeerName = nil
            activeScreen = (render, offer)
        case .screenViewerEnded: activeScreen = nil
        case .screenViewerFailed(_, _, let reason):
            screenRequestTimeout?.cancel()
            pendingPeerName = nil
            activeScreen = nil
            toast = "Couldn't show that screen: \(reason)"
        case .screenFailed(let reason):
            screenRequestTimeout?.cancel()
            pendingPeerName = nil
            toast = "Screen: \(reason)"
        case .notificationReceived(_, let body): toast = "🔔 \(body.appName): \(body.title)"
        default: break
        }
    }
}

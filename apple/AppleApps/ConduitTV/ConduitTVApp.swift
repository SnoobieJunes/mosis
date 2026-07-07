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
    @Published var toast: String?

    private var node: ConduitNode?

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
        case .screenViewerStarted(_, let offer, let render): activeScreen = (render, offer)
        case .screenViewerEnded: activeScreen = nil
        case .notificationReceived(_, let body): toast = "🔔 \(body.appName): \(body.title)"
        default: break
        }
    }
}

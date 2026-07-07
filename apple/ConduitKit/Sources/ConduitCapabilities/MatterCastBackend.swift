#if canImport(MatterTvCastingBridge)
import Foundation
import MatterTvCastingBridge

/// Matter Casting sender (spec §9 Phase 6 step 6: "Matter Casting only if
/// ecosystem adoption has grown by then"). Compiles only when the Matter
/// Casting SDK (the connectedhomeip casting bridge) is linked — see
/// docs/adr/0011. Discovers Matter-capable casting players (Fire TV is the main
/// adopter today), connects, and launches the Conduit HLS URL via the
/// Content Launcher cluster.
///
/// The user asked for Matter Casting explicitly; this is the real Matter
/// Casting path, gated so the default build needs no extra dependency and the
/// thin-adoption reality doesn't hold the rest of Phase 6 hostage.
public final class MatterCastBackend: CastBackend {
    public let kind: CastKind = .matter
    public var isAvailable: Bool { MTRCastingApp.getShared() != nil }

    private var discoveredPlayers: [MCCastingPlayer] = []
    private var onRoutes: (@Sendable ([CastRoute]) -> Void)?

    public func startDiscovery(onRoutesChanged: @escaping @Sendable ([CastRoute]) -> Void) {
        guard let app = MTRCastingApp.getShared() else { onRoutesChanged([]); return }
        onRoutes = onRoutesChanged
        app.start { _ in }
        MCCastingPlayerDiscovery.sharedInstance().addDiscoveryEventsSubscriber { [weak self] players in
            guard let self else { return }
            self.discoveredPlayers = players
            self.onRoutes?(players.map { CastRoute(id: $0.identifier(), name: $0.deviceName(), kind: .matter) })
        }
        MCCastingPlayerDiscovery.sharedInstance().start()
    }

    public func stopDiscovery() {
        MCCastingPlayerDiscovery.sharedInstance().stop()
    }

    public func cast(url: URL, to route: CastRoute) {
        guard let player = discoveredPlayers.first(where: { $0.identifier() == route.id }) else { return }
        // Verify or establish a Matter commissioning connection to the player,
        // then launch the URL through its Content Launcher endpoint cluster.
        player.verifyOrEstablishConnection(
            completionBlock: { [weak self] err in
                if err == nil { self?.launch(url: url, on: player) }
            },
            desiredEndpointFilter: nil
        )
    }

    private func launch(url: URL, on player: MCCastingPlayer) {
        guard let endpoint = player.endpoints().first(where: {
            ($0 as? MCEndpoint)?.hasCluster(MCContentLauncherCluster.self) == true
        }) as? MCEndpoint else { return }
        let cluster = endpoint.cluster(for: MCContentLauncherCluster.self) as? MCContentLauncherCluster
        let command = cluster?.launchURLCommand()
        let request = MCContentLauncherClusterLaunchURLRequest()
        request.contentURL = url.absoluteString
        command?.invoke(request, context: nil, completion: { _, _, _ in }, timedInvokeTimeoutMs: 5000)
    }

    public func stopCasting() {
        MCCastingPlayerDiscovery.sharedInstance().stop()
    }
}
#endif

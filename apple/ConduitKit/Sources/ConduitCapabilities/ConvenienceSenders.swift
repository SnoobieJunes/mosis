import Foundation
import AVFoundation
import CoreMedia
import Observation
import ConduitTransport

/// Convenience senders (spec §9 Phase 6 step 6): re-broadcast a Conduit screen
/// the app is *viewing* out to a nearby TV — the hotel-TV scenario. Three
/// backends over one mechanism (the HLS re-publisher):
///   • AirPlay      — AVKit route picker + AVPlayer external playback (built-in)
///   • Google Cast  — the Cast SDK, when linked (#if canImport(GoogleCast))
///   • Matter Casting — the Matter Casting SDK, when linked
///
/// The two SDK backends compile only when their framework is present, so the
/// default build has no extra dependency; adding the SDK lights the backend up
/// (see docs/adr/0011). The user asked for all three, so all three are here.
public enum CastKind: String, Sendable, CaseIterable {
    case airplay = "AirPlay"
    case googleCast = "Google Cast"
    case matter = "Matter Casting"
}

public struct CastRoute: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: CastKind
    public init(id: String, name: String, kind: CastKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One casting technology. Backends discover routes and load the published URL.
public protocol CastBackend: AnyObject {
    var kind: CastKind { get }
    var isAvailable: Bool { get }
    func startDiscovery(onRoutesChanged: @escaping @Sendable ([CastRoute]) -> Void)
    func stopDiscovery()
    /// Begin playing the HLS URL on the given route.
    func cast(url: URL, to route: CastRoute)
    func stopCasting()
}

/// Coordinates the HLS re-publisher and the available cast backends, and drives
/// the "Cast this screen to a TV" flow from the viewer UI.
@MainActor
@Observable
public final class CastManager {
    public private(set) var routes: [CastRoute] = []
    public private(set) var activeRoute: CastRoute?
    public private(set) var isPublishing = false

    /// AirPlay's AVPlayer, exposed so the UI's AVRoutePickerView can target it.
    public let airPlayPlayer = AVPlayer()

    private let publisher = HLSPublisher()
    private var backends: [CastBackend] = []
    private var publishedURL: URL?
    private weak var renderTarget: ScreenRenderTarget?
    private let started = Locked(false)

    public init() {
        backends = Self.makeBackends(airPlayPlayer: airPlayPlayer)
    }

    /// Begins discovering routes across all available backends.
    public func startDiscovery() {
        for backend in backends where backend.isAvailable {
            let kind = backend.kind
            backend.startDiscovery { [weak self] newRoutes in
                Task { @MainActor in self?.mergeRoutes(newRoutes, kind: kind) }
            }
        }
    }

    public func stopDiscovery() {
        backends.forEach { $0.stopDiscovery() }
    }

    private func mergeRoutes(_ newRoutes: [CastRoute], kind: CastKind) {
        routes.removeAll { $0.kind == kind }
        routes.append(contentsOf: newRoutes)
        routes.sort { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Casts the screen the given render target is displaying to `route`. Starts
    /// the HLS re-publisher (teeing the render target's decoded frames) on first
    /// use, then hands the URL to the chosen backend.
    public func cast(_ renderTarget: ScreenRenderTarget, to route: CastRoute) {
        self.renderTarget = renderTarget
        beginPublishingIfNeeded(from: renderTarget) { [weak self] url in
            guard let self, let url else { return }
            Task { @MainActor in
                self.activeRoute = route
                self.backends.first { $0.kind == route.kind }?.cast(url: url, to: route)
            }
        }
    }

    public func stopCasting() {
        activeRoute.map { route in backends.first { $0.kind == route.kind }?.stopCasting() }
        activeRoute = nil
        renderTarget?.setSecondarySink(nil)
        publisher.stop()
        isPublishing = false
        started.set(false)
    }

    private func beginPublishingIfNeeded(from renderTarget: ScreenRenderTarget, then: @escaping @Sendable (URL?) -> Void) {
        if let url = publishedURL, isPublishing { then(url); return }
        let publisher = publisher
        let box = Locked<Bool>(false)
        // On the first teed sample buffer, start the publisher with its format
        // description; append all subsequent buffers.
        renderTarget.setSecondarySink { sampleBuffer in
            if !box.withValue({ let was = $0; $0 = true; return was }) {
                guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                let url = publisher.start(formatHint: fmt)
                then(url)
            }
            publisher.append(sampleBuffer)
        }
        isPublishing = true
    }

    private static func makeBackends(airPlayPlayer: AVPlayer) -> [CastBackend] {
        var list: [CastBackend] = [AirPlayBackend(player: airPlayPlayer)]
        #if canImport(GoogleCast)
        list.append(GoogleCastBackend())
        #endif
        #if canImport(MatterTvCastingBridge)
        list.append(MatterCastBackend())
        #endif
        return list
    }
}

/// AirPlay via AVKit. Route selection is the system AVRoutePickerView (shown by
/// the UI and pointed at `player`); casting = play the HLS URL with external
/// playback enabled, so it lands on the picked Apple TV / AirPlay 2 receiver.
public final class AirPlayBackend: CastBackend {
    public let kind: CastKind = .airplay
    public var isAvailable: Bool { true }   // AVKit is always present on Apple platforms
    private let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
        player.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
    }

    public func startDiscovery(onRoutesChanged: @escaping @Sendable ([CastRoute]) -> Void) {
        // AirPlay routes are enumerated by the system AVRoutePickerView the UI
        // presents; we surface a single entry that opens that picker.
        onRoutesChanged([CastRoute(id: "airplay-picker", name: "AirPlay…", kind: .airplay)])
    }

    public func stopDiscovery() {}

    public func cast(url: URL, to route: CastRoute) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    public func stopCasting() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

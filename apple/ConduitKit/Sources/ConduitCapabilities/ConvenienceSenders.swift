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

/// Coordinates the HLS re-publisher and the available cast backends.
///
/// Two sources feed it, and the second one is why this type was rewritten:
///  - **a stream this device is viewing** (`cast(_:to:)`) — the original
///    hotel-TV scenario: re-broadcast someone else's screen onward;
///  - **this device's own screen** (`castLocalScreen(source:to:)`) — which is
///    what a Mac user means by "cast to TV" and which previously had no path at
///    all. Every entry point was gated on `activeScreenView`, a viewer-only
///    value that is nil on a Mac, so the button was a guaranteed silent no-op.
@MainActor
@Observable
public final class CastManager {
    public private(set) var routes: [CastRoute] = []
    public private(set) var activeRoute: CastRoute?
    public private(set) var isPublishing = false
    /// Set whenever a cast attempt fails, so the UI can say why instead of
    /// appearing to ignore the tap.
    public var lastError: String?
    /// The URL any browser on the LAN can open to watch — shown with a QR code
    /// so a TV or a guest laptop needs nothing installed.
    public private(set) var watchURL: URL?
    /// What is being cast right now (a display/window name, or the peer's
    /// stream we're relaying), for the UI's status line.
    public private(set) var castingName: String?

    /// AirPlay's AVPlayer, exposed so the UI's AVRoutePickerView can target it.
    public let airPlayPlayer = AVPlayer()

    private let publisher = HLSPublisher()
    private var backends: [CastBackend] = []
    private weak var renderTarget: ScreenRenderTarget?
    /// Owns its own capturer + encoder when casting this device's own screen.
    private var localCast: LocalScreenCast?

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

    /// Casts **this device's own screen**. Owns a capturer and encoder of its
    /// own (see `LocalScreenCast`), so it works with no MOSIS peer involved —
    /// a Mac and a TV and nothing else.
    ///
    /// `route` may be nil: publishing alone is useful, because it yields the
    /// browser URL any TV, laptop, or tablet can open with nothing installed.
    public func castLocalScreen(
        source: CaptureSourceDescriptor, capturer: any ScreenCapturer, to route: CastRoute?
    ) async {
        lastError = nil
        stopSourcesOnly()
        let cast = LocalScreenCast(capturer: capturer)
        localCast = cast
        do {
            let url = try await cast.start(source: source)
            isPublishing = true
            watchURL = cast.streamURL.flatMap { _ in publisherWatchURL(from: url) }
            castingName = source.name
            if let route {
                activeRoute = route
                backends.first { $0.kind == route.kind }?.cast(url: url, to: route)
            }
        } catch {
            localCast = nil
            isPublishing = false
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Casts a stream this device is *viewing* onward to `route` — the original
    /// hotel-TV relay. Tees the render target's sample buffers into the same
    /// publisher.
    public func cast(_ renderTarget: ScreenRenderTarget, to route: CastRoute?) async {
        lastError = nil
        stopSourcesOnly()
        self.renderTarget = renderTarget
        let publisher = self.publisher
        let firstFrame = Locked(false)
        let urlBox = Locked<URL?>(nil)
        let errorBox = Locked<String?>(nil)
        renderTarget.setSecondarySink { sampleBuffer in
            if !firstFrame.withValue({ let was = $0; $0 = true; return was }) {
                guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                do { urlBox.set(try publisher.start(formatHint: fmt)) }
                catch { errorBox.set((error as? HLSPublisher.StartError)?.errorDescription ?? "\(error)") }
            }
            publisher.append(sampleBuffer)
        }
        isPublishing = true
        // Wait for the first frame to arrive and the publisher to come up,
        // rather than firing a completion that may never run — the old code
        // installed the sink and returned, so a stream with no frames left the
        // UI claiming to cast forever.
        for _ in 0..<100 {
            if let url = urlBox.get() {
                watchURL = publisherWatchURL(from: url)
                castingName = renderTarget.sourceName
                if let route {
                    activeRoute = route
                    backends.first { $0.kind == route.kind }?.cast(url: url, to: route)
                }
                return
            }
            if let failure = errorBox.get() {
                lastError = failure
                stopCasting()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        lastError = HLSPublisher.StartError.noFramesCaptured.errorDescription
        stopCasting()
    }

    public func stopCasting() {
        activeRoute.map { route in backends.first { $0.kind == route.kind }?.stopCasting() }
        activeRoute = nil
        stopSourcesOnly()
    }

    /// Tears down whatever is feeding the publisher without touching the route,
    /// so switching sources mid-cast doesn't drop the TV.
    private func stopSourcesOnly() {
        renderTarget?.setSecondarySink(nil)
        renderTarget = nil
        localCast?.stop()
        localCast = nil
        publisher.stop()
        isPublishing = false
        watchURL = nil
        castingName = nil
    }

    private func publisherWatchURL(from streamURL: URL) -> URL? {
        guard var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        return components.url
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

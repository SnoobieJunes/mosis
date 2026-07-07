#if canImport(GoogleCast)
import Foundation
import GoogleCast

/// Google Cast (Chromecast / Google TV) sender. Compiles only when the Google
/// Cast SDK is linked — add it via SPM/CocoaPods and set the receiver app id in
/// GCKCastOptions at launch (docs/adr/0011). Discovers Cast devices and loads
/// the Conduit HLS URL onto the chosen one.
///
/// The user asked for Google Cast-out explicitly; this is the real Cast SDK
/// path, gated so the default build needs no extra dependency.
public final class GoogleCastBackend: NSObject, CastBackend, GCKDiscoveryManagerListener, GCKSessionManagerListener {
    public let kind: CastKind = .googleCast
    public var isAvailable: Bool { GCKCastContext.isSharedInstanceInitialized() }

    private var onRoutes: (@Sendable ([CastRoute]) -> Void)?
    private var pendingURL: URL?

    public func startDiscovery(onRoutesChanged: @escaping @Sendable ([CastRoute]) -> Void) {
        guard GCKCastContext.isSharedInstanceInitialized() else {
            onRoutesChanged([]); return
        }
        onRoutes = onRoutesChanged
        let context = GCKCastContext.sharedInstance()
        context.discoveryManager.add(self)
        context.discoveryManager.startDiscovery()
        context.sessionManager.add(self)
        publishRoutes()
    }

    public func stopDiscovery() {
        guard GCKCastContext.isSharedInstanceInitialized() else { return }
        GCKCastContext.sharedInstance().discoveryManager.stopDiscovery()
    }

    private func publishRoutes() {
        let dm = GCKCastContext.sharedInstance().discoveryManager
        var routes: [CastRoute] = []
        for i in 0..<dm.deviceCount {
            let device = dm.device(at: i)
            routes.append(CastRoute(id: device.deviceID, name: device.friendlyName ?? "Chromecast", kind: .googleCast))
        }
        onRoutes?(routes)
    }

    public func didUpdateDeviceList() { publishRoutes() }
    public func didInsert(_ device: GCKDevice, at index: UInt) { publishRoutes() }
    public func didUpdate(_ device: GCKDevice, at index: UInt) { publishRoutes() }
    public func didRemove(_ device: GCKDevice, at index: UInt) { publishRoutes() }

    public func cast(url: URL, to route: CastRoute) {
        let dm = GCKCastContext.sharedInstance().discoveryManager
        var device: GCKDevice?
        for i in 0..<dm.deviceCount where dm.device(at: i).deviceID == route.id {
            device = dm.device(at: i)
        }
        guard let device else { return }
        pendingURL = url
        // Start a session; loadMedia fires when the session becomes current.
        GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
    }

    public func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        guard let url = pendingURL else { return }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString("Conduit", forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .live
        builder.contentType = "application/vnd.apple.mpegurl"
        builder.metadata = metadata
        let loadRequest = GCKMediaLoadRequestDataBuilder()
        loadRequest.mediaInformation = builder.build()
        session.remoteMediaClient?.loadMedia(with: loadRequest.build())
        pendingURL = nil
    }

    public func stopCasting() {
        guard GCKCastContext.isSharedInstanceInitialized() else { return }
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }
}
#endif

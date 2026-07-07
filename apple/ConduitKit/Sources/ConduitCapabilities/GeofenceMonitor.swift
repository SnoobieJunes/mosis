import Foundation

/// Geofence context source (spec §9 Phase 7 step 1). Produces region enter/exit
/// signals for the ContextCoordinator. Uses region monitoring (NOT continuous
/// GPS) to keep battery cost low (spec pitfall).
public protocol GeofenceProviding: Sendable {
    /// Start monitoring; `onRegion` fires with the region id on enter, nil on exit.
    func start(onRegion: @escaping @Sendable (String?) -> Void)
    func stop()
    /// Register a region to watch (name + center + radius meters).
    func addRegion(id: String, latitude: Double, longitude: Double, radius: Double)
    var isAuthorized: Bool { get }
}

// Region monitoring exists on iOS/macOS but NOT tvOS/watchOS, so the concrete
// backend is excluded there (you don't geofence from an Apple TV). The protocol
// above still exists everywhere for the ContextCoordinator to depend on.
#if canImport(CoreLocation) && !os(tvOS) && !os(watchOS)
import CoreLocation

/// Core Location region monitoring backend (iOS/macOS). Requires
/// "Always" location permission for background region monitoring; the app
/// requests it with an honest purpose string. iOS wakes the app on region
/// crossings, so profile *offers* fire on wake/notification tap — the app must
/// be honest in UX about what runs automatically vs one-tap (spec pitfall).
public final class GeofenceMonitor: NSObject, GeofenceProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var onRegion: (@Sendable (String?) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var isAuthorized: Bool {
        #if os(iOS)
        manager.authorizationStatus == .authorizedAlways
        #else
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
        #endif
    }

    public func start(onRegion: @escaping @Sendable (String?) -> Void) {
        self.onRegion = onRegion
        #if os(iOS)
        manager.requestAlwaysAuthorization()
        #endif
    }

    public func stop() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        onRegion = nil
    }

    public func addRegion(id: String, latitude: Double, longitude: Double, radius: Double) {
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: radius, identifier: id
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onRegion?(region.identifier)
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        onRegion?(nil)
    }
}
#endif

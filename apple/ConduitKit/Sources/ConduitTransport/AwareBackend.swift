import Foundation

/// Wi-Fi Aware backend — Phase 1 thin slice (spec §9 Phase 1 step 9).
///
/// Status: stub behind `ConduitFeatureFlags.wifiAwareEnabled` (currently false).
/// The com.apple.developer.wifi-aware entitlement has not been requested yet
/// (it needs a real App ID, which is pending product naming), so the real
/// implementation — DeviceDiscoveryUI pairing + Network framework over Aware —
/// is deferred. The LAN backend is the always-on fallback by design (spec §3);
/// nothing in Phase 1 depends on Aware.
///
/// When the entitlement lands: gate at runtime on
/// `WACapabilities.supportedFeatures.contains(.wifiAware)` (iPhone/iPad only)
/// and keep LAN as the automatic fallback path.
public enum AwareBackendStatus {
    /// Whether this build could ever offer Aware (flag + platform).
    public static var isAvailable: Bool {
        guard ConduitFeatureFlags.wifiAwareEnabled else { return false }
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    public static let unavailableReason =
        "Wi-Fi Aware entitlement not yet requested (needs final App ID); LAN backend in use."
}

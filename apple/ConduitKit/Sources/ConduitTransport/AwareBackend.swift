import Foundation

/// Wi-Fi Aware backend — Phase 1 thin slice (spec §9 Phase 1 step 9).
///
/// Status: stub behind `ConduitFeatureFlags.wifiAwareEnabled` (currently false).
/// The com.apple.developer.wifi-aware entitlement IS now granted for the final
/// App ID (org.auston.mosis) and carried in the iOS app's entitlements, but the
/// real implementation — WiFiAware framework publish/subscribe + Network
/// framework over Aware — remains deferred: it is iPhone/iPad-only, so none of
/// the Mac/iPhone/Apple TV beta flows can ride it. The LAN backend is the
/// always-on fallback by design (spec §3); nothing depends on Aware.
///
/// When implementing: gate at runtime on
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
        "Wi-Fi Aware entitlement granted (org.auston.mosis) but the Aware backend is not implemented yet; LAN backend in use."
}

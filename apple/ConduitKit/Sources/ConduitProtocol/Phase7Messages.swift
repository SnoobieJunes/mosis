import Foundation

/// Phase 7 message bodies (spec §9 Phase 7): device state for context signals,
/// and social permissions for multi-viewer screen sharing.

/// A device's live state, exchanged so the other side / the context engine can
/// react (spec §6: battery, charging, docked, foreground, display attached).
public struct DeviceStateBody: Codable, Sendable, Equatable {
    /// Battery fraction 0…1, or nil if unknown (desktops).
    public var battery: Double?
    public var charging: Bool
    public var docked: Bool
    /// Whether the sender's Conduit app is foregrounded (affects what runs).
    public var foreground: Bool
    /// Whether an external display is attached (desktop-mode / connected display).
    public var displayAttached: Bool

    enum CodingKeys: String, CodingKey {
        case battery, charging, docked, foreground
        case displayAttached = "display_attached"
    }

    public init(battery: Double?, charging: Bool, docked: Bool, foreground: Bool, displayAttached: Bool) {
        self.battery = battery
        self.charging = charging
        self.docked = docked
        self.foreground = foreground
        self.displayAttached = displayAttached
    }
}

/// Scope of a social permission: view a screen, or view-and-control (spec §7).
public enum PermissionScope: String, Codable, Sendable {
    case viewOnly = "view-only"
    case control = "control"
}

/// A viewer asks a source to join something it's sharing (spec §6 PERMISSION_*).
public struct PermissionRequestBody: Codable, Sendable, Equatable {
    /// The capability being requested, e.g. "screen-view".
    public var capability: String
    public var scope: PermissionScope

    public init(capability: String, scope: PermissionScope) {
        self.capability = capability
        self.scope = scope
    }
}

/// The source grants a peer a scoped permission, optionally time-limited.
public struct PermissionGrantBody: Codable, Sendable, Equatable {
    public var capability: String
    public var scope: PermissionScope
    /// The peer the grant is for (device id).
    public var peer: String
    /// Seconds until the grant auto-expires, or nil for no expiry.
    public var ttl: Int?

    public init(capability: String, scope: PermissionScope, peer: String, ttl: Int? = nil) {
        self.capability = capability
        self.scope = scope
        self.peer = peer
        self.ttl = ttl
    }
}

/// Revoke a previously granted permission, live (spec: revoked live).
public struct PermissionRevokeBody: Codable, Sendable, Equatable {
    public var capability: String
    public var peer: String

    public init(capability: String, peer: String) {
        self.capability = capability
        self.peer = peer
    }
}

import Foundation
import ConduitProtocol

/// Phase 7 Contexts & Routines (spec §9 Phase 7): profiles that notice context
/// and *offer* to act. Everything here is suggest-then-confirm — nothing runs
/// autonomously, and no context data ever leaves the device (invariant).

/// A snapshot of the signals a profile can match on (spec §9 Phase 7 step 1).
public struct ContextSignal: Sendable, Equatable {
    /// Geofence region the device is currently inside (Core Location region id),
    /// or nil. The actual region monitoring is platform code; this is the result.
    public var regionID: String?
    public var charging: Bool
    public var docked: Bool
    public var displayAttached: Bool
    /// Minutes since local midnight, for time-window matching.
    public var minuteOfDay: Int
    /// Day of week, 1 = Sunday … 7 = Saturday (Calendar convention).
    public var weekday: Int
    /// Device IDs of paired peers currently in range (discovered on the LAN).
    public var peersInRange: Set<String>

    public init(regionID: String? = nil, charging: Bool = false, docked: Bool = false,
                displayAttached: Bool = false, minuteOfDay: Int = 0, weekday: Int = 1,
                peersInRange: Set<String> = []) {
        self.regionID = regionID
        self.charging = charging
        self.docked = docked
        self.displayAttached = displayAttached
        self.minuteOfDay = minuteOfDay
        self.weekday = weekday
        self.peersInRange = peersInRange
    }
}

/// A condition a profile trigger tests against a ContextSignal. All conditions
/// in a profile must hold (AND) for it to match.
public enum TriggerCondition: Codable, Sendable, Equatable {
    case inRegion(String)
    case charging(Bool)
    case docked(Bool)
    case displayAttached(Bool)
    /// Inclusive minute-of-day window [start, end]; wraps past midnight if start > end.
    case timeWindow(start: Int, end: Int)
    case weekdays(Set<Int>)
    case peerInRange(String)

    func matches(_ s: ContextSignal) -> Bool {
        switch self {
        case .inRegion(let id): return s.regionID == id
        case .charging(let v): return s.charging == v
        case .docked(let v): return s.docked == v
        case .displayAttached(let v): return s.displayAttached == v
        case .timeWindow(let start, let end):
            if start <= end { return s.minuteOfDay >= start && s.minuteOfDay <= end }
            return s.minuteOfDay >= start || s.minuteOfDay <= end   // wraps midnight
        case .weekdays(let days): return days.contains(s.weekday)
        case .peerInRange(let id): return s.peersInRange.contains(id)
        }
    }
}

/// An action a profile can perform. Conduit-native ones run directly; platform
/// ones (Matter scene, Shortcut) route to the platform integration.
public enum RoutineAction: Codable, Sendable, Equatable {
    case connectPeer(deviceID: String)
    case startScreenShareToPeer(deviceID: String)
    case enableTrackpadForPeer(deviceID: String)
    /// Matter scene — the ONLY place Matter appears (spec §3). Handle is the
    /// platform home-graph scene identifier.
    case matterScene(handle: String)
    /// Run a donated Shortcut / App Intent by identifier (iOS) or fire an
    /// Android broadcast; platform-executed.
    case runShortcut(identifier: String)
}

/// A profile bundles a trigger (conditions), a set of actions, and grants.
public struct ContextProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var conditions: [TriggerCondition]
    public var actions: [RoutineAction]
    /// Whether the user has approved this profile to be *offered* automatically
    /// when it matches (still one-tap to run — never silent).
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, conditions: [TriggerCondition],
                actions: [RoutineAction], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.actions = actions
        self.enabled = enabled
    }

    /// True when every condition holds for the signal.
    public func matches(_ signal: ContextSignal) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { $0.matches(signal) }
    }
}

/// Evaluates context signals against profiles and yields an offer — never runs
/// anything itself (spec §9 Phase 7 invariant: suggest-then-confirm).
public struct ProfileEngine: Sendable {
    public var profiles: [ContextProfile]

    public init(profiles: [ContextProfile] = []) {
        self.profiles = profiles
    }

    /// The best profile to offer for a signal: the enabled profile with the most
    /// specific match (most conditions), or nil. Ties broken by declaration order.
    public func offer(for signal: ContextSignal) -> ContextProfile? {
        profiles
            .filter { $0.enabled && $0.matches(signal) }
            .max { $0.conditions.count < $1.conditions.count }
    }

    /// All matching profiles (a device may satisfy several), most specific first.
    public func allMatches(for signal: ContextSignal) -> [ContextProfile] {
        profiles
            .filter { $0.enabled && $0.matches(signal) }
            .sorted { $0.conditions.count > $1.conditions.count }
    }
}

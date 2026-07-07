import Foundation

/// On-device suggestion engine (spec §9 Phase 7 step 3): logs context+action
/// pairs locally and proposes automations from recurring patterns. Everything
/// is suggest-then-confirm; **data never leaves the device** (invariant) — the
/// log is a local file, the mining is plain arithmetic, no network call.
///
/// This heuristic miner is the portable baseline. On Apple platforms an Apple
/// Foundation Models pass can rank/phrase the proposals more naturally (device
/// only, familiar from Sclr); the heuristic is what the tests pin and what runs
/// everywhere.

/// One logged event: what the user did, in what context, when.
public struct ContextEvent: Codable, Sendable, Equatable {
    /// A coarse context key the miner groups on (region + rounded time + weekday
    /// bucket). Keeping it coarse is what lets a pattern emerge across days.
    public var contextKey: String
    /// The action taken, encoded (e.g. "connectPeer:<id>").
    public var actionKey: String
    /// Seconds since the epoch. Only day/time buckets are used, never exact times.
    public var timestamp: TimeInterval

    public init(contextKey: String, actionKey: String, timestamp: TimeInterval) {
        self.contextKey = contextKey
        self.actionKey = actionKey
        self.timestamp = timestamp
    }
}

/// A proposed automation the engine surfaces for the user to confirm.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public var id: String { contextKey + "|" + actionKey }
    public var contextKey: String
    public var actionKey: String
    /// How many distinct days this context→action pairing recurred.
    public var occurrences: Int
    /// Human-facing proposal text.
    public var text: String
}

/// Mines a local event log for "in context X you do Y" regularities.
public struct SuggestionEngine: Sendable {
    /// A pairing must recur on at least this many distinct days to be proposed —
    /// enough to be a habit, not a one-off (spec: "a week of real usage").
    public var minDistinctDays: Int

    public init(minDistinctDays: Int = 3) {
        self.minDistinctDays = minDistinctDays
    }

    /// Builds a stable context key from the parts the miner groups on.
    public static func contextKey(regionID: String?, minuteOfDay: Int, weekday: Int) -> String {
        let region = regionID ?? "-"
        // Round to a 30-minute bucket so 9:03 and 9:11 land together.
        let bucket = (minuteOfDay / 30) * 30
        // Weekday class: weekday vs weekend, so a daily habit doesn't need all 7.
        let dayClass = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"
        return "\(region)@\(bucket)/\(dayClass)"
    }

    /// Proposes automations from the log. A pairing is proposed when the same
    /// context→action happened on ≥ `minDistinctDays` distinct calendar days.
    public func suggestions(from events: [ContextEvent], calendar: Calendar = .current) -> [Suggestion] {
        // (contextKey, actionKey) → set of distinct day-stamps it occurred on.
        var days: [String: Set<Int>] = [:]
        for event in events {
            let key = event.contextKey + "\u{1}" + event.actionKey
            let day = Int(event.timestamp / 86_400)   // distinct calendar-ish day
            days[key, default: []].insert(day)
        }
        var out: [Suggestion] = []
        for (key, dayset) in days where dayset.count >= minDistinctDays {
            let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out.append(Suggestion(
                contextKey: parts[0], actionKey: parts[1], occurrences: dayset.count,
                text: Self.phrase(context: parts[0], action: parts[1], occurrences: dayset.count)
            ))
        }
        // Most-recurring first.
        return out.sorted { $0.occurrences > $1.occurrences }
    }

    static func phrase(context: String, action: String, occurrences: Int) -> String {
        let when = context.replacingOccurrences(of: "@", with: " around ")
            .replacingOccurrences(of: "/", with: " on ")
        let act = action
            .replacingOccurrences(of: "connectPeer:", with: "connect to ")
            .replacingOccurrences(of: "startScreenShareToPeer:", with: "share your screen to ")
            .replacingOccurrences(of: "enableTrackpadForPeer:", with: "arm trackpad mode for ")
        return "You’ve \(act) \(occurrences)× in this context (\(when)). Make it a one-tap profile?"
    }
}

/// A tiny append-only local store for the context log (data never leaves device).
public actor ContextLog {
    private let fileURL: URL
    private var events: [ContextEvent] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ContextEvent].self, from: data) {
            events = decoded
        }
    }

    public func record(_ event: ContextEvent) {
        events.append(event)
        // Keep a bounded rolling window (about 60 days of dense use).
        if events.count > 5000 { events.removeFirst(events.count - 5000) }
        persist()
    }

    public func all() -> [ContextEvent] { events }

    public func clear() {
        events.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

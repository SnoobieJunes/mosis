import Foundation
import ConduitProtocol
import ConduitTransport

/// Ties the context pieces together (spec §9 Phase 7): profiles are matched
/// against signals and *offered*; when the user runs one, its actions execute
/// and the context→action pair is logged for the suggestion engine. Nothing
/// runs autonomously; context data never leaves the device.
public actor ContextCoordinator {
    public private(set) var profiles: [ContextProfile]
    private let profileEngine: () -> ProfileEngine
    private let log: ContextLog
    private let suggester: SuggestionEngine
    private let emit: @Sendable (ConduitEvent) -> Void
    /// Performs one action; returns whether it succeeded. Supplied by the app so
    /// the coordinator stays free of platform/node specifics.
    private let perform: @Sendable (RoutineAction) async -> Bool

    private var lastOffered: String?

    public init(
        profiles: [ContextProfile],
        log: ContextLog,
        suggester: SuggestionEngine = SuggestionEngine(),
        emit: @escaping @Sendable (ConduitEvent) -> Void,
        perform: @escaping @Sendable (RoutineAction) async -> Bool
    ) {
        self.profiles = profiles
        self.log = log
        self.suggester = suggester
        self.emit = emit
        self.perform = perform
        self.profileEngine = { ProfileEngine(profiles: profiles) }
    }

    public func setProfiles(_ profiles: [ContextProfile]) {
        self.profiles = profiles
    }

    /// Feed a fresh context signal. If a profile matches, it's *offered* (one
    /// tap) via an event — never run automatically (spec invariant).
    public func ingest(_ signal: ContextSignal) {
        guard let offer = ProfileEngine(profiles: profiles).offer(for: signal) else {
            lastOffered = nil
            return
        }
        // Don't spam the same offer repeatedly for the same context.
        guard offer.id != lastOffered else { return }
        lastOffered = offer.id
        emit(.profileOffered(profileID: offer.id, name: offer.name))
    }

    /// The user tapped to run a profile. Execute its actions and log the
    /// context→action pairs so the suggestion engine can learn the habit.
    public func run(profileID: String, in signal: ContextSignal) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let contextKey = SuggestionEngine.contextKey(
            regionID: signal.regionID, minuteOfDay: signal.minuteOfDay, weekday: signal.weekday
        )
        for action in profile.actions {
            _ = await perform(action)
            await log.record(ContextEvent(
                contextKey: contextKey, actionKey: Self.actionKey(action),
                timestamp: Date().timeIntervalSince1970
            ))
        }
    }

    /// Records a single ad-hoc action the user took manually (not via a profile),
    /// so the suggester can notice a forming habit and propose automating it.
    public func recordManualAction(_ action: RoutineAction, in signal: ContextSignal) async {
        let contextKey = SuggestionEngine.contextKey(
            regionID: signal.regionID, minuteOfDay: signal.minuteOfDay, weekday: signal.weekday
        )
        await log.record(ContextEvent(
            contextKey: contextKey, actionKey: Self.actionKey(action),
            timestamp: Date().timeIntervalSince1970
        ))
    }

    /// Mines the log and surfaces any new automation proposals.
    public func refreshSuggestions() async {
        let events = await log.all()
        let suggestions = suggester.suggestions(from: events)
        // Only surface ones not already a profile.
        let existingActions = Set(profiles.flatMap { $0.actions.map(Self.actionKey) })
        for s in suggestions where !existingActions.contains(s.actionKey) {
            emit(.suggestionSurfaced(text: s.text, contextKey: s.contextKey, actionKey: s.actionKey))
        }
    }

    static func actionKey(_ action: RoutineAction) -> String {
        switch action {
        case .connectPeer(let id): return "connectPeer:\(id)"
        case .startScreenShareToPeer(let id): return "startScreenShareToPeer:\(id)"
        case .enableTrackpadForPeer(let id): return "enableTrackpadForPeer:\(id)"
        case .matterScene(let handle): return "matterScene:\(handle)"
        case .runShortcut(let id): return "runShortcut:\(id)"
        }
    }
}

/// Executes RoutineActions against the running node + platform integrations.
/// Conduit-native actions route to the node; Matter scenes to the Matter
/// controller; shortcuts to the platform (App Intents / Android broadcast).
public struct RoutineExecutor: Sendable {
    let node: ConduitNode
    /// Activates a Matter scene by handle; nil where Matter isn't wired.
    let matterScene: (@Sendable (String) async -> Bool)?

    public init(node: ConduitNode, matterScene: (@Sendable (String) async -> Bool)? = nil) {
        self.node = node
        self.matterScene = matterScene
    }

    public func perform(_ action: RoutineAction) async -> Bool {
        switch action {
        case .connectPeer(let id):
            await node.connect(toDevice: id)
            return true
        case .startScreenShareToPeer(let id):
            await node.requestScreen(from: id)   // pull-to-view; source-initiated push is a variant
            return true
        case .enableTrackpadForPeer(let id):
            await node.requestInputControl(of: id)
            return true
        case .matterScene(let handle):
            return await matterScene?(handle) ?? false
        case .runShortcut:
            // Platform-executed (App Intents on iOS, broadcast on Android); the
            // app layer wires this. No-op in the portable core.
            return true
        }
    }
}

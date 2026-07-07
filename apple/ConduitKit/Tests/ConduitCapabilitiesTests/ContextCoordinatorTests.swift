import Foundation
import Testing
@testable import ConduitCapabilities
import ConduitTransport

/// The context loop end to end (without a node): running a profile executes its
/// actions and logs the context→action pairs, and after enough distinct days
/// the suggestion engine surfaces the habit. Proves the "walk into the office →
/// offer the Office profile → suggestions from a week of usage" acceptance at
/// the logic level (geofencing/Matter/App-Intents are device-gated on top).
@Suite struct ContextCoordinatorTests {
    private func tempLog() -> ContextLog {
        ContextLog(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("ctx.log"))
    }

    @Test func offersAMatchingProfileOncePerContext() async {
        let office = ContextProfile(name: "Office", conditions: [.inRegion("office"), .weekdays([2,3,4,5,6])],
                                    actions: [.connectPeer(deviceID: "mac")])
        let offered = Locked<[String]>([])
        let coord = ContextCoordinator(profiles: [office], log: tempLog(),
            emit: { if case .profileOffered(_, let name) = $0 { offered.withValue { $0.append(name) } } },
            perform: { _ in true })
        let atOffice = ContextSignal(regionID: "office", minuteOfDay: 9 * 60, weekday: 3)
        await coord.ingest(atOffice)
        await coord.ingest(atOffice)   // same context again → not re-offered
        #expect(offered.get() == ["Office"])
    }

    @Test func runningAProfilePerformsActionsAndLogs() async {
        let performed = Locked<[RoutineAction]>([])
        let log = tempLog()
        let office = ContextProfile(name: "Office", conditions: [.inRegion("office")],
            actions: [.connectPeer(deviceID: "mac"), .matterScene(handle: "desk-a")])
        let coord = ContextCoordinator(profiles: [office], log: log, emit: { _ in },
            perform: { action in performed.withValue { $0.append(action) }; return true })
        let signal = ContextSignal(regionID: "office", minuteOfDay: 9 * 60, weekday: 3)
        await coord.run(profileID: office.id, in: signal)
        #expect(performed.get().count == 2)
        #expect(performed.get().contains(.matterScene(handle: "desk-a")))
        #expect(await log.all().count == 2)
    }

    @Test func aWeekOfManualActionsSurfacesASuggestion() async {
        let log = tempLog()
        let surfaced = Locked<[String]>([])
        // No profile yet — the user connects to the office Mac manually each
        // weekday morning. After enough days, propose automating it.
        let coord = ContextCoordinator(profiles: [], log: log,
            suggester: SuggestionEngine(minDistinctDays: 3),
            emit: { if case .suggestionSurfaced(_, _, let action) = $0 { surfaced.withValue { $0.append(action) } } },
            perform: { _ in true })
        // Manually record the same action across 4 weekday mornings.
        for day in 0..<4 {
            let signal = ContextSignal(regionID: "office", minuteOfDay: 9 * 60 + 4, weekday: 3)
            // Backdate by writing directly to the log (record uses "now"); emulate
            // distinct days via the log's own timestamps by recording then poking.
            await log.record(ContextEvent(
                contextKey: SuggestionEngine.contextKey(regionID: signal.regionID, minuteOfDay: signal.minuteOfDay, weekday: signal.weekday),
                actionKey: "connectPeer:mac-office",
                timestamp: Double(10 + day) * 86_400 + 9 * 3600))
        }
        await coord.refreshSuggestions()
        #expect(surfaced.get() == ["connectPeer:mac-office"])
    }

    @Test func doesNotSuggestSomethingAlreadyAProfile() async {
        let log = tempLog()
        let existing = ContextProfile(name: "Office", conditions: [.inRegion("office")],
            actions: [.connectPeer(deviceID: "mac-office")])
        let surfaced = Locked(false)
        let coord = ContextCoordinator(profiles: [existing], log: log,
            suggester: SuggestionEngine(minDistinctDays: 3),
            emit: { if case .suggestionSurfaced = $0 { surfaced.set(true) } }, perform: { _ in true })
        for day in 0..<4 {
            await log.record(ContextEvent(contextKey: "office@540/weekday", actionKey: "connectPeer:mac-office",
                                          timestamp: Double(10 + day) * 86_400))
        }
        await coord.refreshSuggestions()
        #expect(surfaced.get() == false, "shouldn't propose automating what's already a profile")
    }
}

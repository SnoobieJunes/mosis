import Foundation
import Testing
@testable import ConduitCapabilities

@Suite struct ProfileEngineTests {
    // Office: at the office region, on weekdays, ~9am, with the office Mac in range.
    private let officeMac = "mac-office-id"
    private func officeProfile() -> ContextProfile {
        ContextProfile(name: "Office", conditions: [
            .inRegion("office"),
            .weekdays([2, 3, 4, 5, 6]),
            .timeWindow(start: 8 * 60, end: 10 * 60),
            .peerInRange(officeMac),
        ], actions: [
            .connectPeer(deviceID: officeMac),
            .enableTrackpadForPeer(deviceID: officeMac),
            .matterScene(handle: "desk-scene-a"),
        ])
    }
    private func homeProfile() -> ContextProfile {
        ContextProfile(name: "Home", conditions: [.inRegion("home")], actions: [.matterScene(handle: "home-lights")])
    }

    @Test func matchesTheOfficeProfileWalkingIn() {
        let engine = ProfileEngine(profiles: [homeProfile(), officeProfile()])
        // 9:05 on a Tuesday, at the office, Mac in range.
        let signal = ContextSignal(regionID: "office", minuteOfDay: 9 * 60 + 5, weekday: 3, peersInRange: [officeMac])
        let offer = engine.offer(for: signal)
        #expect(offer?.name == "Office")
        #expect(offer?.actions.contains(.matterScene(handle: "desk-scene-a")) == true)
    }

    @Test func doesNotMatchOnWeekend() {
        let engine = ProfileEngine(profiles: [officeProfile()])
        let saturday = ContextSignal(regionID: "office", minuteOfDay: 9 * 60, weekday: 7, peersInRange: [officeMac])
        #expect(engine.offer(for: saturday) == nil)
    }

    @Test func doesNotMatchWithoutThePeerInRange() {
        let engine = ProfileEngine(profiles: [officeProfile()])
        let noMac = ContextSignal(regionID: "office", minuteOfDay: 9 * 60, weekday: 3, peersInRange: [])
        #expect(engine.offer(for: noMac) == nil)
    }

    @Test func mostSpecificProfileWins() {
        // Both match "home"; the more-specific one (extra conditions) is offered.
        let broad = ContextProfile(name: "Home", conditions: [.inRegion("home")], actions: [])
        let specific = ContextProfile(name: "Home Evening", conditions: [
            .inRegion("home"), .timeWindow(start: 18 * 60, end: 23 * 60), .charging(true),
        ], actions: [])
        let engine = ProfileEngine(profiles: [broad, specific])
        let evening = ContextSignal(regionID: "home", charging: true, minuteOfDay: 20 * 60, weekday: 4)
        #expect(engine.offer(for: evening)?.name == "Home Evening")
    }

    @Test func timeWindowWrapsMidnight() {
        let night = ContextProfile(name: "Night", conditions: [.timeWindow(start: 22 * 60, end: 6 * 60)], actions: [])
        let engine = ProfileEngine(profiles: [night])
        #expect(engine.offer(for: ContextSignal(minuteOfDay: 23 * 60)) != nil)   // 11pm
        #expect(engine.offer(for: ContextSignal(minuteOfDay: 2 * 60)) != nil)    // 2am
        #expect(engine.offer(for: ContextSignal(minuteOfDay: 12 * 60)) == nil)   // noon
    }

    @Test func profilesEncodeAndDecode() throws {
        let profile = officeProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ContextProfile.self, from: data)
        #expect(decoded == profile)
    }
}

@Suite struct SuggestionEngineTests {
    private func event(_ context: String, _ action: String, day: Int, minute: Int = 9 * 60) -> ContextEvent {
        ContextEvent(contextKey: context, actionKey: action, timestamp: Double(day) * 86_400 + Double(minute) * 60)
    }

    @Test func proposesARecurringHabit() {
        let ctx = SuggestionEngine.contextKey(regionID: "office", minuteOfDay: 9 * 60 + 5, weekday: 3)
        // Same connect-to-office-Mac after the office geofence, 4 distinct days.
        let events = (10...13).map { day in event(ctx, "connectPeer:mac-office", day: day) }
        let engine = SuggestionEngine(minDistinctDays: 3)
        let suggestions = engine.suggestions(from: events)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.occurrences == 4)
        #expect(suggestions.first?.actionKey == "connectPeer:mac-office")
        #expect(suggestions.first?.text.contains("one-tap") == true)
    }

    @Test func ignoresOneOffs() {
        let ctx = SuggestionEngine.contextKey(regionID: "cafe", minuteOfDay: 15 * 60, weekday: 4)
        let events = [event(ctx, "connectPeer:random", day: 20)]   // once
        #expect(SuggestionEngine(minDistinctDays: 3).suggestions(from: events).isEmpty)
    }

    @Test func sameDayRepeatsDoNotCount() {
        // Five connects on ONE day is not a habit; distinct days is what matters.
        let ctx = SuggestionEngine.contextKey(regionID: "office", minuteOfDay: 9 * 60, weekday: 2)
        let events = (0..<5).map { i in event(ctx, "connectPeer:mac", day: 30, minute: 9 * 60 + i) }
        #expect(SuggestionEngine(minDistinctDays: 3).suggestions(from: events).isEmpty)
    }

    @Test func contextKeyBucketsNearbyTimes() {
        let a = SuggestionEngine.contextKey(regionID: "office", minuteOfDay: 9 * 60 + 3, weekday: 3)
        let b = SuggestionEngine.contextKey(regionID: "office", minuteOfDay: 9 * 60 + 11, weekday: 3)
        #expect(a == b, "9:03 and 9:11 should bucket together (30-min buckets)")
    }

    @Test func logPersistsAndReloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("context.log")
        let log = ContextLog(fileURL: url)
        await log.record(ContextEvent(contextKey: "k", actionKey: "a", timestamp: 100))
        let reloaded = ContextLog(fileURL: url)
        #expect(await reloaded.all().count == 1)
        await reloaded.clear()
        try? FileManager.default.removeItem(at: dir)
    }
}

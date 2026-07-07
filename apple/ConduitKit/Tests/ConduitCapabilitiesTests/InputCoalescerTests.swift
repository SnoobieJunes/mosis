import Foundation
import Testing
@testable import ConduitCapabilities
import ConduitProtocol

/// Thread-safe collector for coalescer output.
private actor Sink {
    var events: [InputEventBody] = []
    func record(_ event: InputEventBody) { events.append(event) }
    func all() -> [InputEventBody] { events }
}

@Suite struct InputCoalescerTests {
    @Test func movesAccumulateIntoOneDeltaPerTick() async throws {
        let sink = Sink()
        let coalescer = InputCoalescer { await sink.record($0) }
        await coalescer.start()

        // Many small moves within a tick collapse to one summed delta.
        for _ in 0..<50 {
            await coalescer.enqueueMove(dx: 1, dy: 2)
        }
        try await Task.sleep(for: .milliseconds(60))
        await coalescer.stop()

        let moves = await sink.all().filter { $0.kind == .move }
        #expect(!moves.isEmpty)
        // Total motion is preserved regardless of how many ticks elapsed.
        let totalDX = moves.reduce(0) { $0 + ($1.dx ?? 0) }
        let totalDY = moves.reduce(0) { $0 + ($1.dy ?? 0) }
        #expect(totalDX == 50)
        #expect(totalDY == 100)
        // Coalescing actually happened: far fewer than 50 move messages.
        #expect(moves.count < 50)
    }

    @Test func clicksFlushImmediatelyAndPreserveOrderAfterMotion() async throws {
        let sink = Sink()
        let coalescer = InputCoalescer { await sink.record($0) }
        await coalescer.start()

        await coalescer.enqueueMove(dx: 5, dy: 5)
        await coalescer.enqueueDiscrete(.click(.left, action: .tap))
        try await Task.sleep(for: .milliseconds(30))
        await coalescer.stop()

        let events = await sink.all()
        let moveIndex = events.firstIndex { $0.kind == .move }
        let clickIndex = events.firstIndex { $0.kind == .click }
        // A click must never overtake the motion that positioned the cursor.
        #expect(moveIndex != nil && clickIndex != nil)
        if let moveIndex, let clickIndex {
            #expect(moveIndex < clickIndex)
        }
    }

    @Test func zeroNetMotionEmitsNothing() async throws {
        let sink = Sink()
        let coalescer = InputCoalescer { await sink.record($0) }
        await coalescer.start()
        await coalescer.enqueueMove(dx: 5, dy: 0)
        await coalescer.enqueueMove(dx: -5, dy: 0)
        try await Task.sleep(for: .milliseconds(40))
        await coalescer.stop()
        #expect(await sink.all().isEmpty)
    }

    @Test func stopHaltsDelivery() async throws {
        let sink = Sink()
        let coalescer = InputCoalescer { await sink.record($0) }
        await coalescer.start()
        await coalescer.stop()
        await coalescer.enqueueMove(dx: 100, dy: 100)
        try await Task.sleep(for: .milliseconds(40))
        // No tick task running → nothing flushed.
        #expect(await sink.all().isEmpty)
    }
}

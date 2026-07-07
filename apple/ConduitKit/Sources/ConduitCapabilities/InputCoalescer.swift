import Foundation
import ConduitProtocol

/// Batches high-frequency pointer motion so the wire sees at most one move per
/// tick (spec §9 Phase 2 step 1: coalesce at 120 Hz, send deltas). Moves and
/// scrolls accumulate; clicks and keys flush immediately and in order so a
/// click never overtakes the motion that positioned the cursor.
public actor InputCoalescer {
    public static let tickHz: Double = 120

    private var pendingMoveDX = 0.0
    private var pendingMoveDY = 0.0
    private var hasPendingMove = false
    private var pendingScrollDX = 0.0
    private var pendingScrollDY = 0.0
    private var hasPendingScroll = false

    private let sink: @Sendable (InputEventBody) async -> Void
    private var tickTask: Task<Void, Never>?

    public init(sink: @escaping @Sendable (InputEventBody) async -> Void) {
        self.sink = sink
    }

    public func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            let interval = UInt64(1_000_000_000 / Self.tickHz)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self?.flushMotion()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        pendingMoveDX = 0; pendingMoveDY = 0; hasPendingMove = false
        pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
    }

    public func enqueueMove(dx: Double, dy: Double) {
        pendingMoveDX += dx
        pendingMoveDY += dy
        hasPendingMove = true
    }

    public func enqueueScroll(dx: Double, dy: Double) {
        pendingScrollDX += dx
        pendingScrollDY += dy
        hasPendingScroll = true
    }

    /// Discrete events flush any accumulated motion first (preserving order),
    /// then send immediately.
    public func enqueueDiscrete(_ event: InputEventBody) async {
        await flushMotion()
        await sink(event)
    }

    private func flushMotion() async {
        if hasPendingMove {
            let dx = pendingMoveDX, dy = pendingMoveDY
            pendingMoveDX = 0; pendingMoveDY = 0; hasPendingMove = false
            if dx != 0 || dy != 0 {
                await sink(.move(dx: dx, dy: dy))
            }
        }
        if hasPendingScroll {
            let dx = pendingScrollDX, dy = pendingScrollDY
            pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
            if dx != 0 || dy != 0 {
                await sink(.scroll(dx: dx, dy: dy))
            }
        }
    }
}

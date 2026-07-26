import Foundation
import ConduitProtocol

/// Batches high-frequency pointer motion so the wire sees at most one move per
/// tick (spec §9 Phase 2 step 1: coalesce and send deltas; the spec's 120 Hz is
/// a floor — we tick at 240 Hz to halve the worst-case added motion latency to
/// ~4 ms). Moves and scrolls accumulate; clicks and keys flush immediately and
/// in order so a click never overtakes the motion that positioned the cursor.
public actor InputCoalescer {
    public static let tickHz: Double = 240

    private var pendingMoveDX = 0.0
    private var pendingMoveDY = 0.0
    private var hasPendingMove = false
    /// Absolute moves coalesce by keeping the LATEST position, not by summing:
    /// two positions in one tick mean the pointer passed through the first, and
    /// adding them would aim at neither. The accumulated delta is still carried
    /// alongside so a receiver that ignores absolute coordinates gets the full
    /// motion (see `InputEventBody.nx`).
    private var pendingNX: Double?
    private var pendingNY: Double?
    private var pendingScreenSessionID: String?
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
        pendingNX = nil; pendingNY = nil; pendingScreenSessionID = nil
        pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
    }

    public func enqueueMove(dx: Double, dy: Double) {
        pendingMoveDX += dx
        pendingMoveDY += dy
        hasPendingMove = true
        // A relative move after an absolute one supersedes the aim point.
        pendingNX = nil; pendingNY = nil; pendingScreenSessionID = nil
    }

    /// A pointer position on a live view of `screenSessionID`, plus the delta
    /// that got there for receivers that only understand deltas.
    public func enqueueAbsoluteMove(
        nx: Double, ny: Double, dx: Double, dy: Double, screenSessionID: String?
    ) {
        pendingMoveDX += dx
        pendingMoveDY += dy
        hasPendingMove = true
        pendingNX = nx
        pendingNY = ny
        pendingScreenSessionID = screenSessionID
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
            let nx = pendingNX, ny = pendingNY, session = pendingScreenSessionID
            pendingMoveDX = 0; pendingMoveDY = 0; hasPendingMove = false
            pendingNX = nil; pendingNY = nil; pendingScreenSessionID = nil
            if let nx, let ny {
                // Sent even when the delta is zero: a tap-to-position with no
                // motion still has somewhere to go.
                await sink(.moveAbsolute(nx: nx, ny: ny, dx: dx, dy: dy, screenSessionID: session))
            } else if dx != 0 || dy != 0 {
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

import Foundation
import Network
import ConduitProtocol
import ConduitTransport

public struct TimeoutError: Error {}

/// Guards a continuation that two racing branches could both try to resume.
/// Resuming a checked continuation twice is a hard crash, so the claim must be
/// atomic. Used by `withTimeout`.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Races an operation against a deadline, and *returns* at that deadline even
/// when the operation cannot be cancelled.
///
/// The obvious implementation — two children in a `withThrowingTaskGroup` — is
/// wrong here, and was the bug: when the sleep wins, the group must drain its
/// remaining child before returning, but that child is typically parked in a
/// `withCheckedContinuation` (an NWConnection callback, a UI prompt, an event
/// waiter). A parked continuation ignores cancellation; it resumes only when
/// someone calls `resume`. So the group could never drain and the "timeout"
/// deadlocked forever. Observed: an E2E test wedged for 78 minutes, and
/// `.timeLimit` could not interrupt it either — that trait is also
/// cancellation-based.
///
/// This version resolves the caller from whichever branch finishes first and
/// never awaits the loser. A non-cancellable operation may linger as an
/// abandoned task; that is a deliberate trade — a leaked task is strictly better
/// than a deadlocked connect, dial, or handshake.
///
/// The real repair is making those continuations cancellation-aware
/// (`withTaskCancellationHandler`); there is currently not one in the codebase.
/// Until then, this keeps every timeout in the product honest.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = ResumeOnce()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() {
                work.cancel() // best effort; honoured only if the operation is cancellable
                continuation.resume(throwing: TimeoutError())
            }
        }
    }
}

public enum SessionError: Error {
    case connectionLost
    case handshakeFailed(String)
    case identityMismatch(String)
    case notReady
    case capabilityNotNegotiated(String)
    case concurrentRead
}

/// A byte-stream connection with Conduit framing, envelope sequencing, and the
/// session ID applied. One logical reader at a time; senders may be concurrent.
public actor FramedConnection {
    /// Box for the stream iterator: Swift forbids calling the mutating async
    /// `next()` on actor-stored iterators directly. Safety: only `nextFrame()`
    /// touches this, and the `readInFlight` guard enforces one reader at a time.
    private final class IteratorBox: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator
        init(_ iterator: AsyncThrowingStream<Data, Error>.Iterator) {
            self.iterator = iterator
        }
        func next() async throws -> Data? {
            try await iterator.next()
        }
    }

    public nonisolated let raw: any ByteStreamConnection

    private let iterator: IteratorBox
    private var reader = FrameReader()
    private var pending: [Frame] = []
    private var sessionID = ""
    private var nextSeq: UInt64 = 0
    private var readInFlight = false

    // MARK: Control-over-video priority (plan 07 RC-10)
    //
    // When the screen share falls back to this session link — the common
    // real-device path, because the source's reverse-dial can't land — 2.5 Mbps
    // of video shares one TCP connection with input events, keepalives and
    // acks. Video frames are large and input events are ~60 bytes, so a click
    // handed to the socket behind a queue of frames waits out all of them:
    // head-of-line blocking, on the one lane that is supposed to keep remote
    // control usable when everything else has degraded.
    //
    // Control frames therefore never wait for video: a screen frame yields
    // until no control send is outstanding. This does not preempt a frame
    // already handed to the transport, so the residual worst case is one
    // frame's transmission time (~10 KB at the fallback bitrate) instead of the
    // whole backlog. Bounded by `screenGateMaxWait` so a wedged control send can
    // never strand the video lane.
    static let screenGateMaxWait: Duration = .milliseconds(250)
    private var controlSendsInFlight = 0
    private var screenGateWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextGateID: UInt64 = 0
    /// How many screen frames yielded to input. Surfaced in tests; a climbing
    /// count on the fallback lane is the fix doing its job.
    public private(set) var screenFramesYielded = 0

    public init(_ raw: any ByteStreamConnection) {
        self.raw = raw
        self.iterator = IteratorBox(raw.incoming.makeAsyncIterator())
    }

    public nonisolated var peerTLSKeyHash: Data? { raw.peerTLSKeyHash }
    public nonisolated var backendKind: TransportBackendKind { raw.backendKind }
    public nonisolated var remoteHost: String? { raw.remoteHost }
    /// Typed peer endpoint (host + observed port) for building reverse-dial
    /// candidates without stringifying the address. See ByteStreamConnection.
    public nonisolated var remoteEndpoint: NWEndpoint? { raw.remoteEndpoint }

    public nonisolated func closeUnderlying() {
        raw.close()
    }

    public func adoptSessionID(_ id: String) {
        sessionID = id
    }

    public func currentSessionID() -> String {
        sessionID
    }

    /// Next complete frame, or nil when the stream ends. Single logical
    /// consumer: concurrent reads are a programming error and throw.
    public func nextFrame() async throws -> Frame? {
        guard !readInFlight else { throw SessionError.concurrentRead }
        readInFlight = true
        defer { readInFlight = false }
        while pending.isEmpty {
            guard let data = try await iterator.next() else { return nil }
            pending.append(contentsOf: try reader.append(data))
        }
        return pending.removeFirst()
    }

    public func send(_ message: Message) async throws {
        let meta = EnvelopeMeta(sessionID: sessionID, seq: nextSeq)
        nextSeq += 1
        let payload = try MessageCodec.encode(meta: meta, message: message)
        controlSendsInFlight += 1
        defer { controlSendFinished() }
        try await raw.send(FrameCodec.encodeControl(payload))
    }

    public func sendChunk(_ chunk: ChunkFrame) async throws {
        try await raw.send(FrameCodec.encode(chunk))
    }

    public func sendScreenFrame(_ frame: ScreenFrame) async throws {
        if controlSendsInFlight > 0 {
            screenFramesYielded += 1
            await waitForControlSends()
        }
        try await raw.send(FrameCodec.encode(frame))
    }

    private func controlSendFinished() {
        controlSendsInFlight -= 1
        guard controlSendsInFlight <= 0 else { return }
        controlSendsInFlight = 0
        let waiters = screenGateWaiters
        screenGateWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    private func waitForControlSends() async {
        let id = nextGateID
        nextGateID &+= 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            screenGateWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.screenGateMaxWait)
                await self?.releaseGateWaiter(id)
            }
        }
    }

    /// Safety valve: a control send that never returns (wedged socket) must not
    /// hold video hostage forever.
    private func releaseGateWaiter(_ id: UInt64) {
        screenGateWaiters.removeValue(forKey: id)?.resume()
    }
}

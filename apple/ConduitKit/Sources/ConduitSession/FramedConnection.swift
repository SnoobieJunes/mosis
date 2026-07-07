import Foundation
import Network
import ConduitProtocol
import ConduitTransport

public struct TimeoutError: Error {}

/// Races an operation against a deadline.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
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
        try await raw.send(FrameCodec.encodeControl(payload))
    }

    public func sendChunk(_ chunk: ChunkFrame) async throws {
        try await raw.send(FrameCodec.encode(chunk))
    }

    public func sendScreenFrame(_ frame: ScreenFrame) async throws {
        try await raw.send(FrameCodec.encode(frame))
    }
}

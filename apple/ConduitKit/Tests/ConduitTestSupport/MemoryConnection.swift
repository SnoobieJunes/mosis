import Foundation
import ConduitTransport

/// An in-process byte-stream pair for exercising session logic without
/// sockets or TLS. `peerTLSKeyHash` is injectable so identity-binding checks
/// can be tested for both the honest and the substituted case.
public final class MemoryConnection: ByteStreamConnection, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    public let peerTLSKeyHash: Data?
    public let backendKind: TransportBackendKind = .lan
    public let remoteDescription = "memory"
    public var remoteHost: String? { nil }

    private let outbound: Locked<AsyncThrowingStream<Data, Error>.Continuation?>
    private let ownContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let closed = Locked(false)

    private init(
        incoming: AsyncThrowingStream<Data, Error>,
        ownContinuation: AsyncThrowingStream<Data, Error>.Continuation,
        peerTLSKeyHash: Data?
    ) {
        self.incoming = incoming
        self.ownContinuation = ownContinuation
        self.peerTLSKeyHash = peerTLSKeyHash
        self.outbound = Locked(nil)
    }

    /// Builds a crossed pair. Pass the TLS key hash each side presents;
    /// side A's `peerTLSKeyHash` becomes what B presented, and vice versa.
    public static func pair(presentedByA hashA: Data?, presentedByB hashB: Data?) -> (a: MemoryConnection, b: MemoryConnection) {
        let (streamA, contA) = AsyncThrowingStream.makeStream(of: Data.self)
        let (streamB, contB) = AsyncThrowingStream.makeStream(of: Data.self)
        let a = MemoryConnection(incoming: streamA, ownContinuation: contA, peerTLSKeyHash: hashB)
        let b = MemoryConnection(incoming: streamB, ownContinuation: contB, peerTLSKeyHash: hashA)
        a.outbound.set(contB)
        b.outbound.set(contA)
        return (a, b)
    }

    public func send(_ data: Data) async throws {
        guard !closed.get() else { throw TransportError.connectionClosed }
        guard let peer = outbound.get() else { throw TransportError.connectionClosed }
        peer.yield(data)
    }

    public func close() {
        guard !closed.withValue({ let was = $0; $0 = true; return was }) else { return }
        outbound.get()?.finish()
        ownContinuation.finish()
    }
}

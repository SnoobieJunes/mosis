import Foundation
import CryptoKit
import os
import ConduitProtocol
import ConduitTransport

let sessionLog = Logger(subsystem: "org.conduit", category: "session")

/// Connection state machine (spec §9 Phase 1 step 6):
/// idle → connecting → hello → ready → degraded → closed.
public enum SessionState: String, Sendable {
    case idle, connecting, hello, ready, degraded, closed
}

public enum PeerLinkEvent: Sendable {
    case stateChanged(deviceID: String, state: SessionState)
    case rttUpdated(deviceID: String, millis: Double)
    /// A negotiated-capability message (file, clipboard, …) for upper layers.
    case capabilityMessage(deviceID: String, message: Message)
    case chunk(deviceID: String, chunk: ChunkFrame)
}

/// One live session with one pinned peer: HELLO negotiation, keepalive,
/// dispatch. Reconnection policy lives above (keyed to identity, not address).
public actor PeerLink {
    public nonisolated let peer: PinnedPeer
    public nonisolated let framed: FramedConnection

    private let localHello: HelloBody
    private let onEvent: @Sendable (PeerLinkEvent) async -> Void

    public private(set) var state: SessionState = .hello
    public private(set) var remoteHello: HelloBody?
    public private(set) var negotiatedCapabilities: Set<String> = []
    public private(set) var lastRTTMillis: Double?

    private var readTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// nonce → send timestamp (ms). Outstanding pings; 3 unanswered = degraded.
    private var pendingPings: [String: UInt64] = [:]

    public init(
        peer: PinnedPeer,
        framed: FramedConnection,
        localHello: HelloBody,
        onEvent: @escaping @Sendable (PeerLinkEvent) async -> Void
    ) {
        self.peer = peer
        self.framed = framed
        self.localHello = localHello
        self.onEvent = onEvent
    }

    // MARK: Handshake

    /// Initiator: send HELLO, await HELLO_ACK. No capability may be used before
    /// it appears in HELLO_ACK (spec §5.4).
    public func performInitiatorHello(timeoutSeconds: Double = 10) async throws {
        await framed.adoptSessionID(UUID().uuidString)
        try await framed.send(.hello(localHello))
        let framed = self.framed
        let ack: HelloBody = try await withTimeout(seconds: timeoutSeconds) {
            while true {
                guard let frame = try await framed.nextFrame() else {
                    throw SessionError.connectionLost
                }
                guard case .control(let payload) = frame else { continue }
                let (_, message) = try MessageCodec.decode(payload)
                switch message {
                case .helloAck(let body): return body
                case .unknown: continue
                default: throw SessionError.handshakeFailed("expected HELLO_ACK, got \(message.typeString)")
                }
            }
        }
        try validate(remote: ack)
        adopt(remote: ack)
    }

    /// Responder: the router already decoded the peer's HELLO; validate, adopt
    /// its session ID, answer with HELLO_ACK.
    public func performResponderHello(remote: HelloBody, meta: EnvelopeMeta) async throws {
        try validate(remote: remote)
        await framed.adoptSessionID(meta.sessionID)
        adopt(remote: remote)
        try await framed.send(.helloAck(localHello))
    }

    private func validate(remote: HelloBody) throws {
        guard DeviceIdentity.deviceID(publicKeyRaw: remote.pubkey) == remote.identity else {
            throw SessionError.identityMismatch("HELLO pubkey does not hash to claimed identity")
        }
        guard remote.identity == peer.deviceID, remote.pubkey == peer.ed25519PublicKey else {
            throw SessionError.identityMismatch("HELLO identity does not match the pinned peer for this TLS key")
        }
    }

    private func adopt(remote: HelloBody) {
        remoteHello = remote
        negotiatedCapabilities = Set(localHello.capabilities).intersection(remote.capabilities)
    }

    // MARK: Run

    public func activate() async {
        await setState(.ready)
        readTask = Task { await self.runReadLoop() }
        pingTask = Task { await self.runPingLoop() }
    }

    public func hasCapability(_ id: String) -> Bool {
        negotiatedCapabilities.contains(id)
    }

    public func send(_ message: Message) async throws {
        guard state == .ready || state == .degraded else { throw SessionError.notReady }
        try await framed.send(message)
    }

    public func sendChunk(_ chunk: ChunkFrame) async throws {
        guard state == .ready || state == .degraded else { throw SessionError.notReady }
        try await framed.sendChunk(chunk)
    }

    public func close() async {
        guard state != .closed else { return }
        readTask?.cancel()
        pingTask?.cancel()
        framed.closeUnderlying()
        await setState(.closed)
    }

    private func setState(_ newState: SessionState) async {
        guard state != newState, state != .closed else { return }
        state = newState
        await onEvent(.stateChanged(deviceID: peer.deviceID, state: newState))
    }

    private func runReadLoop() async {
        do {
            while let frame = try await framed.nextFrame() {
                switch frame {
                case .control(let payload):
                    let (_, message) = try MessageCodec.decode(payload)
                    await handle(message)
                case .fileChunk(let chunk):
                    await onEvent(.chunk(deviceID: peer.deviceID, chunk: chunk))
                }
            }
        } catch {
            if state != .closed {
                sessionLog.info("read loop ended for \(self.peer.name, privacy: .public): \(error)")
            }
        }
        await close()
    }

    private func handle(_ message: Message) async {
        switch message {
        case .ping(let body):
            try? await framed.send(.pong(PingBody(nonce: body.nonce, t: nowMillis())))
        case .pong(let body):
            if let sentAt = pendingPings.removeValue(forKey: body.nonce) {
                let rtt = Double(nowMillis()) - Double(sentAt)
                lastRTTMillis = rtt
                // Any pong proves liveness; older outstanding pings no longer count.
                pendingPings.removeAll()
                if state == .degraded {
                    await setState(.ready)
                }
                await onEvent(.rttUpdated(deviceID: peer.deviceID, millis: rtt))
            }
        case .hello, .helloAck:
            sessionLog.warning("duplicate hello ignored")
        case .unknown(let type):
            sessionLog.warning("ignoring unknown message type \(type, privacy: .public)")
        default:
            await onEvent(.capabilityMessage(deviceID: peer.deviceID, message: message))
        }
    }

    private func runPingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard state == .ready || state == .degraded else { return }
            if pendingPings.count >= 3 {
                await setState(.degraded)
            }
            if pendingPings.count >= 6 {
                sessionLog.warning("peer \(self.peer.name, privacy: .public) unresponsive; closing")
                await close()
                return
            }
            let nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).hexString
            pendingPings[nonce] = nowMillis()
            do {
                try await framed.send(.ping(PingBody(nonce: nonce, t: nowMillis())))
            } catch {
                await close()
                return
            }
        }
    }

    private func nowMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

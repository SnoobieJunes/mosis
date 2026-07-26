import Foundation
import Network
import Security
#if canImport(WiFiAware) && os(iOS)
import WiFiAware
#endif

/// Wi-Fi Aware backend (spec §9 Phase 1 step 9, ADR 0003 step 4).
///
/// Status: **implemented on the iOS 26 WiFiAware + structured-concurrency
/// Network API, compile-verified only — no Aware session has run on hardware.**
/// The com.apple.developer.wifi-aware entitlement is granted for org.auston.mosis
/// and carried in the iOS app's entitlements; `_mosis-aware._tcp` is declared in
/// the iOS Info.plist `WiFiAwareServices` (via project.yml).
///
/// Platform truth this design encodes:
/// - Aware is iPhone/iPad-only. The macOS SDK marks every WiFiAware symbol
///   unavailable (probed 2026-07-20), so everything here is compiled out except
///   on iOS, and LAN remains the always-on path (spec §3: "Aware is an
///   accelerator, never a dependency").
/// - Aware peers must be **OS-paired first** (`WAPairedDevice`, via the
///   DeviceDiscoveryUI pairing flow) — this is Apple's trust gate and is
///   separate from Conduit pairing. Conduit's own trust is unchanged: the same
///   pinned mutual TLS runs over the Aware link (the new API's
///   `certificateValidator` is the verify-block equivalent), so a reachable
///   Aware endpoint that is not the pinned Conduit peer fails the handshake.
/// - Aware discovery carries no TXT record, so Aware endpoints are **not** fed
///   into the discovery UI; they are used as dial candidates for already-pinned
///   peers and for inbound connections, where TLS identifies the device.
public enum AwareBackendStatus {
    /// Whether this build+device could offer Aware right now, with the honest
    /// reason when it can't. Availability is a runtime question (device support,
    /// Info.plist declaration), not just a compile-time one.
    public static func availability() -> (available: Bool, reason: String?) {
        guard ConduitFeatureFlags.wifiAwareEnabled else {
            return (false, "Wi-Fi Aware is compile-time disabled in this build.")
        }
        #if canImport(WiFiAware) && os(iOS)
        guard #available(iOS 26.0, *) else {
            return (false, "Wi-Fi Aware needs iOS 26.")
        }
        guard WACapabilities.supportedFeatures.contains(.wifiAware) else {
            return (false, "This device does not support Wi-Fi Aware.")
        }
        guard WAPublishableService.allServices[ProtocolServiceType.awareService] != nil,
              WASubscribableService.allServices[ProtocolServiceType.awareService] != nil
        else {
            // True for `swift test` and any host whose Info.plist lacks the
            // WiFiAwareServices declaration (only the iOS app carries it).
            return (false, "\(ProtocolServiceType.awareService) is not declared in this process's Info.plist WiFiAwareServices.")
        }
        return (true, nil)
        #else
        return (false, "Wi-Fi Aware is iPhone/iPad-only; LAN backend in use.")
        #endif
    }

    public static var isAvailable: Bool { availability().available }
    public static var unavailableReason: String? { availability().reason }
}

/// Type-erased seam so `ConduitNode` (deployment floor iOS 18) can hold the
/// iOS 26-only backend without availability-restricting itself.
public protocol AwareTransporting: AnyObject, Sendable {
    /// Starts the Aware publisher (inbound listener) and subscriber (endpoint
    /// discovery). Returned stream yields authenticated inbound connections.
    func start() async throws -> AsyncStream<any ByteStreamConnection>
    /// How many Aware endpoints (OS-paired devices running the service) are
    /// visible right now. Used to decide whether an Aware dial is worth trying.
    var visibleEndpointCount: Int { get }
    /// Dials every currently visible Aware endpoint with the pinned policy and
    /// returns the first that completes the Conduit TLS handshake. An endpoint
    /// that is the wrong device fails pinning quickly and the chain moves on.
    func connectFirstAvailable(policy: TLSVerifyPolicy, perEndpointTimeout: Double) async throws -> any ByteStreamConnection
    func shutdown()
}

public enum AwareBackendFactory {
    /// Returns the Aware backend when this process can actually use it, else
    /// nil (with the reason logged once). Callers treat nil as "LAN only".
    public static func make(
        material: TransportTLSMaterial,
        listenerPolicyProvider: @escaping @Sendable () -> TLSVerifyPolicy
    ) -> (any AwareTransporting)? {
        let (available, reason) = AwareBackendStatus.availability()
        guard available else {
            transportLog.info("Wi-Fi Aware unavailable: \(reason ?? "unknown", privacy: .public)")
            return nil
        }
        #if canImport(WiFiAware) && os(iOS)
        guard #available(iOS 26.0, *) else { return nil }
        do {
            return try AwareBackend(material: material, listenerPolicyProvider: listenerPolicyProvider)
        } catch {
            transportLog.error("Wi-Fi Aware backend init failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(WiFiAware) && os(iOS)

/// A pinned-TLS byte stream over a Wi-Fi Aware datapath, carried by the new
/// `NetworkConnection` API (Aware endpoints are only reachable through it —
/// ADR 0001's deferred consequence, now due).
@available(iOS 26.0, *)
final class AwareConnection: ByteStreamConnection, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    public let backendKind: TransportBackendKind = .aware
    public let remoteDescription: String
    /// Aware endpoints have no LAN-dialable address: bulk/datagram lanes fall
    /// back to LAN candidates or the control-lane path (both already exist).
    public var remoteHost: String? { nil }
    public var remoteEndpoint: NWEndpoint? { nil }

    private let connection: NetworkConnection<TLS>
    private let closed = Locked(false)
    private let receiveTask = Locked<Task<Void, Never>?>(nil)
    private let keyHashCache = Locked<Data?>(nil)
    private let closedStream: AsyncStream<Never>
    private let closedContinuation: AsyncStream<Never>.Continuation

    init(_ connection: NetworkConnection<TLS>) {
        self.connection = connection
        self.remoteDescription = connection.remoteEndpoint.map { "\($0)" } ?? "wifi-aware peer"

        var incomingCont: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream(bufferingPolicy: .unbounded) { incomingCont = $0 }
        let cont = incomingCont!

        (self.closedStream, self.closedContinuation) = AsyncStream.makeStream(of: Never.self)
        let closedContinuation = self.closedContinuation

        let task = Task { [connection] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive(atLeast: 1, atMost: 256 * 1024)
                    if !message.content.isEmpty {
                        cont.yield(message.content)
                    }
                    if message.metadata.endOfStream {
                        cont.finish()
                        break
                    }
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
            closedContinuation.finish()
        }
        receiveTask.set(task)
    }

    /// The handshake completes before any Conduit byte flows, but inbound
    /// adoption may construct this wrapper earlier than that — so the hash is
    /// extracted lazily from TLS metadata and cached once seen.
    public var peerTLSKeyHash: Data? {
        if let cached = keyHashCache.get() { return cached }
        guard let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let hash = TLSVerifier.peerLeafKeyHash(securityMetadata: tlsMetadata.securityProtocolMetadata)
        if hash != nil { keyHashCache.set(hash) }
        return hash
    }

    public func send(_ data: Data) async throws {
        if closed.get() { throw TransportError.connectionClosed }
        try await connection.send(data)
    }

    public func close() {
        guard !closed.withValue({ let was = $0; $0 = true; return was }) else { return }
        receiveTask.get()?.cancel()
        let connection = self.connection
        let closedContinuation = self.closedContinuation
        Task {
            // Graceful TLS close; the connection tears down when released.
            try? await connection.send(Data(), endOfStream: true)
            closedContinuation.finish()
        }
    }

    /// Blocks until the connection ends — the listener's per-connection handler
    /// must not return earlier, because the new API scopes the connection's
    /// lifetime to that handler.
    func untilClosed() async {
        for await _ in closedStream {}
    }
}

/// Publisher + subscriber for `_mosis-aware._tcp` over the new Network API,
/// with Conduit's mandatory pinned mutual TLS on every connection.
@available(iOS 26.0, *)
final class AwareBackend: AwareTransporting, @unchecked Sendable {
    private let identity: sec_identity_t
    private let listenerPolicyProvider: @Sendable () -> TLSVerifyPolicy
    private let publishable: WAPublishableService
    private let subscribable: WASubscribableService

    private let endpoints = Locked<[WAEndpoint]>([])
    private let inboundContinuation = Locked<AsyncStream<any ByteStreamConnection>.Continuation?>(nil)
    private let listenerTask = Locked<Task<Void, Never>?>(nil)
    private let browserTask = Locked<Task<Void, Never>?>(nil)

    init(
        material: TransportTLSMaterial,
        listenerPolicyProvider: @escaping @Sendable () -> TLSVerifyPolicy
    ) throws {
        guard let publishable = WAPublishableService.allServices[ProtocolServiceType.awareService],
              let subscribable = WASubscribableService.allServices[ProtocolServiceType.awareService]
        else {
            throw TransportError.backendUnavailable(
                "\(ProtocolServiceType.awareService) missing from Info.plist WiFiAwareServices")
        }
        self.publishable = publishable
        self.subscribable = subscribable

        let secIdentity = try TLSIdentityMaterializer.secIdentity(for: material)
        guard let wrapped = sec_identity_create(secIdentity) else {
            throw TransportError.tlsIdentityUnavailable("sec_identity_create returned nil")
        }
        self.identity = wrapped
        self.listenerPolicyProvider = listenerPolicyProvider
    }

    /// Same TLS rules as `TLSParametersBuilder.make` — 1.3 minimum, mutual
    /// certs, pinned-key verification — expressed in the new API's builder.
    private func tlsStack(policyProvider: @escaping @Sendable () -> TLSVerifyPolicy) -> TLS {
        TLS { TCP().noDelay(true) }
            .localIdentity(identity)
            .peerAuthentication(.required)
            .version(min: .TLSv13)
            .certificateValidator { _, secTrust in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let verdict = TLSVerifier.evaluate(trust: trust, policy: policyProvider())
                if !verdict.isAllowed {
                    transportLog.warning("Aware TLS verify rejected peer key \(verdict.presentedKeyHash?.map { String(format: "%02x", $0) }.joined() ?? "<none>", privacy: .public)")
                }
                return verdict.isAllowed
            }
    }

    var visibleEndpointCount: Int { endpoints.get().count }

    func start() async throws -> AsyncStream<any ByteStreamConnection> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any ByteStreamConnection).self)
        inboundContinuation.set(continuation)

        // Publisher: accept connections from any OS-paired device; Conduit's
        // pinned TLS (listener policy) decides who actually gets a session.
        // Both loops restart on failure like the Bonjour browser (a network
        // change kills them; nothing would ever come back otherwise).
        listenerTask.set(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let listener = try NetworkListener(
                        for: .wifiAware(.connecting(to: self.publishable, from: .allPairedDevices))
                    ) {
                        self.tlsStack(policyProvider: self.listenerPolicyProvider)
                    }
                    transportLog.info("Aware publisher listening (\(ProtocolServiceType.awareService, privacy: .public))")
                    try await listener.run { connection in
                        // The connection lives exactly as long as this handler.
                        let adapted = AwareConnection(connection)
                        self.inboundContinuation.get()?.yield(adapted)
                        await adapted.untilClosed()
                    }
                } catch {
                    transportLog.warning("Aware listener ended: \(String(describing: error), privacy: .public); restarting")
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        })

        // Subscriber: keep a live snapshot of visible endpoints for dialing.
        browserTask.set(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let browser = NetworkBrowser(
                        for: .wifiAware(.connecting(to: .allPairedDevices, from: self.subscribable))
                    )
                    try await browser.run { found in
                        self.endpoints.set(found)
                    }
                } catch {
                    transportLog.warning("Aware browser ended: \(String(describing: error), privacy: .public); restarting")
                }
                self.endpoints.set([])
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        })

        return stream
    }

    func connectFirstAvailable(policy: TLSVerifyPolicy, perEndpointTimeout: Double) async throws -> any ByteStreamConnection {
        let snapshot = endpoints.get()
        guard !snapshot.isEmpty else {
            throw TransportError.connectFailed("no Wi-Fi Aware endpoints visible")
        }
        var errors: [String] = []
        for endpoint in snapshot {
            do {
                return try await open(endpoint: endpoint, policy: policy, timeoutSeconds: perEndpointTimeout)
            } catch {
                errors.append("\(endpoint.device.name ?? "device \(endpoint.device.id)"): \(error)")
            }
        }
        throw TransportError.connectFailed(
            "all \(snapshot.count) Aware endpoint(s) failed — \(errors.joined(separator: " | "))")
    }

    private func open(endpoint: WAEndpoint, policy: TLSVerifyPolicy, timeoutSeconds: Double) async throws -> AwareConnection {
        let connection = NetworkConnection(to: endpoint) {
            tlsStack(policyProvider: { policy })
        }
        // The new API establishes lazily on first I/O; an empty send forces the
        // dial + full TLS handshake so a pinning failure surfaces HERE (and the
        // candidate chain can move on) rather than mid-HELLO.
        return try await withThrowingTaskGroup(of: AwareConnection.self) { group in
            group.addTask {
                try await connection.send(Data())
                return AwareConnection(connection)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TransportError.connectFailed("Aware dial timed out after \(Int(timeoutSeconds))s")
            }
            guard let first = try await group.next() else { throw TransportError.timeout }
            group.cancelAll()
            return first
        }
    }

    func shutdown() {
        listenerTask.withValue { $0?.cancel(); $0 = nil }
        browserTask.withValue { $0?.cancel(); $0 = nil }
        endpoints.set([])
        inboundContinuation.withValue { cont in
            cont?.finish()
            cont = nil
        }
    }
}

#endif

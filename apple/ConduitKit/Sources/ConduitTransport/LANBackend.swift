import Foundation
import Network
import Security
import os

let transportLog = Logger(subsystem: "org.conduit", category: "transport")

/// A single TLS-over-TCP connection wrapped for async use.
public final class LANConnection: ByteStreamConnection, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    public let peerTLSKeyHash: Data?
    public let backendKind: TransportBackendKind = .lan
    public let remoteDescription: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let closed = Locked(false)

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.remoteDescription = String(describing: connection.endpoint)
        self.peerTLSKeyHash = Self.extractPeerKeyHash(connection)

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incoming = AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let cont = continuation!

        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .failed(let error):
                cont.finish(throwing: error)
                connection?.cancel()
            case .cancelled:
                cont.finish()
            default:
                break
            }
        }
        Self.receiveLoop(connection, cont)
    }

    private static func receiveLoop(_ connection: NWConnection, _ cont: AsyncThrowingStream<Data, Error>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                cont.yield(data)
            }
            if let error {
                cont.finish(throwing: error)
                return
            }
            if isComplete {
                cont.finish()
                connection.cancel()
                return
            }
            receiveLoop(connection, cont)
        }
    }

    private static func extractPeerKeyHash(_ connection: NWConnection) -> Data? {
        guard let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var leaf: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(tlsMetadata.securityProtocolMetadata) { cert in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(cert).takeRetainedValue()
            }
        }
        guard let leaf else { return nil }
        return TLSVerifier.publicKeyHash(of: leaf)
    }

    /// The peer's IP address (used to reach its listener for the bulk lane).
    public var remoteHost: String? {
        guard let path = connection.currentPath,
              let remote = path.remoteEndpoint,
              case .hostPort(let host, _) = remote
        else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    public func send(_ data: Data) async throws {
        if closed.get() { throw TransportError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        closed.set(true)
        connection.cancel()
    }
}

/// Builds NWParameters enforcing Conduit's TLS rules: TLS 1.3 minimum, mutual
/// certificates, verification by pinned key only. No plaintext option exists.
enum TLSParametersBuilder {
    static func make(
        identity: sec_identity_t,
        policyProvider: @escaping @Sendable () -> TLSVerifyPolicy,
        queue: DispatchQueue
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let options = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, identity)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let verdict = TLSVerifier.evaluate(trust: trust, policy: policyProvider())
            if !verdict.isAllowed {
                transportLog.warning("TLS verify rejected peer key \(verdict.presentedKeyHash?.map { String(format: "%02x", $0) }.joined() ?? "<none>", privacy: .public)")
            }
            complete(verdict.isAllowed)
        }, queue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// Bonjour + TCP + Conduit TLS: the universal backend (spec §5.3).
public final class LANBackend: TransportBackend, @unchecked Sendable {
    public let kind: TransportBackendKind = .lan

    private let queue = DispatchQueue(label: "org.conduit.transport.lan")
    private let identity: sec_identity_t
    /// Policy for connections we accept; consulted per handshake so pairing
    /// mode and newly pinned peers take effect immediately.
    private let listenerPolicyProvider: @Sendable () -> TLSVerifyPolicy

    private let listener = Locked<NWListener?>(nil)
    private let browser = Locked<NWBrowser?>(nil)
    private let inboundContinuation = Locked<AsyncStream<any ByteStreamConnection>.Continuation?>(nil)

    public init(
        material: TransportTLSMaterial,
        keychainLabel: String,
        listenerPolicyProvider: @escaping @Sendable () -> TLSVerifyPolicy
    ) throws {
        let secIdentity = try TLSIdentityMaterializer.secIdentity(for: material, label: keychainLabel)
        guard let wrapped = sec_identity_create(secIdentity) else {
            throw TransportError.tlsIdentityUnavailable("sec_identity_create returned nil")
        }
        self.identity = wrapped
        self.listenerPolicyProvider = listenerPolicyProvider
    }

    // MARK: Listener

    public func start() async throws -> (port: UInt16, inbound: AsyncStream<any ByteStreamConnection>) {
        let parameters = TLSParametersBuilder.make(identity: identity, policyProvider: listenerPolicyProvider, queue: queue)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw TransportError.listenerFailed("\(error)")
        }

        let (stream, continuation) = AsyncStream.makeStream(of: (any ByteStreamConnection).self)
        inboundContinuation.set(continuation)

        newListener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else {
                nwConnection.cancel()
                return
            }
            self.adoptInbound(nwConnection)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = Locked(false)
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                        cont.resume(returning: newListener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                        cont.resume(throwing: TransportError.listenerFailed("\(error)"))
                    }
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }

        listener.set(newListener)
        transportLog.info("LAN listener ready on port \(port)")
        return (port, stream)
    }

    private func adoptInbound(_ nwConnection: NWConnection) {
        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                nwConnection.stateUpdateHandler = nil
                let connection = LANConnection(connection: nwConnection, queue: self.queue)
                self.inboundContinuation.get()?.yield(connection)
            case .failed, .cancelled:
                nwConnection.stateUpdateHandler = nil
            default:
                break
            }
        }
        nwConnection.start(queue: queue)
    }

    // MARK: Advertise

    public func advertise(_ service: ServiceDescriptor) throws {
        guard let listener = listener.get() else {
            throw TransportError.listenerFailed("advertise before start()")
        }
        var txtRecord = NWTXTRecord()
        for (key, value) in service.txt {
            txtRecord[key] = value
        }
        listener.service = NWListener.Service(
            name: service.name,
            type: service.type,
            domain: nil,
            txtRecord: txtRecord
        )
    }

    public func stopAdvertising() {
        listener.get()?.service = nil
    }

    // MARK: Browse

    public func browse() -> AsyncStream<[DiscoveredEndpoint]> {
        stopBrowsing()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ProtocolServiceType.appService, domain: nil),
            using: parameters
        )
        let (stream, continuation) = AsyncStream.makeStream(of: [DiscoveredEndpoint].self)
        newBrowser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.compactMap { result -> DiscoveredEndpoint? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case .bonjour(let record) = result.metadata {
                    txt = record.dictionary
                }
                return DiscoveredEndpoint(endpoint: result.endpoint, serviceName: name, txt: txt)
            }
            continuation.yield(endpoints.sorted { $0.serviceName < $1.serviceName })
        }
        newBrowser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                transportLog.error("browser failed: \(String(describing: error), privacy: .public)")
                continuation.finish()
            }
        }
        newBrowser.start(queue: queue)
        browser.set(newBrowser)
        return stream
    }

    public func stopBrowsing() {
        browser.withValue { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: Connect

    public func connect(to endpoint: DiscoveredEndpoint, policy: TLSVerifyPolicy) async throws -> any ByteStreamConnection {
        try await open(endpoint: endpoint.endpoint, policy: policy)
    }

    public func connect(host: String, port: UInt16, policy: TLSVerifyPolicy) async throws -> any ByteStreamConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.connectFailed("bad port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        return try await open(endpoint: endpoint, policy: policy)
    }

    private func open(endpoint: NWEndpoint, policy: TLSVerifyPolicy, timeoutSeconds: Double = 15) async throws -> LANConnection {
        let parameters = TLSParametersBuilder.make(identity: identity, policyProvider: { policy }, queue: queue)
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        let queue = self.queue

        return try await withThrowingTaskGroup(of: LANConnection.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LANConnection, Error>) in
                    let resumed = Locked(false)
                    nwConnection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                                nwConnection.stateUpdateHandler = nil
                                cont.resume(returning: LANConnection(connection: nwConnection, queue: queue))
                            }
                        case .failed(let error):
                            if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                                cont.resume(throwing: TransportError.connectFailed("\(error)"))
                            }
                        case .waiting(let error):
                            transportLog.info("connect waiting: \(String(describing: error), privacy: .public)")
                        default:
                            break
                        }
                    }
                    nwConnection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TransportError.timeout
            }
            do {
                guard let first = try await group.next() else { throw TransportError.timeout }
                group.cancelAll()
                return first
            } catch {
                nwConnection.cancel()
                group.cancelAll()
                throw error
            }
        }
    }

    public func shutdown() {
        stopBrowsing()
        listener.withValue { current in
            current?.cancel()
            current = nil
        }
        inboundContinuation.withValue { cont in
            cont?.finish()
            cont = nil
        }
    }
}

/// Service type constants live here (not ConduitProtocol) so the transport
/// module stays protocol-agnostic while sharing the registered names (spec §5.3).
public enum ProtocolServiceType {
    public static let appService = "_cndt-app._tcp"
}

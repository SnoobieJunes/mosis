import Foundation
import Network
import Security

/// DTLS-over-UDP connection for latency-sensitive traffic (spec §9 Phase 2
/// step 4): pointer moves ride here so a lost packet costs one stale delta
/// instead of a TCP retransmit stall. Same trust rules as the TCP path —
/// mutual certificates, pinned-key verification, no plaintext variant.
public final class DatagramConnection: @unchecked Sendable {
    public let incomingDatagrams: AsyncThrowingStream<Data, Error>
    public let peerTLSKeyHash: Data?
    public let remoteDescription: String

    private let connection: NWConnection
    private let closed = Locked(false)

    init(connection: NWConnection) {
        self.connection = connection
        self.remoteDescription = String(describing: connection.endpoint)
        self.peerTLSKeyHash = Self.extractPeerKeyHash(connection)

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incomingDatagrams = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
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
        connection.receiveMessage { data, _, _, error in
            if let data, !data.isEmpty {
                cont.yield(data)
            }
            if let error {
                cont.finish(throwing: error)
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

    /// Sends one datagram (boundaries preserved). Fire-and-forget semantics:
    /// callers should treat errors as lane loss, not retry individual sends.
    public func send(_ datagram: Data) async throws {
        if closed.get() { throw TransportError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
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

enum DTLSParametersBuilder {
    static func make(
        identity: sec_identity_t,
        policyProvider: @escaping @Sendable () -> TLSVerifyPolicy,
        queue: DispatchQueue
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let options = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, identity)
        sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let verdict = TLSVerifier.evaluate(trust: trust, policy: policyProvider())
            if !verdict.isAllowed {
                transportLog.warning("DTLS verify rejected peer")
            }
            complete(verdict.isAllowed)
        }, queue)

        let udpOptions = NWProtocolUDP.Options()
        let parameters = NWParameters(dtls: tlsOptions, udp: udpOptions)
        parameters.includePeerToPeer = false
        return parameters
    }
}

extension LANBackend {
    /// Starts the UDP/DTLS listener (lazily, when input receiving is first
    /// granted). Uses the same dynamic policy as the TCP listener.
    public func startDatagramListener() async throws -> (port: UInt16, inbound: AsyncStream<DatagramConnection>) {
        let parameters = DTLSParametersBuilder.make(
            identity: identityForLanes,
            policyProvider: listenerPolicyProviderForLanes,
            queue: laneQueue
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TransportError.listenerFailed("\(error)")
        }

        let (stream, continuation) = AsyncStream.makeStream(of: DatagramConnection.self)
        listener.newConnectionHandler = { [queue = laneQueue] nwConnection in
            nwConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    nwConnection.stateUpdateHandler = nil
                    continuation.yield(DatagramConnection(connection: nwConnection))
                case .failed, .cancelled:
                    nwConnection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            nwConnection.start(queue: queue)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                        cont.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                        cont.resume(throwing: TransportError.listenerFailed("\(error)"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: laneQueue)
        }
        retainDatagramListener(listener)
        transportLog.info("DTLS datagram listener ready on port \(port)")
        return (port, stream)
    }

    public func connectDatagram(
        host: String, port: UInt16, policy: TLSVerifyPolicy, timeoutSeconds: Double = 10
    ) async throws -> DatagramConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.connectFailed("bad port \(port)")
        }
        let parameters = DTLSParametersBuilder.make(
            identity: identityForLanes, policyProvider: { policy }, queue: laneQueue
        )
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let nwConnection = NWConnection(to: endpoint, using: parameters)
        let queue = laneQueue

        return try await withThrowingTaskGroup(of: DatagramConnection.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DatagramConnection, Error>) in
                    let resumed = Locked(false)
                    nwConnection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                                nwConnection.stateUpdateHandler = nil
                                cont.resume(returning: DatagramConnection(connection: nwConnection))
                            }
                        case .failed(let error):
                            if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                                cont.resume(throwing: TransportError.connectFailed("\(error)"))
                            }
                        case .cancelled:
                            if !resumed.withValue({ let was = $0; $0 = true; return was }) {
                                cont.resume(throwing: TransportError.connectFailed("cancelled"))
                            }
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
}

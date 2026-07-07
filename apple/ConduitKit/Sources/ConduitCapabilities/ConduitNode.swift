import Foundation
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

let nodeLog = Logger(subsystem: "org.conduit", category: "node")

public struct NodeConfiguration: Sendable {
    public var deviceName: String
    public var deviceClass: DeviceClass
    public var appVersion: String
    /// Where completed incoming files land (Downloads/Conduit on Mac, Documents on iOS).
    public var receiveDirectory: URL
    /// Where peers.json and partial transfers live.
    public var stateDirectory: URL
    /// Keychain label for the TLS identity items.
    public var keychainLabel: String

    public init(
        deviceName: String,
        deviceClass: DeviceClass,
        appVersion: String,
        receiveDirectory: URL,
        stateDirectory: URL,
        keychainLabel: String = "org.conduit.tls"
    ) {
        self.deviceName = deviceName
        self.deviceClass = deviceClass
        self.appVersion = appVersion
        self.receiveDirectory = receiveDirectory
        self.stateDirectory = stateDirectory
        self.keychainLabel = keychainLabel
    }

    /// What this platform cannot do (spec §4), advertised honestly in HELLO.
    public static func defaultPlatformWalls() -> [String] {
        #if os(iOS)
        return ["clipboard-ambient", "input-inject", "notification-source"]
        #elseif os(macOS)
        return ["notification-source"]
        #else
        return []
        #endif
    }
}

/// The composition root: owns the transport backend, session links, pairing
/// flows, and capability engines. Apps talk to this actor and consume `events`.
public actor ConduitNode {
    public let config: NodeConfiguration
    private let bundle: IdentityBundle
    private let identity: DeviceIdentity
    private let peerStore: PeerStore
    private let backend: LANBackend
    private let pairingAcceptance: Locked<Bool>

    private let sendEngine: FileSendEngine
    private let receiveEngine: FileReceiveEngine

    public nonisolated let events: AsyncStream<ConduitEvent>
    private let eventsContinuation: AsyncStream<ConduitEvent>.Continuation

    private var listenPort: UInt16?
    private var sessions: [String: PeerLink] = [:]
    private var lastDiscovered: [DiscoveredPeer] = []
    private var lastEndpoints: [DiscoveredEndpoint] = []
    /// Devices the user wants connected; reconnect-with-backoff targets these
    /// identities, never addresses (spec §5.2).
    private var desiredConnections: Set<String> = []
    private var connectLoops: [String: Task<Void, Never>] = [:]
    private var pairingWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var acceptTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var started = false

    public init(config: NodeConfiguration, identityStore: any IdentityStore) throws {
        self.config = config
        self.bundle = try IdentityBootstrap.loadOrCreate(
            store: identityStore, name: config.deviceName, deviceClass: config.deviceClass
        )
        self.identity = try bundle.deviceIdentity()

        let peerStore = PeerStore(fileURL: config.stateDirectory.appendingPathComponent("peers.json"))
        self.peerStore = peerStore
        let pairingAcceptance = Locked(false)
        self.pairingAcceptance = pairingAcceptance

        self.backend = try LANBackend(
            material: bundle.tlsMaterial,
            keychainLabel: config.keychainLabel,
            listenerPolicyProvider: {
                pairingAcceptance.get()
                    ? .acceptAnyForPairing
                    : .pinned(peerStore.currentPinnedTLSKeyHashes())
            }
        )

        let (stream, continuation) = AsyncStream.makeStream(of: ConduitEvent.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.eventsContinuation = continuation

        let backend = self.backend
        self.sendEngine = FileSendEngine(
            emit: { continuation.yield($0) },
            bulkOpener: { peer, host, port in
                let connection = try await backend.connect(
                    host: host, port: port, policy: .pinned([peer.tlsPubkeySHA256])
                )
                return FramedConnection(connection)
            }
        )
        self.receiveEngine = FileReceiveEngine(
            receiveDirectory: config.receiveDirectory,
            partialsDirectory: config.stateDirectory.appendingPathComponent("partials"),
            emit: { continuation.yield($0) }
        )
    }

    // MARK: Introspection

    public nonisolated var localDeviceName: String { config.deviceName }
    public var localDeviceID: String { identity.deviceID }
    public var localListenPort: UInt16? { listenPort }

    public func pinnedPeers() async -> [PinnedPeer] {
        await peerStore.allPeers()
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard !started else { return }
        started = true

        let (port, inbound) = try await backend.start()
        listenPort = port
        emit(.listenerReady(port: port))

        try backend.advertise(ServiceDescriptor(
            type: ProtocolServiceType.appService,
            name: config.deviceName,
            txt: [
                ProtocolConstants.TXTKey.deviceID: identity.deviceID,
                ProtocolConstants.TXTKey.name: config.deviceName,
                ProtocolConstants.TXTKey.deviceClass: config.deviceClass.rawValue,
                ProtocolConstants.TXTKey.version: ProtocolConstants.version,
            ]
        ))

        acceptTask = Task {
            for await connection in inbound {
                Task { await self.routeInbound(connection) }
            }
        }
        browseTask = Task {
            for await endpoints in self.backend.browse() {
                await self.updateDiscovered(endpoints)
            }
        }
        emit(.pinnedPeersChanged(await peerStore.allPeers()))
    }

    public func stop() async {
        acceptTask?.cancel()
        browseTask?.cancel()
        for loop in connectLoops.values { loop.cancel() }
        connectLoops.removeAll()
        for (_, link) in sessions {
            await link.close()
        }
        sessions.removeAll()
        backend.shutdown()
        started = false
    }

    // MARK: Discovery

    private func updateDiscovered(_ endpoints: [DiscoveredEndpoint]) async {
        lastEndpoints = endpoints
        var peers: [DiscoveredPeer] = []
        for endpoint in endpoints {
            let deviceID = endpoint.txt[ProtocolConstants.TXTKey.deviceID]
            if deviceID == identity.deviceID { continue } // self
            let isPaired: Bool
            if let deviceID, await peerStore.peer(id: deviceID) != nil {
                isPaired = true
            } else {
                isPaired = false
            }
            peers.append(DiscoveredPeer(
                endpoint: endpoint,
                deviceID: deviceID,
                name: endpoint.txt[ProtocolConstants.TXTKey.name] ?? endpoint.serviceName,
                deviceClassRaw: endpoint.txt[ProtocolConstants.TXTKey.deviceClass] ?? DeviceClass.unknown.rawValue,
                isPaired: isPaired
            ))
        }
        lastDiscovered = peers
        emit(.discoveredPeersChanged(peers))
    }

    // MARK: Inbound routing

    private func routeInbound(_ connection: any ByteStreamConnection) async {
        let framed = FramedConnection(connection)
        do {
            let first = try await withTimeout(seconds: 15) { try await framed.nextFrame() }
            guard let first, case .control(let payload) = first else {
                framed.closeUnderlying()
                return
            }
            let (meta, message) = try MessageCodec.decode(payload)
            switch message {
            case .hello(let body):
                try await adoptInboundSession(framed, hello: body, meta: meta)
            case .pairRequest(let body):
                await respondToPairRequest(framed, request: body, meta: meta)
            case .bulkAttach(let body):
                let attached = await receiveEngine.attachBulk(framed, fileID: body.fileID, token: body.bulkToken)
                if !attached {
                    nodeLog.warning("bulk attach rejected for file \(body.fileID, privacy: .public)")
                    framed.closeUnderlying()
                }
            default:
                nodeLog.warning("unexpected first message \(message.typeString, privacy: .public); closing")
                framed.closeUnderlying()
            }
        } catch {
            framed.closeUnderlying()
        }
    }

    private func adoptInboundSession(_ framed: FramedConnection, hello: HelloBody, meta: EnvelopeMeta) async throws {
        guard let keyHash = framed.peerTLSKeyHash,
              let peer = await peerStore.peer(tlsKeyHash: keyHash)
        else {
            nodeLog.warning("HELLO from unpinned TLS key; closing")
            framed.closeUnderlying()
            return
        }
        if let existing = sessions.removeValue(forKey: peer.deviceID) {
            await existing.close()
        }
        let link = PeerLink(
            peer: peer, framed: framed, localHello: makeLocalHello(),
            onEvent: { [weak self] event in await self?.handleLinkEvent(event) }
        )
        try await link.performResponderHello(remote: hello, meta: meta)
        sessions[peer.deviceID] = link
        await link.activate()
        await peerStore.markSeen(deviceID: peer.deviceID)
    }

    // MARK: Pairing

    /// While on, inbound unpinned TLS connections are allowed so a new device
    /// can start the ceremony. Off by default; the UI exposes the toggle.
    public func setPairingAcceptance(_ accepting: Bool) {
        pairingAcceptance.set(accepting)
    }

    public func beginPairing(withDiscoveredID id: String) async {
        guard let target = lastDiscovered.first(where: { $0.id == id }) else {
            emit(.pairingFailed(reason: "device no longer visible"))
            return
        }
        do {
            let localBody = try PairingFlow.makeLocalBody(bundle: bundle)
            let connection = try await backend.connect(to: target.endpoint, policy: .acceptAnyForPairing)
            let framed = FramedConnection(connection)
            let outcome = await PairingFlow.initiate(framed: framed, localBody: localBody) { [weak self] prompt in
                await self?.awaitPairingDecision(prompt) ?? false
            }
            await handlePairingOutcome(outcome, framed: framed)
        } catch {
            emit(.pairingFailed(reason: "\(error)"))
        }
    }

    private func respondToPairRequest(_ framed: FramedConnection, request: PairBody, meta: EnvelopeMeta) async {
        guard pairingAcceptance.get() else {
            try? await framed.send(.pairReject(PairRejectBody(reason: "pairing not enabled on this device")))
            framed.closeUnderlying()
            return
        }
        do {
            let localBody = try PairingFlow.makeLocalBody(bundle: bundle)
            let outcome = await PairingFlow.respond(
                framed: framed, request: request, requestMeta: meta, localBody: localBody
            ) { [weak self] prompt in
                await self?.awaitPairingDecision(prompt) ?? false
            }
            await handlePairingOutcome(outcome, framed: framed)
        } catch {
            emit(.pairingFailed(reason: "\(error)"))
            framed.closeUnderlying()
        }
    }

    private func awaitPairingDecision(_ prompt: PairingPromptInfo) async -> Bool {
        await withCheckedContinuation { continuation in
            pairingWaiters[prompt.flowID] = continuation
            emit(.pairingPrompt(prompt))
        }
    }

    public func resolvePairingPrompt(flowID: UUID, accept: Bool) {
        pairingWaiters.removeValue(forKey: flowID)?.resume(returning: accept)
    }

    private func handlePairingOutcome(_ outcome: PairingOutcome, framed: FramedConnection) async {
        switch outcome {
        case .paired(let peer):
            try? await peerStore.upsert(peer)
            emit(.pairingCompleted(peer))
            emit(.pinnedPeersChanged(await peerStore.allPeers()))
            framed.closeUnderlying()
            // Refresh paired flags on the visible peer list.
            await updateDiscovered(lastEndpoints)
        case .rejectedLocally:
            emit(.pairingFailed(reason: "declined on this device"))
        case .failed(let reason):
            emit(.pairingFailed(reason: reason))
        }
    }

    // MARK: Sessions

    public func connect(toDevice deviceID: String) async {
        desiredConnections.insert(deviceID)
        startConnectLoop(deviceID)
    }

    public func disconnect(deviceID: String) async {
        desiredConnections.remove(deviceID)
        connectLoops.removeValue(forKey: deviceID)?.cancel()
        if let link = sessions.removeValue(forKey: deviceID) {
            await link.close()
        }
    }

    public func unpair(deviceID: String) async {
        await disconnect(deviceID: deviceID)
        try? await peerStore.remove(deviceID: deviceID)
        emit(.pinnedPeersChanged(await peerStore.allPeers()))
        await updateDiscovered(lastEndpoints)
    }

    private func startConnectLoop(_ deviceID: String) {
        guard connectLoops[deviceID] == nil, sessions[deviceID] == nil else { return }
        let task = Task { [weak self] in
            var attempt = 0
            while let self, await self.shouldKeepConnecting(deviceID) {
                let connected = await self.attemptConnection(deviceID)
                if connected { break }
                attempt += 1
                let backoff = min(pow(2.0, Double(attempt - 1)), 30.0)
                try? await Task.sleep(for: .seconds(backoff))
                if Task.isCancelled { break }
            }
            await self?.connectLoopFinished(deviceID)
        }
        connectLoops[deviceID] = task
    }

    private func shouldKeepConnecting(_ deviceID: String) -> Bool {
        desiredConnections.contains(deviceID) && sessions[deviceID] == nil && !Task.isCancelled
    }

    private func connectLoopFinished(_ deviceID: String) {
        connectLoops.removeValue(forKey: deviceID)
    }

    private func attemptConnection(_ deviceID: String) async -> Bool {
        guard let peer = await peerStore.peer(id: deviceID) else { return false }
        guard let target = lastDiscovered.first(where: { $0.deviceID == deviceID }) else {
            emit(.sessionStateChanged(deviceID: deviceID, state: .connecting, backend: nil))
            return false // not visible yet; back off and retry
        }
        emit(.sessionStateChanged(deviceID: deviceID, state: .connecting, backend: nil))
        do {
            let connection = try await backend.connect(
                to: target.endpoint, policy: .pinned([peer.tlsPubkeySHA256])
            )
            let framed = FramedConnection(connection)
            let link = PeerLink(
                peer: peer, framed: framed, localHello: makeLocalHello(),
                onEvent: { [weak self] event in await self?.handleLinkEvent(event) }
            )
            emit(.sessionStateChanged(deviceID: deviceID, state: .hello, backend: connection.backendKind))
            try await link.performInitiatorHello()
            sessions[deviceID] = link
            await link.activate()
            await peerStore.markSeen(deviceID: deviceID)
            return true
        } catch {
            nodeLog.info("connect attempt to \(peer.name, privacy: .public) failed: \(error)")
            return false
        }
    }

    private func makeLocalHello() -> HelloBody {
        HelloBody(
            identity: identity.deviceID,
            name: config.deviceName,
            deviceClass: config.deviceClass,
            appVersion: config.appVersion,
            pubkey: identity.publicKeyRaw,
            capabilities: [CapabilityID.file, CapabilityID.clipboard],
            platformWalls: NodeConfiguration.defaultPlatformWalls(),
            listenPort: listenPort
        )
    }

    // MARK: Link events

    private func handleLinkEvent(_ event: PeerLinkEvent) async {
        switch event {
        case .stateChanged(let deviceID, let state):
            let backend = sessions[deviceID]?.framed.backendKind
            emit(.sessionStateChanged(deviceID: deviceID, state: state, backend: backend))
            switch state {
            case .ready:
                if let link = sessions[deviceID] {
                    await sendEngine.retryPending(peerDeviceID: deviceID, over: link)
                }
            case .closed:
                sessions.removeValue(forKey: deviceID)
                if desiredConnections.contains(deviceID) {
                    startConnectLoop(deviceID)
                }
            default:
                break
            }
        case .rttUpdated(let deviceID, let millis):
            emit(.rttUpdated(deviceID: deviceID, millis: millis))
        case .capabilityMessage(let deviceID, let message):
            await routeCapabilityMessage(message, from: deviceID)
        case .chunk(_, let chunk):
            await receiveEngine.handleChunk(chunk)
        }
    }

    private func routeCapabilityMessage(_ message: Message, from deviceID: String) async {
        switch message {
        case .clipboardPush(let body):
            emit(.clipboardReceived(fromDeviceID: deviceID, body: body))
        case .fileOffer(let offer):
            guard let link = sessions[deviceID] else { return }
            await receiveEngine.handleOffer(offer, from: link)
        case .fileAccept, .fileAck, .fileReject:
            await sendEngine.handleMessage(message)
        case .bulkAttach:
            nodeLog.warning("BULK_ATTACH on a session connection; ignoring")
        default:
            nodeLog.warning("unrouted message \(message.typeString, privacy: .public)")
        }
    }

    // MARK: Capabilities API (UI entry points)

    public func sendFile(url: URL, to deviceID: String) async {
        guard let link = sessions[deviceID] else {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "no active session"))
            return
        }
        guard await link.hasCapability(CapabilityID.file) else {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "peer does not support file transfer"))
            return
        }
        do {
            try await sendEngine.offerFile(url: url, to: link)
        } catch {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "\(error)"))
        }
    }

    public func respondToFileOffer(fileID: String, accept: Bool) async {
        if accept {
            await receiveEngine.accept(fileID: fileID)
        } else {
            await receiveEngine.reject(fileID: fileID)
        }
    }

    public func sendClipboard(_ body: ClipboardPushBody, to deviceID: String) async {
        guard let link = sessions[deviceID], await link.hasCapability(CapabilityID.clipboard) else {
            emit(.nodeLog("clipboard: no session or capability for \(deviceID)"))
            return
        }
        do {
            try await link.send(.clipboardPush(body))
            emit(.clipboardSent(toDeviceID: deviceID))
        } catch {
            emit(.nodeLog("clipboard send failed: \(error)"))
        }
    }

    public func sessionState(for deviceID: String) async -> SessionState {
        if let link = sessions[deviceID] {
            return await link.state
        }
        return .idle
    }

    private func emit(_ event: ConduitEvent) {
        eventsContinuation.yield(event)
    }
}

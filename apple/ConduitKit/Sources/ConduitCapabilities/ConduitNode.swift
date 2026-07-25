import Foundation
import Network
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

let nodeLog = Logger(subsystem: "org.mosis", category: "node")

public struct NodeConfiguration: Sendable {
    public var deviceName: String
    public var deviceClass: DeviceClass
    public var appVersion: String
    /// Where completed incoming files land (Downloads/Conduit on Mac, Documents on iOS).
    public var receiveDirectory: URL
    /// Where peers.json and partial transfers live.
    public var stateDirectory: URL
    /// App Group id shared with the iOS broadcast extension (Phase 3 step 4).
    /// nil on macOS and in tests, where there is no broadcast extension.
    public var appGroupID: String?

    public init(
        deviceName: String,
        deviceClass: DeviceClass,
        appVersion: String,
        receiveDirectory: URL,
        stateDirectory: URL,
        appGroupID: String? = nil
    ) {
        self.deviceName = deviceName
        self.deviceClass = deviceClass
        self.appVersion = appVersion
        self.receiveDirectory = receiveDirectory
        self.stateDirectory = stateDirectory
        self.appGroupID = appGroupID
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
    /// Device-seam counters for the debug HUD (M2). Snapshotted ~1 Hz in start().
    private let diagnostics: Diagnostics
    private var diagnosticsTask: Task<Void, Never>?

    private let sendEngine: FileSendEngine
    private let receiveEngine: FileReceiveEngine
    /// Present only on platforms that can inject input (macOS). Its presence
    /// is what makes this device advertise the input-inject capability.
    private let inputReceiveEngine: InputReceiveEngine?
    private let inputControllerEngine: InputControllerEngine
    private var inputConsentWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    /// Screen source engine present only where a capturer exists (macOS); its
    /// presence is what advertises the screen-source capability. The viewer
    /// engine exists everywhere (every platform can display a stream).
    private let screenSourceEngine: ScreenSourceEngine?
    /// The capturer this node shares with — kept so permission queries describe
    /// the object that actually does the capturing.
    private let screenCapturer: (any ScreenCapturer)?
    private let screenViewerEngine: ScreenViewerEngine
    private var screenPickWaiters: [String: CheckedContinuation<CaptureSourceDescriptor?, Never>] = [:]
    private var pendingScreenSources: [String: [CaptureSourceDescriptor]] = [:]
    /// Pending viewer-grant prompts (multi-viewer social permissions, Phase 7).
    private var viewerGrantWaiters: [String: CheckedContinuation<PermissionScope?, Never>] = [:]
    private var iosBroadcastWireSession: UInt16 = 1
    /// Non-nil only in tests (see `simulateUnreachableListenerForTesting`).
    private var helloListenPortOverride: UInt16?
    /// Consecutive failed connect attempts per peer; reset on success.
    private var connectFailureCounts: [String: Int] = [:]
    /// The broadcast offer announced to a viewer but not yet (or currently)
    /// being streamed by the extension — so cancelling/stopping can tell the
    /// viewer over the control link instead of leaving it waiting on the
    /// attach watchdog.
    /// The announced-but-not-yet-streaming iOS broadcast. Keeps the offer so it
    /// can be re-sent as a keep-alive while the user works through Apple's
    /// broadcast picker (see `refreshIOSScreenBroadcastOffer`).
    private var pendingIOSBroadcast: (deviceID: String, screenSessionID: String, offer: ScreenOfferBody)?

    public nonisolated let events: AsyncStream<ConduitEvent>
    private let eventsContinuation: AsyncStream<ConduitEvent>.Continuation

    private var listenPort: UInt16?
    private var sessions: [String: PeerLink] = [:]
    private var lastDiscovered: [DiscoveredPeer] = []
    private var lastEndpoints: [DiscoveredEndpoint] = []
    /// Devices the user wants connected; reconnect-with-backoff targets these
    /// identities, never addresses (spec §5.2).
    private var desiredConnections: Set<String> = []
    /// Debug/tests: explicit host:port per device, used when discovery can't
    /// see the peer (also the seam loopback E2E tests use, avoiding mDNS).
    private var manualEndpoints: [String: (host: String, port: UInt16)] = [:]
    private var connectLoops: [String: Task<Void, Never>] = [:]
    private var pairingWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var acceptTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var started = false

    /// `inputInjector` is injected for testability; when nil the node uses the
    /// platform default (MacInputInjector on macOS, none elsewhere).
    public init(
        config: NodeConfiguration,
        identityStore: any IdentityStore,
        inputInjector: (any InputInjector)? = nil,
        screenCapturer: (any ScreenCapturer)? = nil
    ) throws {
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
        let diagnostics = Diagnostics()
        self.diagnostics = diagnostics
        // A weak self-box shared by every engine callback that must round-trip
        // through the node (reverse-dial candidates, input consent, screen pick).
        let selfBox = NodeSelfBox()
        self.selfBox = selfBox
        // Shared opener for dedicated bulk connections (files + screen frames).
        // Tries a candidate chain (live session endpoint → discovered Bonjour →
        // manual) so a reverse-dial that can't use the session's address still
        // lands; records the winning target/label, else the exhaustive failure.
        let bulkOpener: @Sendable (PinnedPeer, UInt16) async throws -> FramedConnection = { peer, listenPort in
            let candidates = await selfBox.node?.bulkCandidates(for: peer, listenPort: listenPort) ?? []
            do {
                let result = try await backend.connectFirstAvailable(
                    candidates: candidates, policy: .pinned([peer.tlsPubkeySHA256])
                )
                diagnostics.dial(target: result.target, result: "ok via \(result.label)")
                return FramedConnection(result.connection)
            } catch {
                diagnostics.dial(
                    target: candidates.first.map { "\($0.endpoint)" } ?? "no candidates",
                    result: "failed: \(error)"
                )
                throw error
            }
        }
        self.sendEngine = FileSendEngine(
            emit: { continuation.yield($0) },
            bulkOpener: bulkOpener
        )
        self.receiveEngine = FileReceiveEngine(
            receiveDirectory: config.receiveDirectory,
            partialsDirectory: config.stateDirectory.appendingPathComponent("partials"),
            emit: { continuation.yield($0) }
        )

        // Input: the controller half exists everywhere (any device can drive a
        // Mac); the receive half exists only where an injector is supplied.
        // The platform default (MacInputInjector on macOS) is chosen by the app
        // layer, not here — so tests and non-Mac hosts can be injector-free.
        self.inputControllerEngine = InputControllerEngine(
            backend: backend, emit: { continuation.yield($0) }, diagnostics: diagnostics
        )
        if let injector = inputInjector {
            self.inputReceiveEngine = InputReceiveEngine(
                injector: injector,
                backend: backend,
                emit: { continuation.yield($0) },
                diagnostics: diagnostics,
                requestConsent: { peerID in
                    await selfBox.node?.awaitInputConsent(peerID: peerID) ?? false
                }
            )
        } else {
            self.inputReceiveEngine = nil
        }

        // Screen: viewer half everywhere; source half only where a capturer
        // exists (macOS). The source pick is bridged to the UI via selfBox.
        self.screenViewerEngine = ScreenViewerEngine(emit: { continuation.yield($0) }, diagnostics: diagnostics)
        self.screenCapturer = screenCapturer
        if let capturer = screenCapturer {
            self.screenSourceEngine = ScreenSourceEngine(
                capturer: capturer,
                emit: { continuation.yield($0) },
                diagnostics: diagnostics,
                bulkOpener: bulkOpener,
                pickSource: { peerID, sources in
                    await selfBox.node?.awaitScreenPick(peerID: peerID, sources: sources) ?? nil
                },
                grantViewer: { peerID, capability in
                    await selfBox.node?.awaitViewerGrant(peerID: peerID, capability: capability) ?? nil
                }
            )
        } else {
            self.screenSourceEngine = nil
        }
    }

    /// Weak self-reference engine callbacks capture without a cycle.
    private final class NodeSelfBox: @unchecked Sendable {
        weak var node: ConduitNode?
    }
    private let selfBox: NodeSelfBox

    /// The platform's default input injector (MacInputInjector on macOS, none
    /// elsewhere). Apps pass this into `init`; tests pass their own or nil.
    public static func defaultInjector() -> (any InputInjector)? {
        #if os(macOS)
        return MacInputInjector()
        #else
        return nil
        #endif
    }

    /// The platform's default screen capturer (ScreenCaptureKit on macOS; iOS
    /// sourcing is a ReplayKit broadcast extension, a separate process, so nil
    /// here). Apps pass this into `init`; tests pass their own or nil.
    public static func defaultScreenCapturer() -> (any ScreenCapturer)? {
        #if os(macOS)
        return MacScreenCapturer()
        #else
        return nil
        #endif
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
        selfBox.node = self

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
        // Bonjour browsing can die on its own (observed on device:
        // "browser failed: -65569: DefunctConnection" after a network change).
        // The stream then simply ends and nothing is ever discovered again
        // until the app is relaunched — so restart it.
        browseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await endpoints in self.backend.browse() {
                    await self.updateDiscovered(endpoints)
                }
                guard !Task.isCancelled else { return }
                nodeLog.warning("discovery browser ended; restarting")
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Snapshot the device-seam counters ~1 Hz for the debug HUD (M2).
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.emitDiagnostics()
            }
        }
        emit(.pinnedPeersChanged(await peerStore.allPeers()))
    }

    private func emitDiagnostics() {
        emit(.diagnosticsSnapshot(diagnostics.snapshot()))
    }

    public func stop() async {
        acceptTask?.cancel()
        browseTask?.cancel()
        diagnosticsTask?.cancel()
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
            case .screenAttach(let body):
                // The source opened this connection to stream frames to us.
                let attached = await screenViewerEngine.attachStream(framed, attach: body)
                if !attached {
                    nodeLog.warning("screen attach rejected for \(body.screenSessionID, privacy: .public)")
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
        await runInitiatorPairing {
            try await self.backend.connect(to: target.endpoint, policy: .acceptAnyForPairing)
        }
    }

    /// Direct-address pairing (debug UI and tests; no discovery involved).
    public func beginPairing(host: String, port: UInt16) async {
        await runInitiatorPairing {
            try await self.backend.connect(host: host, port: port, policy: .acceptAnyForPairing)
        }
    }

    private func runInitiatorPairing(_ open: @Sendable () async throws -> any ByteStreamConnection) async {
        do {
            let localBody = try PairingFlow.makeLocalBody(bundle: bundle)
            let connection = try await open()
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

    /// Connect via an explicit address (debug UI and tests). The address is
    /// remembered for reconnects of this device within the process lifetime.
    public func connect(toDevice deviceID: String, host: String, port: UInt16) async {
        manualEndpoints[deviceID] = (host, port)
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

    /// Reverse-dial candidates for reaching `peer`'s listener, best-first:
    /// (1) the live control connection's TYPED peer endpoint retargeted to the
    /// peer's HELLO listen port (no String round-trip, so an IPv6 zone survives),
    /// (2) the peer's discovered Bonjour endpoint (fresh mDNS resolution when
    /// dialed), (3) any manual host:port. The candidate-chain opener tries them
    /// in order — so a reverse-dial no longer hinges on a single stringified path.
    private func bulkCandidates(for peer: PinnedPeer, listenPort: UInt16) -> [LANBackend.DialCandidate] {
        var candidates: [LANBackend.DialCandidate] = []
        guard let port = NWEndpoint.Port(rawValue: listenPort) else { return candidates }
        if let sessionEndpoint = sessions[peer.deviceID]?.framed.remoteEndpoint,
           case .hostPort(let host, _) = sessionEndpoint {
            candidates.append(.init(label: "session", endpoint: .hostPort(host: host, port: port)))
        }
        if let disco = lastDiscovered.first(where: { $0.deviceID == peer.deviceID }) {
            candidates.append(.init(label: "bonjour", endpoint: disco.endpoint.endpoint))
        }
        if let manual = manualEndpoints[peer.deviceID],
           let manualPort = NWEndpoint.Port(rawValue: manual.port) {
            candidates.append(.init(label: "manual",
                                    endpoint: .hostPort(host: NWEndpoint.Host(manual.host), port: manualPort)))
        }
        return candidates
    }

    private func attemptConnection(_ deviceID: String) async -> Bool {
        guard let peer = await peerStore.peer(id: deviceID) else { return false }
        let discovered = lastDiscovered.first(where: { $0.deviceID == deviceID })
        let manual = manualEndpoints[deviceID]
        emit(.sessionStateChanged(deviceID: deviceID, state: .connecting, backend: nil))
        guard discovered != nil || manual != nil else {
            return false // not visible yet; back off and retry
        }
        do {
            let policy = TLSVerifyPolicy.pinned([peer.tlsPubkeySHA256])
            // Try EVERY address we have, best-first, within one attempt — the
            // same candidate-chain discipline the bulk dial already uses (M3).
            //
            // This used to pick exactly one: the Bonjour record if the peer had
            // been discovered, otherwise the manual address. So a stale or
            // wrong-interface mDNS resolution beat a known-good address and the
            // whole attempt failed, then backed off 1→2→4→8→16→30s before
            // trying again — and tried the same bad candidate every time. On a
            // busy network that is minutes of "Connecting…" with a perfectly
            // reachable peer.
            var connection: (any ByteStreamConnection)?
            var errors: [String] = []
            if let discovered {
                do { connection = try await backend.connect(to: discovered.endpoint, policy: policy) }
                catch { errors.append("bonjour: \(error)") }
            }
            if connection == nil, let manual {
                do { connection = try await backend.connect(host: manual.host, port: manual.port, policy: policy) }
                catch { errors.append("\(manual.host):\(manual.port): \(error)") }
            }
            guard let connection else {
                throw TransportError.connectFailed(errors.isEmpty
                    ? "no reachable address" : errors.joined(separator: " | "))
            }
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
            connectFailureCounts[deviceID] = nil
            return true
        } catch {
            nodeLog.info("connect attempt to \(peer.name, privacy: .public) failed: \(error)")
            let attempts = (connectFailureCounts[deviceID] ?? 0) + 1
            connectFailureCounts[deviceID] = attempts
            // Stay quiet for a couple of attempts (a peer that just woke up
            // reconnects fine), then explain rather than spinning forever.
            if attempts == 3 || attempts % 10 == 0 {
                emit(.connectFailing(
                    deviceID: deviceID,
                    reason: diagnoseConnectFailure(peer: peer, error: error, discovered: discovered != nil),
                    attempts: attempts
                ))
            }
            return false
        }
    }

    /// Turns a connect error into something the user can act on. The important
    /// case: the peer is right there on the network but rejects us — that is a
    /// trust mismatch (its pinned record no longer matches this device's
    /// identity, e.g. after a reinstall or a bundle/App-Group change), and no
    /// amount of retrying fixes it. Re-pairing does.
    private func diagnoseConnectFailure(peer: PinnedPeer, error: Error, discovered: Bool) -> String {
        let text = "\(error)".lowercased()
        let looksLikeTLS = text.contains("tls") || text.contains("handshake")
            || text.contains("-9807") || text.contains("-9836") || text.contains("badcert")
            || text.contains("peer") && text.contains("reject")
        if looksLikeTLS || (discovered && !text.contains("timed out")) {
            return "\(peer.name) is on the network but refused the connection — "
                + "it no longer recognises this device. Unpair \(peer.name) here and pair again."
        }
        if !discovered {
            return "\(peer.name) isn't visible on this network. Check both devices are on the same Wi-Fi "
                + "with Conduit open, and that Local Network permission is allowed."
        }
        return "Can't connect to \(peer.name): \(error)"
    }

    private func makeLocalHello() -> HelloBody {
        var capabilities = [CapabilityID.file, CapabilityID.clipboard]
        // input-inject and media-target are advertised only where we can act on
        // them — i.e. where an injector exists (macOS). Direction matters
        // (spec §4): the phone omits these yet still drives a Mac that has them.
        if inputReceiveEngine != nil {
            capabilities.append(CapabilityID.inputInject)
            capabilities.append(CapabilityID.mediaTarget)
        }
        // Every platform can display a stream; only ones with a capturer source.
        capabilities.append(CapabilityID.screenView)
        if screenSourceEngine != nil {
            capabilities.append(CapabilityID.screenSource)
        }
        // iOS/macOS can display mirrored notifications (Phase 4); the API to
        // SOURCE other apps' notifications doesn't exist on Apple platforms
        // (spec §4), so notify-source is never advertised here.
        capabilities.append(CapabilityID.notifyShow)
        return HelloBody(
            identity: identity.deviceID,
            name: config.deviceName,
            deviceClass: config.deviceClass,
            appVersion: config.appVersion,
            pubkey: identity.publicKeyRaw,
            capabilities: capabilities,
            platformWalls: NodeConfiguration.defaultPlatformWalls(),
            listenPort: helloListenPortOverride ?? listenPort
        )
    }

    /// Diagnostic seam: makes this node look exactly like a device the peer
    /// cannot reverse-dial — it advertises a listener nothing answers on and
    /// stops being discoverable. That is the real-world failure (macOS Local
    /// Network prompt unanswered, AP client isolation, unreachable iOS
    /// listener), and it must degrade to the control-lane fallback rather than
    /// a blank screen. Used by tests and by `conduit-devnode --no-inbound` to
    /// rehearse that path deliberately.
    public func simulateUnreachableListenerForTesting() {
        helloListenPortOverride = 9   // discard port: refuses fast
        backend.stopAdvertising()
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
                    if let remote = await link.remoteHello {
                        emit(.remoteCapabilities(deviceID: deviceID, capabilities: remote.capabilities))
                    }
                    await sendEngine.retryPending(peerDeviceID: deviceID, over: link)
                }
            case .closed:
                sessions.removeValue(forKey: deviceID)
                await inputReceiveEngine?.handleSessionClosed(peerDeviceID: deviceID)
                if await inputControllerEngine.controllingPeerID == deviceID {
                    await inputControllerEngine.stopControlling()
                }
                await screenSourceEngine?.handleSessionClosed(peerDeviceID: deviceID)
                await screenViewerEngine.handleSessionClosed(peerDeviceID: deviceID)
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
        case .screenFrame(let deviceID, let frame):
            // Control-lane fallback: the source couldn't dial a bulk lane back
            // to us and is streaming over the session connection instead.
            guard let link = sessions[deviceID] else { return }
            await screenViewerEngine.handleControlLaneFrame(frame, framed: link.framed, from: deviceID)
        }
    }

    private func routeCapabilityMessage(_ message: Message, from deviceID: String) async {
        switch message {
        case .clipboardPush(let body):
            emit(.clipboardReceived(fromDeviceID: deviceID, body: body))
        case .notification(let body):
            emit(.notificationReceived(fromDeviceID: deviceID, body: body))
        case .fileOffer(let offer):
            guard let link = sessions[deviceID] else { return }
            await receiveEngine.handleOffer(offer, from: link)
        case .fileAccept, .fileAck, .fileReject:
            await sendEngine.handleMessage(message)
        case .bulkAttach:
            nodeLog.warning("BULK_ATTACH on a session connection; ignoring")
        // Phase 2 — remote input. Receiver-side handling:
        case .inputRequest:
            guard let engine = inputReceiveEngine, let link = sessions[deviceID] else { return }
            // Consent is a USER round-trip, and this runs inside
            // PeerLink.runReadLoop. Awaiting a prompt here stops reading on this
            // peer: inbound PINGs are never dequeued so no PONG goes out, and we
            // can't read the peer's pongs either -- six unanswered pings later
            // (~35 s) both ends close a perfectly healthy session. Hand it to a
            // task so the loop keeps pumping while the sheet is up.
            Task { await engine.handleRequest(from: link) }
        case .inputEvent(let event):
            guard let engine = inputReceiveEngine else { return }
            await engine.handleControlEvent(event, from: deviceID)
        case .mediaControl(let control):
            guard let engine = inputReceiveEngine else { return }
            await engine.handleMedia(control, from: deviceID)
        // Controller-side handling:
        case .inputStatus(let status):
            await inputControllerEngine.handleStatus(status, from: deviceID)
        case .inputAttach:
            nodeLog.warning("INPUT_ATTACH on a session connection; belongs on the datagram lane")
        // Phase 3 — screen sharing. Source-side:
        case .screenRequest(let request):
            guard let engine = screenSourceEngine, let link = sessions[deviceID] else {
                if let link = sessions[deviceID] {
                    try? await link.send(.screenReject(ScreenRejectBody(reason: "this device can't share its screen")))
                }
                return
            }
            // Picking a display/window is a user round-trip -- see the note on
            // .inputRequest. Must not block this peer's read loop.
            Task { await engine.handleRequest(request, from: link) }
        // Viewer-side:
        case .screenOffer(let offer):
            await screenViewerEngine.handleOffer(offer, from: deviceID)
        case .screenReject(let body):
            emit(.screenFailed(reason: body.reason))
        case .screenEnd(let body):
            // Carry the source's reason so a failed share surfaces (with Retry)
            // instead of the viewer silently going blank.
            await screenViewerEngine.stopViewing(screenSessionID: body.screenSessionID, reason: body.reason)
        case .screenAck(let ack):
            // The viewer acks over the session link when frames are riding the
            // control-lane fallback (it has no bulk connection to ack on).
            await screenSourceEngine?.handleControlLaneAck(ack)
        case .screenAttach:
            nodeLog.warning("SCREEN_ATTACH on a session connection; belongs on the screen lane")
        // Phase 7 — social permissions + device state.
        case .permissionRequest(let request):
            // A viewer explicitly asks to join the live screen share.
            guard request.capability == CapabilityID.screenView,
                  let engine = screenSourceEngine, let link = sessions[deviceID] else { return }
            // The grant prompt is a user round-trip -- see the note on
            // .inputRequest. Must not block this peer's read loop.
            Task {
                if let scope = await self.awaitViewerGrant(peerID: deviceID, capability: request.capability) {
                    await engine.addViewer(to: link, scope: scope)
                    try? await link.send(.permissionGrant(PermissionGrantBody(
                        capability: request.capability, scope: scope, peer: self.identity.deviceID)))
                } else {
                    try? await link.send(.permissionRevoke(PermissionRevokeBody(capability: request.capability, peer: deviceID)))
                }
            }
        case .permissionGrant, .permissionRevoke:
            emit(.nodeLog("permission update from \(deviceID): \(message.typeString)"))
        case .deviceState(let body):
            emit(.deviceStateReceived(fromDeviceID: deviceID, body: body))
        default:
            nodeLog.warning("unrouted message \(message.typeString, privacy: .public)")
        }
    }

    // MARK: Capabilities API (UI entry points)

    /// Returns the transfer's fileID so callers can correlate later events
    /// (e.g. releasing a security-scoped URL on completion).
    @discardableResult
    public func sendFile(url: URL, to deviceID: String) async -> String? {
        guard let link = sessions[deviceID] else {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "no active session"))
            return nil
        }
        guard await link.hasCapability(CapabilityID.file) else {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "peer does not support file transfer"))
            return nil
        }
        do {
            return try await sendEngine.offerFile(url: url, to: link)
        } catch {
            emit(.transferFailed(fileID: url.lastPathComponent, reason: "\(error)"))
            return nil
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

    // MARK: Remote input API (Phase 2)

    /// Controller side: ask to drive a peer. Requires the peer to advertise
    /// input-inject; the grant/refusal arrives as an inputControl* event.
    public func requestInputControl(of deviceID: String) async {
        guard let link = sessions[deviceID] else {
            emit(.inputControlFailed(reason: "no active session"))
            return
        }
        await inputControllerEngine.requestControl(of: link)
    }

    public func stopInputControl() async {
        await inputControllerEngine.stopControlling()
    }

    public func sendPointerMove(dx: Double, dy: Double) async {
        await inputControllerEngine.sendMove(dx: dx, dy: dy)
    }

    public func sendScroll(dx: Double, dy: Double) async {
        await inputControllerEngine.sendScroll(dx: dx, dy: dy)
    }

    public func sendClick(_ button: PointerButton, action: InputAction, clickCount: Int = 1) async {
        await inputControllerEngine.sendClick(button, action: action, clickCount: clickCount)
    }

    public func sendText(_ text: String, modifiers: [InputModifier] = []) async {
        await inputControllerEngine.sendText(text, modifiers: modifiers)
    }

    public func sendSpecialKey(_ name: String, modifiers: [InputModifier] = []) async {
        await inputControllerEngine.sendSpecialKey(name, modifiers: modifiers)
    }

    public func sendMedia(_ action: MediaAction, value: Double? = nil) async {
        await inputControllerEngine.sendMedia(action, value: value)
    }

    /// Receiver side: the kill switch (spec invariant — instantly revocable).
    public func revokeInputControl() async {
        await inputReceiveEngine?.revoke(reason: "kill switch")
    }

    public func inputReceiveActivePeer() async -> String? {
        await inputReceiveEngine?.activePeerDeviceID
    }

    /// The app answers an inputConsentRequested prompt through here.
    public func resolveInputConsent(peerDeviceID: String, accept: Bool) {
        inputConsentWaiters.removeValue(forKey: peerDeviceID)?.resume(returning: accept)
    }

    /// Whether this device can be controlled at all (has an injector).
    public var canReceiveInput: Bool {
        inputReceiveEngine != nil
    }

    /// Whether the OS currently permits injection (macOS: Accessibility/TCC).
    public func inputPermissionGranted() async -> Bool {
        await inputReceiveEngine?.isPermitted ?? false
    }

    public func inputPermissionInstructions() async -> String? {
        await inputReceiveEngine?.permissionInstructions
    }

    /// Opens the OS settings pane where the user grants injection permission.
    public func openInputPermissionSettings() async {
        await inputReceiveEngine?.openPermissionSettings()
    }

    /// How long a prompt may sit unanswered before it resolves itself.
    ///
    /// The read loop no longer blocks on these (see routeCapabilityMessage), so
    /// this is hygiene rather than a liveness fix: it stops an ignored sheet
    /// leaking a continuation and leaves the asking peer with a definite answer.
    /// Deliberately longer than the viewer's 45 s attach watchdog -- by the time
    /// this fires the requester has already given up and been told why.
    static let promptTimeout: TimeInterval = 120

    /// Longest edge an iPhone screen broadcast is scaled to. The ReplayKit
    /// extension encodes inside a ~50 MB process, and native phone resolutions
    /// (1290×2796 on a 15 Pro Max) cost far more memory and bitrate than a
    /// viewer can use.
    static let broadcastMaxLongEdge = 1920

    /// Bridges the receive engine's consent request to the app's UI round-trip.
    fileprivate func awaitInputConsent(peerID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            // A duplicate request while one is pending: refuse the newcomer.
            if inputConsentWaiters[peerID] != nil {
                continuation.resume(returning: false)
                return
            }
            inputConsentWaiters[peerID] = continuation
            emit(.inputConsentRequested(peerDeviceID: peerID, promptID: UUID()))
            // resolve* is idempotent (removeValue returns nil the second time),
            // so a late tap after this fires is a harmless no-op.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.promptTimeout))
                await self?.resolveInputConsent(peerDeviceID: peerID, accept: false)
            }
        }
    }

    // MARK: Screen sharing API (Phase 3)

    /// Whether this device can source (share) its screen (has a capturer).
    public var canSourceScreen: Bool {
        screenSourceEngine != nil
    }

    /// Viewer side: ask to view a peer's screen ("Connect to screen" — pull).
    public func requestScreen(from deviceID: String) async {
        guard let link = sessions[deviceID] else {
            emit(.screenFailed(reason: "no active session"))
            return
        }
        guard await link.remoteAdvertises(CapabilityID.screenSource) else {
            emit(.screenFailed(reason: "\(link.peer.name) can't share its screen"))
            return
        }
        let request = ScreenRequestBody(maxWidth: 1920, maxHeight: 1200, maxFps: 30, codecs: [.hevc, .h264])
        do {
            try await link.send(.screenRequest(request))
        } catch {
            emit(.screenFailed(reason: "\(error)"))
        }
    }

    /// Displays and windows this device can share, for a picker shown *before*
    /// anything is offered. Empty when there's no capturer or Screen Recording
    /// is off.
    public func localScreenSources() async -> [CaptureSourceDescriptor] {
        await screenSourceEngine?.localSources() ?? []
    }

    /// Source side: "show my screen on <peer>" — push, the other half of the
    /// spec §8 verb pair. Until now the Mac could only ever have its screen
    /// *pulled* by the far end, so there was no way to put the Mac on a TV or a
    /// tablet from the Mac. Returns nil on success or a reason to show.
    ///
    /// Calling it again with another peer while a share is live adds that peer
    /// to the same capture (one encode, fanned out) rather than restarting.
    public func shareScreen(source: CaptureSourceDescriptor, with deviceID: String) async -> String? {
        guard let engine = screenSourceEngine else {
            return "This device can't share its screen."
        }
        guard let link = sessions[deviceID] else {
            return "Not connected — connect first, then share."
        }
        guard await link.remoteAdvertises(CapabilityID.screenView) else {
            return "\(link.peer.name) can't display a screen."
        }
        return await engine.shareScreen(source: source, to: link)
    }

    /// Source side: stop sharing (also the kill switch for the source indicator).
    /// A clean, user-initiated stop (nil reason) so the viewer ends quietly
    /// rather than seeing it as a failure with a Retry.
    public func stopSourcingScreen() async {
        await screenSourceEngine?.stopSharing(reason: nil)
    }

    /// Viewer side: stop viewing a stream.
    public func stopViewingScreen(screenSessionID: String) async {
        await screenViewerEngine.stopViewing(screenSessionID: screenSessionID)
    }

    /// Diagnostic/testing: drop the dedicated screen lane mid-stream so the
    /// source's demote-to-session-link path can be exercised deliberately.
    public func dropScreenBulkLaneForTesting() async {
        await screenViewerEngine.dropBulkLaneForTesting()
    }

    /// The source app answers a screenSourcePickRequested prompt through here.
    ///
    /// A tap that arrives after the request already expired used to return
    /// silently, leaving a live-looking picker whose every button did nothing.
    /// Now the UI is told to take it down and why.
    public func resolveScreenPick(peerDeviceID: String, sourceID: String?) {
        guard let continuation = screenPickWaiters.removeValue(forKey: peerDeviceID) else {
            if sourceID != nil {
                emit(.screenSourcePickCancelled(
                    peerDeviceID: peerDeviceID,
                    reason: "That request expired before a screen was chosen. Ask again from \(peerName(peerDeviceID))."
                ))
            }
            return
        }
        let sources = pendingScreenSources.removeValue(forKey: peerDeviceID) ?? []
        continuation.resume(returning: sources.first { $0.id == sourceID })
    }

    private func peerName(_ deviceID: String) -> String {
        sessions[deviceID]?.peer.name ?? "that device"
    }

    /// The pick prompt timed out. Resolve the waiting request AND take the
    /// picker off the source's screen — leaving it up is what made the next tap
    /// look like a broken button.
    private func expireScreenPick(peerID: String) {
        guard let continuation = screenPickWaiters.removeValue(forKey: peerID) else { return }
        pendingScreenSources.removeValue(forKey: peerID)
        continuation.resume(returning: nil)
        emit(.screenSourcePickCancelled(
            peerDeviceID: peerID,
            reason: "\(peerName(peerID)) stopped waiting for you to pick a screen. Ask again from that device."
        ))
    }

    // MARK: Multi-viewer social permissions API (Phase 7)

    /// Bridges the screen engine's grant request to a UI prompt.
    fileprivate func awaitViewerGrant(peerID: String, capability: String) async -> PermissionScope? {
        await withCheckedContinuation { continuation in
            if viewerGrantWaiters[peerID] != nil {
                continuation.resume(returning: nil)
                return
            }
            viewerGrantWaiters[peerID] = continuation
            emit(.permissionRequested(peerDeviceID: peerID, capability: capability, scope: "view-only", promptID: UUID()))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.promptTimeout))
                await self?.resolveViewerGrant(peerDeviceID: peerID, scope: nil)
            }
        }
    }

    /// The source app answers a permissionRequested prompt: grant a scope or deny.
    public func resolveViewerGrant(peerDeviceID: String, scope: PermissionScope?) {
        viewerGrantWaiters.removeValue(forKey: peerDeviceID)?.resume(returning: scope)
    }

    /// Viewer side: ask to join a peer's live screen share (view-only).
    public func requestScreenJoin(from deviceID: String) async {
        guard let link = sessions[deviceID] else { return }
        try? await link.send(.permissionRequest(PermissionRequestBody(capability: CapabilityID.screenView, scope: .viewOnly)))
    }

    /// Source side: revoke an additional viewer of the live share, live.
    public func revokeViewer(deviceID: String) async {
        await screenSourceEngine?.revokeViewer(deviceID: deviceID, reason: "revoked by source")
    }

    /// Source side: current viewers of the live share → scope.
    public func screenViewerScopes() async -> [String: String] {
        await screenSourceEngine?.activeViewerScopes() ?? [:]
    }

    /// Send this device's live state to a connected peer (context signaling).
    public func sendDeviceState(_ state: DeviceStateBody, to deviceID: String) async {
        try? await sessions[deviceID]?.send(.deviceState(state))
    }

    /// The source app reads the offered sources for its picker via this snapshot.
    public func screenSources(forPeer peerDeviceID: String) -> [CaptureSourceDescriptor] {
        pendingScreenSources[peerDeviceID] ?? []
    }

    /// iOS source push (Phase 3 step 4): announce a SCREEN_OFFER to a viewer and
    /// write the shared config the broadcast extension reads. Returns the config
    /// (nil if unavailable) so the app can then present the broadcast picker.
    /// The extension — not the node — opens the bulk lane and streams frames.
    public func prepareIOSScreenBroadcast(
        to deviceID: String, width: Int, height: Int, fps: Int
    ) async -> BroadcastConfig? {
        // A previous prepared-but-unused offer would leave that viewer waiting;
        // retire it first (no-op when none).
        await endIOSScreenBroadcast()
        guard let appGroupID = config.appGroupID else {
            emit(.screenFailed(reason: "no app group configured"))
            return nil
        }
        guard let link = sessions[deviceID] else {
            emit(.screenFailed(reason: "no active session"))
            return nil
        }
        guard await link.remoteAdvertises(CapabilityID.screenView) else {
            emit(.screenFailed(reason: "\(link.peer.name) can't view a screen"))
            return nil
        }
        guard let host = link.framed.remoteHost, let port = await link.remoteHello?.listenPort else {
            emit(.screenFailed(reason: "viewer has no reachable listener"))
            return nil
        }
        // Actually cap it. This read `maxW: width, maxH: height`, which makes
        // `fit`'s scale `min(1, 1, 1)` — the source dimensions, unchanged. So
        // the comment at the call site promised a cap that did not exist, and a
        // modern iPhone broadcast 1290×2796 at 8 Mbps from inside a process the
        // OS jetsams at ~50 MB. Cap the long edge to 1080p-class instead.
        let longEdge = max(width, height)
        let (w, h) = longEdge > Self.broadcastMaxLongEdge
            ? ScreenSourceEngine.fit(
                sourceW: width, sourceH: height,
                maxW: width >= height ? Self.broadcastMaxLongEdge : Int.max,
                maxH: height > width ? Self.broadcastMaxLongEdge : Int.max
              )
            : ScreenSourceEngine.fit(sourceW: width, sourceH: height, maxW: width, maxH: height)
        let codec: ScreenVideoCodec = VideoEncoder.isHEVCAvailable() ? .hevc : .h264
        let wireSessionID = iosBroadcastWireSession; iosBroadcastWireSession &+= 1
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
        let screenSessionID = UUID().uuidString

        let offer = ScreenOfferBody(
            screenSessionID: screenSessionID, wireSessionID: wireSessionID, codec: codec,
            width: w, height: h, fps: fps, captureKind: .display,
            sourceName: config.deviceName, bulkToken: token
        )
        do {
            try await link.send(.screenOffer(offer))
        } catch {
            emit(.screenFailed(reason: "offer send failed: \(error)"))
            return nil
        }
        // Pre-compute host fallbacks for the extension (it can't re-resolve mDNS):
        // the session address, then any manual address.
        var hostCandidates = [host]
        if let manualHost = manualEndpoints[deviceID]?.host, !hostCandidates.contains(manualHost) {
            hostCandidates.append(manualHost)
        }
        let bcConfig = BroadcastConfig(
            viewerHost: host, viewerName: link.peer.name, viewerHostCandidates: hostCandidates,
            viewerPort: port, viewerTLSKeySHA256: link.peer.tlsPubkeySHA256,
            screenSessionID: screenSessionID, wireSessionID: wireSessionID, bulkToken: token,
            codec: codec, width: w, height: h, fps: fps, bitrate: ScreenSourceEngine.initialBitrate,
            tlsMaterial: bundle.tlsMaterial
        )
        do {
            BroadcastSharedStore.clearStatus(appGroupID: appGroupID)   // stale status from a prior run
            try BroadcastSharedStore.write(bcConfig, appGroupID: appGroupID)
        } catch {
            emit(.screenFailed(reason: "cannot write broadcast config: \(error)"))
            return nil
        }
        pendingIOSBroadcast = (deviceID, screenSessionID, offer)
        emit(.screenSourceStarted(peerDeviceID: deviceID, sourceName: "your iPhone screen"))
        return bcConfig
    }

    /// Re-sends the pending broadcast offer as a keep-alive.
    ///
    /// The viewer starts a 45 s attach watchdog when the offer arrives, but the
    /// user still has the whole system broadcast picker + countdown ahead of
    /// them. Repeating the *same* offer re-arms that watchdog on the viewer
    /// (`ScreenViewerEngine.handleOffer` treats a repeat as a keep-alive) so the
    /// far end waits as long as the person actually takes. No wire change: it is
    /// the same message, sent again.
    public func refreshIOSScreenBroadcastOffer() async {
        guard let pending = pendingIOSBroadcast,
              let link = sessions[pending.deviceID] else { return }
        try? await link.send(.screenOffer(pending.offer))
    }

    /// Retire the announced broadcast: clear the shared config and tell the
    /// viewer over the control link (clean end). If the extension is streaming,
    /// the viewer closes the bulk lane on receipt and the extension ends —
    /// which makes this the app-side "stop broadcasting" too.
    public func endIOSScreenBroadcast() async {
        if let appGroupID = config.appGroupID {
            BroadcastSharedStore.clear(appGroupID: appGroupID)
        }
        guard let pending = pendingIOSBroadcast else { return }
        pendingIOSBroadcast = nil
        try? await sessions[pending.deviceID]?.send(.screenEnd(ScreenEndBody(
            screenSessionID: pending.screenSessionID, reason: nil
        )))
        emit(.screenSourceEnded(peerDeviceID: pending.deviceID))
    }

    /// Whether Screen Recording is granted, asked of the capturer this node is
    /// actually using. (It used to build a throwaway capturer and ask that one,
    /// so the answer described an object no share would ever use.)
    public func screenPermissionGranted() async -> Bool {
        guard let screenCapturer else { return false }
        return await screenCapturer.isPermitted()
    }

    /// Triggers the OS Screen Recording prompt (first grant needs a relaunch
    /// before ScreenCaptureKit will actually hand over frames).
    public func requestScreenPermission() async {
        await screenCapturer?.requestPermission()
    }

    /// Bridges the source engine's pick request to the app's UI round-trip.
    fileprivate func awaitScreenPick(
        peerID: String, sources: [CaptureSourceDescriptor]
    ) async -> CaptureSourceDescriptor? {
        await withCheckedContinuation { continuation in
            if screenPickWaiters[peerID] != nil {
                continuation.resume(returning: nil)
                return
            }
            screenPickWaiters[peerID] = continuation
            pendingScreenSources[peerID] = sources
            emit(.screenSourcePickRequested(peerDeviceID: peerID, sources: sources))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.promptTimeout))
                await self?.expireScreenPick(peerID: peerID)
            }
        }
    }

    private func emit(_ event: ConduitEvent) {
        eventsContinuation.yield(event)
    }
}

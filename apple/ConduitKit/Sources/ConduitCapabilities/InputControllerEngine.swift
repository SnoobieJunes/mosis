import Foundation
import Network
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

/// Controller side of the remote-input capability (spec §9 Phase 2 step 3
/// backing logic): requests control, coalesces motion at 120 Hz, and prefers
/// the DTLS datagram lane for moves while clicks/keys stay on the reliable
/// control lane. The phone never injects — it only sends (spec §4).
public actor InputControllerEngine {
    private let backend: LANBackend
    private let emit: @Sendable (ConduitEvent) -> Void
    private let diagnostics: Diagnostics

    struct Controlling {
        let peerDeviceID: String
        let link: PeerLink
        var datagram: DatagramConnection?
        var datagramSeq: UInt64 = 0
    }

    private var active: Controlling?
    private var coalescer: InputCoalescer?
    /// Fires if the receiver never answers an INPUT_REQUEST (message lost, peer
    /// wedged). Cancelled as soon as any status arrives.
    private var requestTimeout: Task<Void, Never>?
    private var awaitingGrant = false
    /// Background task that dials + confirms the datagram lane after control is
    /// already live on the reliable lane. Cancelled when control ends.
    private var datagramUpgradeTask: Task<Void, Never>?

    public init(backend: LANBackend, emit: @escaping @Sendable (ConduitEvent) -> Void, diagnostics: Diagnostics) {
        self.backend = backend
        self.emit = emit
        self.diagnostics = diagnostics
    }

    public var isControlling: Bool { active != nil }
    public var controllingPeerID: String? { active?.peerDeviceID }

    /// Ask a peer for control. The grant (or refusal) arrives via handleStatus.
    public func requestControl(of link: PeerLink) async {
        guard await link.remoteAdvertises(CapabilityID.inputInject) else {
            emit(.inputControlFailed(reason: "\(link.peer.name) can't be controlled (no input-inject capability)"))
            return
        }
        active = Controlling(peerDeviceID: link.peer.deviceID, link: link)
        awaitingGrant = true
        do {
            try await link.send(.inputRequest)
            startRequestTimeout(peerDeviceID: link.peer.deviceID)
        } catch {
            active = nil
            awaitingGrant = false
            emit(.inputControlFailed(reason: "\(error)"))
        }
    }

    private func startRequestTimeout(peerDeviceID: String) {
        requestTimeout?.cancel()
        requestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.requestTimedOut(peerDeviceID: peerDeviceID)
        }
    }

    private func requestTimedOut(peerDeviceID: String) async {
        guard awaitingGrant, active?.peerDeviceID == peerDeviceID else { return }
        awaitingGrant = false
        active = nil
        emit(.inputControlFailed(reason: "no response from peer"))
    }

    public func stopControlling() async {
        requestTimeout?.cancel()
        requestTimeout = nil
        datagramUpgradeTask?.cancel()
        datagramUpgradeTask = nil
        awaitingGrant = false
        guard let current = active else { return }
        await coalescer?.stop()
        coalescer = nil
        current.datagram?.close()
        active = nil
        diagnostics.inputControllerLane(nil)
        emit(.inputControlEnded(peerDeviceID: current.peerDeviceID))
    }

    /// Receiver's INPUT_STATUS: grant opened/closed, datagram invite, secure flag.
    public func handleStatus(_ status: InputStatusBody, from peerDeviceID: String) async {
        guard active?.peerDeviceID == peerDeviceID else { return }
        requestTimeout?.cancel()
        requestTimeout = nil
        awaitingGrant = false
        if status.active {
            await beginSending(status: status)
            emit(.inputControlStarted(peerDeviceID: peerDeviceID, secureInput: status.secureInput ?? false))
        } else {
            let reason = status.reason ?? "ended"
            await stopControlling()
            emit(.inputControlFailed(reason: reason))
        }
        if let secure = status.secureInput {
            emit(.inputRemoteSecureInput(peerDeviceID: peerDeviceID, active: secure))
        }
    }

    private func beginSending(status: InputStatusBody) async {
        guard let current = active else { return }

        // Control is live IMMEDIATELY on the reliable lane: start the coalescer
        // now so motion rides from t=0. (The old code awaited a DTLS datagram dial
        // first — up to a 10 s timeout of dead trackpad before anything moved.)
        let coalescer = InputCoalescer { [weak self] event in
            await self?.transmit(event)
        }
        await coalescer.start()
        self.coalescer = coalescer
        diagnostics.inputControllerLane("reliable")

        // The datagram lane is a BACKGROUND upgrade for loss-tolerant moves,
        // adopted only after the receiver echoes our INPUT_ATTACH back over it.
        //
        // It RETRIES rather than trying once. Getting this lane up is what keeps
        // pointer motion off the TCP session link, and that matters most in
        // exactly the situation where the first attempt is likeliest to fail:
        // the screen share has fallen back to the session link, so every move
        // now queues behind 2.5 Mbps of video on one connection. One failed dial
        // at grant time used to condemn the whole session to that.
        datagramUpgradeTask?.cancel()
        datagramUpgradeTask = nil
        if let udpPort = status.udpPort, let token = status.datagramToken {
            let peerID = current.peerDeviceID
            datagramUpgradeTask = Task { [weak self] in
                for attempt in 0..<Self.datagramUpgradeAttempts {
                    if attempt > 0 {
                        try? await Task.sleep(for: .seconds(Self.datagramRetryDelay))
                    }
                    guard !Task.isCancelled else { return }
                    guard await self?.stillNeedsDatagram(peerDeviceID: peerID) == true else { return }
                    await self?.upgradeToDatagram(peerDeviceID: peerID, udpPort: udpPort, token: token)
                }
            }
        }
    }

    /// How many times to try bringing the datagram lane up before settling for
    /// the reliable lane, and how long to wait between attempts.
    static let datagramUpgradeAttempts = 5
    static let datagramRetryDelay: Double = 15

    /// True while this peer is still being controlled with no datagram lane —
    /// i.e. another attempt is worth making.
    private func stillNeedsDatagram(peerDeviceID: String) -> Bool {
        guard let current = active, current.peerDeviceID == peerDeviceID else { return false }
        return current.datagram == nil
    }

    /// Background upgrade: dial the DTLS datagram lane and adopt it for moves ONLY
    /// after the receiver echoes INPUT_ATTACH back over it — proof the lane is
    /// bidirectional, not a black hole that would silently eat every move. Up to
    /// 3 attach attempts; on failure (or a receiver that never echoes, e.g. a
    /// non-Swift peer) the controller just stays on the reliable lane.
    private func upgradeToDatagram(peerDeviceID: String, udpPort: UInt16, token: String) async {
        guard let current = active, current.peerDeviceID == peerDeviceID,
              let sessionEndpoint = current.link.framed.remoteEndpoint,
              case .hostPort(let host, _) = sessionEndpoint else { return }

        guard let datagram = try? await backend.connectDatagram(
            toHost: host, port: udpPort, policy: .pinned([current.link.peer.tlsPubkeySHA256])
        ) else { return }

        guard let attach = try? MessageCodec.encode(
            meta: EnvelopeMeta(sessionID: "", seq: 0),
            message: .inputAttach(InputAttachBody(token: token))
        ) else {
            datagram.close()
            return
        }

        guard await Self.confirmDatagram(datagram, attach: attach, token: token),
              !Task.isCancelled,
              var upgraded = active, upgraded.peerDeviceID == peerDeviceID else {
            datagram.close()
            return
        }
        upgraded.datagram = datagram
        active = upgraded
        diagnostics.inputControllerLane("datagram")
        inputLog.info("input datagram lane confirmed for \(peerDeviceID, privacy: .public)")
    }

    /// Sends INPUT_ATTACH up to 3× and waits (≤1.5 s total) for the receiver to
    /// echo it back over the datagram. Static so the read loop captures nothing
    /// actor-isolated. Returns true on echo, false otherwise.
    private static func confirmDatagram(_ datagram: DatagramConnection, attach: Data, token: String) async -> Bool {
        let confirmed = try? await withTimeout(seconds: 1.5) {
            let sender = Task {
                for _ in 1...3 {
                    try? await datagram.send(FrameCodec.encodeControl(attach))
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
            defer { sender.cancel() }
            return await awaitAttachEcho(datagram, token: token)
        }
        return confirmed ?? false
    }

    private static func awaitAttachEcho(_ datagram: DatagramConnection, token: String) async -> Bool {
        var reader = FrameReader()
        do {
            for try await bytes in datagram.incomingDatagrams {
                for frame in try reader.append(bytes) {
                    guard case .control(let payload) = frame else { continue }
                    let (_, message) = try MessageCodec.decode(payload)
                    if case .inputAttach(let echo) = message, echo.token == token {
                        return true
                    }
                }
            }
        } catch { /* stream ended / cancelled → not confirmed */ }
        return false
    }

    // MARK: Outgoing events (called from the UI)

    public func sendMove(dx: Double, dy: Double) async {
        await coalescer?.enqueueMove(dx: dx, dy: dy)
    }

    /// Point at a position on a screen this controller is watching. `dx`/`dy`
    /// are the equivalent delta, kept so a receiver that predates absolute
    /// coordinates still follows the pointer.
    public func sendMoveAbsolute(
        nx: Double, ny: Double, dx: Double, dy: Double, screenSessionID: String?
    ) async {
        await coalescer?.enqueueAbsoluteMove(
            nx: nx, ny: ny, dx: dx, dy: dy, screenSessionID: screenSessionID
        )
    }

    public func sendScroll(dx: Double, dy: Double) async {
        await coalescer?.enqueueScroll(dx: dx, dy: dy)
    }

    public func sendClick(_ button: PointerButton, action: InputAction, clickCount: Int = 1) async {
        await coalescer?.enqueueDiscrete(.click(button, action: action, clickCount: clickCount))
    }

    public func sendText(
        _ text: String, action: InputAction? = nil, modifiers: [InputModifier] = []
    ) async {
        await coalescer?.enqueueDiscrete(.text(text, action: action, modifiers: modifiers))
    }

    public func sendSpecialKey(
        _ name: String, action: InputAction? = nil, modifiers: [InputModifier] = []
    ) async {
        await coalescer?.enqueueDiscrete(.specialKey(name, action: action, modifiers: modifiers))
    }

    public func sendMedia(_ action: MediaAction, value: Double? = nil) async {
        guard let current = active else { return }
        try? await current.link.send(.mediaControl(MediaControlBody(action: action, value: value)))
    }

    /// The coalescer's sink: moves/scrolls out the datagram lane when present
    /// (loss-tolerant), everything else on the reliable control lane.
    private func transmit(_ event: InputEventBody) async {
        guard var current = active else { return }
        diagnostics.inputEventSent()
        let useDatagram = (event.kind == .move || event.kind == .scroll) && current.datagram != nil
        if useDatagram, let datagram = current.datagram {
            let meta = EnvelopeMeta(sessionID: "", seq: current.datagramSeq)
            current.datagramSeq += 1
            active = current
            if let encoded = try? MessageCodec.encode(meta: meta, message: .inputEvent(event)) {
                do {
                    try await datagram.send(FrameCodec.encodeControl(encoded))
                    return
                } catch {
                    // Lane lost mid-session; fall back to the control lane.
                    current.datagram?.close()
                    current.datagram = nil
                    active = current
                    diagnostics.inputControllerLane("reliable")
                }
            }
        }
        try? await current.link.send(.inputEvent(event))
    }
}

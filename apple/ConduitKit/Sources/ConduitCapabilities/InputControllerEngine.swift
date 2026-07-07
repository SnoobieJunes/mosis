import Foundation
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

    public init(backend: LANBackend, emit: @escaping @Sendable (ConduitEvent) -> Void) {
        self.backend = backend
        self.emit = emit
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
        awaitingGrant = false
        guard let current = active else { return }
        await coalescer?.stop()
        coalescer = nil
        current.datagram?.close()
        active = nil
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
        guard var current = active else { return }

        // Open the datagram lane if invited and reachable.
        if let udpPort = status.udpPort, let token = status.datagramToken,
           let host = current.link.framed.remoteHost {
            if let datagram = try? await backend.connectDatagram(
                host: host, port: udpPort,
                policy: .pinned([current.link.peer.tlsPubkeySHA256])
            ) {
                let attach = try? MessageCodec.encode(
                    meta: EnvelopeMeta(sessionID: "", seq: 0),
                    message: .inputAttach(InputAttachBody(token: token))
                )
                if let attach {
                    try? await datagram.send(FrameCodec.encodeControl(attach))
                    current.datagram = datagram
                }
            }
        }
        active = current

        let coalescer = InputCoalescer { [weak self] event in
            await self?.transmit(event)
        }
        await coalescer.start()
        self.coalescer = coalescer
    }

    // MARK: Outgoing events (called from the UI)

    public func sendMove(dx: Double, dy: Double) async {
        await coalescer?.enqueueMove(dx: dx, dy: dy)
    }

    public func sendScroll(dx: Double, dy: Double) async {
        await coalescer?.enqueueScroll(dx: dx, dy: dy)
    }

    public func sendClick(_ button: PointerButton, action: InputAction, clickCount: Int = 1) async {
        await coalescer?.enqueueDiscrete(.click(button, action: action, clickCount: clickCount))
    }

    public func sendText(_ text: String, modifiers: [InputModifier] = []) async {
        await coalescer?.enqueueDiscrete(.text(text, modifiers: modifiers))
    }

    public func sendSpecialKey(_ name: String, modifiers: [InputModifier] = []) async {
        await coalescer?.enqueueDiscrete(.specialKey(name, modifiers: modifiers))
    }

    public func sendMedia(_ action: MediaAction, value: Double? = nil) async {
        guard let current = active else { return }
        try? await current.link.send(.mediaControl(MediaControlBody(action: action, value: value)))
    }

    /// The coalescer's sink: moves/scrolls out the datagram lane when present
    /// (loss-tolerant), everything else on the reliable control lane.
    private func transmit(_ event: InputEventBody) async {
        guard var current = active else { return }
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
                }
            }
        }
        try? await current.link.send(.inputEvent(event))
    }
}

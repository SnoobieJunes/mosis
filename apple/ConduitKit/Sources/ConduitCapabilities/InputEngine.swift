import Foundation
import os
import ConduitProtocol
import ConduitSession
import ConduitTransport

let inputLog = Logger(subsystem: "org.mosis", category: "input")

/// Receiver side of the remote-input capability (spec §9 Phase 2 steps 2 & 5).
///
/// Owns the per-session consent gate, the injector, the auto-expiring grant,
/// and the DTLS datagram lane that carries coalesced pointer moves. Invariant
/// (spec §9 Phase 2 step 2): input control is always visibly indicated on the
/// receiver and instantly revocable — the node surfaces `inputActiveChanged`
/// for the persistent indicator, and `revoke()` / kill switch call through here.
public actor InputReceiveEngine {
    /// A grant auto-expires after this idle interval with no events.
    static let grantIdleTimeout: TimeInterval = 300

    private let injector: any InputInjector
    private let backend: LANBackend
    private let emit: @Sendable (ConduitEvent) -> Void
    private let diagnostics: Diagnostics
    /// Asks the user to allow control from this peer; returns their decision.
    private let requestConsent: @Sendable (String) async -> Bool

    struct Grant {
        let peerDeviceID: String
        let link: PeerLink
        var datagramToken: String
        var udpPort: UInt16?
        var datagramListenTask: Task<Void, Never>?
        var expiryTask: Task<Void, Never>?
        var lastEventAt: Date
    }

    /// At most one active grant at a time (single controller drives the Mac).
    private var grant: Grant?
    private var pendingConsent: Set<String> = []

    /// Injection health. `injectFailureCount` climbs when the injector rejects
    /// events (a black-holed lane or broken injector was otherwise invisible);
    /// `lastInjectErrorAt` rate-limits the surfaced event to ≈1/s.
    private var injectFailures = 0
    private var lastInjectErrorAt: Date?
    public var injectFailureCount: Int { injectFailures }

    public init(
        injector: any InputInjector,
        backend: LANBackend,
        emit: @escaping @Sendable (ConduitEvent) -> Void,
        diagnostics: Diagnostics,
        requestConsent: @escaping @Sendable (String) async -> Bool
    ) {
        self.injector = injector
        self.backend = backend
        self.emit = emit
        self.diagnostics = diagnostics
        self.requestConsent = requestConsent
    }

    public var isActive: Bool { grant != nil }
    public var activePeerDeviceID: String? { grant?.peerDeviceID }
    public var isPermitted: Bool { injector.isPermitted }
    public var permissionInstructions: String { injector.permissionInstructions }
    public func openPermissionSettings() { injector.openPermissionSettings() }

    // MARK: Grant lifecycle

    /// Handles INPUT_REQUEST from a controller: check permission, ask the user,
    /// then either open a grant (with a datagram lane) or refuse with a reason.
    public func handleRequest(from link: PeerLink) async {
        let peerID = link.peer.deviceID

        guard injector.isPermitted else {
            try? await link.send(.inputStatus(InputStatusBody(
                active: false,
                reason: "Accessibility permission is off on \(hostName()). \(injector.permissionInstructions)"
            )))
            emit(.inputPermissionNeeded(instructions: injector.permissionInstructions))
            return
        }

        // Already controlling from this peer: the controller is re-requesting
        // (typically it navigated away and back, ending its local send but never
        // telling us — so our grant lingered). Refresh AND re-send the active
        // status so the controller re-arms; without this it waits for a status
        // that never comes and times out ("the second time didn't work").
        if let grant, grant.peerDeviceID == peerID {
            touchGrant()
            try? await link.send(.inputStatus(InputStatusBody(
                active: true, udpPort: grant.udpPort, datagramToken: grant.datagramToken,
                secureInput: injector.isSecureInputActive
            )))
            emit(.inputActiveChanged(peerDeviceID: peerID, active: true))
            return
        }
        // Someone else holds control: refuse (single controller).
        if let existing = grant, existing.peerDeviceID != peerID {
            try? await link.send(.inputStatus(InputStatusBody(
                active: false, reason: "Another device is currently controlling this Mac"
            )))
            return
        }
        guard !pendingConsent.contains(peerID) else { return }
        pendingConsent.insert(peerID)
        let allowed = await requestConsent(peerID)
        pendingConsent.remove(peerID)
        guard allowed else {
            try? await link.send(.inputStatus(InputStatusBody(active: false, reason: "declined")))
            return
        }
        await openGrant(for: link)
    }

    private func openGrant(for link: PeerLink) async {
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hexString
        var udpPort: UInt16?
        var listenTask: Task<Void, Never>?

        // Best-effort datagram lane; control lane always works as fallback.
        if let (port, inbound) = try? await backend.startDatagramListener() {
            udpPort = port
            listenTask = Task { [weak self] in
                for await datagram in inbound {
                    await self?.adoptDatagramLane(datagram, expectedToken: token)
                }
            }
        }

        var newGrant = Grant(
            peerDeviceID: link.peer.deviceID, link: link,
            datagramToken: token, udpPort: udpPort,
            datagramListenTask: listenTask, expiryTask: nil, lastEventAt: Date()
        )
        newGrant.expiryTask = makeExpiryTask(for: link.peer.deviceID)
        grant = newGrant

        try? await link.send(.inputStatus(InputStatusBody(
            active: true, udpPort: udpPort, datagramToken: token,
            secureInput: injector.isSecureInputActive
        )))
        emit(.inputActiveChanged(peerDeviceID: link.peer.deviceID, active: true))
        inputLog.info("input grant opened for \(link.peer.name, privacy: .public)")
    }

    /// Kill switch + grant-end (spec invariant: instantly revocable).
    public func revoke(reason: String = "stopped") async {
        guard let current = grant else { return }
        grant = nil
        current.datagramListenTask?.cancel()
        current.expiryTask?.cancel()
        injector.releaseAll()
        try? await current.link.send(.inputStatus(InputStatusBody(active: false, reason: reason)))
        emit(.inputActiveChanged(peerDeviceID: current.peerDeviceID, active: false))
        inputLog.info("input grant revoked: \(reason, privacy: .public)")
    }

    /// Called when the controlling peer's session drops.
    public func handleSessionClosed(peerDeviceID: String) async {
        if grant?.peerDeviceID == peerDeviceID {
            await revoke(reason: "peer disconnected")
        }
    }

    private func makeExpiryTask(for peerID: String) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if await self.grantIdleExpired() {
                    await self.revoke(reason: "idle timeout")
                    return
                }
            }
        }
    }

    private func grantIdleExpired() -> Bool {
        guard let grant else { return false }
        return Date().timeIntervalSince(grant.lastEventAt) > Self.grantIdleTimeout
    }

    private func touchGrant() {
        grant?.lastEventAt = Date()
    }

    // MARK: Event delivery

    /// INPUT_EVENT arriving on the reliable control lane.
    public func handleControlEvent(_ event: InputEventBody, from peerDeviceID: String) async {
        guard let grant, grant.peerDeviceID == peerDeviceID else { return }
        deliver(event, link: grant.link)
        touchGrant()
    }

    public func handleMedia(_ control: MediaControlBody, from peerDeviceID: String) async {
        guard let grant, grant.peerDeviceID == peerDeviceID else { return }
        do {
            try injector.injectMedia(control)
            touchGrant()
        } catch {
            inputLog.warning("media inject failed: \(error)")
        }
    }

    private func adoptDatagramLane(_ datagram: DatagramConnection, expectedToken: String) async {
        // First datagram must be an INPUT_ATTACH binding the lane to this grant.
        var reader = FrameReader()
        do {
            for try await bytes in datagram.incomingDatagrams {
                let frames = try reader.append(bytes)
                for frame in frames {
                    guard case .control(let payload) = frame else { continue }
                    let (_, message) = try MessageCodec.decode(payload)
                    switch message {
                    case .inputAttach(let attach):
                        guard attach.token == expectedToken, grant != nil else {
                            datagram.close()
                            return
                        }
                        // Echo INPUT_ATTACH back so the controller can confirm this
                        // datagram lane is actually bidirectional before it routes
                        // moves onto it (reuses the same message — no wire change).
                        if let echo = try? MessageCodec.encode(
                            meta: EnvelopeMeta(sessionID: "", seq: 0),
                            message: .inputAttach(InputAttachBody(token: expectedToken))
                        ) {
                            try? await datagram.send(FrameCodec.encodeControl(echo))
                        }
                    case .inputEvent(let event):
                        guard let grant, grant.datagramToken == expectedToken else {
                            datagram.close(); return
                        }
                        deliver(event, link: grant.link)
                        touchGrant()
                    default:
                        break
                    }
                }
            }
        } catch {
            inputLog.info("datagram lane ended: \(error)")
        }
        datagram.close()
    }

    private func deliver(_ event: InputEventBody, link: PeerLink) {
        do {
            try injector.inject(event)
            diagnostics.inputInjected()
        } catch InputInjectorError.secureInputActive {
            // Surface once; don't spam. The controller already knows from status.
            Task { try? await link.send(.inputStatus(InputStatusBody(
                active: true, reason: "secure input field — keys blocked by macOS",
                secureInput: true
            ))) }
            emit(.inputSecureFieldBlocked)
        } catch {
            // Don't just log: a persistently failing injector means the cursor is
            // dead with no signal. Count every failure; surface at most ≈1/s.
            injectFailures += 1
            diagnostics.inputInjectFailures(injectFailures)
            inputLog.warning("inject failed: \(error)")
            let now = Date()
            if lastInjectErrorAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
                lastInjectErrorAt = now
                emit(.inputInjectFailed(reason: "\(error)"))
            }
        }
    }

    private func hostName() -> String {
        #if os(macOS)
        Host.current().localizedName ?? "this Mac"
        #else
        "this device"
        #endif
    }
}

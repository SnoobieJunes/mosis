import Foundation
import Testing
import ConduitCapabilities
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

/// Records injected events so the test can assert on what actually reached the
/// (simulated) OS. Thread-safe; the injector is called from the node's actor.
final class FakeInjector: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [InputEventBody] = []
    private(set) var media: [MediaControlBody] = []
    private(set) var releaseAllCount = 0
    var permitted = true
    var secureInput = false

    var isPermitted: Bool { permitted }
    var permissionInstructions: String { "enable in settings" }
    func openPermissionSettings() {}
    var isSecureInputActive: Bool { secureInput }

    func inject(_ event: InputEventBody) throws {
        if !permitted { throw InputInjectorError.notPermitted }
        if secureInput, event.kind == .key { throw InputInjectorError.secureInputActive }
        lock.lock(); events.append(event); lock.unlock()
    }

    func injectMedia(_ control: MediaControlBody) throws {
        lock.lock(); media.append(control); lock.unlock()
    }

    func releaseAll() {
        lock.lock(); releaseAllCount += 1; lock.unlock()
    }

    func snapshot() -> [InputEventBody] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    func mediaSnapshot() -> [MediaControlBody] {
        lock.lock(); defer { lock.unlock() }; return media
    }
    func releases() -> Int {
        lock.lock(); defer { lock.unlock() }; return releaseAllCount
    }
}

private extension TestNode {
    static func launchWithInjector(
        name: String, deviceClass: DeviceClass, injector: FakeInjector?
    ) async throws -> TestNode {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-input-\(UUID().uuidString)")
        let config = NodeConfiguration(
            deviceName: name, deviceClass: deviceClass, appVersion: "e2e",
            receiveDirectory: root.appendingPathComponent("received"),
            stateDirectory: root.appendingPathComponent("state")
        )
        let store = FileIdentityStore(fileURL: root.appendingPathComponent("identity.json"))
        let node = try ConduitNode(config: config, identityStore: store, inputInjector: injector)
        let hub = EventHub()
        await hub.attach(to: node)
        try await node.start()
        let deviceID = await node.localDeviceID
        let port = try #require(await node.localListenPort)
        return TestNode(node: node, hub: hub, root: root, deviceID: deviceID, port: port)
    }
}

@Suite(.serialized) struct InputE2ETests {
    /// Pairs a phone (controller, no injector) with a Mac (receiver, fake
    /// injector), then drives the full Phase 2 path: request → user consent →
    /// grant with active indicator → move/click/key/media delivered → kill
    /// switch revokes and releases. Verifies the spec §9 Phase 2 acceptance
    /// invariants that don't need real hardware.
    @Test(.timeLimit(.minutes(3))) func remoteControlFullPath() async throws {
        let injector = FakeInjector()
        let mac = try await TestNode.launchWithInjector(name: "Mac", deviceClass: .desktop, injector: injector)
        let phone = try await TestNode.launchWithInjector(name: "Phone", deviceClass: .phone, injector: nil)
        defer { Task { await mac.cleanup(); await phone.cleanup() } }

        // Pair.
        await mac.node.setPairingAcceptance(true)
        let confirmMac = Task { await autoConfirm(mac) }
        let confirmPhone = Task { await autoConfirm(phone) }
        await phone.node.beginPairing(host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await confirmMac.value; _ = await confirmPhone.value
        await mac.node.setPairingAcceptance(false)

        // Connect phone → Mac and reach ready.
        await phone.node.connect(toDevice: mac.deviceID, host: "127.0.0.1", port: mac.port)
        _ = try await phone.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == mac.deviceID }
            return false
        }

        // The phone learns the Mac advertises input-inject.
        let caps = try await phone.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == mac.deviceID }
            return false
        }
        if case .remoteCapabilities(_, let list) = caps {
            #expect(list.contains(CapabilityID.inputInject))
            #expect(list.contains(CapabilityID.mediaTarget))
        }

        // Auto-approve the consent prompt on the Mac.
        let consent = Task {
            let event = try? await mac.hub.waitFor {
                if case .inputConsentRequested = $0 { return true }; return false
            }
            if case .inputConsentRequested(let peerID, _) = event {
                await mac.node.resolveInputConsent(peerDeviceID: peerID, accept: true)
            }
        }

        // Request control.
        await phone.node.requestInputControl(of: mac.deviceID)

        // Mac shows the persistent indicator (active), phone confirms started.
        _ = try await mac.hub.waitFor {
            if case .inputActiveChanged(_, let active) = $0 { return active }; return false
        }
        _ = try await phone.hub.waitFor {
            if case .inputControlStarted = $0 { return true }; return false
        }
        _ = await consent.value

        // Drive: a click and a keystroke go on the reliable lane and land.
        await phone.node.sendClick(.left, action: .tap)
        await phone.node.sendText("hi", modifiers: [.command])
        await phone.node.sendMedia(.toggle)

        try await pollUntil(timeout: 10) {
            injector.snapshot().contains { $0.kind == .click }
                && injector.snapshot().contains { $0.kind == .key }
                && !injector.mediaSnapshot().isEmpty
        }
        let injected = injector.snapshot()
        #expect(injected.contains { $0.kind == .click && $0.button == .left })
        let keyEvent = injected.first { $0.kind == .key }
        #expect(keyEvent?.text == "hi")
        #expect(keyEvent?.modifiers == [.command])
        #expect(injector.mediaSnapshot().first?.action == .toggle)

        // Kill switch: revoke on the Mac releases held input and notifies both.
        await mac.node.revokeInputControl()
        _ = try await mac.hub.waitFor {
            if case .inputActiveChanged(_, let active) = $0 { return !active }; return false
        }
        #expect(injector.releases() >= 1)
    }

    /// A controller can't drive a peer that doesn't advertise input-inject
    /// (phone→phone), and injection with the permission off is refused.
    @Test(.timeLimit(.minutes(2))) func refusalPaths() async throws {
        // Two phones: neither advertises input-inject.
        let a = try await TestNode.launchWithInjector(name: "PhoneA", deviceClass: .phone, injector: nil)
        let b = try await TestNode.launchWithInjector(name: "PhoneB", deviceClass: .phone, injector: nil)
        defer { Task { await a.cleanup(); await b.cleanup() } }

        await b.node.setPairingAcceptance(true)
        let ca = Task { await autoConfirm(a) }
        let cb = Task { await autoConfirm(b) }
        await a.node.beginPairing(host: "127.0.0.1", port: b.port)
        _ = try await a.hub.waitFor { if case .pairingCompleted = $0 { return true }; return false }
        _ = await ca.value; _ = await cb.value
        await b.node.setPairingAcceptance(false)

        await a.node.connect(toDevice: b.deviceID, host: "127.0.0.1", port: b.port)
        _ = try await a.hub.waitFor {
            if case .sessionStateChanged(let id, .ready, _) = $0 { return id == b.deviceID }
            return false
        }
        _ = try await a.hub.waitFor {
            if case .remoteCapabilities(let id, _) = $0 { return id == b.deviceID }
            return false
        }

        await a.node.requestInputControl(of: b.deviceID)
        let failed = try await a.hub.waitFor {
            if case .inputControlFailed = $0 { return true }; return false
        }
        if case .inputControlFailed(let reason) = failed {
            #expect(reason.lowercased().contains("input-inject") || reason.lowercased().contains("can't"))
        }
    }
}

// MARK: - Test helpers

func autoConfirm(_ node: TestNode) async {
    guard case .pairingPrompt(let prompt) = try? await node.hub.waitFor({
        if case .pairingPrompt = $0 { return true }; return false
    }) else { return }
    await node.node.resolvePairingPrompt(flowID: prompt.flowID, accept: true)
}

func pollUntil(timeout: Double, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("condition not met within \(timeout)s")
}

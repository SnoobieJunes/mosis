import Foundation
import Testing
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport
import ConduitTestSupport

private func makeBundle(name: String, class deviceClass: DeviceClass) throws -> IdentityBundle {
    try IdentityBundle.createNew(name: name, deviceClass: deviceClass)
}

@Suite struct PairingFlowTests {
    @Test func fullCeremonyPinsBothSides() async throws {
        let bundleA = try makeBundle(name: "Mac", class: .desktop)
        let bundleB = try makeBundle(name: "iPhone", class: .phone)
        let bodyA = try PairingFlow.makeLocalBody(bundle: bundleA)
        let bodyB = try PairingFlow.makeLocalBody(bundle: bundleB)

        let (connA, connB) = MemoryConnection.pair(
            presentedByA: bundleA.tlsMaterial.publicKeyHash,
            presentedByB: bundleB.tlsMaterial.publicKeyHash
        )
        let framedA = FramedConnection(connA)
        let framedB = FramedConnection(connB)

        let promptA = Locked<PairingPromptInfo?>(nil)
        let promptB = Locked<PairingPromptInfo?>(nil)

        // B is the responder: read A's PAIR_REQUEST off the wire first (the node router does this in production).
        async let outcomeA = PairingFlow.initiate(framed: framedA, localBody: bodyA) { prompt in
            promptA.set(prompt)
            return true
        }
        let firstFrame = try await framedB.nextFrame()
        guard case .control(let payload) = try #require(firstFrame) else {
            Issue.record("expected control frame")
            return
        }
        let (meta, message) = try MessageCodec.decode(payload)
        guard case .pairRequest(let request) = message else {
            Issue.record("expected PAIR_REQUEST, got \(message.typeString)")
            return
        }
        let outcomeB = await PairingFlow.respond(
            framed: framedB, request: request, requestMeta: meta, localBody: bodyB
        ) { prompt in
            promptB.set(prompt)
            return true
        }
        let resolvedA = await outcomeA

        guard case .paired(let pinnedByA) = resolvedA else {
            Issue.record("initiator outcome was \(resolvedA)")
            return
        }
        guard case .paired(let pinnedByB) = outcomeB else {
            Issue.record("responder outcome was \(outcomeB)")
            return
        }
        // Each side pinned the *other* device with the right key material.
        #expect(pinnedByA.deviceID == (try bundleB.deviceIdentity().deviceID))
        #expect(pinnedByB.deviceID == (try bundleA.deviceIdentity().deviceID))
        #expect(pinnedByA.tlsPubkeySHA256 == bundleB.tlsMaterial.publicKeyHash)
        #expect(pinnedByB.tlsPubkeySHA256 == bundleA.tlsMaterial.publicKeyHash)
        // Both screens showed the same code and words.
        #expect(promptA.get()?.code == promptB.get()?.code)
        #expect(promptA.get()?.wordA == promptB.get()?.wordA)
        #expect(promptA.get()?.wordB == promptB.get()?.wordB)
    }

    @Test func declineOnOneSideFailsBoth() async throws {
        let bundleA = try makeBundle(name: "Mac", class: .desktop)
        let bundleB = try makeBundle(name: "iPhone", class: .phone)
        let bodyA = try PairingFlow.makeLocalBody(bundle: bundleA)
        let bodyB = try PairingFlow.makeLocalBody(bundle: bundleB)
        let (connA, connB) = MemoryConnection.pair(
            presentedByA: bundleA.tlsMaterial.publicKeyHash,
            presentedByB: bundleB.tlsMaterial.publicKeyHash
        )
        let framedA = FramedConnection(connA)
        let framedB = FramedConnection(connB)

        async let outcomeA = PairingFlow.initiate(framed: framedA, localBody: bodyA) { _ in true }
        let firstFrame = try await framedB.nextFrame()
        guard case .control(let payload) = try #require(firstFrame),
              case let (meta, .pairRequest(request)) = try MessageCodec.decode(payload) else {
            Issue.record("expected PAIR_REQUEST")
            return
        }
        // B's user declines.
        let outcomeB = await PairingFlow.respond(
            framed: framedB, request: request, requestMeta: meta, localBody: bodyB
        ) { _ in false }
        let resolvedA = await outcomeA

        guard case .rejectedLocally = outcomeB else {
            Issue.record("responder outcome was \(outcomeB)")
            return
        }
        if case .paired = resolvedA {
            Issue.record("initiator paired despite peer decline")
        }
    }

    @Test func tlsKeySubstitutionIsDetected() async throws {
        let bundleA = try makeBundle(name: "Mac", class: .desktop)
        let bundleB = try makeBundle(name: "iPhone", class: .phone)
        let bodyA = try PairingFlow.makeLocalBody(bundle: bundleA)
        // The connection presents a DIFFERENT TLS key than B's signed body claims
        // (a middle-man terminating TLS with its own certificate).
        let mitmed = try makeBundle(name: "Evil", class: .desktop)
        let (connA, connB) = MemoryConnection.pair(
            presentedByA: bundleA.tlsMaterial.publicKeyHash,
            presentedByB: mitmed.tlsMaterial.publicKeyHash
        )
        let framedA = FramedConnection(connA)
        let framedB = FramedConnection(connB)
        let bodyB = try PairingFlow.makeLocalBody(bundle: bundleB)

        async let outcomeA = PairingFlow.initiate(framed: framedA, localBody: bodyA) { _ in
            Issue.record("must fail before any user prompt")
            return true
        }
        let firstFrame = try await framedB.nextFrame()
        guard case .control(let payload) = try #require(firstFrame),
              case let (meta, .pairRequest(request)) = try MessageCodec.decode(payload) else {
            Issue.record("expected PAIR_REQUEST")
            return
        }
        _ = await PairingFlow.respond(
            framed: framedB, request: request, requestMeta: meta, localBody: bodyB
        ) { _ in true }
        let resolvedA = await outcomeA
        guard case .failed(let reason) = resolvedA else {
            Issue.record("expected failure, got \(resolvedA)")
            return
        }
        #expect(reason.contains("tlsKeySubstitution"))
    }

    @Test func validateRejectsForgedIdentity() throws {
        let bundle = try makeBundle(name: "Honest", class: .phone)
        var body = try PairingFlow.makeLocalBody(bundle: bundle)
        let honestHash = bundle.tlsMaterial.publicKeyHash
        #expect(PairingFlow.validate(remote: body, connectionTLSKeyHash: honestHash) == nil)

        // Claiming someone else's identity string.
        body.identity = String(repeating: "0", size: 64)
        #expect(PairingFlow.validate(remote: body, connectionTLSKeyHash: honestHash) == .identityMismatch)
    }
}

private extension String {
    init(repeating character: String, size: Int) {
        self = String(repeating: character, count: size)
    }
}

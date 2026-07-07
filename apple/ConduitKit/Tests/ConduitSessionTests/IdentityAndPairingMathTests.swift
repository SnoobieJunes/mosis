import Foundation
import CryptoKit
import Testing
@testable import ConduitSession
import ConduitProtocol
import ConduitTransport

@Suite struct IdentityTests {
    @Test func deviceIDIsSHA256OfPublicKey() {
        let identity = DeviceIdentity.generate()
        let expected = Data(SHA256.hash(data: identity.publicKeyRaw)).hexString
        #expect(identity.deviceID == expected)
        #expect(identity.deviceID.count == 64)
    }

    @Test func tlsBindingRoundTrip() throws {
        let identity = DeviceIdentity.generate()
        let tlsHash = Data(repeating: 0x42, count: 32)
        let signature = try identity.signTLSBinding(tlsPublicKeyHash: tlsHash)
        #expect(DeviceIdentity.verifyTLSBinding(
            signature: signature, tlsPublicKeyHash: tlsHash, publicKeyRaw: identity.publicKeyRaw
        ))
        // Tampered hash must fail.
        #expect(!DeviceIdentity.verifyTLSBinding(
            signature: signature, tlsPublicKeyHash: Data(repeating: 0x43, count: 32),
            publicKeyRaw: identity.publicKeyRaw
        ))
        // Different signer must fail.
        #expect(!DeviceIdentity.verifyTLSBinding(
            signature: signature, tlsPublicKeyHash: tlsHash,
            publicKeyRaw: DeviceIdentity.generate().publicKeyRaw
        ))
    }

    @Test func fileStorePersistsBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileIdentityStore(fileURL: dir.appendingPathComponent("identity.json"))
        #expect(try store.load() == nil)
        let bundle = try IdentityBootstrap.loadOrCreate(store: store, name: "Test", deviceClass: .laptop)
        let reloaded = try #require(try store.load())
        #expect(reloaded.ed25519PrivateKey == bundle.ed25519PrivateKey)
        #expect(reloaded.tlsMaterial == bundle.tlsMaterial)
        // Second bootstrap returns the same identity, not a fresh one.
        let again = try IdentityBootstrap.loadOrCreate(store: store, name: "Other", deviceClass: .phone)
        #expect(try again.deviceIdentity().deviceID == bundle.deviceIdentity().deviceID)
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite struct PairingMathTests {
    let pubA = Data((0..<32).map { UInt8($0) })
    let pubB = Data((0..<32).map { UInt8(255 - $0) })

    @Test func wordlistIsExactly256UniqueWords() {
        #expect(PairingWordlist.words.count == 256)
        #expect(Set(PairingWordlist.words).count == 256)
        #expect(PairingWordlist.words.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }

    @Test func codeIsSymmetricAndStable() {
        let code1 = PairingMath.verificationCode(pubA: pubA, pubB: pubB)
        let code2 = PairingMath.verificationCode(pubA: pubB, pubB: pubA)
        #expect(code1 == code2)
        #expect(code1.count == 6)
        #expect(code1.allSatisfy { $0.isNumber })
        // Stable across runs (golden value guarded by proto/vectors too).
        #expect(code1 == PairingMath.verificationCode(pubA: pubA, pubB: pubB))
    }

    @Test func wordsAreSymmetricAndFromList() {
        let words1 = PairingMath.verificationWords(pubA: pubA, pubB: pubB)
        let words2 = PairingMath.verificationWords(pubA: pubB, pubB: pubA)
        #expect(words1 == words2)
        #expect(PairingWordlist.words.contains(words1.0))
        #expect(PairingWordlist.words.contains(words1.1))
    }

    @Test func substitutedKeyChangesCode() {
        // The MITM check: swap one key and the code the two screens show differs.
        let honest = PairingMath.verificationCode(pubA: pubA, pubB: pubB)
        let mitm = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let substituted = PairingMath.verificationCode(pubA: pubA, pubB: mitm)
        #expect(honest != substituted) // astronomically unlikely to collide
    }
}

@Suite struct PeerStoreTests {
    @Test func upsertPersistsAndReloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("peers.json")
        let store = PeerStore(fileURL: url)
        let peer = PinnedPeer(
            deviceID: "abc123", name: "Test iPhone", deviceClassRaw: "phone",
            ed25519PublicKey: Data(repeating: 1, count: 32),
            tlsPubkeySHA256: Data(repeating: 2, count: 32),
            pairedAt: Date()
        )
        try await store.upsert(peer)
        #expect(store.currentPinnedTLSKeyHashes() == [Data(repeating: 2, count: 32)])

        let reloaded = PeerStore(fileURL: url)
        let peers = await reloaded.allPeers()
        #expect(peers.count == 1)
        #expect(peers.first?.deviceID == "abc123")
        #expect(await reloaded.peer(tlsKeyHash: Data(repeating: 2, count: 32))?.deviceID == "abc123")

        try await reloaded.remove(deviceID: "abc123")
        #expect(await reloaded.allPeers().isEmpty)
        #expect(reloaded.currentPinnedTLSKeyHashes().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}

import Foundation
import CryptoKit
import Testing
@testable import ConduitSession
import ConduitProtocol

@Suite struct PairingVectorConformance {
    private func loadVectors() throws -> (file: [String: Any], vectors: [[String: Any]]) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("proto/vectors/pairing.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (file, try #require(file["vectors"] as? [[String: Any]]))
    }

    @Test func wordlistIsFrozen() throws {
        let (file, _) = try loadVectors()
        let expected = try #require(file["wordlist_sha256"] as? String)
        let actual = Data(SHA256.hash(data: Data(PairingWordlist.words.joined(separator: "\n").utf8))).hexString
        #expect(actual == expected, "the pairing wordlist is frozen; changing it breaks every paired device")
    }

    private func hexField(_ vector: [String: Any], _ key: String) throws -> Data {
        let hexString = try #require(vector[key] as? String)
        let data = Data(hexString: hexString)
        return try #require(data, "bad hex in field \(key)")
    }

    @Test func pairingCodeAndWordsMatchVectors() throws {
        let (_, vectors) = try loadVectors()
        let vector = try #require(vectors.first { $0["name"] as? String == "pairing_basic" })
        let pubA = try hexField(vector, "pub_a_hex")
        let pubB = try hexField(vector, "pub_b_hex")
        #expect(PairingMath.verificationCode(pubA: pubA, pubB: pubB) == (vector["code"] as? String))
        let words = PairingMath.verificationWords(pubA: pubA, pubB: pubB)
        #expect(words.0 == (vector["word_a"] as? String))
        #expect(words.1 == (vector["word_b"] as? String))
    }

    @Test func identityDerivationMatchesVector() throws {
        let (_, vectors) = try loadVectors()
        let vector = try #require(vectors.first { $0["name"] as? String == "identity_derivation" })
        let pub = try hexField(vector, "ed25519_pub_hex")
        #expect(DeviceIdentity.deviceID(publicKeyRaw: pub) == (vector["device_id"] as? String))
    }

    @Test func tlsBindingSignatureStillVerifies() throws {
        let (_, vectors) = try loadVectors()
        let vector = try #require(vectors.first { $0["name"] as? String == "tls_binding" })
        let pub = try hexField(vector, "ed25519_pub_hex")
        let hash = try hexField(vector, "tls_key_hash_hex")
        let signature = try hexField(vector, "signature_hex")
        #expect(DeviceIdentity.verifyTLSBinding(signature: signature, tlsPublicKeyHash: hash, publicKeyRaw: pub))
    }
}

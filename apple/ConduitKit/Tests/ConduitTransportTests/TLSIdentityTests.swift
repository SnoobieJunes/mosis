import Foundation
import Security
import CryptoKit
import Testing
@testable import ConduitTransport

@Suite struct TLSMaterialTests {
    @Test func generatedCertificateParsesAndHashesMatch() throws {
        let material = try TransportTLSMaterial.generate(commonName: "conduit-test")
        #expect(material.publicKeyHash.count == 32)

        let cert = try #require(SecCertificateCreateWithData(nil, material.certificateDER as CFData))
        // The hash TLSVerifier computes from the certificate must equal the
        // hash recorded in the material (what pairing pins).
        let fromCert = try #require(TLSVerifier.publicKeyHash(of: cert))
        #expect(fromCert == material.publicKeyHash)
    }

    // 3 minutes, not 1: this is the slowest test in the suite (64 real keygen +
    // PKCS#12 import round-trips) and it is load-sensitive — ~35 s run alone,
    // ~66 s under full-suite parallel load on the same machine, i.e. it was
    // already over a 1-minute limit locally and would flake red on a slower
    // hosted CI runner. Now that CI runs the FULL suite rather than the
    // conformance filter, a wall-clock-tight test is a trust problem: a suite
    // that goes red at random teaches people to ignore it. The limit exists to
    // catch a genuine hang, so it should sit well clear of legitimate slowness.
    @Test(.timeLimit(.minutes(3))) func pkcs12ImportIsRobustAcrossRandomSalts() throws {
        // Salts are random per build; a KDF or DER edge case would surface as
        // a sporadic import failure. Hammer it.
        for round in 0..<64 {
            let material = try TransportTLSMaterial.generate(commonName: "conduit-salt-\(round)")
            _ = try TLSIdentityMaterializer.secIdentity(for: material)
        }
    }

    @Test(.timeLimit(.minutes(1))) func pkcs12ImportMintsWorkingIdentity() throws {
        let material = try TransportTLSMaterial.generate(commonName: "conduit-p12-test")
        let identity = try TLSIdentityMaterializer.secIdentity(for: material)

        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &cert) == errSecSuccess)
        #expect((SecCertificateCopyData(try #require(cert)) as Data) == material.certificateDER)

        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess)
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            try #require(key), .ecdsaSignatureMessageX962SHA256,
            Data("conduit".utf8) as CFData, &error
        )
        #expect(signature != nil, "identity's private key must be able to sign (TLS handshake requirement)")
    }

    @Test func verifierEvaluatesPinningPolicies() throws {
        let material = try TransportTLSMaterial.generate(commonName: "conduit-test")
        let cert = try #require(SecCertificateCreateWithData(nil, material.certificateDER as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        let secTrust = try #require(trust)

        let pinnedMatch = TLSVerifier.evaluate(trust: secTrust, policy: .pinned([material.publicKeyHash]))
        #expect(pinnedMatch.isAllowed)
        #expect(pinnedMatch.presentedKeyHash == material.publicKeyHash)

        let pinnedMismatch = TLSVerifier.evaluate(trust: secTrust, policy: .pinned([Data(repeating: 0, count: 32)]))
        #expect(!pinnedMismatch.isAllowed)

        let pairing = TLSVerifier.evaluate(trust: secTrust, policy: .acceptAnyForPairing)
        #expect(pairing.isAllowed)

        let reject = TLSVerifier.evaluate(trust: secTrust, policy: .rejectAll)
        #expect(!reject.isAllowed)
    }
}

/// Real TLS 1.3 handshakes over loopback TCP — no Bonjour, no local-network
/// permission involved. This is the spec §9 Phase 1 step 5 acceptance test:
/// "unit test that an unpinned peer is rejected".
@Suite(.serialized) struct LoopbackTLSTests {
    private func makeBackends() throws -> (a: LANBackend, aHash: Data, b: LANBackend, bHash: Data) {
        let materialA = try TransportTLSMaterial.generate(commonName: "conduit-a")
        let materialB = try TransportTLSMaterial.generate(commonName: "conduit-b")
        let pinnedByB = Locked<Set<Data>>([materialA.publicKeyHash])
        let a = try LANBackend(material: materialA, listenerPolicyProvider: { .rejectAll })
        let b = try LANBackend(material: materialB, listenerPolicyProvider: { .pinned(pinnedByB.get()) })
        return (a, materialA.publicKeyHash, b, materialB.publicKeyHash)
    }

    @Test func pinnedHandshakeSucceedsAndExtractsPeerKey() async throws {
        let (a, aHash, b, bHash) = try makeBackends()
        defer {
            a.shutdown()
            b.shutdown()
        }
        let (port, inbound) = try await b.start()

        async let inboundFirst = inbound.first { _ in true }
        let outbound = try await a.connect(host: "127.0.0.1", port: port, policy: .pinned([bHash]))
        let accepted = try #require(await inboundFirst)

        // Both directions authenticated: each side sees the other's pinned key.
        #expect(outbound.peerTLSKeyHash == bHash)
        #expect(accepted.peerTLSKeyHash == aHash)

        // Bytes flow both ways.
        try await outbound.send(Data("ping-from-a".utf8))
        var received = Data()
        for try await segment in accepted.incoming {
            received.append(segment)
            if received.count >= 11 { break }
        }
        #expect(String(decoding: received, as: UTF8.self) == "ping-from-a")

        try await accepted.send(Data("pong-from-b".utf8))
        var back = Data()
        for try await segment in outbound.incoming {
            back.append(segment)
            if back.count >= 11 { break }
        }
        #expect(String(decoding: back, as: UTF8.self) == "pong-from-b")

        outbound.close()
        accepted.close()
    }

    @Test func unpinnedPeerIsRejected() async throws {
        let (a, _, b, bHash) = try makeBackends()
        defer {
            a.shutdown()
            b.shutdown()
        }
        let (port, inbound) = try await b.start()
        let inboundSurfaced = Locked(false)
        let watcher = Task {
            for await _ in inbound {
                inboundSurfaced.set(true)
            }
        }

        // A malicious/unknown device: fresh key material B has never pinned.
        let evilMaterial = try TransportTLSMaterial.generate(commonName: "conduit-evil")
        let evil = try LANBackend(
            material: evilMaterial,
            listenerPolicyProvider: { .rejectAll }
        )
        defer { evil.shutdown() }

        // TLS 1.3 lets the client believe it connected before the server has
        // judged its certificate, so `connect` may return; the guarantees that
        // matter are (1) the listener never surfaces the connection and
        // (2) no data ever flows.
        var sawData = false
        do {
            let connection = try await evil.connect(host: "127.0.0.1", port: port, policy: .acceptAnyForPairing)
            defer { connection.close() }
            try await connection.send(Data("intrusion".utf8))
            for try await _ in connection.incoming {
                sawData = true
                break
            }
        } catch {
            // Rejection surfacing as a thrown error is equally acceptable.
        }
        #expect(!sawData, "unpinned peer must never receive data")

        try await Task.sleep(for: .milliseconds(500))
        #expect(!inboundSurfaced.get(), "listener must never surface an unpinned connection")
        watcher.cancel()

        // The pinned client still gets through afterwards (listener healthy).
        let ok = try await a.connect(host: "127.0.0.1", port: port, policy: .pinned([bHash]))
        #expect(ok.peerTLSKeyHash == bHash)
        ok.close()
    }

    @Test func clientRejectsServerWithWrongKey() async throws {
        let (a, aHash, b, _) = try makeBackends()
        defer {
            a.shutdown()
            b.shutdown()
        }
        let (port, _) = try await b.start()
        // Client pins a key the server does not have → handshake must fail.
        await #expect(throws: (any Error).self) {
            _ = try await a.connect(host: "127.0.0.1", port: port, policy: .pinned([aHash]))
        }
    }
}

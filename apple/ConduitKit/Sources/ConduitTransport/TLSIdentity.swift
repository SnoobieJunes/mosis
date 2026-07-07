import Foundation
import Security
import Crypto
import X509
import SwiftASN1

/// The TLS half of a device's identity: a P-256 key wrapped in a long-lived
/// self-signed certificate.
///
/// Two keys by necessity, not choice: the long-term identity is Ed25519
/// (spec §9 Phase 1 step 4), but Apple's Security framework cannot make a
/// SecIdentity from an Ed25519 key, so TLS runs on P-256 and pairing binds the
/// TLS key to the Ed25519 identity with a signature (docs/adr/0002).
public struct TransportTLSMaterial: Codable, Sendable, Equatable {
    public var certificateDER: Data
    public var privateKeyX963: Data
    /// SHA-256 of the public key (X9.63) — the value peers pin.
    public var publicKeyHash: Data

    public static func generate(commonName: String) throws -> TransportTLSMaterial {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(commonName)
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return TransportTLSMaterial(
            certificateDER: Data(serializer.serializedBytes),
            privateKeyX963: key.x963Representation,
            publicKeyHash: Data(SHA256.hash(data: key.publicKey.x963Representation))
        )
    }
}

/// Materializes a SecIdentity for Network.framework from stored TLS material.
///
/// Route: serialize a transient PKCS#12 in memory and hand it to
/// SecPKCS12Import, which mints an identity for ANY process — signed app,
/// sandboxed app, or bare `swift test` runner. Keychain-write routes to a
/// SecIdentity are closed to unsigned processes on macOS 26
/// (errSecMissingEntitlement); see PKCS12Writer for the probe notes.
public enum TLSIdentityMaterializer {
    /// Protects an in-memory container that lives for one import call;
    /// real key custody belongs to the identity store.
    private static let transientPassphrase = "conduit-transient-pfx"

    /// SecPKCS12Import intermittently fails MAC verification when invoked
    /// concurrently from multiple threads (observed on macOS 26). Imports are
    /// rare (node startup), so serialize them.
    private static let importLock = NSLock()

    public static func secIdentity(for material: TransportTLSMaterial) throws -> SecIdentity {
        importLock.lock()
        defer { importLock.unlock() }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(x963Representation: material.privateKeyX963)
        } catch {
            throw TransportError.tlsIdentityUnavailable("stored TLS key unreadable: \(error)")
        }
        let pfx = try PKCS12Writer.build(
            certificateDER: material.certificateDER,
            privateKeyPKCS8: key.derRepresentation,
            passphrase: transientPassphrase
        )
        let options: [CFString: Any] = [kSecImportExportPassphrase: transientPassphrase]
        var rawItems: CFArray?
        let status = SecPKCS12Import(pfx as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[CFString: Any]],
              let first = items.first,
              let identityRef = first[kSecImportItemIdentity],
              CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID()
        else {
            throw TransportError.tlsIdentityUnavailable("SecPKCS12Import status \(status)")
        }
        return (identityRef as! SecIdentity)
    }
}

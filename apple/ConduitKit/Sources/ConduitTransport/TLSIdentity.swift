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
/// SecIdentity requires the key and certificate to live in the keychain; adds
/// are idempotent (duplicates tolerated).
public enum TLSIdentityMaterializer {
    public static func secIdentity(for material: TransportTLSMaterial, label: String) throws -> SecIdentity {
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(material.privateKeyX963 as CFData, keyAttributes as CFDictionary, &error) else {
            throw TransportError.tlsIdentityUnavailable("SecKeyCreateWithData: \(String(describing: error?.takeRetainedValue()))")
        }
        guard let secCert = SecCertificateCreateWithData(nil, material.certificateDER as CFData) else {
            throw TransportError.tlsIdentityUnavailable("SecCertificateCreateWithData failed")
        }

        let tag = Data(label.utf8)
        let addKey: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrLabel: label,
            kSecAttrApplicationTag: tag,
        ]
        let addKeyStatus = SecItemAdd(addKey as CFDictionary, nil)
        guard addKeyStatus == errSecSuccess || addKeyStatus == errSecDuplicateItem else {
            throw TransportError.tlsIdentityUnavailable("SecItemAdd(key) status \(addKeyStatus)")
        }

        let addCert: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: label,
        ]
        let addCertStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard addCertStatus == errSecSuccess || addCertStatus == errSecDuplicateItem else {
            throw TransportError.tlsIdentityUnavailable("SecItemAdd(cert) status \(addCertStatus)")
        }

        #if os(macOS)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, secCert, &identity)
        guard status == errSecSuccess, let identity else {
            throw TransportError.tlsIdentityUnavailable("SecIdentityCreateWithCertificate status \(status)")
        }
        return identity
        #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw TransportError.tlsIdentityUnavailable("identity query status \(status)")
        }
        for candidate in identities {
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(candidate, &certRef) == errSecSuccess,
                  let certRef else { continue }
            let der = SecCertificateCopyData(certRef) as Data
            if der == material.certificateDER {
                return candidate
            }
        }
        throw TransportError.tlsIdentityUnavailable("no identity matched the stored certificate")
        #endif
    }
}

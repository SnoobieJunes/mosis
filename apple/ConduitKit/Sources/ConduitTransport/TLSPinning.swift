import Foundation
import Security
import Crypto

/// How to judge the peer's TLS certificate.
///
/// Conduit never uses X.509 chain evaluation: certificates are self-signed
/// carriers for a pinned public key (spec §7). Trust comes from pairing.
public enum TLSVerifyPolicy: Sendable {
    /// Pairing mode only: accept any presented key, then verify out-of-band via
    /// the code + word pair. The presented key hash is cross-checked against the
    /// signed PAIR_REQUEST/PAIR_RESPONSE before anything is pinned.
    case acceptAnyForPairing
    /// Normal operation: the presented key must hash into the pinned set.
    case pinned(Set<Data>)
    /// Refuse everything (listener outside pairing mode with no pinned peers).
    case rejectAll
}

public struct TLSVerifyVerdict: Sendable {
    public let isAllowed: Bool
    public let presentedKeyHash: Data?
}

public enum TLSVerifier {
    /// SHA-256 over the certificate's public key in X9.63 uncompressed form.
    /// This is the value pairing pins and PAIR_* messages carry as tls_pubkey_sha256.
    public static func publicKeyHash(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return Data(SHA256.hash(data: external))
    }

    /// SHA-256 key hash of the peer's leaf certificate from established-handshake
    /// metadata. Shared by the classic-API LAN connection and the new-API Aware
    /// connection so the pinning identity is extracted exactly one way.
    public static func peerLeafKeyHash(securityMetadata: sec_protocol_metadata_t) -> Data? {
        var leaf: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(securityMetadata) { cert in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(cert).takeRetainedValue()
            }
        }
        guard let leaf else { return nil }
        return publicKeyHash(of: leaf)
    }

    public static func evaluate(trust: SecTrust, policy: TLSVerifyPolicy) -> TLSVerifyVerdict {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let keyHash = publicKeyHash(of: leaf)
        else {
            return TLSVerifyVerdict(isAllowed: false, presentedKeyHash: nil)
        }
        switch policy {
        case .acceptAnyForPairing:
            return TLSVerifyVerdict(isAllowed: true, presentedKeyHash: keyHash)
        case .pinned(let allowed):
            return TLSVerifyVerdict(isAllowed: allowed.contains(keyHash), presentedKeyHash: keyHash)
        case .rejectAll:
            return TLSVerifyVerdict(isAllowed: false, presentedKeyHash: keyHash)
        }
    }
}

import Foundation
import CryptoKit
import ConduitProtocol
import ConduitTransport

/// A device's long-term identity: an Ed25519 keypair (spec §5.2). The stable
/// device ID is the SHA-256 of the raw public key, lowercase hex. Never an IP.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
    }

    public var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

    public var deviceID: String { Self.deviceID(publicKeyRaw: publicKeyRaw) }

    public static func deviceID(publicKeyRaw: Data) -> String {
        Data(SHA256.hash(data: publicKeyRaw)).hexString
    }

    static let tlsBindingContext = Data("conduit-tls-binding-v1".utf8)

    /// Signature binding this identity to a TLS key (docs/adr/0002): proves the
    /// device that owns the Ed25519 identity also owns the TLS certificate key.
    public func signTLSBinding(tlsPublicKeyHash: Data) throws -> Data {
        try privateKey.signature(for: Self.tlsBindingContext + tlsPublicKeyHash)
    }

    public static func verifyTLSBinding(signature: Data, tlsPublicKeyHash: Data, publicKeyRaw: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return false
        }
        return key.isValidSignature(signature, for: tlsBindingContext + tlsPublicKeyHash)
    }
}

/// Everything a device persists about itself (spec §5.2: identity store is
/// local, per device, exportable for backup).
public struct IdentityBundle: Codable, Sendable {
    public var ed25519PrivateKey: Data
    public var tlsMaterial: TransportTLSMaterial
    public var name: String
    public var deviceClassRaw: String
    public var createdAt: Date

    public init(ed25519PrivateKey: Data, tlsMaterial: TransportTLSMaterial,
                name: String, deviceClassRaw: String, createdAt: Date) {
        self.ed25519PrivateKey = ed25519PrivateKey
        self.tlsMaterial = tlsMaterial
        self.name = name
        self.deviceClassRaw = deviceClassRaw
        self.createdAt = createdAt
    }

    public static func createNew(name: String, deviceClass: DeviceClass) throws -> IdentityBundle {
        let identity = DeviceIdentity.generate()
        let material = try TransportTLSMaterial.generate(commonName: "conduit-\(identity.deviceID.prefix(16))")
        return IdentityBundle(
            ed25519PrivateKey: identity.privateKey.rawRepresentation,
            tlsMaterial: material,
            name: name,
            deviceClassRaw: deviceClass.rawValue,
            createdAt: Date()
        )
    }

    public func deviceIdentity() throws -> DeviceIdentity {
        DeviceIdentity(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519PrivateKey))
    }

    public var deviceClass: DeviceClass {
        DeviceClass(rawValue: deviceClassRaw) ?? .unknown
    }
}

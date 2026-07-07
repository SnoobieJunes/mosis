import Foundation
import Security
import ConduitProtocol

public enum IdentityStoreError: Error {
    case keychainStatus(OSStatus)
    case corrupt(String)
}

public protocol IdentityStore: Sendable {
    func load() throws -> IdentityBundle?
    func save(_ bundle: IdentityBundle) throws
}

private func makeStoreEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func makeStoreDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

/// Production store: the whole bundle as one generic-password item
/// (Ed25519 keys have no SecKey representation, so a data blob is the
/// boring, correct keychain shape for them).
public struct KeychainIdentityStore: IdentityStore {
    public var service: String
    public var account: String

    public init(service: String = "org.conduit.identity", account: String = "primary") {
        self.service = service
        self.account = account
    }

    public func load() throws -> IdentityBundle? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw IdentityStoreError.corrupt("keychain item is not data")
            }
            return try makeStoreDecoder().decode(IdentityBundle.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityStoreError.keychainStatus(status)
        }
    }

    public func save(_ bundle: IdentityBundle) throws {
        let data = try makeStoreEncoder().encode(bundle)
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychainStatus(status)
        }
    }
}

/// Test / tooling store: plain JSON file with owner-only permissions.
public struct FileIdentityStore: IdentityStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> IdentityBundle? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try makeStoreDecoder().decode(IdentityBundle.self, from: data)
    }

    public func save(_ bundle: IdentityBundle) throws {
        let data = try makeStoreEncoder().encode(bundle)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Loads the existing identity or mints one on first launch.
public enum IdentityBootstrap {
    public static func loadOrCreate(store: any IdentityStore, name: String, deviceClass: DeviceClass) throws -> IdentityBundle {
        if let existing = try store.load() {
            return existing
        }
        let fresh = try IdentityBundle.createNew(name: name, deviceClass: deviceClass)
        try store.save(fresh)
        return fresh
    }
}

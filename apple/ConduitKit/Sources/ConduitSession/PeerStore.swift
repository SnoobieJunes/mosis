import Foundation
import ConduitProtocol
import ConduitTransport

/// A paired device: identity pinned at pairing, trusted thereafter (spec §7).
public struct PinnedPeer: Codable, Sendable, Equatable, Identifiable {
    public var deviceID: String
    public var name: String
    public var deviceClassRaw: String
    public var ed25519PublicKey: Data
    /// SHA-256 of the peer's TLS public key; the TLS verification anchor.
    public var tlsPubkeySHA256: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public var id: String { deviceID }

    public var deviceClass: DeviceClass {
        DeviceClass(rawValue: deviceClassRaw) ?? .unknown
    }

    public init(deviceID: String, name: String, deviceClassRaw: String,
                ed25519PublicKey: Data, tlsPubkeySHA256: Data,
                pairedAt: Date, lastSeenAt: Date? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.deviceClassRaw = deviceClassRaw
        self.ed25519PublicKey = ed25519PublicKey
        self.tlsPubkeySHA256 = tlsPubkeySHA256
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

/// Pinned peer records in a flat JSON file (spec: "SwiftData or flat file,
/// keep it boring" — flat file is the boring one).
public actor PeerStore {
    private let fileURL: URL
    private var peersByID: [String: PinnedPeer] = [:]
    /// Snapshot used by synchronous TLS verify callbacks.
    private let pinnedHashes: Locked<Set<Data>>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.pinnedHashes = Locked([])
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder().decode([PinnedPeer].self, from: data) {
            peersByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.deviceID, $0) })
            pinnedHashes.set(Set(decoded.map(\.tlsPubkeySHA256)))
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public func allPeers() -> [PinnedPeer] {
        peersByID.values.sorted { $0.name < $1.name }
    }

    public func peer(id: String) -> PinnedPeer? {
        peersByID[id]
    }

    public func peer(tlsKeyHash: Data) -> PinnedPeer? {
        peersByID.values.first { $0.tlsPubkeySHA256 == tlsKeyHash }
    }

    public func upsert(_ peer: PinnedPeer) throws {
        peersByID[peer.deviceID] = peer
        try persist()
    }

    public func markSeen(deviceID: String) {
        guard var peer = peersByID[deviceID] else { return }
        peer.lastSeenAt = Date()
        peersByID[deviceID] = peer
        try? persist()
    }

    public func remove(deviceID: String) throws {
        peersByID.removeValue(forKey: deviceID)
        try persist()
    }

    /// Sendable accessor for TLS verify blocks; safe to call from any thread.
    public nonisolated func currentPinnedTLSKeyHashes() -> Set<Data> {
        pinnedHashes.get()
    }

    private func persist() throws {
        pinnedHashes.set(Set(peersByID.values.map(\.tlsPubkeySHA256)))
        let data = try Self.encoder().encode(peersByID.values.sorted { $0.deviceID < $1.deviceID })
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

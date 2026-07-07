import Foundation
import ConduitProtocol
import ConduitTransport

/// Everything the ReplayKit broadcast extension needs to stream the iPhone's
/// screen to an already-paired viewer (spec §9 Phase 3 step 4).
///
/// The extension is a separate, memory-capped process that cannot see the
/// container app's live session, so the app hands it this config through the
/// shared App Group container: where to connect, which key the viewer pins,
/// the screen session/token the app already announced via SCREEN_OFFER, and
/// the iPhone's own TLS material to authenticate the direct connection.
public struct BroadcastConfig: Codable, Sendable {
    public var viewerHost: String
    public var viewerPort: UInt16
    /// SHA-256 of the viewer's TLS public key — the extension pins it.
    public var viewerTLSKeySHA256: Data
    public var screenSessionID: String
    public var wireSessionID: UInt16
    public var bulkToken: String
    public var codec: ScreenVideoCodec
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int
    /// The iPhone's own TLS identity (same one the viewer pinned at pairing).
    public var tlsMaterial: TransportTLSMaterial

    public init(viewerHost: String, viewerPort: UInt16, viewerTLSKeySHA256: Data,
                screenSessionID: String, wireSessionID: UInt16, bulkToken: String,
                codec: ScreenVideoCodec, width: Int, height: Int, fps: Int, bitrate: Int,
                tlsMaterial: TransportTLSMaterial) {
        self.viewerHost = viewerHost
        self.viewerPort = viewerPort
        self.viewerTLSKeySHA256 = viewerTLSKeySHA256
        self.screenSessionID = screenSessionID
        self.wireSessionID = wireSessionID
        self.bulkToken = bulkToken
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.tlsMaterial = tlsMaterial
    }
}

/// Reads/writes the broadcast config in the shared App Group container. The
/// container app writes it just before presenting the broadcast picker; the
/// extension reads it on start and deletes it when done.
public enum BroadcastSharedStore {
    /// Fill in the real App Group id at build time; keep app + extension in sync.
    public static let appGroupID = "group.org.auston.conduit"
    static let filename = "broadcast-config.json"

    static func containerURL(appGroupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func write(_ config: BroadcastConfig, appGroupID: String = appGroupID) throws {
        guard let dir = containerURL(appGroupID: appGroupID) else {
            throw BroadcastError.noAppGroup
        }
        let data = try JSONEncoder().encode(config)
        try data.write(to: dir.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
    }

    public static func read(appGroupID: String = appGroupID) -> BroadcastConfig? {
        guard let dir = containerURL(appGroupID: appGroupID),
              let data = try? Data(contentsOf: dir.appendingPathComponent(filename)) else {
            return nil
        }
        return try? JSONDecoder().decode(BroadcastConfig.self, from: data)
    }

    public static func clear(appGroupID: String = appGroupID) {
        guard let dir = containerURL(appGroupID: appGroupID) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
    }
}

public enum BroadcastError: Error {
    case noAppGroup
    case connectFailed(String)
    case notConfigured
}

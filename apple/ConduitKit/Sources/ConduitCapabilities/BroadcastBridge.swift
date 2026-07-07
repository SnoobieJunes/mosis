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
    /// Human name of the viewer device ("Leroy's Mac") for status surfaces —
    /// the extension has no session to ask, so the app records it here.
    public var viewerName: String
    /// Fallback viewer hosts the extension tries in order (session address,
    /// manual address) before giving up — the reverse-dial from a separate,
    /// memory-capped process can't re-resolve mDNS, so it dials pre-computed
    /// host strings. Empty ⇒ just `viewerHost`.
    public var viewerHostCandidates: [String]
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

    public init(viewerHost: String, viewerName: String = "", viewerHostCandidates: [String] = [], viewerPort: UInt16, viewerTLSKeySHA256: Data,
                screenSessionID: String, wireSessionID: UInt16, bulkToken: String,
                codec: ScreenVideoCodec, width: Int, height: Int, fps: Int, bitrate: Int,
                tlsMaterial: TransportTLSMaterial) {
        self.viewerHost = viewerHost
        self.viewerName = viewerName
        self.viewerHostCandidates = viewerHostCandidates
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

/// Live status the broadcast extension reports back to the container app —
/// the reverse direction of `BroadcastConfig`, through the same App Group.
/// This is what lets the app show "Broadcasting ✓ / failed because X" instead
/// of the phone silently showing a red recording pill forever.
public struct BroadcastStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case connecting   // extension launched, dialing the viewer
        case streaming    // attach accepted (or unconfirmed-but-open), frames flowing
        case ended        // clean stop (user stopped, or viewer stopped watching)
        case failed       // named failure — surface it
    }
    public var phase: Phase
    public var detail: String
    public var viewerName: String
    public var framesSent: UInt64
    public var updatedAt: Date

    public init(phase: Phase, detail: String, viewerName: String, framesSent: UInt64 = 0, updatedAt: Date = Date()) {
        self.phase = phase
        self.detail = detail
        self.viewerName = viewerName
        self.framesSent = framesSent
        self.updatedAt = updatedAt
    }
}

/// Reads/writes the broadcast config in the shared App Group container. The
/// container app writes it just before presenting the broadcast picker; the
/// extension reads it on start and deletes it when done.
public enum BroadcastSharedStore {
    /// The real App Group id (bundle family org.auston.mosis); keep app +
    /// extension entitlements in sync with this.
    public static let appGroupID = "group.org.auston.mosis"
    static let filename = "broadcast-config.json"
    static let statusFilename = "broadcast-status.json"

    /// Test seam: E2E tests have no App Group entitlement, so they point the
    /// store at a plain temp directory. Set once before use; nil in apps.
    public static let containerOverride = Locked<URL?>(nil)

    static func containerURL(appGroupID: String) -> URL? {
        if let override = containerOverride.get() { return override }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
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

    // MARK: Status (extension → app)

    /// Best-effort by design: a status that can't be written must never take
    /// the broadcast down with it.
    public static func writeStatus(_ status: BroadcastStatus, appGroupID: String = appGroupID) {
        guard let dir = containerURL(appGroupID: appGroupID),
              let data = try? JSONEncoder().encode(status) else { return }
        // Weaker protection class than the config: the status is written while
        // streaming, which can outlast the device being unlocked.
        try? data.write(to: dir.appendingPathComponent(statusFilename),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func readStatus(appGroupID: String = appGroupID) -> BroadcastStatus? {
        guard let dir = containerURL(appGroupID: appGroupID),
              let data = try? Data(contentsOf: dir.appendingPathComponent(statusFilename)) else {
            return nil
        }
        return try? JSONDecoder().decode(BroadcastStatus.self, from: data)
    }

    public static func clearStatus(appGroupID: String = appGroupID) {
        guard let dir = containerURL(appGroupID: appGroupID) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(statusFilename))
    }
}

public enum BroadcastError: Error {
    case noAppGroup
    case connectFailed(String)
    case notConfigured
}

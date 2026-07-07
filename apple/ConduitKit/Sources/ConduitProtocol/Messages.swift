import Foundation

/// Device class carried in HELLO and pairing messages.
public enum DeviceClass: String, Codable, Sendable, CaseIterable {
    case phone, tablet, laptop, desktop, tv, unknown
}

/// Capability identifiers are feature-flagged strings (spec §6 versioning rule):
/// old and new peers interoperate at the intersection.
public enum CapabilityID {
    public static let file = "file"
    public static let clipboard = "clipboard"
    /// Advertiser can RECEIVE InputEvent and inject it into its OS (Phase 2).
    /// Direction-specific: controllers check the remote's list, not the intersection.
    public static let inputInject = "input-inject"
    /// Advertiser's system Now Playing can be driven via MediaControl (Phase 2).
    public static let mediaTarget = "media-target"
    /// Advertiser can capture and stream its screen (Phase 3). Direction-specific.
    public static let screenSource = "screen-source"
    /// Advertiser can display a received screen stream (Phase 3).
    public static let screenView = "screen-view"
    /// Advertiser can source its OS notifications (Phase 4). Direction-specific.
    public static let notifySource = "notify-source"
    /// Advertiser can display received notifications (Phase 4).
    public static let notifyShow = "notify-show"
}

/// Payload of HELLO and HELLO_ACK (identical shape, spec §6).
public struct HelloBody: Codable, Sendable, Equatable {
    /// Stable device identity: lowercase hex SHA-256 of the raw Ed25519 public key.
    public var identity: String
    public var name: String
    public var deviceClass: DeviceClass
    /// Implementation version (app build), distinct from the envelope protocol version.
    public var appVersion: String
    /// Raw Ed25519 public key, base64.
    public var pubkey: Data
    public var capabilities: [String]
    /// Informative list of things this platform cannot do (spec §4), e.g. "clipboard-ambient".
    public var platformWalls: [String]
    /// TCP port of this device's Conduit listener, used by the peer to open the bulk lane.
    public var listenPort: UInt16?

    enum CodingKeys: String, CodingKey {
        case identity, name, pubkey, capabilities
        case deviceClass = "device_class"
        case appVersion = "app_version"
        case platformWalls = "platform_walls"
        case listenPort = "listen_port"
    }

    public init(identity: String, name: String, deviceClass: DeviceClass, appVersion: String,
                pubkey: Data, capabilities: [String], platformWalls: [String], listenPort: UInt16?) {
        self.identity = identity
        self.name = name
        self.deviceClass = deviceClass
        self.appVersion = appVersion
        self.pubkey = pubkey
        self.capabilities = capabilities
        self.platformWalls = platformWalls
        self.listenPort = listenPort
    }
}

public struct PingBody: Codable, Sendable, Equatable {
    /// Random nonce, echoed back in PONG.
    public var nonce: String
    /// Sender clock, milliseconds since Unix epoch. Used for RTT only, never trusted.
    public var t: UInt64

    public init(nonce: String, t: UInt64) {
        self.nonce = nonce
        self.t = t
    }
}

public struct ClipboardPushBody: Codable, Sendable, Equatable {
    /// MIME type, e.g. "text/plain;charset=utf-8" or "image/png".
    public var mime: String
    /// Raw content bytes (base64 on the wire).
    public var data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    public static func text(_ string: String) -> ClipboardPushBody {
        ClipboardPushBody(mime: "text/plain;charset=utf-8", data: Data(string.utf8))
    }

    public var textValue: String? {
        guard mime.hasPrefix("text/") else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct FileOfferBody: Codable, Sendable, Equatable {
    public var fileID: String
    public var name: String
    public var size: UInt64
    public var mime: String
    /// Lowercase hex SHA-256 of the complete file.
    public var sha256: String
    /// Chunk size the sender will use; resume offsets are in units of this.
    public var chunkSize: UInt32
    public var chunkCount: UInt64

    enum CodingKeys: String, CodingKey {
        case name, size, mime, sha256
        case fileID = "file_id"
        case chunkSize = "chunk_size"
        case chunkCount = "chunk_count"
    }

    public init(fileID: String, name: String, size: UInt64, mime: String,
                sha256: String, chunkSize: UInt32, chunkCount: UInt64) {
        self.fileID = fileID
        self.name = name
        self.size = size
        self.mime = mime
        self.sha256 = sha256
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
    }
}

public struct FileAcceptBody: Codable, Sendable, Equatable {
    public var fileID: String
    /// First chunk the receiver still needs (0 for a fresh transfer).
    public var resumeFromChunk: UInt64
    /// One-time token the sender presents in BULK_ATTACH to bind the bulk lane.
    public var bulkToken: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case resumeFromChunk = "resume_from_chunk"
        case bulkToken = "bulk_token"
    }

    public init(fileID: String, resumeFromChunk: UInt64, bulkToken: String) {
        self.fileID = fileID
        self.resumeFromChunk = resumeFromChunk
        self.bulkToken = bulkToken
    }
}

public struct FileRejectBody: Codable, Sendable, Equatable {
    public var fileID: String
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case reason
        case fileID = "file_id"
    }

    public init(fileID: String, reason: String) {
        self.fileID = fileID
        self.reason = reason
    }
}

public enum FileAckStatus: String, Codable, Sendable {
    case progress
    case complete
    case hashMismatch = "hash_mismatch"
    case error
}

public struct FileAckBody: Codable, Sendable, Equatable {
    public var fileID: String
    public var status: FileAckStatus
    /// Number of contiguous chunks received from the start of the file.
    public var ackedThrough: UInt64
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case status, message
        case fileID = "file_id"
        case ackedThrough = "acked_through"
    }

    public init(fileID: String, status: FileAckStatus, ackedThrough: UInt64, message: String? = nil) {
        self.fileID = fileID
        self.status = status
        self.ackedThrough = ackedThrough
        self.message = message
    }
}

/// Payload of PAIR_REQUEST and PAIR_RESPONSE (identical shape).
///
/// LAN pairing (spec §7): trust on first use, verified out-of-band by the
/// short code + word pair both screens render. `bindingSig` ties the TLS key
/// to the long-term identity so a later connection presenting this TLS key
/// is provably the paired identity.
public struct PairBody: Codable, Sendable, Equatable {
    public var identity: String
    public var name: String
    public var deviceClass: DeviceClass
    /// Raw Ed25519 public key, base64.
    public var pubkey: Data
    /// Lowercase hex SHA-256 of the peer's TLS public key (X9.63 uncompressed point).
    public var tlsPubkeySHA256: String
    /// Ed25519 signature over "conduit-tls-binding-v1" || tlsPubkeySHA256 bytes, base64.
    public var bindingSig: Data

    enum CodingKeys: String, CodingKey {
        case identity, name, pubkey
        case deviceClass = "device_class"
        case tlsPubkeySHA256 = "tls_pubkey_sha256"
        case bindingSig = "binding_sig"
    }

    public init(identity: String, name: String, deviceClass: DeviceClass,
                pubkey: Data, tlsPubkeySHA256: String, bindingSig: Data) {
        self.identity = identity
        self.name = name
        self.deviceClass = deviceClass
        self.pubkey = pubkey
        self.tlsPubkeySHA256 = tlsPubkeySHA256
        self.bindingSig = bindingSig
    }
}

/// Empty payload (PAIR_CONFIRM). Encodes as `{}`.
public struct EmptyBody: Codable, Sendable, Equatable {
    public init() {}
}

public struct PairRejectBody: Codable, Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// First control frame on a bulk-lane connection; binds it to an accepted file.
public struct BulkAttachBody: Codable, Sendable, Equatable {
    public var fileID: String
    public var bulkToken: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case bulkToken = "bulk_token"
    }

    public init(fileID: String, bulkToken: String) {
        self.fileID = fileID
        self.bulkToken = bulkToken
    }
}

/// A decoded control message: payload switched on the envelope `type`.
public enum Message: Sendable, Equatable {
    case hello(HelloBody)
    case helloAck(HelloBody)
    case ping(PingBody)
    case pong(PingBody)
    case clipboardPush(ClipboardPushBody)
    case fileOffer(FileOfferBody)
    case fileAccept(FileAcceptBody)
    case fileReject(FileRejectBody)
    case fileAck(FileAckBody)
    case pairRequest(PairBody)
    case pairResponse(PairBody)
    case pairConfirm
    case pairReject(PairRejectBody)
    case bulkAttach(BulkAttachBody)
    case inputRequest
    case inputStatus(InputStatusBody)
    case inputEvent(InputEventBody)
    case inputAttach(InputAttachBody)
    case mediaControl(MediaControlBody)
    case screenRequest(ScreenRequestBody)
    case screenOffer(ScreenOfferBody)
    case screenReject(ScreenRejectBody)
    case screenAttach(ScreenAttachBody)
    case screenAck(ScreenAckBody)
    case screenEnd(ScreenEndBody)
    case notification(NotificationBody)
    /// Unknown `type`: ignored with a logged warning (spec §6 invariant), never fatal.
    case unknown(type: String)

    public var typeString: String {
        switch self {
        case .hello: MessageType.hello.rawValue
        case .helloAck: MessageType.helloAck.rawValue
        case .ping: MessageType.ping.rawValue
        case .pong: MessageType.pong.rawValue
        case .clipboardPush: MessageType.clipboardPush.rawValue
        case .fileOffer: MessageType.fileOffer.rawValue
        case .fileAccept: MessageType.fileAccept.rawValue
        case .fileReject: MessageType.fileReject.rawValue
        case .fileAck: MessageType.fileAck.rawValue
        case .pairRequest: MessageType.pairRequest.rawValue
        case .pairResponse: MessageType.pairResponse.rawValue
        case .pairConfirm: MessageType.pairConfirm.rawValue
        case .pairReject: MessageType.pairReject.rawValue
        case .bulkAttach: MessageType.bulkAttach.rawValue
        case .inputRequest: MessageType.inputRequest.rawValue
        case .inputStatus: MessageType.inputStatus.rawValue
        case .inputEvent: MessageType.inputEvent.rawValue
        case .inputAttach: MessageType.inputAttach.rawValue
        case .mediaControl: MessageType.mediaControl.rawValue
        case .screenRequest: MessageType.screenRequest.rawValue
        case .screenOffer: MessageType.screenOffer.rawValue
        case .screenReject: MessageType.screenReject.rawValue
        case .screenAttach: MessageType.screenAttach.rawValue
        case .screenAck: MessageType.screenAck.rawValue
        case .screenEnd: MessageType.screenEnd.rawValue
        case .notification: MessageType.notification.rawValue
        case .unknown(let type): type
        }
    }
}

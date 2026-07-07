import Foundation

/// Phase 3 message bodies: screen sharing (spec §9 Phase 3).
///
/// Direction (spec §4): a device advertising `screen-source` can capture and
/// send its screen; `screen-view` can display a received screen. Flow, pull
/// case ("Connect to screen" — I want to see yours):
///   viewer → SCREEN_REQUEST → source
///   source (user picks display/window) → SCREEN_OFFER{token} → viewer
///   source opens a dedicated TLS connection to the viewer's listener,
///     sends SCREEN_ATTACH{token} as its first frame, then streams SCREEN_FRAME
///   viewer sends SCREEN_ACK back on that connection (bitrate/keyframe feedback)
///   either side ends with SCREEN_END.

public enum ScreenVideoCodec: String, Codable, Sendable {
    case hevc, h264
}

public enum ScreenCaptureKind: String, Codable, Sendable {
    case display, window
}

/// Viewer → source: request to view, advertising decoder support and limits.
public struct ScreenRequestBody: Codable, Sendable, Equatable {
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var maxFps: Int?
    /// Codecs the viewer can decode, in preference order.
    public var codecs: [ScreenVideoCodec]

    enum CodingKeys: String, CodingKey {
        case codecs
        case maxWidth = "max_width"
        case maxHeight = "max_height"
        case maxFps = "max_fps"
    }

    public init(maxWidth: Int? = nil, maxHeight: Int? = nil, maxFps: Int? = nil,
                codecs: [ScreenVideoCodec] = [.hevc, .h264]) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFps = maxFps
        self.codecs = codecs
    }
}

/// Source → viewer: the source accepted and will stream. The viewer expects an
/// inbound bulk connection whose first frame is SCREEN_ATTACH bearing `bulkToken`.
public struct ScreenOfferBody: Codable, Sendable, Equatable {
    public var screenSessionID: String
    public var wireSessionID: UInt16
    public var codec: ScreenVideoCodec
    public var width: Int
    public var height: Int
    public var fps: Int
    public var captureKind: ScreenCaptureKind
    public var sourceName: String
    public var bulkToken: String

    enum CodingKeys: String, CodingKey {
        case codec, width, height, fps
        case screenSessionID = "screen_session_id"
        case wireSessionID = "wire_session_id"
        case captureKind = "capture_kind"
        case sourceName = "source_name"
        case bulkToken = "bulk_token"
    }

    public init(screenSessionID: String, wireSessionID: UInt16, codec: ScreenVideoCodec,
                width: Int, height: Int, fps: Int, captureKind: ScreenCaptureKind,
                sourceName: String, bulkToken: String) {
        self.screenSessionID = screenSessionID
        self.wireSessionID = wireSessionID
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.captureKind = captureKind
        self.sourceName = sourceName
        self.bulkToken = bulkToken
    }
}

public struct ScreenRejectBody: Codable, Sendable, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

/// First control frame on a screen bulk connection; binds it to an offer.
public struct ScreenAttachBody: Codable, Sendable, Equatable {
    public var screenSessionID: String
    public var bulkToken: String

    enum CodingKeys: String, CodingKey {
        case screenSessionID = "screen_session_id"
        case bulkToken = "bulk_token"
    }

    public init(screenSessionID: String, bulkToken: String) {
        self.screenSessionID = screenSessionID
        self.bulkToken = bulkToken
    }
}

/// Viewer → source, on the bulk connection: delivery feedback driving adaptive
/// bitrate and keyframe recovery (spec §9 Phase 3 step 2).
public struct ScreenAckBody: Codable, Sendable, Equatable {
    public var screenSessionID: String
    /// Highest frame seq the viewer has decoded.
    public var ackedSeq: UInt32
    /// Ask the source to emit a keyframe now (viewer joined or lost sync).
    public var requestKeyframe: Bool

    enum CodingKeys: String, CodingKey {
        case screenSessionID = "screen_session_id"
        case ackedSeq = "acked_seq"
        case requestKeyframe = "request_keyframe"
    }

    public init(screenSessionID: String, ackedSeq: UInt32, requestKeyframe: Bool) {
        self.screenSessionID = screenSessionID
        self.ackedSeq = ackedSeq
        self.requestKeyframe = requestKeyframe
    }
}

public struct ScreenEndBody: Codable, Sendable, Equatable {
    public var screenSessionID: String
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case reason
        case screenSessionID = "screen_session_id"
    }

    public init(screenSessionID: String, reason: String? = nil) {
        self.screenSessionID = screenSessionID
        self.reason = reason
    }
}

/// Phase 4-5: a notification mirrored from a source device (Windows/Linux/
/// Android) to a display device (iPhone/Mac). Direction-specific: `notify-source`
/// advertises sourcing, `notify-show` advertises display (spec §4).
public struct NotificationBody: Codable, Sendable, Equatable {
    public var appName: String
    public var title: String
    public var body: String
    public var id: String
    public var actions: [String]?

    enum CodingKeys: String, CodingKey {
        case title, body, id, actions
        case appName = "app_name"
    }

    public init(appName: String, title: String, body: String, id: String, actions: [String]? = nil) {
        self.appName = appName
        self.title = title
        self.body = body
        self.id = id
        self.actions = actions
    }
}

import Foundation

/// Message type discriminator carried in every envelope.
///
/// Invariant (spec §6): the envelope never changes shape. Unknown types are
/// ignored with a logged warning, never treated as fatal.
public enum MessageType: String, Codable, Sendable, CaseIterable {
    case hello = "HELLO"
    case helloAck = "HELLO_ACK"
    case ping = "PING"
    case pong = "PONG"
    case clipboardPush = "CLIPBOARD_PUSH"
    case fileOffer = "FILE_OFFER"
    case fileAccept = "FILE_ACCEPT"
    case fileReject = "FILE_REJECT"
    case fileAck = "FILE_ACK"
    case pairRequest = "PAIR_REQUEST"
    case pairResponse = "PAIR_RESPONSE"
    case pairConfirm = "PAIR_CONFIRM"
    case pairReject = "PAIR_REJECT"
    case bulkAttach = "BULK_ATTACH"
    // Phase 2 (spec §9): remote input + media control.
    case inputRequest = "INPUT_REQUEST"
    case inputStatus = "INPUT_STATUS"
    case inputEvent = "INPUT_EVENT"
    case inputAttach = "INPUT_ATTACH"
    case mediaControl = "MEDIA_CONTROL"
    // Phase 3 (spec §9): screen sharing. SCREEN_FRAME is binary (frame kind
    // 0x03), not a control message, so it has no entry here.
    case screenRequest = "SCREEN_REQUEST"
    case screenOffer = "SCREEN_OFFER"
    case screenReject = "SCREEN_REJECT"
    case screenAttach = "SCREEN_ATTACH"
    case screenAck = "SCREEN_ACK"
    case screenEnd = "SCREEN_END"
    // Phase 4-5 (spec §6): notification mirroring.
    case notification = "NOTIFICATION"
}

/// The envelope fields every control message carries (spec §6):
/// `version`, `type`, `session_id`, `seq`. Payload is type-specific.
public struct EnvelopeMeta: Sendable, Equatable {
    public var version: String
    public var sessionID: String
    public var seq: UInt64

    public init(version: String = ProtocolConstants.version, sessionID: String, seq: UInt64) {
        self.version = version
        self.sessionID = sessionID
        self.seq = seq
    }
}

/// Generic wire shape. Concrete payloads are in Messages.swift.
struct WireEnvelope<Payload: Codable>: Codable {
    var version: String
    var type: String
    var sessionID: String
    var seq: UInt64
    var payload: Payload

    enum CodingKeys: String, CodingKey {
        case version, type, seq, payload
        case sessionID = "session_id"
    }
}

/// Header-only decode used to dispatch on `type` before decoding the payload.
struct WireHeader: Codable {
    var version: String
    var type: String
    var sessionID: String
    var seq: UInt64

    enum CodingKeys: String, CodingKey {
        case version, type, seq
        case sessionID = "session_id"
    }
}

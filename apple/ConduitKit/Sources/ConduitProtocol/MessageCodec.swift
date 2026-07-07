import Foundation

public enum MessageCodecError: Error, Equatable {
    case notJSON
    case missingEnvelopeField(String)
}

/// Encodes and decodes control messages to/from their canonical JSON wire form.
public enum MessageCodec {
    /// Canonical encoding of one control message (the bytes that go inside a control frame).
    public static func encode(meta: EnvelopeMeta, message: Message) throws -> Data {
        let encoder = CanonicalJSON.makeEncoder()

        func env<P: Codable>(_ type: MessageType, _ payload: P) throws -> Data {
            try encoder.encode(WireEnvelope(
                version: meta.version,
                type: type.rawValue,
                sessionID: meta.sessionID,
                seq: meta.seq,
                payload: payload
            ))
        }

        switch message {
        case .hello(let body): return try env(.hello, body)
        case .helloAck(let body): return try env(.helloAck, body)
        case .ping(let body): return try env(.ping, body)
        case .pong(let body): return try env(.pong, body)
        case .clipboardPush(let body): return try env(.clipboardPush, body)
        case .fileOffer(let body): return try env(.fileOffer, body)
        case .fileAccept(let body): return try env(.fileAccept, body)
        case .fileReject(let body): return try env(.fileReject, body)
        case .fileAck(let body): return try env(.fileAck, body)
        case .pairRequest(let body): return try env(.pairRequest, body)
        case .pairResponse(let body): return try env(.pairResponse, body)
        case .pairConfirm: return try env(.pairConfirm, EmptyBody())
        case .pairReject(let body): return try env(.pairReject, body)
        case .bulkAttach(let body): return try env(.bulkAttach, body)
        case .inputRequest: return try env(.inputRequest, EmptyBody())
        case .inputStatus(let body): return try env(.inputStatus, body)
        case .inputEvent(let body): return try env(.inputEvent, body)
        case .inputAttach(let body): return try env(.inputAttach, body)
        case .mediaControl(let body): return try env(.mediaControl, body)
        case .screenRequest(let body): return try env(.screenRequest, body)
        case .screenOffer(let body): return try env(.screenOffer, body)
        case .screenReject(let body): return try env(.screenReject, body)
        case .screenAttach(let body): return try env(.screenAttach, body)
        case .screenAck(let body): return try env(.screenAck, body)
        case .screenEnd(let body): return try env(.screenEnd, body)
        case .notification(let body): return try env(.notification, body)
        case .unknown(let type):
            throw MessageCodecError.missingEnvelopeField("cannot encode unknown type \(type)")
        }
    }

    /// Decodes one control frame payload. Unknown `type` yields `.unknown`, not an error.
    public static func decode(_ data: Data) throws -> (EnvelopeMeta, Message) {
        let decoder = CanonicalJSON.makeDecoder()
        let header: WireHeader
        do {
            header = try decoder.decode(WireHeader.self, from: data)
        } catch {
            throw MessageCodecError.notJSON
        }
        let meta = EnvelopeMeta(version: header.version, sessionID: header.sessionID, seq: header.seq)

        func body<P: Codable>(_ type: P.Type) throws -> P {
            try decoder.decode(WireEnvelope<P>.self, from: data).payload
        }

        guard let type = MessageType(rawValue: header.type) else {
            return (meta, .unknown(type: header.type))
        }

        let message: Message
        switch type {
        case .hello: message = .hello(try body(HelloBody.self))
        case .helloAck: message = .helloAck(try body(HelloBody.self))
        case .ping: message = .ping(try body(PingBody.self))
        case .pong: message = .pong(try body(PingBody.self))
        case .clipboardPush: message = .clipboardPush(try body(ClipboardPushBody.self))
        case .fileOffer: message = .fileOffer(try body(FileOfferBody.self))
        case .fileAccept: message = .fileAccept(try body(FileAcceptBody.self))
        case .fileReject: message = .fileReject(try body(FileRejectBody.self))
        case .fileAck: message = .fileAck(try body(FileAckBody.self))
        case .pairRequest: message = .pairRequest(try body(PairBody.self))
        case .pairResponse: message = .pairResponse(try body(PairBody.self))
        case .pairConfirm: message = .pairConfirm
        case .pairReject: message = .pairReject(try body(PairRejectBody.self))
        case .bulkAttach: message = .bulkAttach(try body(BulkAttachBody.self))
        case .inputRequest: message = .inputRequest
        case .inputStatus: message = .inputStatus(try body(InputStatusBody.self))
        case .inputEvent: message = .inputEvent(try body(InputEventBody.self))
        case .inputAttach: message = .inputAttach(try body(InputAttachBody.self))
        case .mediaControl: message = .mediaControl(try body(MediaControlBody.self))
        case .screenRequest: message = .screenRequest(try body(ScreenRequestBody.self))
        case .screenOffer: message = .screenOffer(try body(ScreenOfferBody.self))
        case .screenReject: message = .screenReject(try body(ScreenRejectBody.self))
        case .screenAttach: message = .screenAttach(try body(ScreenAttachBody.self))
        case .screenAck: message = .screenAck(try body(ScreenAckBody.self))
        case .screenEnd: message = .screenEnd(try body(ScreenEndBody.self))
        case .notification: message = .notification(try body(NotificationBody.self))
        }
        return (meta, message)
    }
}

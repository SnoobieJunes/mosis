import Foundation
import Testing
@testable import ConduitProtocol

/// Phase 2 message bodies round-trip through the canonical codec, and the
/// stateless-modifier design holds (every key event carries its full set).
@Suite struct InputCodecTests {
    let meta = EnvelopeMeta(sessionID: "S", seq: 3)

    @Test func inputEventsRoundTrip() throws {
        let events: [InputEventBody] = [
            .move(dx: 12.5, dy: -3.25),
            .scroll(dx: 0, dy: -40),
            .click(.left, action: .down),
            .click(.left, action: .up),
            .click(.right, action: .tap, clickCount: 2),
            .text("Hello", modifiers: [.command, .shift]),
            .specialKey("return"),
            .specialKey("f5", modifiers: [.control]),
        ]
        for event in events {
            let encoded = try MessageCodec.encode(meta: meta, message: .inputEvent(event))
            let (_, decoded) = try MessageCodec.decode(encoded)
            #expect(decoded == .inputEvent(event))
        }
    }

    @Test func statusAndControlRoundTrip() throws {
        let messages: [Message] = [
            .inputRequest,
            .inputStatus(InputStatusBody(active: true, udpPort: 52_114, datagramToken: "abcd", secureInput: false)),
            .inputStatus(InputStatusBody(active: false, reason: "declined")),
            .inputAttach(InputAttachBody(token: "abcd")),
            .mediaControl(MediaControlBody(action: .toggle)),
            .mediaControl(MediaControlBody(action: .volume, value: -1)),
        ]
        for message in messages {
            let encoded = try MessageCodec.encode(meta: meta, message: message)
            let (_, decoded) = try MessageCodec.decode(encoded)
            #expect(decoded == message, "round-trip mismatch for \(message.typeString)")
        }
    }

    @Test func everyKeyEventCarriesCompleteModifierSet() throws {
        // Stateless-modifier invariant: a dropped message can't wedge a
        // modifier because state is never implied between events.
        let chord = InputEventBody.text("c", modifiers: [.command])
        let encoded = try MessageCodec.encode(meta: meta, message: .inputEvent(chord))
        let (_, decoded) = try MessageCodec.decode(encoded)
        guard case .inputEvent(let body) = decoded else {
            Issue.record("not an input event"); return
        }
        #expect(body.modifiers == [.command])
    }

    @Test func newTypesDoNotDisturbOldEnvelope() throws {
        // An old peer seeing INPUT_EVENT ignores it, never faults (spec §6).
        let json = #"{"version":"0.2","type":"INPUT_EVENT","session_id":"s","seq":1,"payload":{"kind":"move","dx":1,"dy":1}}"#
        // Decoder here knows the type, but the invariant we assert is that an
        // UNKNOWN type is inert — simulate a future type.
        let future = #"{"version":"0.2","type":"HOLOGRAM","session_id":"s","seq":1,"payload":{}}"#
        let (_, known) = try MessageCodec.decode(Data(json.utf8))
        let (_, unknown) = try MessageCodec.decode(Data(future.utf8))
        #expect(known == .inputEvent(.move(dx: 1, dy: 1)))
        #expect(unknown == .unknown(type: "HOLOGRAM"))
    }
}

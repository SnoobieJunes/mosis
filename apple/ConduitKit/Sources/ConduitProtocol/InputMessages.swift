import Foundation

/// Phase 2 message bodies: remote input and media control (spec §9 Phase 2).
///
/// Direction semantics: a device that advertises the `input-inject` capability
/// can RECEIVE InputEvent and inject it into its OS; `media-target` marks a
/// device whose system Now Playing can be driven. Controllers check the
/// REMOTE side's capability list, not the intersection (the phone can never
/// inject, yet drives the Mac).

public enum InputKind: String, Codable, Sendable {
    case move, click, scroll, key
}

public enum PointerButton: String, Codable, Sendable {
    case left, right, middle
}

public enum InputAction: String, Codable, Sendable {
    case down, up, tap
}

/// Modifier names on the wire. Stateless by design: every key event carries
/// its complete modifier set, so a dropped message can never wedge a modifier
/// on the receiver (spec Phase 2 acceptance: zero stuck-modifier bugs).
public enum InputModifier: String, Codable, Sendable, CaseIterable {
    case shift, control, option, command, function
}

public struct InputEventBody: Codable, Sendable, Equatable {
    public var kind: InputKind
    /// move: pointer delta in points. scroll: scroll delta in points
    /// (positive dy scrolls content up, trackpad-natural).
    public var dx: Double?
    public var dy: Double?
    /// click fields.
    public var button: PointerButton?
    public var action: InputAction?
    public var clickCount: Int?
    /// key fields: exactly one of `key` (special-key name: return, tab,
    /// escape, backspace, delete_forward, up, down, left, right, home, end,
    /// page_up, page_down, f1…f12) or `text` (literal characters to insert).
    public var key: String?
    public var text: String?
    public var modifiers: [InputModifier]?

    enum CodingKeys: String, CodingKey {
        case kind, dx, dy, button, action, key, text, modifiers
        case clickCount = "click_count"
    }

    public init(kind: InputKind, dx: Double? = nil, dy: Double? = nil,
                button: PointerButton? = nil, action: InputAction? = nil,
                clickCount: Int? = nil, key: String? = nil, text: String? = nil,
                modifiers: [InputModifier]? = nil) {
        self.kind = kind
        self.dx = dx
        self.dy = dy
        self.button = button
        self.action = action
        self.clickCount = clickCount
        self.key = key
        self.text = text
        self.modifiers = modifiers
    }

    public static func move(dx: Double, dy: Double) -> InputEventBody {
        InputEventBody(kind: .move, dx: dx, dy: dy)
    }

    public static func scroll(dx: Double, dy: Double) -> InputEventBody {
        InputEventBody(kind: .scroll, dx: dx, dy: dy)
    }

    public static func click(_ button: PointerButton, action: InputAction, clickCount: Int = 1) -> InputEventBody {
        InputEventBody(kind: .click, button: button, action: action, clickCount: clickCount)
    }

    public static func text(_ text: String, modifiers: [InputModifier] = []) -> InputEventBody {
        InputEventBody(kind: .key, text: text, modifiers: modifiers.isEmpty ? nil : modifiers)
    }

    public static func specialKey(_ name: String, modifiers: [InputModifier] = []) -> InputEventBody {
        InputEventBody(kind: .key, key: name, modifiers: modifiers.isEmpty ? nil : modifiers)
    }
}

/// Receiver → controller: grant lifecycle and delivery hints.
/// `udpPort`/`datagramToken` invite the controller to open the low-latency
/// datagram lane (spec Phase 2 step 4); absent means control-lane only.
public struct InputStatusBody: Codable, Sendable, Equatable {
    public var active: Bool
    public var reason: String?
    public var udpPort: UInt16?
    public var datagramToken: String?
    /// True while the receiver is in a secure-input field (password box):
    /// key events are being refused, not silently dropped (spec pitfall).
    public var secureInput: Bool?

    enum CodingKeys: String, CodingKey {
        case active, reason
        case udpPort = "udp_port"
        case datagramToken = "datagram_token"
        case secureInput = "secure_input"
    }

    public init(active: Bool, reason: String? = nil, udpPort: UInt16? = nil,
                datagramToken: String? = nil, secureInput: Bool? = nil) {
        self.active = active
        self.reason = reason
        self.udpPort = udpPort
        self.datagramToken = datagramToken
        self.secureInput = secureInput
    }
}

/// First frame on a datagram lane; binds it to an input grant.
public struct InputAttachBody: Codable, Sendable, Equatable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public enum MediaAction: String, Codable, Sendable {
    case play, pause, toggle, next, prev, seek, volume, mute
}

public struct MediaControlBody: Codable, Sendable, Equatable {
    public var action: MediaAction
    /// seek: signed seconds. volume: signed steps.
    public var value: Double?

    public init(action: MediaAction, value: Double? = nil) {
        self.action = action
        self.value = value
    }
}

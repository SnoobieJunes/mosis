import SwiftUI
import ConduitProtocol
import ConduitCapabilities

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The input half of "watch and drive at once": a transparent surface laid over
/// the live video that forwards pointing, clicking, scrolling and typing to the
/// peer whose screen is on it.
///
/// `ScreenViews.swift` claimed in a header comment to do this since Phase 3. It
/// never did — the viewer was pixels with no gestures, and the trackpad was
/// gestures with no pixels, on two screens you could not be on at once. This is
/// the thing that comment described.
///
/// Coordinates go through `ScreenGeometry`, so a tap lands where the picture is
/// rather than where the container is (they differ by the letterbox bars).
struct ScreenControlSurface: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            ScreenControlRepresentable(
                model: model,
                containerSize: geometry.size
            )
            #elseif os(macOS)
            MacScreenControlRepresentable(
                model: model,
                containerSize: geometry.size
            )
            #else
            Color.clear
            #endif
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote screen control surface")
        .accessibilityHint("Drag to move the remote pointer, tap to click. Two-finger drag scrolls; two-finger tap right-clicks. A connected keyboard types on the remote device.")
    }
}

// MARK: - Key translation (shared)

/// One key event ready for the wire: either literal `text` or a named special
/// key, plus the modifier set. Modifiers are stateless on the wire by design,
/// so every event carries the full set (spec Phase 2 acceptance).
struct RemoteKeyEvent {
    var text: String?
    var key: String?
    var modifiers: [InputModifier]
}

enum RemoteKeyTranslation {
    /// Special-key names shared with `MacInputInjector.virtualKey(for:)` and the
    /// Android receiver. Anything not here travels as literal text instead.
    static func specialKeyName(forUSBHIDUsage usage: Int) -> String? {
        // USB HID keyboard usage page (0x07) — the identifiers UIKey and
        // NSEvent's key codes both ultimately derive from.
        switch usage {
        case 0x28: "return"
        case 0x29: "escape"
        case 0x2A: "backspace"
        case 0x2B: "tab"
        case 0x4C: "delete_forward"
        case 0x4A: "home"
        case 0x4D: "end"
        case 0x4B: "page_up"
        case 0x4E: "page_down"
        case 0x4F: "right"
        case 0x50: "left"
        case 0x51: "down"
        case 0x52: "up"
        case 0x3A...0x45: "f\(usage - 0x39)"   // F1…F12
        default: nil
        }
    }
}

// MARK: - iOS / iPadOS

#if os(iOS)
struct ScreenControlRepresentable: UIViewRepresentable {
    let model: AppModel
    let containerSize: CGSize

    func makeUIView(context: Context) -> ScreenControlUIView {
        let view = ScreenControlUIView()
        view.model = model
        return view
    }

    func updateUIView(_ uiView: ScreenControlUIView, context: Context) {
        uiView.model = model
    }
}

/// Touch → remote pointer, on the picture rather than on a trackpad.
///
/// One finger positions and left-clicks, a long press right-clicks, two fingers
/// scroll. A connected hardware keyboard types through `pressesBegan/Ended`,
/// which give real down/up events (and therefore working modifier chords) —
/// the on-screen `TextField` could never do either.
final class ScreenControlUIView: UIView {
    weak var model: AppModel?
    private let scrollGain: Double = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let onePan = UIPanGestureRecognizer(target: self, action: #selector(handleOnePan))
        onePan.minimumNumberOfTouches = 1
        onePan.maximumNumberOfTouches = 1
        addGestureRecognizer(onePan)

        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoPan))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.numberOfTouchesRequired = 1
        tap.require(toFail: onePan)
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)

        // iPadOS pointer devices: hovering moves the remote cursor with no
        // button held, which is what makes menus and tooltips work at all.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))
    }

    required init?(coder: NSCoder) { fatalError() }

    // Hardware keys only arrive at the first responder.
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private func send(_ point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        model?.pointerMoveOnScreen(
            x: Double(point.x), y: Double(point.y),
            containerWidth: Double(bounds.width), containerHeight: Double(bounds.height)
        )
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: send(gesture.location(in: self))
        default: model?.endPointerGesture()
        }
    }

    @objc private func handleOnePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: send(gesture.location(in: self))
        default: model?.endPointerGesture()
        }
    }

    @objc private func handleTwoPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        model?.scroll(dx: Double(translation.x) * scrollGain, dy: Double(translation.y) * scrollGain)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Position first so the click lands where the finger was, then click.
        // The coalescer flushes pending motion before any discrete event, so
        // ordering is guaranteed rather than hoped for.
        send(gesture.location(in: self))
        model?.click(.left, action: .tap)
        model?.endPointerGesture()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        send(gesture.location(in: self))
        model?.click(.right, action: .tap)
        model?.endPointerGesture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, action: .down) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, action: .up) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, action: .up) { super.pressesCancelled(presses, with: event) }
    }

    /// Returns true if anything was forwarded, so unhandled presses still reach
    /// the system (⌘-Tab, the Home indicator gesture, accessibility shortcuts).
    private func forward(_ presses: Set<UIPress>, action: InputAction) -> Bool {
        guard let model, model.viewerForwardsInput else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let modifiers = Self.modifiers(from: key.modifierFlags)
            if let name = RemoteKeyTranslation.specialKeyName(forUSBHIDUsage: key.keyCode.rawValue) {
                model.specialKey(name, action: action, modifiers: modifiers)
                handled = true
            } else if !key.charactersIgnoringModifiers.isEmpty {
                // Literal characters are layout-independent on the receiver
                // (they arrive as a unicode payload), so send what the keyboard
                // means, not which physical key it was.
                let text = modifiers.isEmpty ? key.characters : key.charactersIgnoringModifiers
                guard !text.isEmpty else { continue }
                model.typeText(text, action: action, modifiers: modifiers)
                handled = true
            }
        }
        return handled
    }

    static func modifiers(from flags: UIKeyModifierFlags) -> [InputModifier] {
        var out: [InputModifier] = []
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.alternate) { out.append(.option) }
        if flags.contains(.command) { out.append(.command) }
        return out
    }
}
#endif

// MARK: - macOS

#if os(macOS)
struct MacScreenControlRepresentable: NSViewRepresentable {
    let model: AppModel
    let containerSize: CGSize

    func makeNSView(context: Context) -> ScreenControlNSView {
        let view = ScreenControlNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: ScreenControlNSView, context: Context) {
        nsView.model = model
    }

    static func dismantleNSView(_ nsView: ScreenControlNSView, coordinator: ()) {
        nsView.teardown()
    }
}

/// A Mac driving another Mac: real mouse tracking, both buttons, the scroll
/// wheel, and a local key monitor so keystrokes go to the remote machine
/// instead of this one while the viewer has focus.
final class ScreenControlNSView: NSView {
    weak var model: AppModel?
    private var keyMonitor: Any?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    /// Click straight through to the remote without first activating this
    /// window — otherwise every click after a window switch is swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installKeyMonitor()
        } else {
            teardown()
        }
    }

    /// Removes the key monitor. Called when the view leaves its window and from
    /// `dismantleNSView`, rather than from `deinit`: a monitor left installed
    /// would keep swallowing keystrokes for a viewer that is gone.
    func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Pointer

    /// AppKit's view space is bottom-left origin; the wire (and every
    /// `ScreenGeometry` call) is top-left. Flip here, once.
    private func send(_ event: NSEvent) {
        guard bounds.height > 0, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        model?.pointerMoveOnScreen(
            x: Double(point.x), y: Double(bounds.height - point.y),
            containerWidth: Double(bounds.width), containerHeight: Double(bounds.height)
        )
    }

    override func mouseMoved(with event: NSEvent) { send(event) }
    override func mouseDragged(with event: NSEvent) { send(event) }
    override func rightMouseDragged(with event: NSEvent) { send(event) }

    override func mouseDown(with event: NSEvent) {
        send(event)
        model?.click(.left, action: .down, clickCount: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        send(event)
        model?.click(.left, action: .up, clickCount: event.clickCount)
        model?.endPointerGesture()
    }

    override func rightMouseDown(with event: NSEvent) {
        send(event)
        model?.click(.right, action: .down)
    }

    override func rightMouseUp(with event: NSEvent) {
        send(event)
        model?.click(.right, action: .up)
        model?.endPointerGesture()
    }

    override func scrollWheel(with event: NSEvent) {
        model?.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
    }

    override func mouseExited(with event: NSEvent) {
        model?.endPointerGesture()
    }

    // MARK: Keyboard

    /// A local monitor, not `keyDown(with:)`: it sees the event before menu-key
    /// equivalents do, so ⌘Q and ⌘W go to the machine being driven instead of
    /// quitting the app you are driving it from. Returning nil swallows the
    /// event locally — the whole point of a remote-control surface.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let model = self.model,
                  self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self,
                  model.viewerForwardsInput
            else { return event }
            self.forward(event)
            return nil
        }
    }

    private func forward(_ event: NSEvent) {
        guard let model else { return }
        let action: InputAction = event.type == .keyDown ? .down : .up
        let modifiers = Self.modifiers(from: event.modifierFlags)
        if let name = Self.specialKeyName(forVirtualKey: event.keyCode) {
            model.specialKey(name, action: action, modifiers: modifiers)
            return
        }
        // Literal text. `charactersIgnoringModifiers` under a chord so ⌘⇧Z
        // arrives as "z" + [command, shift] rather than as an already-shifted
        // "Z" the receiver would then shift again.
        let text = modifiers.isEmpty
            ? (event.characters ?? "")
            : (event.charactersIgnoringModifiers ?? "")
        guard !text.isEmpty else { return }
        model.typeText(text, action: action, modifiers: modifiers)
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> [InputModifier] {
        var out: [InputModifier] = []
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.option) { out.append(.option) }
        if flags.contains(.command) { out.append(.command) }
        if flags.contains(.function) { out.append(.function) }
        return out
    }

    /// Carbon virtual keycodes for the keys that have no useful character.
    static func specialKeyName(forVirtualKey code: UInt16) -> String? {
        switch code {
        case 36, 76: "return"
        case 48: "tab"
        case 51: "backspace"
        case 53: "escape"
        case 117: "delete_forward"
        case 115: "home"
        case 119: "end"
        case 116: "page_up"
        case 121: "page_down"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 122: "f1"
        case 120: "f2"
        case 99: "f3"
        case 118: "f4"
        case 96: "f5"
        case 97: "f6"
        case 98: "f7"
        case 100: "f8"
        case 101: "f9"
        case 109: "f10"
        case 103: "f11"
        case 111: "f12"
        default: nil
        }
    }
}
#endif

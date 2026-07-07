#if os(macOS)
import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit
import ConduitProtocol

/// macOS input injection via CGEvent (spec §9 Phase 2 step 2). Requires the
/// Accessibility (TCC) permission. Posts deltas relative to the current cursor
/// (the phone sends deltas, never absolute coordinates — spec pitfall), clamps
/// to the display union so multi-monitor origins are handled, refuses keys
/// while secure input is on, and can release everything on the kill switch.
public final class MacInputInjector: InputInjector, @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    /// Buttons currently held down, so releaseAll() can lift them.
    private var heldButtons: Set<PointerButton> = []

    public init() {}

    public var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    public var permissionInstructions: String {
        "Open System Settings → Privacy & Security → Accessibility and enable Conduit, so it can move the pointer and type for you."
    }

    public func openPermissionSettings() {
        // Ask the system to prompt first: that call is what registers the app in
        // the Accessibility list, so the user has something to tick when the
        // pane opens. Without it they land on a list Conduit isn't in yet.
        // The constant itself is an imported `var` (not concurrency-safe to
        // reference under strict checking); its value is this documented key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: Injection

    public func inject(_ event: InputEventBody) throws {
        guard isPermitted else { throw InputInjectorError.notPermitted }
        switch event.kind {
        case .move: try injectMove(event)
        case .scroll: try injectScroll(event)
        case .click: try injectClick(event)
        case .key: try injectKey(event)
        }
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Clamps a point to the union of all screen frames (global/top-left space).
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return point }
        // Global display bounds in CG (top-left origin) space.
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        let totalHeight = screens.map { $0.frame.maxY }.max() ?? 0
        for screen in screens {
            let f = screen.frame
            let top = totalHeight - f.maxY
            minX = min(minX, f.minX); maxX = max(maxX, f.maxX)
            minY = min(minY, top); maxY = max(maxY, top + f.height)
        }
        return CGPoint(
            x: Swift.min(Swift.max(point.x, minX), maxX - 1),
            y: Swift.min(Swift.max(point.y, minY), maxY - 1)
        )
    }

    private func injectMove(_ event: InputEventBody) throws {
        let current = currentLocation()
        let target = clampToDisplays(CGPoint(
            x: current.x + (event.dx ?? 0),
            y: current.y + (event.dy ?? 0)
        ))
        let dragButton = lock.withLock { heldButtons.first }
        let type: CGEventType
        let button: CGMouseButton
        switch dragButton {
        case .left: type = .leftMouseDragged; button = .left
        case .right: type = .rightMouseDragged; button = .right
        case .middle: type = .otherMouseDragged; button = .center
        case nil: type = .mouseMoved; button = .left
        }
        let move = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button)
        move?.post(tap: .cghidEventTap)
    }

    private func injectScroll(_ event: InputEventBody) throws {
        // Pixel-precise scrolling; dy positive scrolls content up (natural).
        let dy = Int32((event.dy ?? 0).rounded())
        let dx = Int32((event.dx ?? 0).rounded())
        let scroll = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel,
            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        )
        scroll?.post(tap: .cghidEventTap)
    }

    private func injectClick(_ event: InputEventBody) throws {
        let button = event.button ?? .left
        let location = currentLocation()
        let (downType, upType, cgButton) = mouseTypes(for: button)

        func post(_ type: CGEventType, isDown: Bool) {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
            if let count = event.clickCount, count > 1 {
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            }
            e?.post(tap: .cghidEventTap)
        }

        switch event.action ?? .tap {
        case .down:
            lock.withLock { _ = heldButtons.insert(button) }
            post(downType, isDown: true)
        case .up:
            lock.withLock { heldButtons.remove(button) }
            post(upType, isDown: false)
        case .tap:
            post(downType, isDown: true)
            post(upType, isDown: false)
        }
    }

    private func mouseTypes(for button: PointerButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private func injectKey(_ event: InputEventBody) throws {
        // Password fields consume synthetic keys; tell the user instead of
        // dropping silently (spec pitfall).
        if isSecureInputActive {
            throw InputInjectorError.secureInputActive
        }
        let flags = cgFlags(for: event.modifiers ?? [])

        if let text = event.text {
            // Type literal characters via unicode payload — layout-independent.
            for scalarGroup in text.unicodeScalars.chunked(into: 20) {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
                var utf16 = Array(String(String.UnicodeScalarView(scalarGroup)).utf16)
                down.flags = flags
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            return
        }

        guard let keyName = event.key, let keyCode = Self.virtualKey(for: keyName) else {
            throw InputInjectorError.unsupportedEvent("key \(event.key ?? "nil")")
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw InputInjectorError.unsupportedEvent("keycode alloc")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func cgFlags(for modifiers: [InputModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .shift: flags.insert(.maskShift)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    // MARK: Media keys (NX system-defined events, spec §9 Phase 2 step 2)

    public func injectMedia(_ control: MediaControlBody) throws {
        guard isPermitted else { throw InputInjectorError.notPermitted }
        let key: Int32?
        switch control.action {
        case .play, .pause, .toggle: key = NX_KEYTYPE_PLAY
        case .next: key = NX_KEYTYPE_NEXT
        case .prev: key = NX_KEYTYPE_PREVIOUS
        case .volume:
            key = (control.value ?? 0) >= 0 ? NX_KEYTYPE_SOUND_UP : NX_KEYTYPE_SOUND_DOWN
        case .mute: key = NX_KEYTYPE_MUTE
        case .seek: key = nil // no system media key for seek; ignore
        }
        guard let key else { return }
        postSystemDefinedKey(key, down: true)
        postSystemDefinedKey(key, down: false)
    }

    private func postSystemDefinedKey(_ key: Int32, down: Bool) {
        let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
        let data1 = Int((key << 16)) | (down ? (0xA << 8) : (0xB << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: Cleanup

    public func releaseAll() {
        let held = lock.withLock { () -> Set<PointerButton> in
            let copy = heldButtons
            heldButtons.removeAll()
            return copy
        }
        let location = currentLocation()
        for button in held {
            let (_, upType, cgButton) = mouseTypes(for: button)
            CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: location, mouseButton: cgButton)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Special-key name → virtual keycode

    static func virtualKey(for name: String) -> CGKeyCode? {
        switch name {
        case "return", "enter": CGKeyCode(kVK_Return)
        case "tab": CGKeyCode(kVK_Tab)
        case "space": CGKeyCode(kVK_Space)
        case "delete", "backspace": CGKeyCode(kVK_Delete)
        case "delete_forward": CGKeyCode(kVK_ForwardDelete)
        case "escape": CGKeyCode(kVK_Escape)
        case "up": CGKeyCode(kVK_UpArrow)
        case "down": CGKeyCode(kVK_DownArrow)
        case "left": CGKeyCode(kVK_LeftArrow)
        case "right": CGKeyCode(kVK_RightArrow)
        case "home": CGKeyCode(kVK_Home)
        case "end": CGKeyCode(kVK_End)
        case "page_up": CGKeyCode(kVK_PageUp)
        case "page_down": CGKeyCode(kVK_PageDown)
        case "f1": CGKeyCode(kVK_F1)
        case "f2": CGKeyCode(kVK_F2)
        case "f3": CGKeyCode(kVK_F3)
        case "f4": CGKeyCode(kVK_F4)
        case "f5": CGKeyCode(kVK_F5)
        case "f6": CGKeyCode(kVK_F6)
        case "f7": CGKeyCode(kVK_F7)
        case "f8": CGKeyCode(kVK_F8)
        case "f9": CGKeyCode(kVK_F9)
        case "f10": CGKeyCode(kVK_F10)
        case "f11": CGKeyCode(kVK_F11)
        case "f12": CGKeyCode(kVK_F12)
        default: nil
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Collection {
    func chunked(into size: Int) -> [[Element]] {
        var result: [[Element]] = []
        var index = startIndex
        while index != endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
#endif

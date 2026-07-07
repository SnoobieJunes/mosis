import Foundation
import ConduitProtocol

/// Platform-neutral input injection contract. macOS implements it with CGEvent
/// (spec §9 Phase 2 step 2); Android's AccessibilityService implements it in
/// Phase 5. iOS never implements it — the platform forbids input injection
/// (spec §4), so iOS ships no conforming type.
public protocol InputInjector: Sendable {
    /// Whether the OS currently permits injection (macOS: AXIsProcessTrusted).
    var isPermitted: Bool { get }
    /// Human-facing instruction when not permitted (which Settings pane, etc.).
    var permissionInstructions: String { get }
    /// Opens the relevant system settings pane, if the platform has one.
    func openPermissionSettings()
    /// True while the frontmost field refuses synthetic keys (secure input).
    var isSecureInputActive: Bool { get }

    func inject(_ event: InputEventBody) throws
    func injectMedia(_ control: MediaControlBody) throws
    /// Releases any held buttons/modifiers. Called on grant end and kill switch.
    func releaseAll()
}

public enum InputInjectorError: Error {
    case notPermitted
    case secureInputActive
    case unsupportedEvent(String)
}

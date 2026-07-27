import Foundation
import ConduitProtocol

/// The area an absolute (normalized) pointer position maps into: the bounds of
/// the display or window a controller is actually watching, in the receiver's
/// own global coordinate space, top-left origin.
///
/// Without it, `nx: 0.5` would mean "the middle of everything this device can
/// see", which on a three-display Mac is somewhere the controller isn't looking.
public struct InjectionRegion: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Maps a normalized point (0…1, top-left origin) into this region.
    public func point(nx: Double, ny: Double) -> (x: Double, y: Double) {
        (x + min(max(nx, 0), 1) * width, y + min(max(ny, 0), 1) * height)
    }
}

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
    /// Sets the area normalized absolute coordinates map into. nil means the
    /// platform's own default (on macOS, the union of all displays). The
    /// receive engine calls this when a controller's events name a screen
    /// session it can resolve to a captured display or window.
    func setAbsoluteRegion(_ region: InjectionRegion?)
}

public extension InputInjector {
    /// Default for injectors that only understand deltas: absolute events then
    /// fall back to their `dx`/`dy`, which every absolute move also carries.
    func setAbsoluteRegion(_ region: InjectionRegion?) {}
}

public enum InputInjectorError: Error {
    case notPermitted
    case secureInputActive
    case unsupportedEvent(String)
}

import Foundation
import CoreMedia
import CoreVideo
import ConduitProtocol

/// A thing a source can capture (spec §9 Phase 3 step 2: display OR single
/// window — the mosis capture-kind toggle). Platform-neutral so the source
/// engine and UI don't depend on ScreenCaptureKit directly.
public struct CaptureSourceDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ScreenCaptureKind
    public let name: String
    public let width: Int
    public let height: Int

    public init(id: String, kind: ScreenCaptureKind, name: String, width: Int, height: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.width = width
        self.height = height
    }
}

public struct CaptureConfiguration: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }
}

/// Platform capture contract. macOS implements it with ScreenCaptureKit; iOS
/// sourcing goes through a ReplayKit broadcast extension (a different process
/// model), so the iOS in-app path is out of scope for this protocol.
public protocol ScreenCapturer: AnyObject, Sendable {
    func isPermitted() async -> Bool
    func requestPermission() async
    func availableSources() async throws -> [CaptureSourceDescriptor]
    func start(
        source: CaptureSourceDescriptor,
        configuration: CaptureConfiguration,
        onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void
    ) async throws
    func stop() async
    /// Observe the capture stopping on its own — a display disconnecting, the
    /// window closing, or Screen Recording being revoked mid-stream. The source
    /// engine registers here so it ends the share with a reason instead of the
    /// viewer freezing on a dead stream. Default: no-op (fakes, and platforms
    /// with no mid-stream stop signal). `error` is nil on a clean self-stop.
    func setStreamStoppedHandler(_ handler: @escaping @Sendable (Error?) -> Void)
}

public extension ScreenCapturer {
    func setStreamStoppedHandler(_ handler: @escaping @Sendable (Error?) -> Void) {}
}

public enum ScreenCaptureError: Error {
    case notPermitted
    case sourceNotFound
    case unsupportedPlatform
    case startFailed(String)
}

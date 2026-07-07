import Foundation

/// Moves a value across an isolation boundary when the compiler can't prove it
/// Sendable but the usage is single-owner hand-off. Used for CoreVideo/CoreMedia
/// buffers (CVPixelBuffer, CMSampleBuffer): reference types that are immutable
/// once produced by the encoder/capturer, so a one-way hand-off is race-free.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

import Foundation

/// Canonical JSON encoding for control messages.
///
/// The wire form of every control message is the canonical encoding: sorted keys,
/// no added whitespace, forward slashes unescaped, `Data` fields as base64.
/// Golden vectors in proto/vectors are byte-exact against this form.
/// Decoders MUST accept any valid JSON (key order is not significant on receive).
public enum CanonicalJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

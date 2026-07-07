import Foundation

/// Wire-protocol constants. See docs/protocol.md; changes here are network-visible
/// and MUST be reflected there in the same PR (repo convention, spec §10).
public enum ProtocolConstants {
    /// Protocol version carried in every envelope. Frozen shape; see spec §6.
    public static let version = "0.2"

    /// Bonjour / Wi-Fi Aware service type for the app-to-app channel (spec §5.3).
    /// Registered name placeholder pending final product naming.
    public static let serviceType = "_cndt-app._tcp"

    /// Maximum encoded size of a control (JSON) frame payload.
    public static let maxControlPayload = 1 << 20 // 1 MiB

    /// Fixed binary header size of a file-chunk frame payload (uuid 16 + seq 8 + flags 1).
    public static let chunkHeaderSize = 25

    /// Maximum size of the data portion of a single file chunk.
    public static let maxChunkData = 2 << 20 // 2 MiB

    /// Default chunk size used by the file capability (also carried in FILE_OFFER).
    public static let defaultChunkSize: UInt32 = 512 * 1024

    /// TXT record keys used in Bonjour advertisements.
    public enum TXTKey {
        public static let deviceID = "id"
        public static let name = "nm"
        public static let deviceClass = "cl"
        public static let version = "v"
    }
}

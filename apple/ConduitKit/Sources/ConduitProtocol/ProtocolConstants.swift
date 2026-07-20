import Foundation

/// Wire-protocol constants. See docs/protocol.md; changes here are network-visible
/// and MUST be reflected there in the same PR (repo convention, spec §10).
public enum ProtocolConstants {
    /// Protocol version carried in every envelope. Frozen shape; see spec §6.
    public static let version = "0.2"

    // NOTE: the Bonjour service type is deliberately NOT defined here.
    //
    // There used to be a `serviceType` constant in this enum carrying a large
    // DO-NOT-RENAME warning — on a string that nothing referenced. The live
    // constant is `ProtocolServiceType.appService` in ConduitTransport, which is
    // what the browser and the advertiser actually use. Two copies of a
    // compatibility-boundary string, with the documentation attached to the dead
    // one, is precisely the shape of the bug the warning was trying to prevent:
    // rename the documented constant and nothing changes; rename the real one
    // and discovery breaks with no warning in sight.
    //
    // The transport module owns it (see the comment on `ProtocolServiceType`),
    // so this module has no business holding a second copy.

    /// Maximum encoded size of a control (JSON) frame payload.
    public static let maxControlPayload = 1 << 20 // 1 MiB

    /// Fixed binary header size of a file-chunk frame payload (uuid 16 + seq 8 + flags 1).
    public static let chunkHeaderSize = 25

    /// Maximum size of the data portion of a single file chunk.
    public static let maxChunkData = 2 << 20 // 2 MiB

    /// Default chunk size used by the file capability (also carried in FILE_OFFER).
    public static let defaultChunkSize: UInt32 = 512 * 1024

    /// Fixed binary header of a screen-frame payload:
    /// sessionId u16 + seq u32 + flags u8 + ptsMillis u64 = 15 bytes.
    public static let screenFrameHeaderSize = 15

    /// Max encoded size of a single screen frame's data. A 1080p HEVC keyframe
    /// is well under this; 4 MiB leaves headroom without inviting abuse.
    public static let maxScreenFrameData = 4 << 20

    /// TXT record keys used in Bonjour advertisements.
    public enum TXTKey {
        public static let deviceID = "id"
        public static let name = "nm"
        public static let deviceClass = "cl"
        public static let version = "v"
    }
}

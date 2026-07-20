import Foundation

/// Wire-protocol constants. See docs/protocol.md; changes here are network-visible
/// and MUST be reflected there in the same PR (repo convention, spec §10).
public enum ProtocolConstants {
    /// Protocol version carried in every envelope. Frozen shape; see spec §6.
    public static let version = "0.2"

    /// Bonjour / Wi-Fi Aware service type for the app-to-app channel (spec §5.3).
    ///
    /// DO NOT rename this to `_mosis-*` on its own. It is a compatibility
    /// boundary, not cosmetics: a device running a build that advertises and
    /// browses a different service type is invisible to every other device, so
    /// discovery — and therefore reconnection of already-paired peers — breaks
    /// until *every* device in the fleet is reinstalled simultaneously. This was
    /// tried, and it broke pairing.
    ///
    /// It belongs to the same one-time pre-publication break as the
    /// `conduit-*-v1` crypto domain strings (frozen into the golden vectors),
    /// the Keychain service in IdentityStore, and the Application Support
    /// directory that holds peers.json. Those four move together, once, with a
    /// planned reinstall + re-pair — never piecemeal.
    /// See plans/01-rename-to-mosis.md.
    public static let serviceType = "_cndt-app._tcp"

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

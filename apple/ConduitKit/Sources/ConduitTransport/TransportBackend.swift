import Foundation
import Network

/// Which backend carried a connection. Surfaced in the stats overlay (spec §8).
public enum TransportBackendKind: String, Sendable {
    case lan = "LAN"
    case aware = "AWARE"
}

public struct ServiceDescriptor: Sendable {
    public var type: String
    public var name: String
    public var txt: [String: String]

    public init(type: String, name: String, txt: [String: String]) {
        self.type = type
        self.name = name
        self.txt = txt
    }
}

/// A peer found by discovery, labeled with its TXT record so the UI can show
/// known peers before connecting (spec §9 Phase 1 step 3).
public struct DiscoveredEndpoint: @unchecked Sendable, Identifiable, Equatable {
    /// NWEndpoint is an immutable value; @unchecked is safe.
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let txt: [String: String]

    public var id: String { serviceName }

    public init(endpoint: NWEndpoint, serviceName: String, txt: [String: String]) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.txt = txt
    }
}

public enum TransportError: Error {
    case backendUnavailable(String)
    case connectFailed(String)
    case connectionClosed
    case timeout
    case tlsIdentityUnavailable(String)
    case listenerFailed(String)
}

/// One authenticated byte stream between two devices. TLS is mandatory on the
/// LAN path in all builds (spec §7 invariant); there is no plaintext variant.
public protocol ByteStreamConnection: AnyObject, Sendable {
    /// Raw received byte segments, in order. Single consumer.
    var incoming: AsyncThrowingStream<Data, Error> { get }
    /// SHA-256 of the peer's TLS public key (X9.63), extracted from the handshake.
    var peerTLSKeyHash: Data? { get }
    var backendKind: TransportBackendKind { get }
    var remoteDescription: String { get }
    /// The peer's address, when the backend can name one (used to reach the
    /// peer's listener for the bulk lane). Nil on backends without addresses.
    var remoteHost: String? { get }
    func send(_ data: Data) async throws
    func close()
}

/// The transport abstraction (spec §5.3): one interface, two backends.
/// LAN is universal and always on; Aware is an accelerator, never a dependency.
public protocol TransportBackend: AnyObject, Sendable {
    var kind: TransportBackendKind { get }

    /// Starts the listener. Returns the bound port and the stream of inbound connections.
    func start() async throws -> (port: UInt16, inbound: AsyncStream<any ByteStreamConnection>)

    func advertise(_ service: ServiceDescriptor) throws
    func stopAdvertising()

    /// Emits full snapshots of currently visible endpoints whenever the set changes.
    func browse() -> AsyncStream<[DiscoveredEndpoint]>
    func stopBrowsing()

    func connect(to endpoint: DiscoveredEndpoint, policy: TLSVerifyPolicy) async throws -> any ByteStreamConnection
    func connect(host: String, port: UInt16, policy: TLSVerifyPolicy) async throws -> any ByteStreamConnection

    func shutdown()
}

/// Compile-time feature flags (spec §12 risk 2: everything Aware-specific is
/// feature-flagged until the entitlement lands).
public enum ConduitFeatureFlags {
    /// Wi-Fi Aware requires the com.apple.developer.wifi-aware entitlement,
    /// which requires a real App ID. Not yet requested — see docs/adr/0003.
    public static let wifiAwareEnabled = false
}

/// Minimal lock box for state shared with synchronous Network.framework callbacks.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    public func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

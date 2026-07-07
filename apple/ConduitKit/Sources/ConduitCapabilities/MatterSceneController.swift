import Foundation

/// Matter scene control (spec §9 Phase 7 step 2: "Matter appears here and only
/// here"). A RoutineAction.matterScene(handle:) routes here to recall a scene on
/// an already-commissioned Matter device via the platform's home graph — e.g.
/// "Office profile on → desk lamp scene A".
///
/// Matter is a home CONTROL plane, never a Conduit transport (spec §3). Scene
/// commissioning is its own project (spec pitfall); this starts from
/// already-commissioned devices in the home graph.
public protocol MatterSceneActivating: Sendable {
    /// Recall a scene by its home-graph handle. Returns success.
    func recallScene(handle: String) async -> Bool
    /// Whether Matter control is available on this platform/build.
    var isAvailable: Bool { get }
}

/// No-op used where Matter isn't linked (tests, non-Matter builds).
public struct NoMatterScenes: MatterSceneActivating {
    public init() {}
    public var isAvailable: Bool { false }
    public func recallScene(handle: String) async -> Bool { false }
}

// Gated behind an explicit build flag as well as canImport, because the Matter
// framework is present on Apple platforms but its generated Scenes-cluster class
// names shift across SDK versions. The generic invokeCommand path used here is
// stable, but the whole thing needs a commissioned Matter home to validate, so
// the default build excludes it (set CONDUIT_MATTER_SCENES to enable).
#if canImport(Matter) && CONDUIT_MATTER_SCENES
import Matter

/// Real Matter framework backend. The handle encodes node id + endpoint + scene
/// id ("<nodeID>/<endpoint>/<sceneID>") from the platform home graph. Recalls a
/// scene via the stable generic invoke (Scenes cluster 0x0005, RecallScene 0x05)
/// rather than a version-specific generated cluster class (docs/adr/0013).
public final class MatterSceneController: MatterSceneActivating, @unchecked Sendable {
    private let controller: MTRDeviceController

    public init(controller: MTRDeviceController) {
        self.controller = controller
    }

    public var isAvailable: Bool { true }

    public func recallScene(handle: String) async -> Bool {
        let parts = handle.split(separator: "/")
        guard parts.count == 3,
              let nodeID = UInt64(parts[0]), let endpoint = UInt16(parts[1]), let sceneID = UInt8(parts[2])
        else { return false }

        let device = MTRBaseDevice(nodeID: NSNumber(value: nodeID), controller: controller)
        let fields: [String: Any] = [
            "type": "Structure",
            "value": [
                ["contextTag": 0, "data": ["type": "UnsignedInteger", "value": 0]],        // GroupID
                ["contextTag": 1, "data": ["type": "UnsignedInteger", "value": sceneID]],  // SceneID
            ],
        ]
        return await withCheckedContinuation { continuation in
            device.invokeCommand(
                withEndpointID: NSNumber(value: endpoint),
                clusterID: NSNumber(value: 0x0005),   // Scenes
                commandID: NSNumber(value: 0x05),     // RecallScene
                commandFields: fields, timedInvokeTimeout: nil, queue: DispatchQueue.main
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
#endif

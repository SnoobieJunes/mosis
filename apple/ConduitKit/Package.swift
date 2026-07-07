// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ConduitKit",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
    products: [
        .library(name: "ConduitProtocol", targets: ["ConduitProtocol"]),
        .library(name: "ConduitTransport", targets: ["ConduitTransport"]),
        .library(name: "ConduitSession", targets: ["ConduitSession"]),
        .library(name: "ConduitCapabilities", targets: ["ConduitCapabilities"]),
        .library(name: "ConduitUI", targets: ["ConduitUI"]),
        .executable(name: "conduit-vectorgen", targets: ["conduit-vectorgen"]),
        .executable(name: "conduit-devnode", targets: ["conduit-devnode"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ConduitProtocol"),
        .target(
            name: "ConduitTransport",
            dependencies: [
                .product(name: "X509", package: "swift-certificates")
            ]
        ),
        .target(name: "ConduitSession", dependencies: ["ConduitProtocol", "ConduitTransport"]),
        .target(name: "ConduitCapabilities", dependencies: ["ConduitProtocol", "ConduitSession", "ConduitTransport"]),
        .target(name: "ConduitUI", dependencies: ["ConduitProtocol", "ConduitTransport", "ConduitSession", "ConduitCapabilities"]),
        .executableTarget(name: "conduit-vectorgen", dependencies: ["ConduitProtocol", "ConduitSession"]),
        // Headless node for cross-process / real-LAN debugging (see docs/DEVICE_CHECKLIST.md).
        .executableTarget(
            name: "conduit-devnode",
            dependencies: ["ConduitProtocol", "ConduitSession", "ConduitTransport", "ConduitCapabilities"]
        ),
        .target(name: "ConduitTestSupport", dependencies: ["ConduitTransport"], path: "Tests/ConduitTestSupport"),
        .testTarget(name: "ConduitProtocolTests", dependencies: ["ConduitProtocol"]),
        .testTarget(name: "ConduitSessionTests", dependencies: ["ConduitSession", "ConduitProtocol", "ConduitTransport", "ConduitTestSupport"]),
        .testTarget(name: "ConduitTransportTests", dependencies: ["ConduitTransport"]),
        .testTarget(name: "ConduitCapabilitiesTests", dependencies: ["ConduitCapabilities", "ConduitTestSupport"]),
        .testTarget(name: "ConduitE2ETests", dependencies: ["ConduitProtocol", "ConduitTransport", "ConduitSession", "ConduitCapabilities"]),
    ],
    swiftLanguageModes: [.v6]
)

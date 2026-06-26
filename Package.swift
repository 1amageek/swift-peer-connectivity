// swift-tools-version: 6.2

import PackageDescription

// Embedded toggle controls the experimental Embedded feature + WMO for the
// Embedded-clean core(s). Lifetimes is enabled in BOTH modes because the
// P2PCoreBytes/LibP2PCore dependency surface requires @_lifetime for its
// Span-returning members. Mirrors the swift-libp2p `embedded` branch wiring.
let embeddedEnabled = Context.environment["P2P_CORE_EMBEDDED"] == "1"

let coreSettings: [SwiftSetting] = {
    var s: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]
    if embeddedEnabled {
        s += [.enableExperimentalFeature("Embedded"), .unsafeFlags(["-wmo"])]
    }
    return s
}()

let package = Package(
    name: "swift-peer-connectivity",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "PeerConnectivityCore", targets: ["PeerConnectivityCore"]),
        .library(name: "PeerConnectivity", targets: ["PeerConnectivity"]),
        .library(name: "PeerConnectivityLibP2P", targets: ["PeerConnectivityLibP2P"]),
        .library(name: "PeerConnectivityMultipeer", targets: ["PeerConnectivityMultipeer"]),
        .library(name: "PeerConnectivityNetwork", targets: ["PeerConnectivityNetwork"]),
        .library(name: "PeerConnectivityBonjour", targets: ["PeerConnectivityBonjour"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-libp2p.git", from: "0.2.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
    ],
    targets: [
        // Embedded-clean value-type wire codec (dual-build: host + Embedded).
        // No Foundation, no NIO, no `any`, no Mutex/ContinuousClock/key paths.
        // Owns the resource-transfer header framing (`"<name>\0<size>\0"`) over
        // `[UInt8]`; the async stream loop / file I/O / chunk transfer stay in
        // the `PeerConnectivityLibP2P` adapter.
        .target(
            name: "PeerConnectivityCore",
            dependencies: [],
            exclude: ["CONTEXT.md"],
            swiftSettings: coreSettings
        ),
        .target(
            name: "PeerConnectivity",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "PeerConnectivityLibP2P",
            dependencies: [
                "PeerConnectivity",
                "PeerConnectivityCore",
                "PeerConnectivityNetwork",
                "PeerConnectivityBonjour",
                .product(name: "P2P", package: "swift-libp2p"),
                .product(name: "P2PCore", package: "swift-libp2p"),
                .product(name: "P2PDiscovery", package: "swift-libp2p"),
                .product(name: "P2PMux", package: "swift-libp2p"),
                .product(name: "P2PMuxYamux", package: "swift-libp2p"),
                .product(name: "P2PSecurityNoise", package: "swift-libp2p"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "PeerConnectivityMultipeer",
            dependencies: [
                "PeerConnectivity",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "PeerConnectivityNetwork",
            dependencies: [
                .product(name: "P2PTransport", package: "swift-libp2p"),
                .product(name: "P2PCore", package: "swift-libp2p"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "PeerConnectivityBonjour",
            dependencies: [
                .product(name: "P2PDiscovery", package: "swift-libp2p"),
                .product(name: "P2PCore", package: "swift-libp2p"),
            ]
        ),
        .testTarget(
            name: "PeerConnectivityTests",
            dependencies: [
                "PeerConnectivity",
                "PeerConnectivityLibP2P",
                "PeerConnectivityMultipeer",
                .product(name: "P2P", package: "swift-libp2p"),
                .product(name: "P2PCore", package: "swift-libp2p"),
                .product(name: "P2PTransportTCP", package: "swift-libp2p"),
                .product(name: "P2PTransportMemory", package: "swift-libp2p"),
                .product(name: "P2PSecurityPlaintext", package: "swift-libp2p"),
                .product(name: "P2PSecurityNoise", package: "swift-libp2p"),
                .product(name: "P2PMuxYamux", package: "swift-libp2p"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PeerConnectivityNetworkTests",
            dependencies: [
                "PeerConnectivityNetwork",
                .product(name: "P2PCore", package: "swift-libp2p"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PeerConnectivityBonjourTests",
            dependencies: [
                "PeerConnectivityBonjour",
                .product(name: "P2PCore", package: "swift-libp2p"),
            ]
        ),
    ]
)

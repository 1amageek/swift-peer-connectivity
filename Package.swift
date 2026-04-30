// swift-tools-version: 6.2

import PackageDescription

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
        .library(name: "PeerConnectivity", targets: ["PeerConnectivity"]),
        .library(name: "PeerConnectivityLibP2P", targets: ["PeerConnectivityLibP2P"]),
        .library(name: "PeerConnectivityMultipeer", targets: ["PeerConnectivityMultipeer"]),
        .library(name: "PeerConnectivityNetwork", targets: ["PeerConnectivityNetwork"]),
        .library(name: "PeerConnectivityBonjour", targets: ["PeerConnectivityBonjour"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-libp2p.git", from: "0.1.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
    ],
    targets: [
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
                "PeerConnectivityNetwork",
                "PeerConnectivityBonjour",
                .product(name: "P2P", package: "swift-libp2p"),
                .product(name: "P2PCore", package: "swift-libp2p"),
                .product(name: "P2PDiscovery", package: "swift-libp2p"),
                .product(name: "P2PMux", package: "swift-libp2p"),
                .product(name: "P2PMuxYamux", package: "swift-libp2p"),
                .product(name: "P2PSecurityNoise", package: "swift-libp2p"),
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

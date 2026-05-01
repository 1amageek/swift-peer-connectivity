// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    dependencies: [
        .package(name: "swift-peer-connectivity", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Chat",
            dependencies: [
                .product(name: "PeerConnectivity", package: "swift-peer-connectivity"),
                .product(name: "PeerConnectivityMultipeer", package: "swift-peer-connectivity"),
            ]
        ),
    ]
)

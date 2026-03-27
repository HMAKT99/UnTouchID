// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TouchBridgeProtocol",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TouchBridgeProtocol", targets: ["TouchBridgeProtocol"]),
    ],
    targets: [
        .target(name: "TouchBridgeProtocol"),
        .testTarget(
            name: "TouchBridgeProtocolTests",
            dependencies: ["TouchBridgeProtocol"]
        ),
    ]
)

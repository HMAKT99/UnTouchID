// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TouchBridgeDaemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "touchbridged", targets: ["touchbridged"]),
        .executable(name: "touchbridge-test", targets: ["touchbridge-test"]),
        .executable(name: "touchbridge-nmh", targets: ["touchbridge-nmh"]),
        .library(name: "TouchBridgeCore", targets: ["TouchBridgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(path: "../protocol"),
    ],
    targets: [
        .target(
            name: "TouchBridgeCore",
            dependencies: [
                .product(name: "TouchBridgeProtocol", package: "protocol"),
            ]
        ),
        .executableTarget(
            name: "touchbridged",
            dependencies: [
                "TouchBridgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "touchbridge-test",
            dependencies: [
                "TouchBridgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "touchbridge-nmh",
            dependencies: ["TouchBridgeCore"]
        ),
        .testTarget(
            name: "TouchBridgeCoreTests",
            dependencies: ["TouchBridgeCore"]
        ),
    ]
)

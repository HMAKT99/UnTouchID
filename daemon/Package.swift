// swift-tools-version: 5.9

import PackageDescription
import Foundation

// Resolves to the directory containing this Package.swift, regardless of the
// working directory `swift build` is invoked from — needed for the
// -sectcreate __info_plist linker flags below.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

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
            ],
            linkerSettings: [
                // Embeds an Info.plist so CoreBluetooth can find
                // NSBluetoothAlwaysUsageDescription — without it macOS silently
                // denies Bluetooth authorization for plain SwiftPM executables.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Sources/touchbridged/Supporting/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "touchbridge-test",
            dependencies: [
                "TouchBridgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Sources/touchbridge-test/Supporting/Info.plist",
                ])
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

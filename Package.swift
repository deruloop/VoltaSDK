// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoltaSDK",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        // The core: no UI dependency, configurable headless.
        .library(name: "VoltaSDK", targets: ["VoltaSDK"]),
        // Optional SwiftUI components: apps can ignore them entirely.
        .library(name: "VoltaSDKUI", targets: ["VoltaSDKUI"]),
        // Demo UI, shared between macOS and iOS (Examples/iOSDemo).
        .library(name: "VoltaSDKDemoUI", targets: ["VoltaSDKDemoUI"]),
        // Test app (macOS): `swift run VoltaSDKDemo`.
        .executable(name: "VoltaSDKDemo", targets: ["VoltaSDKDemo"])
    ],
    targets: [
        .target(name: "VoltaSDK"),
        .target(
            name: "VoltaSDKUI",
            dependencies: ["VoltaSDK"]
        ),
        .target(
            name: "VoltaSDKDemoUI",
            dependencies: ["VoltaSDK", "VoltaSDKUI"]
        ),
        .executableTarget(
            name: "VoltaSDKDemo",
            dependencies: ["VoltaSDKDemoUI"]
        ),
        .testTarget(
            name: "VoltaSDKTests",
            dependencies: ["VoltaSDK"]
        )
    ]
)

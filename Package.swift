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
        // Demo UI, shared between the iOS and macOS demo apps
        // (Examples/iOSDemo, Examples/macOSDemo).
        .library(name: "VoltaSDKDemoUI", targets: ["VoltaSDKDemoUI"])
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
        .testTarget(
            name: "VoltaSDKTests",
            dependencies: ["VoltaSDK"]
        )
    ]
)

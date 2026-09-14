// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoltaSDK",
    // Floor iOS 18 / macOS 15 (D19): the package INSTALLS in apps deploying
    // to 18+, and each capability tier is @available-gated — the cloud chain,
    // streaming, needs, and the UI kit work from 18; on-device joins at 26;
    // PCC, the front door, and the profiles bridge at 27. 18 is the hard
    // minimum: the core uses Synchronization.Mutex (iOS 18+).
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // The core: no UI dependency, configurable headless.
        .library(name: "VoltaSDK", targets: ["VoltaSDK"]),
        // Optional SwiftUI components: apps can ignore them entirely.
        .library(name: "VoltaSDKUI", targets: ["VoltaSDKUI"]),
        // Demo UI, shared between the iOS and macOS demo apps
        // (Examples/iOSDemo, Examples/macOSDemo).
        .library(name: "VoltaSDKDemoUI", targets: ["VoltaSDKDemoUI"]),
        // Optional OAuth automation for user-account providers (iOS 27). Uses
        // AuthenticationServices/Keychain, so it's separate from the headless
        // core: apps that want managed sign-in add this; others ignore it.
        .library(name: "VoltaSDKAuth", targets: ["VoltaSDKAuth"])
    ],
    targets: [
        .target(name: "VoltaSDK"),
        .target(
            name: "VoltaSDKUI",
            dependencies: ["VoltaSDK"]
        ),
        .target(
            name: "VoltaSDKAuth",
            dependencies: ["VoltaSDK"]
        ),
        .target(
            name: "VoltaSDKDemoUI",
            dependencies: ["VoltaSDK", "VoltaSDKUI"]
        ),
        .testTarget(
            name: "VoltaSDKTests",
            dependencies: ["VoltaSDK", "VoltaSDKAuth"]
        )
    ]
)

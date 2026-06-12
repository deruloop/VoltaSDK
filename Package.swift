// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIProviderKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        // Il core: nessuna dipendenza UI, configurabile headless.
        .library(name: "AIProviderKit", targets: ["AIProviderKit"]),
        // Componenti SwiftUI opzionali: l'app può ignorarli del tutto.
        .library(name: "AIProviderKitUI", targets: ["AIProviderKitUI"]),
        // UI della demo, condivisa tra macOS e iOS (Examples/iOSDemo).
        .library(name: "AIProviderKitDemoUI", targets: ["AIProviderKitDemoUI"]),
        // App di prova (macOS): `swift run AIProviderKitDemo`.
        .executable(name: "AIProviderKitDemo", targets: ["AIProviderKitDemo"])
    ],
    targets: [
        .target(name: "AIProviderKit"),
        .target(
            name: "AIProviderKitUI",
            dependencies: ["AIProviderKit"]
        ),
        .target(
            name: "AIProviderKitDemoUI",
            dependencies: ["AIProviderKit", "AIProviderKitUI"]
        ),
        .executableTarget(
            name: "AIProviderKitDemo",
            dependencies: ["AIProviderKitDemoUI"]
        ),
        .testTarget(
            name: "AIProviderKitTests",
            dependencies: ["AIProviderKit"]
        )
    ]
)

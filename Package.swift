// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIUsageBarCore", targets: ["AIUsageBarCore"]),
        .executable(name: "AIUsageBar", targets: ["AIUsageBarApp"]),
    ],
    targets: [
        .target(
            name: "AIUsageBarCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "AIUsageBarApp",
            dependencies: ["AIUsageBarCore"]
        ),
        .executableTarget(
            name: "AIUsageBarCoreTests",
            dependencies: ["AIUsageBarCore"],
            path: "Sources/AIUsageBarCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)

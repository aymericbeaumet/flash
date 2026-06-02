// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Flash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flash", targets: ["flash"]),
        .library(name: "FlashCore", targets: ["FlashCore"]),
        .library(name: "FlashProviders", targets: ["FlashProviders"]),
    ],
    targets: [
        .executableTarget(
            name: "flash",
            dependencies: ["FlashCore", "FlashProviders"],
            path: "Sources/flash"
        ),
        .target(
            name: "FlashCore",
            path: "Sources/FlashCore"
        ),
        .target(
            name: "FlashProviders",
            dependencies: ["FlashCore"],
            path: "Sources/FlashProviders"
        ),
        .testTarget(
            name: "FlashTests",
            dependencies: ["flash", "FlashCore", "FlashProviders"],
            path: "Tests/FlashTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)

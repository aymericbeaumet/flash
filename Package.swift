// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "Flash",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "flash", targets: ["flash"]),
    .executable(name: "flash-vimium-oracle", targets: ["flash-vimium-oracle"]),
    .library(name: "FlashCore", targets: ["FlashCore"]),
    .library(name: "FlashProviders", targets: ["FlashProviders"]),
    .library(name: "FlashE2EKit", targets: ["FlashE2EKit"]),
  ],
  targets: [
    .executableTarget(
      name: "flash",
      dependencies: ["FlashCore", "FlashProviders"],
      path: "Sources/flash"
    ),
    .executableTarget(
      name: "flash-vimium-oracle",
      dependencies: ["FlashCore", "FlashProviders", "FlashE2EKit"],
      path: "Sources/flash-vimium-oracle"
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
    .target(
      name: "FlashE2EKit",
      dependencies: ["FlashCore", "FlashProviders"],
      path: "Sources/FlashE2EKit",
      resources: [.copy("Snapshots")]
    ),
    .testTarget(
      name: "FlashTests",
      dependencies: ["flash", "FlashCore", "FlashProviders", "FlashE2EKit"],
      path: "Tests/FlashTests"
    ),
  ],
  swiftLanguageVersions: [.v5]
)

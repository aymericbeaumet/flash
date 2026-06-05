// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "Flash",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "flash", targets: ["flash"]),
    .executable(name: "flashctl", targets: ["flashctl"]),
    .executable(name: "flash-vimium-oracle", targets: ["flash-vimium-oracle"]),
    .executable(name: "flash-native-fixture", targets: ["flash-native-fixture"]),
    .executable(name: "flash-native-oracle", targets: ["flash-native-oracle"]),
    .executable(name: "flash-electron-oracle", targets: ["flash-electron-oracle"]),
    .library(name: "FlashCore", targets: ["FlashCore"]),
    .library(name: "FlashProviders", targets: ["FlashProviders"]),
    .library(name: "FlashIntegrationTestSupport", targets: ["FlashIntegrationTestSupport"]),
    .library(name: "FlashBrowserTestSupport", targets: ["FlashBrowserTestSupport"]),
  ],
  targets: [
    .executableTarget(
      name: "flash",
      dependencies: ["FlashCore", "FlashProviders"],
      path: "Sources/flash"
    ),
    .executableTarget(
      name: "flashctl",
      path: "Sources/flashctl"
    ),
    .executableTarget(
      name: "flash-vimium-oracle",
      dependencies: [
        "FlashCore", "FlashProviders", "FlashIntegrationTestSupport",
        "FlashBrowserTestSupport",
      ],
      path: "Sources/flash-vimium-oracle"
    ),
    .executableTarget(
      name: "flash-native-fixture",
      path: "Sources/flash-native-fixture"
    ),
    .executableTarget(
      name: "flash-native-oracle",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/flash-native-oracle"
    ),
    .executableTarget(
      name: "flash-electron-oracle",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/flash-electron-oracle"
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
      name: "FlashIntegrationTestSupport",
      dependencies: ["FlashCore", "FlashProviders"],
      path: "Sources/FlashIntegrationTestSupport"
    ),
    .target(
      name: "FlashBrowserTestSupport",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/FlashBrowserTestSupport"
    ),
    .testTarget(
      name: "FlashTests",
      dependencies: [
        "flash", "FlashCore", "FlashProviders", "FlashIntegrationTestSupport",
        "FlashBrowserTestSupport",
      ],
      path: "Tests/FlashTests"
    ),
  ],
  swiftLanguageVersions: [.v5]
)

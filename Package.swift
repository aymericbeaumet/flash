// swift-tools-version: 5.10
import PackageDescription

// Project-wide swift compiler flags.
//
// - `-warnings-as-errors` forces fresh code to compile cleanly; we don't
//   want to ship master with a backlog of "soft" warnings that mask real
//   regressions when something genuinely starts misbehaving.
// - The upcoming-feature flags walk the codebase a few Swift-evolution
//   defaults early so the Swift-6 transition is a no-op: existential-any
//   syntax stays explicit, integer-literal narrowing is rejected at
//   compile time, and importing a module no longer re-exports its own
//   imports by accident.
let strictSwiftSettings: [SwiftSetting] = [
  .unsafeFlags(["-warnings-as-errors"]),
  .enableUpcomingFeature("ForwardTrailingClosures"),
  .enableUpcomingFeature("ConciseMagicFile"),
  .enableUpcomingFeature("BareSlashRegexLiterals"),
  .enableUpcomingFeature("DeprecateApplicationMain"),
  .enableUpcomingFeature("ImportObjcForwardDeclarations"),
  .enableUpcomingFeature("DisableOutwardActorInference"),
]

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
    .library(name: "FlashSearch", targets: ["FlashSearch"]),
    .library(name: "FlashIntegrationTestSupport", targets: ["FlashIntegrationTestSupport"]),
    .library(name: "FlashBrowserTestSupport", targets: ["FlashBrowserTestSupport"]),
  ],
  dependencies: [
    // Repo's first external dependency. GRDB is used only as a thin
    // facade around the system SQLite (DatabasePool + DatabaseMigrator
    // + Row decoding); all FTS/storage SQL is hand-written so a future
    // GRDB major bump is a trivial swap. Floor `6.29.0` keeps us on
    // the most-recent 6.x line while remaining compatible with the
    // tools-5.10 root manifest — a Swift 6 toolchain can consume 7.x
    // too if a maintainer raises the floor later.
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
  ],
  targets: [
    .executableTarget(
      name: "flash",
      dependencies: ["FlashCore", "FlashProviders", "FlashSearch"],
      path: "Sources/flash",
      resources: [.copy("Resources/inspector.html")],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "flashctl",
      path: "Sources/flashctl",
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "flash-vimium-oracle",
      dependencies: [
        "FlashCore", "FlashProviders", "FlashIntegrationTestSupport",
        "FlashBrowserTestSupport",
      ],
      path: "Sources/flash-vimium-oracle",
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "flash-native-fixture",
      path: "Sources/flash-native-fixture",
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "flash-native-oracle",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/flash-native-oracle",
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "flash-electron-oracle",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/flash-electron-oracle",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "FlashCore",
      path: "Sources/FlashCore",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "FlashProviders",
      dependencies: ["FlashCore"],
      path: "Sources/FlashProviders",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "FlashSearch",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "Sources/FlashSearch",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "FlashIntegrationTestSupport",
      dependencies: ["FlashCore", "FlashProviders"],
      path: "Sources/FlashIntegrationTestSupport",
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "FlashBrowserTestSupport",
      dependencies: ["FlashCore", "FlashProviders", "FlashIntegrationTestSupport"],
      path: "Sources/FlashBrowserTestSupport",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "FlashTests",
      dependencies: [
        "flash", "FlashCore", "FlashProviders", "FlashSearch",
        "FlashIntegrationTestSupport", "FlashBrowserTestSupport",
      ],
      path: "Tests/FlashTests",
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "FlashSearchTests",
      dependencies: ["FlashSearch"],
      path: "Tests/FlashSearchTests",
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageVersions: [.v5]
)

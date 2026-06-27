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
    .executable(name: "flash-vimium-oracle", targets: ["flash-vimium-oracle"]),
    .executable(name: "flash-native-fixture", targets: ["flash-native-fixture"]),
    .executable(name: "flash-native-oracle", targets: ["flash-native-oracle"]),
    .executable(name: "flash-electron-oracle", targets: ["flash-electron-oracle"]),
    .library(name: "FlashCore", targets: ["FlashCore"]),
    .library(name: "FlashProviders", targets: ["FlashProviders"]),
    .library(name: "FlashIntegrationTestSupport", targets: ["FlashIntegrationTestSupport"]),
    .library(name: "FlashBrowserTestSupport", targets: ["FlashBrowserTestSupport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    .package(url: "https://github.com/a2/MessagePack.swift", from: "4.0.0"),
    // Apple's cmark-gfm wrapper. Used to parse `:help`, `:mappings`,
    // `:plugins`, and plugin toasts as CommonMark + GFM and render
    // them into the modal text view as styled `NSAttributedString`s.
    .package(url: "https://github.com/apple/swift-markdown.git", from: "0.8.0"),
  ],
  targets: [
    .executableTarget(
      name: "flash",
      dependencies: [
        "FlashCore", "FlashProviders",
        .product(name: "TOMLKit", package: "TOMLKit"),
        .product(name: "Markdown", package: "swift-markdown"),
      ],
      path: "Sources/flash",
      resources: [.copy("Resources/inspector.html")],
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
      dependencies: [
        .product(name: "MessagePack", package: "MessagePack.swift")
      ],
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
        "flash", "FlashCore", "FlashProviders",
        "FlashIntegrationTestSupport", "FlashBrowserTestSupport",
      ],
      path: "Tests/FlashTests",
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageVersions: [.v5]
)

import FlashCore
import Foundation
import XCTest

@testable import flash

final class PluginSystemTests: XCTestCase {
  func testOfficialPluginManifestsLoadAndRegisterExpectedCommands() throws {
    let roots = try officialPluginRoots()
    let manifests = try roots.map { try PluginManifest.load(from: $0) }
    let ids = Set(manifests.map(\.id))
    XCTAssertEqual(
      ids,
      [
        "aiproviders", "calculator", "chromium", "clipboard", "contacts", "defaults",
        "emojis", "firefox", "gmail", "marks", "media", "notes", "processes", "reminders",
        "safari", "screenshot", "searchengines", "slack", "spotify", "system", "tmux",
      ])

    let runCommandRequired: Set<String> = [
      "media", "slack", "spotify",
    ]
    for manifest in manifests {
      // Bundled plugins are compiled Rust binaries: `install` is a no-op
      // and `start` exec's the embedded binary. See Scripts/build-plugins.sh.
      XCTAssertEqual(manifest.install, "true")
      XCTAssertEqual(manifest.start, "exec ./flash-plugin-\(manifest.id)")
      XCTAssertFalse(manifest.description.isEmpty)
      if runCommandRequired.contains(manifest.id) {
        XCTAssertTrue(
          manifest.commands.contains { $0.subcommand == "run" },
          "\(manifest.id) is missing the run subcommand")
      }
    }
    for root in roots {
      let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
      let object = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
      for source in object["sources"] as? [[String: Any]] ?? [] {
        XCTAssertNotNil(
          source["priority"],
          "\(root.lastPathComponent) source \(source["name"] ?? "<unnamed>") must declare priority")
      }
    }
    let tmux = try XCTUnwrap(manifests.first { $0.id == "tmux" })
    XCTAssertEqual(tmux.install, "true")
    XCTAssertEqual(tmux.start, "exec ./flash-plugin-tmux")
    XCTAssertTrue(tmux.volatile)
    XCTAssertEqual(tmux.priority, 20)
    XCTAssertTrue(tmux.onlyBundleIDs.contains("org.alacritty"))
    XCTAssertTrue(tmux.sourceActions.contains("tab_new"))
    XCTAssertTrue(tmux.sourceActions.contains("app_reload"))
    XCTAssertEqual(tmux.navigationSchemes, ["tmux"])
    XCTAssertEqual(
      tmux.candidateSourceDescriptors,
      [CandidateSourceDescriptor(name: "tmux.windows", kind: .locations, priority: .high)])
    for id in ["chromium", "firefox", "safari"] {
      let manifest = try XCTUnwrap(manifests.first { $0.id == id })
      XCTAssertFalse(manifest.candidateSourceDescriptors.isEmpty)
      XCTAssertTrue(
        manifest.candidateSourceDescriptors.allSatisfy { $0.kind == .locations },
        "\(id) must classify tab sources as locations")
      XCTAssertTrue(
        manifest.candidateSourceDescriptors.allSatisfy { $0.priority == .high },
        "\(id) must rank tab sources as high-priority locations")
    }
    let slack = try XCTUnwrap(manifests.first { $0.id == "slack" })
    XCTAssertEqual(
      slack.candidateSourceDescriptors,
      [CandidateSourceDescriptor(name: "slack.channels", kind: .locations, priority: .high)])
    let defaults = try XCTUnwrap(manifests.first { $0.id == "defaults" })
    XCTAssertEqual(
      Set(defaults.verbs.map(\.name)),
      ["app_save", "app_print", "document_open", "window_new"])

    let gmail = try XCTUnwrap(manifests.first { $0.id == "gmail" })
    XCTAssertEqual(gmail.priority, 60)
    XCTAssertEqual(gmail.capabilities, [.accessibility, .appControl])
    XCTAssertEqual(gmail.onlyURLs, ["https://mail.google.com/*"])
    XCTAssertEqual(gmail.sourceActions, ["resource_archive", "resource_next", "resource_previous"])
    XCTAssertEqual(
      gmail.commands.map { "\($0.command) \($0.subcommand)" },
      [
        "gmail inbox", "gmail starred", "gmail snoozed", "gmail sent", "gmail drafts",
        "gmail all", "gmail tasks", "gmail label",
      ])
    XCTAssertEqual(gmail.mappings.count, 11)
    XCTAssertEqual(
      Set(gmail.mappings.map(\.key)),
      ["gi", "gs", "gb", "gt", "gd", "ga", "gk", "gl", "gn", "gp", "o"])
    let expectedGmailMappings = [
      "gi": "inbox",
      "gs": "starred",
      "gb": "snoozed",
      "gt": "sent",
      "gd": "drafts",
      "ga": "all",
      "gk": "tasks",
      "gl": "label",
    ]
    for (key, subcommand) in expectedGmailMappings {
      XCTAssertEqual(
        gmail.mappings.first { $0.key == key }?.command,
        ["flash", "plugin_command", "--command=gmail", "--subcommand=\(subcommand)"])
    }
    XCTAssertEqual(
      gmail.mappings.first { $0.key == "gn" }?.command,
      ["flash", "history_forward"])
    XCTAssertEqual(
      gmail.mappings.first { $0.key == "gp" }?.command,
      ["flash", "history_back"])
    XCTAssertEqual(
      gmail.mappings.first { $0.key == "o" }?.command,
      ["flash", "send_key", "--keys=o"])

    XCTAssertTrue(
      commandNames(for: "spotify", manifests: manifests).isSuperset(of: [
        "login", "status", "pause", "play", "toggle", "next", "previous", "search", "run",
      ]))
    XCTAssertTrue(
      commandNames(for: "slack", manifests: manifests).isSuperset(of: [
        "login", "version", "run",
      ]))
    let system = try XCTUnwrap(manifests.first { $0.id == "system" })
    XCTAssertEqual(system.statusSegments, ["battery"])
    XCTAssertEqual(
      system.candidateSourceDescriptors,
      [CandidateSourceDescriptor(name: "system.actions", priority: .normal)])
    XCTAssertTrue(
      commandNames(for: "system", manifests: manifests).isSuperset(of: [
        "", "lock", "sleep", "displaysleep", "restart", "shutdown", "logout", "trash", "dark",
        "screensaver", "caffeinate", "decaffeinate",
      ]))

    let screenshot = try XCTUnwrap(manifests.first { $0.id == "screenshot" })
    XCTAssertEqual(
      Set(screenshot.commands.map(\.subcommand)),
      [
        "", "options", "screen", "selection", "window",
        "screen_clipboard", "selection_clipboard", "window_clipboard",
      ])
    XCTAssertEqual(
      Set(screenshot.verbs.map(\.name)),
      [
        "screenshot_options", "screenshot_screen", "screenshot_selection",
        "screenshot_window", "screenshot_screen_clipboard", "screenshot_selection_clipboard",
        "screenshot_window_clipboard",
      ])
  }

  func testClipboardManifestRegistersBrowseCommand() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "clipboard" })
    let manifest = try PluginManifest.load(from: root)
    let browse = try XCTUnwrap(
      manifest.commands.first { $0.command == "clipboard" && $0.subcommand.isEmpty },
      "clipboard plugin must register the bare `:clipboard` history command")
    XCTAssertFalse(browse.description.isEmpty)
  }

  func testDecodeClipboardModalEntriesRoundTripsPluginJSON() throws {
    // The shape the Rust clipboard plugin emits for `:clipboard`.
    let json = """
      [{"preview":"hello","value":"hello"},{"preview":"two…","value":"two lines\\nof text"}]
      """
    let entries = try XCTUnwrap(AppDelegate.decodeClipboardModalEntries(json))
    XCTAssertEqual(entries.map(\.preview), ["hello", "two…"])
    XCTAssertEqual(entries.map(\.value), ["hello", "two lines\nof text"])
  }

  func testDecodeClipboardModalEntriesAcceptsEmptyHistory() throws {
    let entries = try XCTUnwrap(AppDelegate.decodeClipboardModalEntries("[]"))
    XCTAssertTrue(entries.isEmpty)
  }

  func testDecodeClipboardModalEntriesRejectsMalformedJSON() {
    XCTAssertNil(AppDelegate.decodeClipboardModalEntries("not json"))
    XCTAssertNil(
      AppDelegate.decodeClipboardModalEntries("[{\"preview\":\"x\"}]"),
      "an entry missing the required `value` field decodes to nil")
  }

  func testOfficialPluginInstallScriptsAvoidGlobalInstallTargets() throws {
    let banned = [
      "sudo", "brew install", "npm install -g", "deno install -g", "/usr/local/bin",
      "$HOME/.local/bin", "~/.local/bin",
    ]
    // Bundled plugins are Rust binaries with no shell install step: the
    // manifest's `install`/`start` strings and the crate sources must not
    // reach for global install locations.
    for root in try officialPluginRoots() {
      let manifest = try PluginManifest.load(from: root)
      for field in [manifest.install, manifest.start] {
        for needle in banned {
          XCTAssertFalse(
            field.contains(needle), "\(root.lastPathComponent) manifest contains \(needle)")
        }
      }
      for name in ["Cargo.toml", "src/main.rs"] {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let body = try String(contentsOf: file)
        for needle in banned {
          XCTAssertFalse(
            body.contains(needle), "\(root.lastPathComponent)/\(name) contains \(needle)")
        }
      }
    }
  }

  func testOfficialPluginsRespondOverMessagePackWithMockedCLIs() throws {
    let cases = [
      ("slack", "slack"),
      ("spotify", "spotify_player"),
    ]
    for (pluginID, binary) in cases {
      try runPluginSmoke(pluginID: pluginID, binary: binary)
    }
  }

  func testRustPluginExitsWhenDeclaredParentProcessExits() throws {
    try runPluginParentDeathSmoke(pluginID: "calculator")
  }

  func testManifestRootDiscoveryFollowsSymlinkedBundleDirectory() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }

    let bundlePlugins = temp.appendingPathComponent("real/Plugins")
    let pluginRoot = bundlePlugins.appendingPathComponent("sample")
    try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "sample",
      "name": "Sample",
      "version": "0.1.0",
      "description": "Sample plugin",
      "install": "./install.sh",
      "start": "./start.sh"
    }
    """.write(
      to: pluginRoot.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)

    let linkedPlugins = temp.appendingPathComponent("app/Contents/Resources/Plugins")
    try FileManager.default.createDirectory(
      at: linkedPlugins.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedPlugins,
      withDestinationURL: bundlePlugins)

    let roots = PluginManager.manifestRoots(in: [linkedPlugins])
    XCTAssertEqual(roots.map(\.path), [pluginRoot.path])
  }

  func testManifestLoadsRequiredFields() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "npm install",
          "start": "npm start",
          "listen": [
            "core:apps.*",
            "core:config.*"
          ],
          "only_bundle_ids": ["com.spotify.client"],
          "only_urls": ["https://open.spotify.com/*"],
          "commands": {
            "items": [
              { "command": "spotify", "subcommand": "pause", "description": "Pause playback" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.start, "npm start")
    XCTAssertEqual(manifest.listen, ["core:apps.*", "core:config.*"])
    XCTAssertEqual(manifest.onlyBundleIDs, ["com.spotify.client"])
    XCTAssertEqual(manifest.onlyURLs, ["https://open.spotify.com/*"])
    XCTAssertEqual(manifest.commands.first?.command, "spotify")
    XCTAssertEqual(manifest.commands.first?.subcommand, "pause")
    XCTAssertTrue(manifest.mappings.isEmpty, "absent mappings key defaults to []")
  }

  func testManifestRejectsLegacyTopLevelKeys() throws {
    for key in ["manifest_version", "subscriptions", "bundle_ids", "candidates"] {
      let value: String
      switch key {
      case "manifest_version":
        value = "2"
      case "subscriptions":
        value = #"["core:config.*"]"#
      case "bundle_ids":
        value = #"["com.example.app"]"#
      case "candidates":
        value = #"{"sources": [{"name": "example.items"}]}"#
      default:
        value = "null"
      }
      let root = try temporaryPluginRoot(
        manifest:
          """
          {
            "id": "legacy",
            "name": "Legacy",
            "version": "0.1.0",
            "description": "Legacy key",
            "install": "true",
            "start": "true",
            "\(key)": \(value)
          }
          """)
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(try PluginManifest.load(from: root), key) { error in
        XCTAssertTrue(String(describing: error).contains("manifest.json unknown field \(key)"))
      }
    }
  }

  func testManifestDecodesMappingsWithDefaults() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "slack",
          "name": "Slack",
          "version": "0.1.0",
          "description": "Slack",
          "install": "true",
          "start": "true",
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "plugin_command", "--command=slack", "--subcommand=run"] },
              {
                "key": "ctrl+k",
                "mode": "insert",
                "command": ["flash", "hints_dismiss"],
                "only_bundle_ids": ["com.tinyspeck.slackmacgap"],
                "only_urls": ["slack://*"],
                "priority": 40
              }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.mappings.count, 2)

    let first = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(first.key, "q")
    XCTAssertEqual(first.mode, "normal", "mode defaults to normal")
    XCTAssertEqual(first.scope, .normal)
    XCTAssertTrue(first.selector.onlyBundleIDs.isEmpty, "only_bundle_ids defaults to []")
    XCTAssertNil(first.priority, "priority is optional")

    let second = manifest.mappings[1]
    XCTAssertEqual(second.mode, "insert")
    XCTAssertEqual(second.scope, .insert)
    XCTAssertEqual(second.selector.onlyBundleIDs, ["com.tinyspeck.slackmacgap"])
    XCTAssertEqual(second.selector.onlyURLs, ["slack://*"])
    XCTAssertEqual(second.priority, 40)
  }

  func testMappingRegistrationEncodeOmitsDefaults() throws {
    let mapping = PluginMappingRegistration(
      key: "q", command: ["flash", "hints_dismiss"])
    let data = try JSONEncoder().encode(mapping)
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["key"] as? String, "q")
    XCTAssertEqual(json["command"] as? [String], ["flash", "hints_dismiss"])
    XCTAssertNil(json["mode"], "default \"normal\" mode is not encoded")
    XCTAssertNil(json["only_bundle_ids"], "empty only_bundle_ids is not encoded")
    XCTAssertNil(json["only_urls"], "empty only_urls is not encoded")
    XCTAssertNil(json["priority"], "nil priority is not encoded")
  }

  func testSafariPluginOverridesHardRefreshBinding() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "safari" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.onlyBundleIDs,
      ["com.apple.Safari", "com.apple.SafariTechnologyPreview"])
    let mapping = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(manifest.mappings.count, 1)
    XCTAssertEqual(mapping.key, "R")
    XCTAssertEqual(mapping.scope, .normal)
    // Safari's "Reload Page From Origin" is ⌘⌥R, unlike the ⌘⇧R that the
    // built-in `R` → app_reload(force) default sends for Firefox/Chrome.
    XCTAssertEqual(mapping.command, ["flash", "send_key", "--keys=cmd+option+r"])
    // The mappings provider scopes itself to release Safari only (the
    // technology preview reload shortcut is different on some builds),
    // while the manifest-wide `only_bundle_ids` include the preview.
    XCTAssertEqual(mapping.selector.onlyBundleIDs, ["com.apple.Safari"])
  }

  func testManifestRejectsInvalidID() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "Spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "true",
          "start": "true"
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root))
  }

  func testManifestDecodesProviderSectionsAcrossKinds() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface in split provider sections",
          "install": "true",
          "start": "true",
          "only_bundle_ids": ["com.example.app"],
          "sources": [
            { "name": "multi.items" }
          ],
          "navigation": { "schemes": ["multi"] },
          "source_actions": ["resource_archive", "resource_next"],
          "status": { "segments": ["battery"] },
          "hints": {},
          "commands": {
            "items": [
              { "command": "multi", "subcommand": "go", "description": "Go" }
            ]
          },
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "hints_dismiss"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertTrue(manifest.providesHints)
    XCTAssertTrue(manifest.providesCandidates)
    XCTAssertEqual(manifest.candidateSources, ["multi.items"])
    XCTAssertEqual(manifest.navigationSchemes, ["multi"])
    XCTAssertEqual(manifest.sourceActions, ["resource_archive", "resource_next"])
    XCTAssertEqual(manifest.statusSegments, ["battery"])
    XCTAssertEqual(manifest.commands.map(\.subcommand), ["go"])
    XCTAssertEqual(manifest.mappings.map(\.key), ["q"])
  }

  func testPluginRegistrationInventoryCountsManifestSurfaces() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface in split provider sections",
          "install": "true",
          "start": "true",
          "listen": ["core:apps.*", "core:config.*"],
          "capabilities": ["accessibility"],
          "sources": [
            { "name": "multi.items" }
          ],
          "navigation": { "schemes": ["multi"] },
          "source_actions": ["resource_archive", "resource_next"],
          "status": { "segments": ["battery"] },
          "hints": {},
          "commands": {
            "items": [
              { "command": "multi", "subcommand": "go", "description": "Go" }
            ]
          },
          "mappings": {
            "items": [
              { "key": "q", "command": ["flash", "hints_dismiss"] }
            ]
          },
          "shebangs": {
            "command": "multi",
            "items": [
              { "token": "m", "description": "Multi" }
            ]
          },
          "verbs": {
            "command": "multi",
            "items": [
              { "name": "multi_open", "description": "Open" }
            ]
          },
          "help": {
            "topics": [
              { "name": "multi", "title": "Multi", "summary": "Multi", "body": "# Multi" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let inventory = PluginRegistrationInventory(manifests: [manifest])
    XCTAssertEqual(inventory.plugins, 1)
    XCTAssertEqual(inventory.commands, 1)
    XCTAssertEqual(inventory.mappings, 1)
    XCTAssertEqual(inventory.shebangs, 1)
    XCTAssertEqual(inventory.verbs, 1)
    XCTAssertEqual(inventory.candidateSources, 1)
    XCTAssertEqual(inventory.sourceActions, 2)
    XCTAssertEqual(inventory.statusSegments, 1)
    XCTAssertEqual(inventory.navigationSchemes, 1)
    XCTAssertEqual(inventory.helpTopics, 1)
    XCTAssertEqual(inventory.listeners, 2)
    XCTAssertEqual(inventory.hintProviders, 1)
    XCTAssertEqual(inventory.capabilityRequests, 1)
  }

  func testProvidesFlagsFalseWithoutMatchingProvider() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "cmdsonly",
          "name": "Commands Only",
          "version": "0.1.0",
          "description": "No hints, no candidates",
          "install": "true",
          "start": "true",
          "commands": {
            "items": [
              { "command": "x", "subcommand": "", "description": "X" }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertFalse(manifest.providesHints)
    XCTAssertFalse(manifest.providesCandidates)
  }

  func testCommandEntriesOwnSelectors() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "scoped",
          "name": "Scoped",
          "version": "0.1.0",
          "description": "App-scoped commands",
          "install": "true",
          "start": "true",
          "only_bundle_ids": ["com.example.app"],
          "commands": {
            "items": [
              { "command": "scoped", "subcommand": "here", "description": "Uses root scope" },
              {
                "command": "scoped",
                "subcommand": "elsewhere",
                "description": "Overrides scope",
                "only_bundle_ids": ["com.other.app"],
                "only_urls": ["https://example.com/*"]
              }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let here = try XCTUnwrap(manifest.commands.first { $0.subcommand == "here" })
    XCTAssertTrue(here.selector.onlyBundleIDs.isEmpty, "root selector is not copied into entries")
    let elsewhere = try XCTUnwrap(manifest.commands.first { $0.subcommand == "elsewhere" })
    XCTAssertEqual(elsewhere.selector.onlyBundleIDs, ["com.other.app"])
    XCTAssertEqual(elsewhere.selector.onlyURLs, ["https://example.com/*"])
  }

  func testMappingsProviderModeFoldsIntoEntries() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "moded",
          "name": "Moded",
          "version": "0.1.0",
          "description": "Provider-level mode gate",
          "install": "true",
          "start": "true",
          "mappings": {
            "modes": ["insert"],
            "items": [
              { "key": "j", "command": ["flash", "hints_dismiss"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let mapping = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(mapping.mode, "insert", "single provider mode folds into the default entry")
    XCTAssertEqual(mapping.scope, .insert)
  }

  func testShebangProviderFoldsCommandAndScope() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "banger",
          "name": "Banger",
          "version": "0.1.0",
          "description": "Flashlight bangs",
          "install": "true",
          "start": "true",
          "only_bundle_ids": ["com.example.app"],
          "shebangs": {
            "command": "search",
            "items": [
              { "token": "r", "description": "Reddit" },
              { "token": "*", "_note": "catch-all" },
              { "token": "gh", "command": "github", "only_bundle_ids": ["com.other.app"] }
            ]
          }
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(Set(manifest.shebangs.map(\.token)), ["r", "*", "gh"])
    let reddit = try XCTUnwrap(manifest.shebangs.first { $0.token == "r" })
    XCTAssertEqual(reddit.command, "search", "entry inherits the provider's command")
    XCTAssertTrue(reddit.selector.onlyBundleIDs.isEmpty)
    let catchAll = try XCTUnwrap(manifest.shebangs.first { $0.token == "*" })
    XCTAssertEqual(catchAll.command, "search")
    XCTAssertEqual(catchAll.meta["_note"], "catch-all", "_-prefixed fields are retained as meta")
    let github = try XCTUnwrap(manifest.shebangs.first { $0.token == "gh" })
    XCTAssertEqual(github.command, "github", "entry's own command wins")
    XCTAssertEqual(github.selector.onlyBundleIDs, ["com.other.app"])
  }

  func testProviderSectionEncodeOmitsEmptyFields() throws {
    let provider = PluginProviderGate()
    let data = try JSONEncoder().encode(provider)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(json["modes"], "empty modes is not encoded")
    XCTAssertNil(json["priority"], "nil priority is not encoded")
  }

  func testNavigationProviderEncodesSchemesWhenSet() throws {
    let provider = PluginNavigationProvider(schemes: ["tmux"])
    let data = try JSONEncoder().encode(provider)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["schemes"] as? [String], ["tmux"])
  }

  func testStatusProviderEncodesSegmentsWhenSet() throws {
    let provider = PluginStatusProvider(segments: ["battery"])
    let data = try JSONEncoder().encode(provider)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["segments"] as? [String], ["battery"])
  }

  func testCommandRegistrationEncodesSelectorWhenSet() throws {
    let registration = PluginCommandRegistration(
      command: "scoped",
      subcommand: "here",
      description: "X",
      selector: PluginSelector(
        onlyBundleIDs: ["com.example.app"],
        onlyURLs: ["https://example.com/*"]))
    let data = try JSONEncoder().encode(registration)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["only_bundle_ids"] as? [String], ["com.example.app"])
    XCTAssertEqual(json["only_urls"] as? [String], ["https://example.com/*"])

    let bare = PluginCommandRegistration(command: "x", subcommand: "", description: "X")
    let bareData = try JSONEncoder().encode(bare)
    let bareJSON = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: bareData) as? [String: Any])
    XCTAssertNil(bareJSON["only_bundle_ids"], "empty only_bundle_ids is not encoded")
    XCTAssertNil(bareJSON["only_urls"], "empty only_urls is not encoded")
  }

  func testSelectorPatternMatchingAndSpecificity() {
    let bundleOnly = PluginSelector(onlyBundleIDs: ["com.example.app"])
    let bundleAndURL = PluginSelector(
      onlyBundleIDs: ["com.example.app"],
      onlyURLs: ["https://example.com/work/*"])
    let context = PluginSelectorContext(
      bundleID: "com.example.app",
      url: "https://example.com/work/42")

    XCTAssertTrue(PluginPattern("core:apps.*").matches("core:apps.launched"))
    XCTAssertFalse(PluginPattern("core:apps.*").matches("core:config.changed"))
    XCTAssertTrue(bundleAndURL.matches(context))
    XCTAssertFalse(bundleAndURL.matches(PluginSelectorContext(bundleID: "com.example.app")))
    XCTAssertGreaterThan(
      try XCTUnwrap(bundleAndURL.specificity(in: context)),
      try XCTUnwrap(bundleOnly.specificity(in: context)))
  }

  func testFlashLogIncludesSource() {
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { records.append($0) }
    defer { FlashLog.removeSink(sink) }

    FlashLog.debug("test message", source: "core:test")
    FlashLog.plugin(.info, pluginID: "spotify", message: "plugin message")

    XCTAssertEqual(records.first?.source, "core:test")
    XCTAssertEqual(records.last?.source, "plugin:spotify")
    XCTAssertTrue(FlashLog.jsonLine(records[0]).contains("\"source\":\"core:test\""))
  }

  private func temporaryPluginRoot(manifest: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)
    return root
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func officialPluginRoots() throws -> [URL] {
    let root = repositoryRoot().appendingPathComponent("Plugins")
    return try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func commandNames(for id: String, manifests: [PluginManifest]) -> Set<String> {
    let manifest = manifests.first { $0.id == id }
    return Set(manifest?.commands.map(\.subcommand) ?? [])
  }

  private func runPluginSmoke(pluginID: String, binary: String) throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-smoke-\(pluginID)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let dataDir = temp.appendingPathComponent("data")
    let binDir = dataDir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let mock = binDir.appendingPathComponent(binary)
    try """
    #!/bin/sh
    printf '\(binary) %s\\n' "$*"
    """.write(to: mock, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)

    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run Scripts/build-plugins.sh before the MessagePack smoke test"
      )
    }
    let process = Process()
    process.executableURL = binaryURL
    process.arguments = []
    process.currentDirectoryURL = pluginRoot
    var env = ProcessInfo.processInfo.environment
    env["FLASH_PLUGIN_ID"] = pluginID
    env["FLASH_PLUGIN_VERSION"] = "0.1.0"
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "")"
    if pluginID == "slack" {
      let slackDataDir = dataDir.appendingPathComponent("slack-app-state")
      try FileManager.default.createDirectory(at: slackDataDir, withIntermediateDirectories: true)
      let configData = try JSONSerialization.data(
        withJSONObject: ["data_dir": slackDataDir.path],
        options: [.sortedKeys])
      env["FLASH_PLUGIN_CONFIG"] = String(data: configData, encoding: .utf8)
    }
    process.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    // The smoke test exercises only the managed MessagePack protocol. The
    // plugin owns subprocess execution now, so the host harness just waits for
    // the command response before sending shutdown.
    let collector = MessagePackFrameCollector()
    let writeLock = NSLock()
    func send(_ object: [String: Any]) {
      guard let payload = try? MessagePack.encode(object) else { return }
      let count = UInt32(payload.count)
      var frame = Data(capacity: 4 + payload.count)
      frame.append(UInt8(truncatingIfNeeded: count >> 24))
      frame.append(UInt8(truncatingIfNeeded: count >> 16))
      frame.append(UInt8(truncatingIfNeeded: count >> 8))
      frame.append(UInt8(truncatingIfNeeded: count))
      frame.append(payload)
      writeLock.lock()
      stdin.fileHandleForWriting.write(frame)
      writeLock.unlock()
    }
    let commandResponded = DispatchSemaphore(value: 0)

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      for message in collector.ingest(data) {
        // A plugin→host request carries both `id` and `method`; the tested
        // command should complete without host-side subprocess RPCs.
        if message["method"] is String {
          continue
        }
        if (message["id"] as? NSNumber)?.intValue == 2 {
          commandResponded.signal()
        }
      }
    }

    send(["id": 1, "jsonrpc": "2.0", "method": "initialize", "params": [:]])
    send(["id": -1, "jsonrpc": "2.0", "method": "heartbeat", "params": [:]])
    send([
      "id": 2,
      "jsonrpc": "2.0",
      "method": "command.invoke",
      "params": [
        "args": ["--version"],
        "command": pluginID,
        "subcommand": "run",
        "raw": ":\(pluginID) run --version",
      ],
    ])

    if commandResponded.wait(timeout: .now() + 5) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not respond to command.invoke")
      return
    }
    send(["jsonrpc": "2.0", "method": "shutdown", "params": ["reason": "test"]])
    stdin.fileHandleForWriting.closeFile()

    if finished.wait(timeout: .now() + 5) != .success {
      stdout.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      XCTFail("\(pluginID) plugin did not exit")
      return
    }
    stdout.fileHandleForReading.readabilityHandler = nil

    let stderrBody =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrBody)

    let messages = collector.messages()
    XCTAssertEqual(responseOK(id: 1, messages: messages), true, collector.raw())
    XCTAssertEqual(responseOK(id: -1, messages: messages), true, collector.raw())
    XCTAssertEqual(responseOK(id: 2, messages: messages), true, collector.raw())
  }

  private func runPluginParentDeathSmoke(pluginID: String) throws {
    let pluginRoot = repositoryRoot().appendingPathComponent("Plugins/\(pluginID)")
    let binaryURL = pluginRoot.appendingPathComponent("flash-plugin-\(pluginID)")
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      throw XCTSkip(
        "\(pluginID) binary not built — run Scripts/build-plugins.sh before the parent-death smoke test"
      )
    }

    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-parent-\(pluginID)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let dataDir = temp.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    parent.arguments = ["0.2"]
    try parent.run()
    defer {
      if parent.isRunning {
        parent.terminate()
      }
    }

    let process = Process()
    process.executableURL = binaryURL
    process.currentDirectoryURL = pluginRoot
    var env = ProcessInfo.processInfo.environment
    env["FLASH_PLUGIN_ID"] = pluginID
    env["FLASH_PLUGIN_VERSION"] = "0.1.0"
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    env["FLASH_PLUGIN_PARENT_PID"] = String(parent.processIdentifier)
    process.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
      }
      stdin.fileHandleForWriting.closeFile()
    }

    parent.waitUntilExit()
    if finished.wait(timeout: .now() + 3) != .success {
      XCTFail("\(pluginID) plugin did not exit after declared parent exited")
      return
    }

    _ = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrBody =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrBody)
  }

  private func responseOK(id: Int, messages: [[String: Any]]) -> Bool? {
    for message in messages {
      guard (message["id"] as? NSNumber)?.intValue == id else { continue }
      let result = message["result"] as? [String: Any]
      return result?["ok"] as? Bool
    }
    return nil
  }
}

/// Thread-safe accumulator for length-prefixed MessagePack frames streamed from
/// a plugin's stdout. `ingest` is called from the pipe's readability handler (a
/// background queue); `messages`/`raw` are read from the test thread.
private final class MessagePackFrameCollector {
  private let lock = NSLock()
  private var buffer = Data()
  private var parsed: [[String: Any]] = []

  func ingest(_ data: Data) -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    var fresh: [[String: Any]] = []
    while buffer.count >= 4 {
      let base = buffer.startIndex
      let length =
        (Int(buffer[base]) << 24)
        | (Int(buffer[base + 1]) << 16)
        | (Int(buffer[base + 2]) << 8)
        | Int(buffer[base + 3])
      guard length >= 0, buffer.count >= 4 + length else { break }
      let payloadStart = base + 4
      let payloadEnd = payloadStart + length
      let payload = buffer.subdata(in: payloadStart..<payloadEnd)
      buffer.removeSubrange(base..<payloadEnd)
      guard let object = try? MessagePack.decode(payload) as? [String: Any] else { continue }
      parsed.append(object)
      fresh.append(object)
    }
    return fresh
  }

  func messages() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return parsed
  }

  /// A rendering of the frames parsed so far, for failure diagnostics (the
  /// wire is now binary, so there's no raw text to echo).
  func raw() -> String {
    lock.lock()
    defer { lock.unlock() }
    return parsed.map { String(describing: $0) }.joined(separator: "\n")
  }
}

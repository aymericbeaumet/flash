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
        "aiproviders", "calculator", "clipboard", "contacts", "emojis", "firefox", "media",
        "notes", "reminders", "safari", "searchengines", "slack", "spotify", "system", "tmux",
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
    let tmux = try XCTUnwrap(manifests.first { $0.id == "tmux" })
    XCTAssertEqual(tmux.install, "true")
    XCTAssertEqual(tmux.start, "exec ./flash-plugin-tmux")
    XCTAssertTrue(tmux.volatile)
    XCTAssertEqual(tmux.priority, 20)
    XCTAssertTrue(tmux.bundleIDs.contains("org.alacritty"))

    XCTAssertTrue(
      commandNames(for: "spotify", manifests: manifests).isSuperset(of: [
        "login", "status", "pause", "play", "toggle", "next", "previous", "search", "run",
      ]))
    XCTAssertTrue(
      commandNames(for: "slack", manifests: manifests).isSuperset(of: [
        "login", "version", "run",
      ]))
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

  func testManifestRootDiscoveryFollowsSymlinkedBundleDirectory() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }

    let bundlePlugins = temp.appendingPathComponent("real/Plugins")
    let pluginRoot = bundlePlugins.appendingPathComponent("sample")
    try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
    try """
    {
      "manifest_version": 1,
      "id": "sample",
      "name": "Sample",
      "version": "0.1.0",
      "description": "Sample plugin",
      "install": "./install.sh",
      "start": "./start.sh",
      "subscriptions": [],
      "providers": []
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
          "manifest_version": 1,
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "npm install",
          "start": "npm start",
          "subscriptions": [
            { "match": "core:apps.*", "bundle_ids": ["com.spotify.client"] },
            "core:config.*"
          ],
          "providers": [
            {
              "kind": "commands",
              "commands": [
                { "command": "spotify", "subcommand": "pause", "description": "Pause playback" }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.start, "npm start")
    XCTAssertEqual(manifest.subscriptions.count, 2)
    XCTAssertEqual(manifest.commands.first?.command, "spotify")
    XCTAssertEqual(manifest.commands.first?.subcommand, "pause")
    XCTAssertTrue(manifest.mappings.isEmpty, "absent mappings key defaults to []")
  }

  func testManifestRejectsUnknownEventsKey() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "true",
          "start": "true",
          "events": [
            { "match": "core:apps.*", "bundle_ids": ["com.spotify.client"] },
            "core:config.*"
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root)) { error in
      XCTAssertTrue(String(describing: error).contains("manifest.json unknown field events"))
    }
  }

  func testManifestDecodesMappingsWithDefaults() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "slack",
          "name": "Slack",
          "version": "0.1.0",
          "description": "Slack",
          "install": "true",
          "start": "true",
          "providers": [
            {
              "kind": "mappings",
              "mappings": [
                { "key": "q", "command": "flash://plugin_command?command=slack&subcommand=run" },
                {
                  "key": "ctrl+k",
                  "mode": "insert",
                  "command": "flash://hints_dismiss",
                  "bundle_ids": ["com.tinyspeck.slackmacgap"],
                  "priority": 40
                }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.mappings.count, 2)

    let first = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(first.key, "q")
    XCTAssertEqual(first.mode, "normal", "mode defaults to normal")
    XCTAssertEqual(first.scope, .normal)
    XCTAssertTrue(first.bundleIDs.isEmpty, "bundle_ids defaults to []")
    XCTAssertNil(first.priority, "priority is optional")

    let second = manifest.mappings[1]
    XCTAssertEqual(second.mode, "insert")
    XCTAssertEqual(second.scope, .insert)
    XCTAssertEqual(second.bundleIDs, ["com.tinyspeck.slackmacgap"])
    XCTAssertEqual(second.priority, 40)
  }

  func testMappingRegistrationEncodeOmitsDefaults() throws {
    let mapping = PluginMappingRegistration(
      key: "q", command: "flash://hints_dismiss")
    let data = try JSONEncoder().encode(mapping)
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["key"] as? String, "q")
    XCTAssertEqual(json["command"] as? String, "flash://hints_dismiss")
    XCTAssertNil(json["mode"], "default \"normal\" mode is not encoded")
    XCTAssertNil(json["bundle_ids"], "empty bundle_ids is not encoded")
    XCTAssertNil(json["priority"], "nil priority is not encoded")
  }

  func testSafariPluginOverridesHardRefreshBinding() throws {
    let root = try XCTUnwrap(
      try officialPluginRoots().first { $0.lastPathComponent == "safari" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.bundleIDs, ["com.apple.Safari"])
    let mapping = try XCTUnwrap(manifest.mappings.first)
    XCTAssertEqual(manifest.mappings.count, 1)
    XCTAssertEqual(mapping.key, "R")
    XCTAssertEqual(mapping.scope, .normal)
    // Safari's "Reload Page From Origin" is ⌘⌥R, unlike the ⌘⇧R that the
    // built-in `R` → flash://app_reload?force=1 default sends for Firefox/Chrome.
    XCTAssertEqual(mapping.command, "flash://send_key?keys=cmd+option+r")
    XCTAssertTrue(
      mapping.bundleIDs.isEmpty,
      "mapping inherits the manifest's com.apple.Safari scope")
  }

  func testManifestRejectsInvalidID() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "Spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "true",
          "start": "true",
          "subscriptions": [],
          "providers": []
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root))
  }

  func testManifestProvidersDecodeAcrossKinds() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "multi",
          "name": "Multi",
          "version": "0.1.0",
          "description": "Every surface in one providers table",
          "install": "true",
          "start": "true",
          "providers": [
            { "kind": "hints", "bundle_ids": ["com.example.app"] },
            { "kind": "candidates", "sources": ["multi.items"] },
            {
              "kind": "commands",
              "commands": [
                { "command": "multi", "subcommand": "go", "description": "Go" }
              ]
            },
            {
              "kind": "mappings",
              "mappings": [
                { "key": "q", "command": "flash://hints_dismiss" }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.providers.count, 4)
    XCTAssertTrue(manifest.providesHints)
    XCTAssertTrue(manifest.providesCandidates)
    XCTAssertEqual(manifest.candidateSources, ["multi.items"])
    XCTAssertEqual(manifest.commands.map(\.subcommand), ["go"])
    XCTAssertEqual(manifest.mappings.map(\.key), ["q"])
  }

  func testProvidesFlagsFalseWithoutMatchingProvider() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "cmdsonly",
          "name": "Commands Only",
          "version": "0.1.0",
          "description": "No hints, no candidates",
          "install": "true",
          "start": "true",
          "providers": [
            {
              "kind": "commands",
              "commands": [
                { "command": "x", "subcommand": "", "description": "X" }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertFalse(manifest.providesHints)
    XCTAssertFalse(manifest.providesCandidates)
  }

  func testCommandsProviderBundleIDsFoldIntoEntries() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "scoped",
          "name": "Scoped",
          "version": "0.1.0",
          "description": "App-scoped commands",
          "install": "true",
          "start": "true",
          "providers": [
            {
              "kind": "commands",
              "bundle_ids": ["com.example.app"],
              "commands": [
                { "command": "scoped", "subcommand": "here", "description": "Inherits scope" },
                {
                  "command": "scoped",
                  "subcommand": "elsewhere",
                  "description": "Overrides scope",
                  "bundle_ids": ["com.other.app"]
                }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    let here = try XCTUnwrap(manifest.commands.first { $0.subcommand == "here" })
    XCTAssertEqual(here.bundleIDs, ["com.example.app"], "entry inherits the provider's gate")
    let elsewhere = try XCTUnwrap(manifest.commands.first { $0.subcommand == "elsewhere" })
    XCTAssertEqual(elsewhere.bundleIDs, ["com.other.app"], "entry's own bundle_ids win")
  }

  func testMappingsProviderModeFoldsIntoEntries() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "manifest_version": 1,
          "id": "moded",
          "name": "Moded",
          "version": "0.1.0",
          "description": "Provider-level mode gate",
          "install": "true",
          "start": "true",
          "providers": [
            {
              "kind": "mappings",
              "modes": ["insert"],
              "mappings": [
                { "key": "j", "command": "flash://hints_dismiss" }
              ]
            }
          ]
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
          "manifest_version": 1,
          "id": "banger",
          "name": "Banger",
          "version": "0.1.0",
          "description": "Flashlight bangs",
          "install": "true",
          "start": "true",
          "providers": [
            {
              "kind": "shebang",
              "command": "search",
              "bundle_ids": ["com.example.app"],
              "shebangs": [
                { "token": "r", "description": "Reddit" },
                { "token": "*", "_note": "catch-all" },
                { "token": "gh", "command": "github", "bundle_ids": ["com.other.app"] }
              ]
            }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(Set(manifest.shebangs.map(\.token)), ["r", "*", "gh"])
    let reddit = try XCTUnwrap(manifest.shebangs.first { $0.token == "r" })
    XCTAssertEqual(reddit.command, "search", "entry inherits the provider's command")
    XCTAssertEqual(reddit.bundleIDs, ["com.example.app"], "entry inherits the provider's gate")
    let catchAll = try XCTUnwrap(manifest.shebangs.first { $0.token == "*" })
    XCTAssertEqual(catchAll.command, "search")
    XCTAssertEqual(catchAll.meta["_note"], "catch-all", "_-prefixed fields are retained as meta")
    let github = try XCTUnwrap(manifest.shebangs.first { $0.token == "gh" })
    XCTAssertEqual(github.command, "github", "entry's own command wins")
    XCTAssertEqual(github.bundleIDs, ["com.other.app"], "entry's own bundle_ids win")
  }

  func testProviderEncodeOmitsEmptyFields() throws {
    let provider = PluginProvider(kind: .candidates)
    let data = try JSONEncoder().encode(provider)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "candidates")
    XCTAssertNil(json["bundle_ids"], "empty bundle_ids is not encoded")
    XCTAssertNil(json["modes"], "empty modes is not encoded")
    XCTAssertNil(json["priority"], "nil priority is not encoded")
    XCTAssertNil(json["sources"], "empty sources is not encoded")
    XCTAssertNil(json["commands"], "empty commands is not encoded")
    XCTAssertNil(json["mappings"], "empty mappings is not encoded")
  }

  func testProviderEncodesCandidateSourcesWhenSet() throws {
    let provider = PluginProvider(kind: .candidates, sources: ["firefox.tabs"])
    let data = try JSONEncoder().encode(provider)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "candidates")
    XCTAssertEqual(json["sources"] as? [String], ["firefox.tabs"])
  }

  func testCommandRegistrationEncodesBundleIDsWhenSet() throws {
    let registration = PluginCommandRegistration(
      command: "scoped", subcommand: "here", description: "X", bundleIDs: ["com.example.app"])
    let data = try JSONEncoder().encode(registration)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["bundle_ids"] as? [String], ["com.example.app"])

    let bare = PluginCommandRegistration(command: "x", subcommand: "", description: "X")
    let bareData = try JSONEncoder().encode(bare)
    let bareJSON = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: bareData) as? [String: Any])
    XCTAssertNil(bareJSON["bundle_ids"], "empty bundle_ids is not encoded")
  }

  func testEventSubscriptionFiltering() {
    let apps = PluginEventSubscription(
      match: "core:apps.*",
      bundleIDs: ["com.spotify.client"])
    XCTAssertTrue(
      apps.matches(
        PluginEvent(
          name: "core:apps.launched",
          payload: [:],
          bundleID: "com.spotify.client",
          configPath: nil,
          focused: false)))
    XCTAssertFalse(
      apps.matches(
        PluginEvent(
          name: "core:apps.launched",
          payload: [:],
          bundleID: "com.apple.Safari",
          configPath: nil,
          focused: false)))

    let config = PluginEventSubscription(match: "core:config.*", paths: ["plugins.*"])
    XCTAssertTrue(
      config.matches(
        PluginEvent(
          name: "core:config.changed",
          payload: [:],
          bundleID: nil,
          configPath: "plugins.third_party",
          focused: nil)))
    XCTAssertFalse(
      config.matches(
        PluginEvent(
          name: "core:config.changed",
          payload: [:],
          bundleID: nil,
          configPath: "debug.log_level",
          focused: nil)))
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

    // The plugin no longer spawns child processes itself: `run_cli` delegates
    // to a `cli.run` host RPC. This harness plays the host — it reads the
    // plugin's stdout, executes any `cli.run` request against the mocked
    // binary (mirroring the core's sandboxed executor), and feeds the result
    // back. Only after the `command.invoke` (id 2) response arrives do we send
    // `shutdown`, so the in-flight CLI call always completes first.
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
        // A plugin→host request carries both `id` and `method`; a response to
        // our scripted requests carries `id` but no `method`.
        if let method = message["method"] as? String,
          let requestID = (message["id"] as? NSNumber)?.intValue
        {
          if method == "cli.run" {
            let params = message["params"] as? [String: Any] ?? [:]
            send([
              "id": requestID, "jsonrpc": "2.0",
              "result": Self.runMockedCLI(params: params, binDir: binDir),
            ])
          }
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

  /// Mirrors the core's `cli.run` executor for the smoke test: runs the
  /// requested argv (resolved against the plugin's mocked `bin/` dir) and
  /// returns the `ok`/`stdout`/`stderr`/`status` shape the SDK expects.
  private static func runMockedCLI(params: [String: Any], binDir: URL) -> [String: Any] {
    let argv = (params["argv"] as? [String]) ?? []
    guard !argv.isEmpty else {
      return ["ok": false, "status": -1, "stdout": "", "stderr": "empty argv"]
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "")"
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
      let stdout = out.fileHandleForReading.readDataToEndOfFile()
      let stderr = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return [
        "ok": process.terminationStatus == 0,
        "status": Int(process.terminationStatus),
        "stdout": String(data: stdout, encoding: .utf8) ?? "",
        "stderr": String(data: stderr, encoding: .utf8) ?? "",
      ]
    } catch {
      return ["ok": false, "status": 127, "stdout": "", "stderr": "\(error)"]
    }
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

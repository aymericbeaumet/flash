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
        "aws", "calculator", "cloudflare", "clipboard", "contacts", "emojis", "github", "linear",
        "media", "notes", "notion", "reminders", "slack", "spotify", "system", "tmux", "vercel",
        "web",
      ])

    let runCommandRequired: Set<String> = [
      "github", "linear", "media", "notion", "slack", "spotify",
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

    XCTAssertTrue(commandNames(for: "spotify", manifests: manifests).isSuperset(of: [
      "login", "status", "pause", "play", "toggle", "next", "previous", "search", "run",
    ]))
    XCTAssertTrue(commandNames(for: "github", manifests: manifests).isSuperset(of: [
      "login", "status", "issues", "prs", "run",
    ]))
    XCTAssertTrue(commandNames(for: "linear", manifests: manifests).isSuperset(of: [
      "login", "mine", "query", "start", "view", "pr", "create", "run",
    ]))
    XCTAssertTrue(commandNames(for: "slack", manifests: manifests).isSuperset(of: [
      "login", "version", "run",
    ]))
    XCTAssertTrue(commandNames(for: "notion", manifests: manifests).isSuperset(of: [
      "login", "version", "api", "workers", "run",
    ]))
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
          XCTAssertFalse(field.contains(needle), "\(root.lastPathComponent) manifest contains \(needle)")
        }
      }
      for name in ["Cargo.toml", "src/main.rs"] {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let body = try String(contentsOf: file)
        for needle in banned {
          XCTAssertFalse(body.contains(needle), "\(root.lastPathComponent)/\(name) contains \(needle)")
        }
      }
    }
  }

  func testOfficialPluginsRespondOverJSONDWithMockedCLIs() throws {
    let cases = [
      ("github", "gh"),
      ("linear", "linear"),
      ("notion", "ntn"),
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
        "id": "sample",
        "name": "Sample",
        "version": "0.1.0",
        "description": "Sample plugin",
        "install": "./install.sh",
        "start": "./start.sh",
        "events": [],
        "commands": []
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
          "events": [
            { "match": "apps.*", "bundle_ids": ["com.spotify.client"] },
            "config.*"
          ],
          "commands": [
            { "command": "spotify", "subcommand": "pause", "description": "Pause playback" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.start, "npm start")
    XCTAssertEqual(manifest.events.count, 2)
    XCTAssertEqual(manifest.commands.first?.command, "spotify")
    XCTAssertEqual(manifest.commands.first?.subcommand, "pause")
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
          "start": "true",
          "events": [],
          "commands": []
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root))
  }

  func testEventSubscriptionFiltering() {
    let apps = PluginEventSubscription(
      match: "apps.*",
      bundleIDs: ["com.spotify.client"])
    XCTAssertTrue(
      apps.matches(
        PluginEvent(
          name: "apps.launched",
          payload: [:],
          bundleID: "com.spotify.client",
          configPath: nil,
          focused: false)))
    XCTAssertFalse(
      apps.matches(
        PluginEvent(
          name: "apps.launched",
          payload: [:],
          bundleID: "com.apple.Safari",
          configPath: nil,
          focused: false)))

    let config = PluginEventSubscription(match: "config.*", paths: ["plugins.*"])
    XCTAssertTrue(
      config.matches(
        PluginEvent(
          name: "config.changed",
          payload: [:],
          bundleID: nil,
          configPath: "plugins.third_party",
          focused: nil)))
    XCTAssertFalse(
      config.matches(
        PluginEvent(
          name: "config.changed",
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
      options: [.skipsHiddenFiles])
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
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
        "\(pluginID) binary not built — run Scripts/build-plugins.sh before the JSOND smoke test")
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

    let lines = try [
      jsonLine(["id": 1, "jsonrpc": "2.0", "method": "initialize", "params": [:]]),
      jsonLine(["id": -1, "jsonrpc": "2.0", "method": "heartbeat", "params": [:]]),
      jsonLine([
        "id": 2,
        "jsonrpc": "2.0",
        "method": "command.invoke",
        "params": [
          "args": ["--version"],
          "command": pluginID,
          "subcommand": "run",
          "raw": ":\(pluginID) run --version",
        ],
      ]),
      jsonLine(["jsonrpc": "2.0", "method": "shutdown", "params": ["reason": "test"]]),
    ].joined(separator: "\n") + "\n"
    stdin.fileHandleForWriting.write(Data(lines.utf8))
    stdin.fileHandleForWriting.closeFile()

    if finished.wait(timeout: .now() + 5) != .success {
      process.terminate()
      XCTFail("\(pluginID) plugin did not exit")
      return
    }

    let stderrBody = String(
      data: stderr.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderrBody)

    let stdoutBody = String(
      data: stdout.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8) ?? ""
    let messages = try stdoutBody.split(separator: "\n").map { line -> [String: Any] in
      let data = Data(String(line).utf8)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    XCTAssertEqual(responseOK(id: 1, messages: messages), true, stdoutBody)
    XCTAssertEqual(responseOK(id: -1, messages: messages), true, stdoutBody)
    XCTAssertEqual(responseOK(id: 2, messages: messages), true, stdoutBody)
  }

  private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
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

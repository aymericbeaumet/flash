import Foundation
import XCTest

@testable import flash

/// A manifest's `settings` is the whole of its `[plugins.<id>]` table: the
/// loader, the plugin manager and the config schema read the same
/// declarations (`PluginSettings`).
final class PluginSettingsTests: XCTestCase {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func temporaryRoot(manifest: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func load(_ fields: String, exec: Bool = true) throws -> PluginManifest {
    try PluginManifest.load(
      from: try temporaryRoot(
        manifest: """
          {
            "id": "sample",
            "name": "Sample",
            "version": "1.0.0",
            "description": "fixture",
            \(exec ? #""exec": ["/usr/bin/true"], "sandbox": false, "status": ["state"],"# : "")
            \(fields)
          }
          """))
  }

  private func failure(_ fields: String, exec: Bool = true) -> String {
    do {
      _ = try load(fields, exec: exec)
      return ""
    } catch {
      return String(describing: error)
    }
  }

  func testAManifestDeclaresItsSettingsByName() throws {
    let manifest = try load(
      """
      "settings": {
        "url": {"type": "string", "description": "The feed."},
        "mode": {"type": "string", "description": "How.", "enum": ["a", "b"], "default": "a"},
        "interval": {"type": "integer", "description": "Seconds.", "default": 300, "min": 1, "max": 86400},
        "ratio": {"type": "number", "description": "Share.", "default": 0.5, "min": 0, "max": 1},
        "loud": {"type": "boolean", "description": "Whether.", "default": false},
        "hosts": {"type": "string_array", "description": "Which.", "default": ["a"]}
      }
      """)
    XCTAssertEqual(
      manifest.settings,
      [
        "url": PluginSettingDeclaration(type: .string, description: "The feed."),
        "mode": PluginSettingDeclaration(
          type: .string, description: "How.", defaultValue: .string("a"), allowed: ["a", "b"]),
        "interval": PluginSettingDeclaration(
          type: .integer, description: "Seconds.", defaultValue: .int(300), min: 1, max: 86400),
        "ratio": PluginSettingDeclaration(
          type: .number, description: "Share.", defaultValue: .double(0.5), min: 0, max: 1),
        "loud": PluginSettingDeclaration(
          type: .boolean, description: "Whether.", defaultValue: .bool(false)),
        "hosts": PluginSettingDeclaration(
          type: .stringArray, description: "Which.", defaultValue: .stringArray(["a"])),
      ])
    XCTAssertEqual(try load(#""listen": []"#).settings, [:])
  }

  func testAMalformedDeclarationFailsTheLoad() {
    for (fields, message) in [
      (#""settings": {"n": {"type": "table", "description": "x"}}"#, "settings"),
      (#""settings": {"n": {"type": "string"}}"#, "settings.n needs a description"),
      (
        #""settings": {"n": {"type": "string", "description": "x", "pattern": "a"}}"#,
        "manifest.json settings.n unknown field pattern"
      ),
      (
        #""settings": {"N-1": {"type": "string", "description": "x"}}"#,
        "settings.N-1 names must be lowercase [a-z0-9_]"
      ),
      (
        #""settings": {"sandbox": {"type": "boolean", "description": "x"}}"#,
        "settings.sandbox is the host's own setting"
      ),
      (
        #""settings": {"n": {"type": "integer", "description": "x", "enum": ["a"]}}"#,
        "settings.n enum belongs to a string"
      ),
      (
        #""settings": {"n": {"type": "string", "description": "x", "enum": []}}"#,
        "settings.n enum must list distinct values"
      ),
      (
        #""settings": {"n": {"type": "string", "description": "x", "min": 1}}"#,
        "settings.n min and max belong to an integer or a number"
      ),
      (
        #""settings": {"n": {"type": "integer", "description": "x", "min": 0.5}}"#,
        "settings.n min and max of an integer must be integers"
      ),
      (
        #""settings": {"n": {"type": "number", "description": "x", "min": 2, "max": 1}}"#,
        "settings.n min must not exceed max"
      ),
      (
        #""settings": {"n": {"type": "integer", "description": "x", "min": 1, "default": 0}}"#,
        "settings.n default must be an integer of at least 1"
      ),
      (
        #""settings": {"n": {"type": "string", "description": "x", "enum": ["a"], "default": "b"}}"#,
        "settings.n default must be one of a"
      ),
      (#""settings": {"n": {"type": "integer", "description": "x", "default": "1"}}"#, "default"),
      (#""settings": ["n"]"#, "settings"),
    ] {
      let error = failure(fields)
      XCTAssertTrue(error.contains(message), "\(fields): \(error)")
    }
    XCTAssertTrue(
      failure(#""settings": {"n": {"type": "string", "description": "x"}}"#, exec: false)
        .contains("without exec cannot declare settings"))
  }

  /// A watched setting is a path, so it is a declared string.
  func testWatchSettingsNameDeclaredStrings() throws {
    let catalog =
      #""exec": ["/usr/bin/true"], "sources": [{"name": "a.b", "type": "b"}], "#
      + #""lifecycle": "publish_then_exit", "watch_settings": ["file"]"#
    func watched(_ settings: String) throws -> PluginManifest {
      try load(catalog + settings, exec: false)
    }
    XCTAssertEqual(
      try watched(#", "settings": {"file": {"type": "string", "description": "x"}}"#)
        .watchSettings, ["file"])
    for settings in ["", #", "settings": {"file": {"type": "boolean", "description": "x"}}"#] {
      XCTAssertThrowsError(try watched(settings)) { error in
        XCTAssertTrue(
          String(describing: error).contains(
            "watch_settings names file, which settings does not declare as a string"),
          String(describing: error))
      }
    }
  }

  private let declared: [String: PluginSettingDeclaration] = [
    "url": PluginSettingDeclaration(type: .string, description: "x"),
    "mode": PluginSettingDeclaration(
      type: .string, description: "x", defaultValue: .string("a"), allowed: ["a", "b"]),
    "interval": PluginSettingDeclaration(
      type: .integer, description: "x", defaultValue: .int(300), min: 1, max: 86400),
    "ratio": PluginSettingDeclaration(type: .number, description: "x", min: 0),
    "hosts": PluginSettingDeclaration(type: .stringArray, description: "x"),
  ]

  /// What reaches `FLASH_PLUGIN_CONFIG`: accepted values over the defaults.
  func testResolveDeliversDeclaredValuesOverTheDefaults() {
    let untouched = PluginSettings.resolve(declared: declared, authored: [:])
    XCTAssertEqual(untouched.values, ["mode": .string("a"), "interval": .int(300)])
    XCTAssertTrue(untouched.problems.isEmpty)

    let resolved = PluginSettings.resolve(
      declared: declared,
      authored: [
        "url": .string("https://example.com"), "mode": .string("c"), "interval": .int(0),
        "ratio": .int(2), "hosts": .string("a"), "urll": .string("x"), "sandbox": .bool(false),
      ])
    XCTAssertEqual(
      resolved.values,
      [
        "url": .string("https://example.com"), "mode": .string("a"), "interval": .int(300),
        "ratio": .int(2), "sandbox": .bool(false),
      ])
    XCTAssertEqual(
      resolved.problems.map { $0.problem.message(path: "plugins.sample.\($0.key)") },
      [
        "plugins.sample.hosts must be an array of strings",
        "plugins.sample.interval must be an integer between 1 and 86400",
        "plugins.sample.mode must be one of a, b",
        "unknown config key 'plugins.sample.urll' — did you mean 'url'?",
      ])
    XCTAssertEqual(
      PluginSettings.problem(key: "ratio", value: .double(-0.5), declared: declared),
      .invalid(requirement: "must be a number of at least 0"))
    XCTAssertEqual(
      PluginSettings.problem(key: "sandbox", value: .string("no"), declared: [:]),
      .invalid(requirement: "must be true or false"))
    XCTAssertEqual(
      PluginSettings.problem(key: "zzzzzzzz", value: .int(1), declared: [:]),
      .undeclared(suggestion: nil))
  }

  /// The loader checks a bundled plugin's table where the file sets it.
  func testTheLoaderChecksABundledPluginsTable() {
    let catalog = PluginSettingsCatalog(declared: ["sample": declared, "quiet": [:]])
    func parse(_ text: String, defaults: String? = nil) -> Config {
      ConfigLoader.parseLayers(
        (defaults.map { [ConfigLoader.Layer(text: $0)] } ?? []) + [ConfigLoader.Layer(text: text)],
        pluginSettings: catalog)
    }
    let config = parse(
      """
      [plugins.sample]
      url = "https://example.com"
      urll = "x"
      interval = 0
      sandbox = false

      [plugins.quiet]
      loud = true

      [plugins.sampel]
      url = "x"
      """)
    XCTAssertEqual(
      config.plugins.settings,
      ["sample": ["url": .string("https://example.com"), "sandbox": .bool(false)]])
    XCTAssertEqual(
      ConfigCheck.rows(config.loadingDiagnostics, file: "flash.toml").map(\.text),
      [
        "flash.toml:3:8: unknown config key 'plugins.sample.urll' — did you mean 'url'?",
        "flash.toml:4:12: plugins.sample.interval must be an integer between 1 and 86400",
        "flash.toml:8:8: unknown config key 'plugins.quiet.loud'",
        "flash.toml:10:1: [plugins.sampel] names no bundled plugin — did you mean 'sample'?",
      ])

    // A value the file gets wrong leaves the layer below in place.
    let layered = parse(
      "[plugins.sample]\ninterval = \"often\"\n", defaults: "[plugins.sample]\ninterval = 60\n")
    XCTAssertEqual(layered.plugins.settings["sample"], ["interval": .int(60)])
    XCTAssertEqual(layered.loadingDiagnostics.count, 1)

    // A third-party plugin's manifest is not at hand: its table passes
    // through, and the plugin manager checks it when the plugin loads.
    let thirdParty = parse(
      """
      [plugins]
      third_party = ["github:someone/other@0123456789abcdef0123456789abcdef01234567"]

      [plugins.other]
      anything = 1
      """)
    XCTAssertEqual(thirdParty.plugins.settings["other"], ["anything": .int(1)])
    XCTAssertEqual(thirdParty.loadingDiagnostics.map(\.message), [])

    // Without a catalog nothing is checked.
    let unchecked = ConfigLoader.parse("[plugins.sample]\nurll = 1\n")
    XCTAssertEqual(unchecked.plugins.settings["sample"], ["urll": .int(1)])
    XCTAssertEqual(unchecked.loadingDiagnostics.map(\.message), [])
  }

  /// The bundled manifests declare every setting their plugin reads, and the
  /// examples in the bundled defaults are settings they take.
  func testTheBundledManifestsDeclareTheDocumentedSettings() throws {
    let roots = PluginRepository.manifestRoots(
      in: [Self.repository.appendingPathComponent("Plugins")])
    let catalog = PluginSettingsCatalog.bundled(roots: roots)
    XCTAssertEqual(
      catalog.declared.filter { !$0.value.isEmpty }.mapValues { $0.keys.sorted() },
      [
        "aiproviders": ["grok_auth_file"],
        "answers": ["target_currencies"],
        "feed": ["cycle_interval", "refresh_interval", "url"],
        "snippets": ["file"],
        "terminals": ["ssh_hosts"],
      ])
    XCTAssertEqual(catalog.declared["sysinfo"], [:], "a plugin without settings is still listed")
    XCTAssertEqual(
      catalog.declared.count, roots.count, "every bundled manifest's settings decode")
    XCTAssertEqual(PluginSettingsCatalog.bundled(roots: roots), catalog, "read once, then cached")

    // Every commented `[plugins.<id>]` example in the defaults, uncommented.
    let defaults = try String(
      contentsOf: Self.repository.appendingPathComponent("config.default.toml"), encoding: .utf8)
    var examples: [String] = []
    var inExample = false
    for line in defaults.components(separatedBy: "\n") {
      if line.hasPrefix("# [plugins.") {
        inExample = true
      } else if inExample, !line.hasPrefix("# ") || line.hasPrefix("# [") || !line.contains(" = ") {
        inExample = false
      }
      if inExample { examples.append(String(line.dropFirst(2))) }
    }
    XCTAssertTrue(examples.contains("[plugins.feed]"), "\(examples)")
    let config = ConfigLoader.parseLayers(
      [ConfigLoader.Layer(text: examples.joined(separator: "\n"))], pluginSettings: catalog)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      Set(config.plugins.settings.keys),
      Set(catalog.declared.filter { !$0.value.isEmpty }.keys),
      "every plugin with settings has its example in the defaults")
  }

  /// An editor completes and checks a bundled plugin's table from the schema.
  func testTheSchemaTypesABundledPluginsTable() throws {
    let schema = ConfigSchema.document(
      defaults: "", pluginSettings: PluginSettingsCatalog(declared: ["sample": declared]))
    let plugins = try XCTUnwrap(
      (schema["properties"] as? [String: Any])?["plugins"] as? [String: Any])
    let sample = try XCTUnwrap(
      (plugins["properties"] as? [String: Any])?["sample"] as? NSDictionary)
    XCTAssertEqual(
      sample,
      [
        "type": "object", "additionalProperties": false,
        "description": "The sample plugin's settings.",
        "properties": [
          "url": ["type": "string", "description": "x"],
          "mode": ["type": "string", "description": "x", "enum": ["a", "b"], "default": "a"],
          "interval": [
            "type": "integer", "description": "x", "default": 300, "minimum": 1, "maximum": 86400,
          ],
          "ratio": ["type": "number", "description": "x", "minimum": 0],
          "hosts": ["type": "array", "items": ["type": "string"], "description": "x"],
          "sandbox": [
            "type": "boolean",
            "description": PluginSettings.host["sandbox"]?.description ?? "",
          ],
        ],
      ] as NSDictionary)
    XCTAssertEqual(
      (plugins["additionalProperties"] as? [String: Any])?["type"] as? String, "object",
      "a third-party plugin's table stays open")
  }
}

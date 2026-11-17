import Foundation
import TOMLKit
import XCTest

@testable import flash

/// flash.toml's JSON Schema (`ConfigSchema`): built from the loader's own key
/// tables and the bundled defaults, published as docs/schema/flash.schema.json.
/// `FLASH_WRITE_SCHEMA=1 swift test --filter ConfigSchemaTests` (or
/// `mise run build:schema`) rewrites the published copy.
final class ConfigSchemaTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let published = root.appendingPathComponent("docs/schema/flash.schema.json")

  private static let defaults: String = {
    (try? String(contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8))
      ?? ""
  }()

  private static let schema: [String: Any] = ConfigSchema.document(defaults: defaults)

  func testThePublishedSchemaIsCurrent() throws {
    let generated = ConfigSchema.json(defaults: Self.defaults)
    if ProcessInfo.processInfo.environment["FLASH_WRITE_SCHEMA"] == "1" {
      try FileManager.default.createDirectory(
        at: Self.published.deletingLastPathComponent(), withIntermediateDirectories: true)
      try generated.write(to: Self.published, atomically: true, encoding: .utf8)
    }
    let committed = try String(contentsOf: Self.published, encoding: .utf8)
    XCTAssertEqual(
      committed, generated,
      "docs/schema/flash.schema.json is stale: run mise run build:schema")
  }

  func testEachSectionHasExactlyTheLoadersKeys() throws {
    let sections = try XCTUnwrap(Self.schema["properties"] as? [String: Any])
    XCTAssertEqual(Set(sections.keys), ConfigLoader.topLevelSections)
    for (name, keys) in ConfigLoader.sectionKeys {
      let section = try XCTUnwrap(sections[name] as? [String: Any], name)
      let properties = try XCTUnwrap(section["properties"] as? [String: Any], name)
      XCTAssertTrue(
        keys.isSubset(of: Set(properties.keys)),
        "\(name) is missing \(keys.subtracting(properties.keys).sorted())")
      // A section may add the subtables the loader reads under it.
      let subtables: Set<String> = [
        "dark", "sources", "click", "labels", "normal", "all",
        "insert", "command", "terminal", "hyper", "hold", "apps", "layers", "aliases",
        "precedence",
      ]
      XCTAssertTrue(
        Set(properties.keys).subtracting(keys).isSubset(of: subtables),
        "\(name) has keys the loader rejects: \(Set(properties.keys).subtracting(keys))")
    }
  }

  func testTheDefaultsTheStarterAndTheStartupExampleValidate() throws {
    XCTAssertEqual(errors(for: Self.defaults), [], "config.default.toml")
    XCTAssertEqual(errors(for: StarterConfig.text), [], "the starter config")
    // The commented [startup] run example, uncommented: the schema and the
    // loader both take it.
    var block = ["[startup]"]
    var inStartup = false
    for line in Self.defaults.components(separatedBy: "\n") {
      if line == "[startup]" {
        inStartup = true
        continue
      }
      guard inStartup else { continue }
      if line.hasPrefix("# run = [") || (!block.dropFirst().isEmpty && line.hasPrefix("# ")) {
        block.append(String(line.dropFirst(2)))
        if line == "# ]" { break }
      }
    }
    XCTAssertGreaterThan(block.count, 3)
    let example = block.joined(separator: "\n")
    XCTAssertEqual(errors(for: example), [], example)
    let config = ConfigLoader.parse(example)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [], example)
    XCTAssertEqual(config.startup.run.count, block.count - 3)
  }

  func testEveryKeyIsTypedUnlessDeliberatelyUntyped() {
    var untyped: [String] = []
    func visit(_ node: [String: Any], path: [String]) {
      if let properties = node["properties"] as? [String: Any] {
        for (name, child) in properties {
          visit(child as? [String: Any] ?? [:], path: path + [name])
        }
      } else if node["type"] == nil, node["anyOf"] == nil, node["const"] == nil,
        node["enum"] == nil
      {
        untyped.append(path.joined(separator: "."))
      }
      if let items = node["items"] as? [String: Any] { visit(items, path: path + ["*"]) }
      if let additional = node["additionalProperties"] as? [String: Any] {
        visit(additional, path: path + ["*"])
      }
    }
    visit(Self.schema, path: [])
    XCTAssertEqual(
      Set(untyped).subtracting(ConfigSchema.untypedKeys), [],
      "type these in ConfigSchema.declaredTypes, or default them in config.default.toml")
  }

  func testItRejectsWhatTheLoaderRejects() {
    for (toml, expected) in [
      ("[hint]\nkeys = \"asdf\"", "hint"),
      ("[hints]\nmin_lenght = 2", "min_lenght"),
      ("[hints]\nmin_length = \"two\"", "min_length"),
      ("[statusbar]\nmonitor = \"left\"", "monitor"),
      ("[mode.normal.mappings]\nj = \"scroll down\"", "j"),
      ("[mode.text]\nenabled = \"yes\"", "enabled"),
      ("[mode.apps.\"com.example.app\".text]\nenabled = \"yes\"", "text.enabled"),
      ("[popup.notes]\ncommand = [\"vim\"]\ntext = \"#{x}\"", "notes"),
      ("[macos.dock]\nautohide = true", "macos"),
      ("[startup]\nrun = \"killall Dock\"", "startup.run"),
      ("[startup]\nrun = [[]]", "startup.run"),
      ("[startup]\ntimeout = \"soon\"", "startup.timeout"),
      ("[app]\nupdates = \"sometimes\"", "updates"),
      ("[flashlight.bangs]\njira = 42", "jira"),
      ("[flashlight.bangs]\njira = { description = \"no url\" }", "jira"),
    ] {
      let problems = errors(for: toml)
      XCTAssertFalse(problems.isEmpty, "\(toml) should not validate")
      XCTAssertTrue(problems.contains { $0.contains(expected) }, "\(toml): \(problems)")
    }
  }

  /// Global and per-app text switches sit beside their text mappings.
  func testTheTextSwitchesValidate() {
    XCTAssertEqual(
      errors(
        for: """
          [mode.text]
          enabled = false
          [mode.text.mappings]
          "H" = ["flash", "history", "back"]
          [mode.apps."com.microsoft.VSCode".text]
          enabled = true
          [mode.apps."com.apple.Safari".text.mappings]
          "L" = false
          """), [])
    let mode = (Self.schema["properties"] as? [String: Any])?["mode"] as? [String: Any]
    let text = (mode?["properties"] as? [String: Any])?["text"] as? [String: Any]
    let enabled = (text?["properties"] as? [String: Any])?["enabled"] as? [String: Any]
    XCTAssertEqual(enabled?["type"] as? String, "boolean")
    XCTAssertFalse((enabled?["description"] as? String ?? "").isEmpty)
  }

  func testAppTextSchemaAllowsTheSwitchBesideMappingsAndRejectsAScalar() {
    XCTAssertEqual(
      errors(
        for: """
          [mode.apps."com.microsoft.VSCode".text]
          enabled = true
          [mode.apps."com.microsoft.VSCode".text.mappings]
          "H" = ["flash", "history", "back"]
          """), [])
    XCTAssertFalse(
      errors(for: "[mode.apps.\"com.microsoft.VSCode\"]\ntext = true").isEmpty)
  }

  func testDescriptionsComeFromTheCommentsAboveEachKey() throws {
    let hints = try XCTUnwrap(
      (Self.schema["properties"] as? [String: Any])?["hints"] as? [String: Any])
    let keys = try XCTUnwrap((hints["properties"] as? [String: Any])?["keys"] as? [String: Any])
    XCTAssertFalse((keys["description"] as? String ?? "").isEmpty)
    let comments = ConfigSchema.comments(
      in: "#:schema x\n# Example table\n[a]\n# Says b.\nb = 1\n# c = 2\nd = 3\n"
        + "# e = [\n#   [\"x\"],\n# ]\nf = 4\n# Says g.\n# g = [\n# ]\n# Says g, really.\ng = 5")
    XCTAssertEqual(comments["a"], "Example table")
    XCTAssertEqual(comments["a.b"], "Says b.")
    XCTAssertNil(comments["a.d"], "a commented-out example describes nothing")
    XCTAssertNil(comments["a.f"], "nor does a multi-line one, its closing bracket included")
    XCTAssertEqual(comments["a.g"], "Says g, really.")
  }

  // MARK: A draft-07 subset validator: what ConfigSchema emits

  private func errors(for toml: String) -> [String] {
    guard let table = try? TOMLTable(string: toml) else { return ["not TOML"] }
    var problems: [String] = []
    validate(ConfigSchema.plain(table), against: Self.schema, path: "", into: &problems)
    return problems
  }

  private func validate(
    _ value: Any, against schema: [String: Any], path: String, into problems: inout [String]
  ) {
    if let options = schema["anyOf"] as? [[String: Any]] {
      let ok = options.contains { option in
        var nested: [String] = []
        validate(value, against: option, path: path, into: &nested)
        return nested.isEmpty
      }
      if !ok { problems.append("\(path): matches none of its forms") }
      return
    }
    if let constant = schema["const"] {
      if !equal(value, constant) { problems.append("\(path): must be \(constant)") }
      return
    }
    if let type = schema["type"] as? String, !matches(value, type) {
      problems.append("\(path): must be \(type)")
      return
    }
    if let values = schema["enum"] as? [Any], !values.contains(where: { equal(value, $0) }) {
      problems.append("\(path): must be one of \(values)")
    }
    if let pattern = schema["pattern"] as? String, let string = value as? String,
      string.range(of: pattern, options: .regularExpression) == nil
    {
      problems.append("\(path): does not match \(pattern)")
    }
    if let number = value as? Double ?? (value as? Int).map(Double.init) {
      if let minimum = schema["minimum"] as? Double ?? (schema["minimum"] as? Int).map(Double.init),
        number < minimum
      {
        problems.append("\(path): below \(minimum)")
      }
      if let maximum = schema["maximum"] as? Double ?? (schema["maximum"] as? Int).map(Double.init),
        number > maximum
      {
        problems.append("\(path): above \(maximum)")
      }
    }
    if let array = value as? [Any] {
      if let minimum = schema["minItems"] as? Int, array.count < minimum {
        problems.append("\(path): fewer than \(minimum) items")
      }
      if let items = schema["items"] as? [String: Any] {
        for (index, item) in array.enumerated() {
          validate(item, against: items, path: "\(path)[\(index)]", into: &problems)
        }
      }
    }
    if let object = value as? [String: Any] {
      let properties = schema["properties"] as? [String: Any] ?? [:]
      for key in schema["required"] as? [String] ?? [] where object[key] == nil {
        problems.append("\(path).\(key): required")
      }
      for (key, child) in object {
        let childPath = path.isEmpty ? key : "\(path).\(key)"
        if let property = properties[key] as? [String: Any] {
          validate(child, against: property, path: childPath, into: &problems)
        } else if let additional = schema["additionalProperties"] as? [String: Any] {
          validate(child, against: additional, path: childPath, into: &problems)
        } else if schema["additionalProperties"] as? Bool == false {
          problems.append("\(childPath): unknown key")
        }
      }
    }
  }

  private func matches(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "boolean": return value is Bool
    case "integer": return value is Int
    case "number": return value is Int || value is Double
    default: return true
    }
  }

  private func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case (let a as Bool, let b as Bool): return a == b
    case (let a as Int, let b as Int): return a == b
    case (let a as String, let b as String): return a == b
    default: return false
    }
  }
}

import FlashCore
import Foundation
import XCTest

@testable import flash

/// Flash never edits text (AGENTS.md hard constraint 11): NORMAL and VISUAL
/// navigate, select, copy and paste; deleting, changing or inserting text
/// belongs to the app (or to kindaVim or SketchyVim, inside a field). The
/// only way into INSERT is bare `mode insert`. These tests walk every default
/// table and the whole command catalog, so a command that edits text, or a
/// second way into INSERT, has to get past them on purpose
/// ([what Flash does not do with text](docs/vim.md)).
final class NoTextEditingTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The topics whose commands act on text, and every action they may take:
  /// the cursor moves `move` and the motions use, the selection keys
  /// VISUAL falls back on, copy and paste. The clipboard's `delete` drops a
  /// history entry, never text.
  private static let textTopicActions: [String: Set<String>] = [
    "input": [
      "focus", "line_start", "line_end", "char_left", "char_right", "line_up", "line_down",
      "document_start", "document_end", "select_left", "select_right", "select_up",
      "select_down", "select_word_left", "select_word_right", "select_line_start",
      "select_line_end", "select_document_start", "select_document_end",
    ],
    "selection": ["copy", "paste", "swap_ends"],
    "clipboard": ["copy", "paste", "show", "delete", "pin", "unpin", "restore"],
    "register": ["yank", "paste"],
  ]

  /// Words no command action may contain in any topic: each names an edit.
  private static let editingWords: Set<String> = [
    "cut", "newline", "backspace", "substitute", "change", "replace", "transpose", "indent",
    "outdent", "type", "insert", "delete",
  ]

  /// The command words a command that changes the mode may have.
  private static let modeCommands: Set<String> = [
    "mode insert", "mode normal", "mode leave", "mode command", "mode layer", "mode terminal",
    "mode visual",
  ]

  /// Why `command` edits text or enters INSERT other than by bare `mode
  /// insert`; nil when it does neither. `inDefaults` also refuses raw keys,
  /// which could type or delete anything (`key send` stays the user's).
  private static func violation(_ command: URLCommand, inDefaults: Bool) -> String? {
    if case .confirm(let wrapped) = command {
      return violation(wrapped.command, inDefaults: inDefaults)
    }
    if case .pluginCommand = command { return nil }
    let argv = command.argv
    guard argv.count >= 3, argv[0] == "flash", let name = CommandName("\(argv[1]) \(argv[2])")
    else { return "\(argv) is not a Flash command" }
    let line = argv.dropFirst().joined(separator: " ")
    if inDefaults, case .sendKey = command { return "\(line) sends raw keys" }
    if inDefaults, case .sendKeys = command { return "\(line) sends raw keys" }
    if let allowed = textTopicActions[name.topic], !allowed.contains(name.action) {
      return "\(line) acts on text but neither moves, selects, copies nor pastes"
    }
    let words = Set(name.action.split(separator: "_").map(String.init))
    if name.description != "mode insert", name.description != "clipboard delete",
      let word = words.intersection(editingWords).sorted().first
    {
      return "\(line) names an edit (\(word))"
    }
    if command.changesMode, !modeCommands.contains(name.description) {
      return "\(line) changes the mode outside the mode topic"
    }
    if name.description == "mode insert", argv.count > 3 {
      return "\(line) enters INSERT other than by bare mode insert"
    }
    return nil
  }

  // MARK: The default tables

  /// Every default table, as Flash builds it, as an empty file loads it and
  /// as the reference file restates it, plus the tables the interpreter
  /// derives from them (text over NORMAL, VISUAL's motions, HOLD over
  /// NORMAL): no default deletes, changes or inserts text, or enters INSERT
  /// but bare `mode insert`.
  func testNoDefaultMappingEditsText() throws {
    let bundled = ConfigLoader.parse(
      try String(
        contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8))
    XCTAssertTrue(bundled.diagnostics.isEmpty, "\(bundled.diagnostics)")
    for (origin, config) in [
      ("built-in", Config.default), ("empty file", ConfigLoader.parse("")),
      ("config.default.toml", bundled),
    ] {
      let mode = config.mode
      let tables: [(String, [ModeMapping])] = [
        ("all", mode.all), ("normal", mode.normal), ("text", mode.text),
        ("visual", mode.visual), ("hold", mode.hold), ("hyper", mode.hyper),
        ("insert", mode.insert), ("command", mode.command), ("terminal", mode.terminal),
        ("normal, resolved", mode.mappings(for: .normal)),
        ("insert, resolved", mode.mappings(for: .insert)),
        ("text, resolved", mode.textMappings()), ("visual, resolved", mode.visualMappings()),
        ("hold, resolved", mode.heldMappings(.hold)),
      ]
      for (table, mappings) in tables {
        XCTAssertFalse(
          mappings.isEmpty && ["normal", "text", "visual", "hold"].contains(table),
          "\(origin) \(table) is empty")
        for mapping in mappings {
          guard let command = mapping.action.command else {
            XCTFail("\(origin) [\(table)] \(mapping.key) runs a program by default")
            continue
          }
          if let violation = Self.violation(command, inDefaults: true) {
            XCTFail("\(origin) [\(table)] \(mapping.key): \(violation)")
          }
        }
      }
    }
  }

  /// Vim's insert and change keys are unbound in NORMAL, and so swallowed:
  /// only `i` enters INSERT. VISUAL keeps `y`, `p`, `P` and the clipboard
  /// chords but cuts nothing, and HOLD has no cut.
  func testOnlyIEntersInsertAndNothingCuts() {
    let mode = Config.default.mode
    func command(_ mappings: [ModeMapping], _ raw: String) -> URLCommand? {
      let key = NormalModeInterpreter.canonicalizeMappingKey(raw) ?? raw
      return mappings.first { $0.key == key }?.action.command
    }
    let insertEntries = mode.normal.filter {
      $0.action.command.map { Array($0.argv.prefix(3)) == ["flash", "mode", "insert"] } ?? false
    }
    XCTAssertEqual(insertEntries.map(\.key), ["i"])
    XCTAssertEqual(command(mode.normal, "i"), .insertMode)
    for raw in ["I", "a", "A", "o", "O", "S", "C", "cmd+x"] {
      XCTAssertNil(command(mode.normal, raw), "NORMAL \(raw)")
    }
    for raw in ["d", "x", "c", "s", "cmd+x"] {
      XCTAssertNil(command(mode.visual, raw), "VISUAL \(raw)")
      XCTAssertNil(command(mode.visualMappings(), raw), "VISUAL resolved \(raw)")
    }
    for raw in ["d", "x"] {
      XCTAssertNil(command(mode.hold, raw), "HOLD \(raw)")
    }
  }

  // MARK: The command catalog

  /// Every command in the catalog, bare and with each value its parameters
  /// name, neither edits text nor enters INSERT but as bare `mode insert`.
  func testNoCommandEditsText() {
    for name in URLEventHandler.commandNames {
      for args in Self.argumentVariants(of: name) {
        guard
          let command = URLEventHandler.parse(topic: name.topic, action: name.action, args: args)
        else { continue }
        if let violation = Self.violation(command, inDefaults: false) {
          XCTFail("\(name) \(args): \(violation)")
        }
      }
    }
  }

  /// The removed edits are not commands: no alias, no accept-both path.
  func testTheRemovedEditsAreUnknown() {
    for words in [
      ["selection", "cut"], ["clipboard", "cut"], ["input", "newline"],
      ["input", "delete_backward"], ["input", "delete_forward"],
    ] {
      XCTAssertNil(URLEventHandler.parse(words: words), words.joined(separator: " "))
      XCTAssertNil(URLEventHandler.summary(of: CommandName(words[0], words[1])))
    }
  }

  /// `mode insert` takes no argument: a placement or a change before it is
  /// malformed, and rejected.
  func testModeInsertIsBare() {
    let name = CommandName("mode", "insert")
    XCTAssertEqual(URLEventHandler.commandParameters(of: name)?.map(\.name), [])
    XCTAssertEqual(URLEventHandler.parse(words: ["mode", "insert"]), .insertMode)
    for argument in [
      "--at=after_cursor", "--at=line_start", "--at=line_end", "--open=below", "--open=above",
      "--change=char", "--change=line", "--change=line_end", "--change=selection",
    ] {
      XCTAssertNil(URLEventHandler.parse(words: ["mode", "insert", argument]), argument)
      XCTAssertNil(parseMappingCommand(argv: ["flash", "mode", "insert", argument]), argument)
    }
  }

  /// No bundled plugin binds a chord for an edit: the binding keys are the
  /// catalog's, and the catalog has none.
  func testNoBundledPluginBindsAnEdit() throws {
    let plugins = Self.root.appendingPathComponent("Plugins")
    for id in try FileManager.default.contentsOfDirectory(atPath: plugins.path).sorted() {
      let url = plugins.appendingPathComponent(id).appendingPathComponent("manifest.json")
      guard let data = FileManager.default.contents(atPath: url.path) else { continue }
      let manifest = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any], id)
      let bindings = manifest["bindings"] as? [String: Any] ?? [:]
      for key in bindings.keys.sorted() {
        let words = key.split(separator: " ").map(String.init)
        guard words.count >= 2, let name = CommandName("\(words[0]) \(words[1])") else {
          XCTFail("\(id) binds \(key)")
          continue
        }
        guard let command = URLEventHandler.parse(words: words) else {
          XCTFail("\(id) binds \(key), which is not a command")
          continue
        }
        XCTAssertNil(Self.violation(command, inDefaults: true), "\(id) binds \(name)")
      }
    }
  }

  /// Each argument set worth parsing for `name`: none, then each parameter
  /// alone — a flag on, an integer 1, each value a `a|b|c` placeholder lists.
  private static func argumentVariants(of name: CommandName) -> [[String: String]] {
    var variants: [[String: String]] = [[:]]
    for parameter in URLEventHandler.commandParameters(of: name) ?? [] {
      switch parameter.kind {
      case .flag:
        variants.append([parameter.name: "1"])
      case .integer:
        variants.append([parameter.name: "1"])
      case .text(let placeholder):
        let values = placeholder.split(separator: "|").map(String.init)
        guard values.count > 1 else { continue }
        variants += values.map { [parameter.name: $0] }
      }
    }
    return variants
  }
}

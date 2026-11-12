import AppKit
import FlashCore
import XCTest

@testable import flash

/// NORMAL's vim defaults: the keys bind high-level commands, `i` is the
/// explicit INSERT entry, `:` opens the command line, and no new key shadows
/// or stalls an existing default.
final class VimDefaultMappingTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static let vimDefaults: [(String, URLCommand)] = [
    (":", .commandMode),
    ("i", .insertMode),
    ("gt", .tabNext), ("gT", .tabPrev),
    ("J", .tabPrev), ("K", .tabNext),
    ("h", .move(.left)), ("j", .move(.down)), ("k", .move(.up)), ("l", .move(.right)),
    ("ctrl+d", .move(.halfPageDown)), ("ctrl+u", .move(.halfPageUp)),
    ("gg", .move(.top)), ("G", .move(.bottom)),
    ("ctrl+e", .scroll(.lineDown)), ("ctrl+y", .scroll(.lineUp)),
    ("s", .mouseBigram(.click(.leftClick, modifiers: []))),
    ("ms", .mouseBigram(.move)),
    ("ds", .mouseBigram(.click(.doubleClick, modifiers: []))),
    ("cs", .mouseBigram(.click(.rightClick, modifiers: []))),
    ("gi", .focusInput),
    ("ZZ", .saveAndQuit(force: false)), ("ZQ", .quitApp(force: false)),
    ("<less><less>", .tabMovePrev), ("<greater><greater>", .tabMoveNext),
    ("n", .findNext), ("N", .findPrevious),
    ("ctrl+f", .move(.pageDown)), ("ctrl+b", .move(.pageUp)),
    ("ctrl+w h", .focusWindow(.direction(.left))),
    ("ctrl+w j", .focusWindow(.direction(.down))),
    ("ctrl+w k", .focusWindow(.direction(.up))),
    ("ctrl+w l", .focusWindow(.direction(.right))),
    ("ctrl+w w", .focusWindow(.app(.next))),
    ("ctrl+w q", .windowClose),
    ("ctrl+w c", .windowClose),
  ]

  func testTheVimDefaultsResolveToTheirCommands() throws {
    let builtin = Dictionary(
      Config.Mode.defaultNormalMappings.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a }
    )
    let toml = try String(
      contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    let file = ConfigLoader.parse(toml)
    XCTAssertTrue(file.diagnostics.isEmpty, file.diagnostics.map(\.message).joined())
    let reference = Dictionary(
      file.mode.normal.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a })
    for (raw, command) in Self.vimDefaults {
      XCTAssertEqual(builtin[key(raw)], .flashCommand(command), raw)
      XCTAssertEqual(reference[key(raw)], .flashCommand(command), "config.default.toml \(raw)")
      XCTAssertEqual(builtin[key(raw)].map(\.argv.first), "flash", raw)
    }
  }

  /// Only `i` enters INSERT: Flash never edits text, so vim's `I` `a` `A`
  /// `o` `O` `S` `C` are unbound and swallowed, and `s` is the letter jump.
  func testOnlyIEntersInsertAndColonOpensTheCommandLine() {
    XCTAssertEqual(command(chars: "i"), .insertMode)
    for letter in ["a", "o"] {
      XCTAssertNil(command(chars: letter), letter)
    }
    for letter in ["i", "a", "o", "s", "c"] {
      XCTAssertNil(
        command(chars: letter.uppercased(), ignoring: letter, flags: [.shift]),
        letter.uppercased())
    }
    XCTAssertEqual(command(chars: "s"), .mouseBigram(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(command(chars: ":", ignoring: ";", flags: [.shift]), .commandMode)
    // The entry is the explicit command, INSERT's one way in.
    XCTAssertEqual(InsertEntry.explicitCommand.rawValue, "explicit_command")
  }

  /// Find's matches are app actions like Find itself: they move the match,
  /// never the mode.
  func testFindNextAndPreviousAreAppActionsThatKeepNormal() {
    XCTAssertEqual(command(chars: "n"), .findNext)
    XCTAssertEqual(command(chars: "N", ignoring: "n", flags: [.shift]), .findPrevious)
    XCTAssertEqual(URLCommand.findNext.sourceCommand?.name, CommandName("app", "find_next"))
    XCTAssertEqual(
      URLCommand.findPrevious.sourceCommand?.name, CommandName("app", "find_previous"))
    XCTAssertEqual(URLCommand.findNext.argv, ["flash", "app", "find_next"])
    XCTAssertEqual(URLCommand.findPrevious.argv, ["flash", "app", "find_previous"])
    XCTAssertEqual(URLEventHandler.parse(words: ["app", "find_next"]), .findNext)
    XCTAssertEqual(URLEventHandler.parse(words: ["app", "find_previous"]), .findPrevious)
    for (raw, command) in Self.vimDefaults where raw != "i" {
      XCTAssertNotEqual(command, .insertMode, raw)
    }
  }

  func testFindNextAndPreviousFollowTheMacOSConvention() throws {
    let defaults = try XCTUnwrap(
      try SourceCommandFallbackTests.officialManifests().first { $0.id == "defaults" })
    let next = try XCTUnwrap(CommandBindingKey("app find_next"))
    let previous = try XCTUnwrap(CommandBindingKey("app find_previous"))
    XCTAssertEqual(defaults.bindings[next]?[""], .chords(["cmd+g"]))
    XCTAssertEqual(defaults.bindings[previous]?[""], .chords(["cmd+shift+g"]))
    let index = CommandBindingIndex(manifests: [defaults])
    let context = PluginSelectorContext(bundleID: "com.example.unknown")
    XCTAssertEqual(index.resolve(next, in: context)?.pluginID, "defaults")
    XCTAssertEqual(index.resolve(previous, in: context)?.pluginID, "defaults")
    XCTAssertTrue(URLEventHandler.sourceCommandNames.contains(next.name))
    XCTAssertTrue(URLEventHandler.sourceCommandNames.contains(previous.name))
  }

  /// `ctrl+f` / `ctrl+b` scroll a full page where they scroll (a page, a
  /// terminal): twice the half page `ctrl+d` / `ctrl+u` derive from `[mode]
  /// scroll_page_lines`, on the same wheel path.
  func testPageScrollIsTwiceTheHalfPage() {
    let half = NormalModeDispatcher.scrollLineDelta(for: .halfPageDown)
    XCTAssertEqual(half, -FlashTunables.scrollPageLines)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .pageDown), half.map { 2 * $0 })
    XCTAssertEqual(
      NormalModeDispatcher.scrollLineDelta(for: .pageUp), 2 * FlashTunables.scrollPageLines)
    XCTAssertEqual(
      NormalModeDispatcher.scrollLineDelta(for: .pageUp, repeatCount: 3),
      6 * FlashTunables.scrollPageLines)
    XCTAssertNil(NormalModeDispatcher.edgeLineDelta(for: .pageDown))
    XCTAssertNil(NormalModeDispatcher.pixelScrollWheelDelta(for: .pageUp))
    XCTAssertEqual(URLCommand.scroll(.pageDown).argv, ["flash", "scroll", "page_down"])
    XCTAssertEqual(URLEventHandler.parse(words: ["scroll", "page_up"]), .scroll(.pageUp))
    XCTAssertEqual(command(chars: "f", flags: [.control]), .move(.pageDown))
    XCTAssertEqual(command(chars: "b", flags: [.control]), .move(.pageUp))
    XCTAssertEqual(
      MoveResolution.resolve(.pageDown, in: .document, pageLines: 15), .scroll(.pageDown))
    XCTAssertEqual(
      MoveResolution.resolve(.halfPageUp, in: .terminal, pageLines: 15), .scroll(.halfPageUp))
  }

  /// The key DSL reads a chord followed by a key as a sequence, so `ctrl+w`
  /// is vim's window prefix: it waits for the direction, then focuses.
  func testControlWIsAWindowPrefix() {
    XCTAssertEqual(NormalModeInterpreter.parseKeySequence("ctrl+w h"), ["ctrl-w", "h"])
    let pending = transition(chars: "w", flags: [.control])
    XCTAssertNil(pending.command)
    XCTAssertEqual(pending.pending, key("ctrl+w"))
    XCTAssertEqual(
      command(pending: pending.pending, chars: "h"), .focusWindow(.direction(.left)))
    XCTAssertEqual(
      command(pending: pending.pending, chars: "l"), .focusWindow(.direction(.right)))
    XCTAssertEqual(command(pending: pending.pending, chars: "w"), .focusWindow(.app(.next)))
    XCTAssertEqual(command(pending: pending.pending, chars: "q"), .windowClose)
    XCTAssertEqual(command(pending: pending.pending, chars: "c"), .windowClose)
  }

  func testShiftedPunctuationSequencesMoveTabs() {
    let less = transition(chars: "<", ignoring: ",", flags: [.shift])
    XCTAssertNil(less.command)
    XCTAssertEqual(
      command(pending: less.pending, chars: "<", ignoring: ",", flags: [.shift]), .tabMovePrev)
    let greater = transition(chars: ">", ignoring: ".", flags: [.shift])
    XCTAssertEqual(
      command(pending: greater.pending, chars: ">", ignoring: ".", flags: [.shift]), .tabMoveNext)
    let g = transition(chars: "g")
    XCTAssertEqual(command(pending: g.pending, chars: "t"), .tabNext)
    XCTAssertEqual(
      command(pending: g.pending, chars: "T", ignoring: "t", flags: [.shift]), .tabPrev)
    XCTAssertEqual(command(pending: g.pending, chars: "i"), .focusInput)
    let z = transition(chars: "Z", ignoring: "z", flags: [.shift])
    XCTAssertNil(z.command)
    XCTAssertEqual(
      command(pending: z.pending, chars: "Z", ignoring: "z", flags: [.shift]),
      .saveAndQuit(force: false))
    XCTAssertEqual(
      command(pending: z.pending, chars: "Q", ignoring: "q", flags: [.shift]),
      .quitApp(force: false))
  }

  /// A key that is both a mapping and the prefix of a longer one waits for
  /// `sequence_timeout_ms`; no default does, and no two defaults share a key.
  func testNoDefaultShadowsOrStallsAnother() {
    let keys = Config.Mode.defaultNormalMappings.map(\.key)
    XCTAssertEqual(keys.count, Set(keys).count, "a key is bound once")
    let atoms = keys.map { NormalModeInterpreter.keyAtoms(from: $0) }
    for (index, shorter) in atoms.enumerated() {
      for (other, longer) in atoms.enumerated()
      where other != index && longer.count > shorter.count
        && Array(longer.prefix(shorter.count)) == shorter
      {
        XCTFail("\(keys[index]) stalls behind \(keys[other])")
      }
    }
    // The vim rows arrived without touching what was bound before them.
    let actions = Dictionary(
      Config.Mode.defaultNormalMappings.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a }
    )
    for (raw, command) in [
      ("x", URLCommand.tabClose), ("X", .tabReopen), ("u", .undo), ("t", .tabNew),
      ("H", .historyBack), ("L", .historyForward), ("/", .find), ("?", .showMappings),
      ("gg", .move(.top)), ("G", .move(.bottom)),
      ("f", .mouseTarget(.click(.leftClick, modifiers: []))),
      ("s", .mouseBigram(.click(.leftClick, modifiers: []))), ("y", .yankSelection(register: nil)),
      ("p", .paste(register: nil)), ("r", .reload(force: false)), ("R", .reload(force: true)),
    ] {
      XCTAssertEqual(actions[key(raw)], .flashCommand(command), raw)
    }
  }

  // MARK: - Helpers

  private func command(
    pending: String = "",
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = []
  ) -> URLCommand? {
    transition(pending: pending, chars: chars, ignoring: ignoring, flags: flags).command
  }

  private func transition(
    pending: String = "",
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = []
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      repeatAnchor: nil,
      keyCode: 0,
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: CompiledMappings(Config.default.mode.normal))
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}

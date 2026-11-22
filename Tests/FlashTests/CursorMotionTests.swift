import AppKit
import FlashCore
import XCTest

@testable import flash

/// Vim's motions in editable text: `[mode.text.mappings]`, read before
/// NORMAL's keys while a field is engaged (`TextScope`), bind
/// the `cursor` commands, which land where Vim's would (`TextMotionEngine`)
/// and set the selection through Accessibility.
final class CursorMotionTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - Commands

  func testEveryMotionIsACursorCommand() throws {
    for (action, motion) in CursorCommand.motionActions {
      let command = try XCTUnwrap(URLEventHandler.parse(words: ["cursor", action]), action)
      XCTAssertEqual(command, .cursor(.motion(motion)), action)
      XCTAssertEqual(command.argv, ["flash", "cursor", action])
      XCTAssertEqual(parseMappingCommand(argv: command.argv)?.command, command)
      XCTAssertEqual(command.sourceCommand?.name, CommandName("cursor", action), action)
      XCTAssertNotNil(CursorCommand.motionSummaries[action], action)
      XCTAssertFalse(command.explanation.isEmpty)
      XCTAssertNil(URLEventHandler.parse(words: ["cursor", action, "--count=2"]), action)
    }
    XCTAssertEqual(Set(CursorCommand.motionActions.map(\.action)).count, 26)
  }

  func testCharacterSearchesTakeTheirCharacter() {
    for kind in CharacterSearchKind.allCases {
      XCTAssertEqual(
        URLEventHandler.parse(words: ["cursor", kind.rawValue]),
        .cursor(.findCharacter(kind, nil)))
      let found = URLEventHandler.parse(words: ["cursor", kind.rawValue, "--char=,"])
      XCTAssertEqual(found, .cursor(.findCharacter(kind, ",")))
      XCTAssertEqual(found?.argv, ["flash", "cursor", kind.rawValue, "--char=,"])
      XCTAssertNil(URLEventHandler.parse(words: ["cursor", kind.rawValue, "--char=ab"]))
      XCTAssertNil(URLEventHandler.parse(words: ["cursor", kind.rawValue, "--char="]))
      // A search is no binding key: an app cannot bind a character.
      XCTAssertNil(URLCommand.cursor(.findCharacter(kind, "x")).sourceCommand)
    }
    XCTAssertEqual(
      URLEventHandler.parse(words: ["cursor", "repeat_char"]),
      .cursor(.repeatCharacterSearch(reversed: false)))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["cursor", "repeat_char_back"]),
      .cursor(.repeatCharacterSearch(reversed: true)))
  }

  func testALineByNumberOrPercentage() {
    XCTAssertEqual(
      URLEventHandler.parse(words: ["cursor", "line", "--index=5"]), .cursor(.line(index: 5)))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["cursor", "line", "--percent=50"]), .cursor(.percent(50)))
    XCTAssertEqual(
      URLCommand.cursor(.line(index: 5)).argv, ["flash", "cursor", "line", "--index=5"])
    for args in [
      [], ["--index=0"], ["--percent=0"], ["--percent=101"], ["--index=2", "--percent=3"],
      ["--index=x"],
    ] {
      XCTAssertNil(URLEventHandler.parse(words: ["cursor", "line"] + args), "\(args)")
    }
  }

  func testScrollCursorAndPasteAfter() {
    for position in ScrollCursorPosition.allCases {
      let command = URLEventHandler.parse(words: ["scroll", position.rawValue])
      XCTAssertEqual(command, .scrollCursor(position))
      XCTAssertEqual(command?.argv, ["flash", "scroll", position.rawValue])
      XCTAssertNil(command?.sourceCommand)
    }
    XCTAssertEqual(
      URLEventHandler.parse(words: ["register", "paste", "--after"]),
      .paste(register: nil, after: true))
    XCTAssertEqual(
      URLCommand.paste(register: "a", after: true).argv,
      ["flash", "register", "paste", "--register=a", "--after"])
    XCTAssertEqual(URLEventHandler.parse(words: ["register", "paste"]), .paste(register: nil))
  }

  /// Vim's `.` repeats a change, never a motion.
  func testAMotionIsNotWhatDotRepeats() {
    XCTAssertFalse(MacroState.repeats(.flashCommand(.cursor(.motion(.nextWord(big: false))))))
    XCTAssertFalse(MacroState.repeats(.flashCommand(.scrollCursor(.middle))))
  }

  // MARK: - The text table

  private static let textDefaults: [(String, URLCommand)] = [
    ("w", .cursor(.motion(.nextWord(big: false)))), ("W", .cursor(.motion(.nextWord(big: true)))),
    ("b", .cursor(.motion(.previousWord(big: false)))),
    ("B", .cursor(.motion(.previousWord(big: true)))),
    ("e", .cursor(.motion(.wordEnd(big: false)))), ("E", .cursor(.motion(.wordEnd(big: true)))),
    ("ge", .cursor(.motion(.previousWordEnd(big: false)))),
    ("gE", .cursor(.motion(.previousWordEnd(big: true)))),
    ("0", .cursor(.motion(.lineStart))), ("^", .cursor(.motion(.firstNonBlank))),
    ("$", .cursor(.motion(.lineEnd))), ("g_", .cursor(.motion(.lastNonBlank))),
    ("|", .cursor(.motion(.column))),
    ("gg", .cursor(.motion(.firstLine))), ("G", .cursor(.motion(.lastLine))),
    ("%", .cursor(.motion(.matchingBracket))),
    ("{", .cursor(.motion(.previousParagraph))), ("}", .cursor(.motion(.nextParagraph))),
    ("(", .cursor(.motion(.previousSentence))), (")", .cursor(.motion(.nextSentence))),
    ("<plus>", .cursor(.motion(.nextLineFirstNonBlank))),
    ("<return>", .cursor(.motion(.nextLineFirstNonBlank))),
    ("-", .cursor(.motion(.previousLineFirstNonBlank))),
    ("_", .cursor(.motion(.lineFirstNonBlank))),
    ("H", .cursor(.motion(.screenTop))), ("M", .cursor(.motion(.screenMiddle))),
    ("L", .cursor(.motion(.screenBottom))),
    ("t", .cursor(.findCharacter(.tillNextChar, nil))),
    ("T", .cursor(.findCharacter(.tillPreviousChar, nil))),
    (";", .cursor(.repeatCharacterSearch(reversed: false))),
    (",", .cursor(.repeatCharacterSearch(reversed: true))),
    ("zt", .scrollCursor(.top)), ("zz", .scrollCursor(.middle)), ("zb", .scrollCursor(.bottom)),
    ("gj", .move(.down)), ("gk", .move(.up)),
    ("p", .paste(register: nil, after: true)), ("P", .paste(register: nil)),
    ("gv", .visualReselect),
    ("<esc>", .leaveMode),
  ]

  func testTheTextTableBindsVimsMotions() throws {
    let toml = try String(
      contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    let file = ConfigLoader.parse(toml)
    XCTAssertTrue(file.diagnostics.isEmpty, file.diagnostics.map(\.message).joined())
    let builtin = Dictionary(
      Config.default.mode.text.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a })
    let reference = Dictionary(
      file.mode.text.map { ($0.key, $0.action) }, uniquingKeysWith: { a, _ in a })
    XCTAssertEqual(builtin.count, Self.textDefaults.count)
    for (raw, command) in Self.textDefaults {
      XCTAssertEqual(builtin[key(raw)], .flashCommand(command), raw)
      XCTAssertEqual(reference[key(raw)], .flashCommand(command), "config.default.toml \(raw)")
    }
  }

  /// Reloading would lose what was typed: NORMAL's `r` / `R` do nothing in
  /// text, in the built-in defaults and the reference file alike, and a
  /// config can map them again in `[mode.text.mappings]`. `x` keeps closing
  /// the tab in a field: the close is the one asked for.
  func testKeysThatLoseTypedTextDoNothingInText() throws {
    let mode = Config.default.mode
    for raw in ["r", "R"] {
      XCTAssertNotNil(mode.compiledNormal.mapping(for: key(raw)), "NORMAL keeps \(raw)")
      XCTAssertNil(mode.compiledText.mapping(for: key(raw)), "text removes \(raw)")
    }
    XCTAssertEqual(mode.compiledText.mapping(for: key("x"))?.action, .flashCommand(.tabClose))
    let toml = try String(
      contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    let file = ConfigLoader.parse(toml)
    XCTAssertEqual(file.mode.unmapped[.text], Set(["r", "R"].map(key)))
    XCTAssertEqual(file.mode.compiledText.mapping(for: key("x"))?.action, .flashCommand(.tabClose))
    let remapped = ConfigLoader.parse(
      """
      [mode.text.mappings]
      "r" = ["flash", "app", "reload"]
      """)
    XCTAssertNotNil(remapped.mode.compiledText.mapping(for: key("r")))
  }

  /// In text the table answers first and NORMAL answers the rest; outside
  /// text NORMAL alone: `H`, `L` and `t` keep their Flash meaning there, and
  /// `f` stays the hints in both.
  func testTheTextTableLayersOverNormal() {
    let mode = Config.default.mode
    let text = mode.compiledText
    let normal = mode.compiledNormal
    XCTAssertEqual(
      text.mapping(for: key("H"))?.action, .flashCommand(.cursor(.motion(.screenTop))))
    XCTAssertEqual(normal.mapping(for: key("H"))?.action, .flashCommand(.historyBack))
    XCTAssertEqual(normal.mapping(for: key("L"))?.action, .flashCommand(.historyForward))
    XCTAssertEqual(normal.mapping(for: key("t"))?.action, .flashCommand(.tabNew))
    XCTAssertEqual(normal.mapping(for: key("gg"))?.action, .flashCommand(.move(.top)))
    XCTAssertNil(normal.mapping(for: key("w")))
    for raw in ["f", "F", "j", "k", "h", "l", "gt", "s", "ms", "ctrl+d"] {
      XCTAssertEqual(
        text.mapping(for: key(raw))?.action, normal.mapping(for: key(raw))?.action, raw)
    }
    XCTAssertEqual(
      AppDelegate.interpreterTable(for: .text, in: mode), mode.compiledText)
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.text, for: .text))
    XCTAssertTrue(MappingsCoordinator.scopeIsActive(.normal, for: .text))
    XCTAssertFalse(MappingsCoordinator.scopeIsActive(.text, for: .normal))
  }

  /// The table is the user's: a key mapped there wins in text, `false`
  /// removes it there (NORMAL's own binding of that key too, as in HOLD),
  /// and an app's table drops an entry for that app, where NORMAL's key
  /// answers again.
  func testTheTextTableIsConfigurable() {
    let config = ConfigLoader.parse(
      """
      [mode.text.mappings]
      "H" = ["flash", "history", "back"]
      "M" = false
      "w" = ["flash", "cursor", "next_big_word"]
      [mode.apps."com.apple.TextEdit".text.mappings]
      "L" = false
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    let text = config.mode.compiledText
    XCTAssertEqual(text.mapping(for: key("H"))?.action, .flashCommand(.historyBack))
    XCTAssertNil(text.mapping(for: key("M")))
    XCTAssertEqual(
      text.mapping(for: key("w"))?.action, .flashCommand(.cursor(.motion(.nextWord(big: true)))))
    XCTAssertEqual(
      text.mapping(for: key("L"))?.action, .flashCommand(.cursor(.motion(.screenBottom))))
    let textEdit = EffectiveMappings.merge(
      base: config.mode, plugin: [], bundleID: "com.apple.TextEdit")
    XCTAssertEqual(
      textEdit.compiledText.mapping(for: key("L"))?.action, .flashCommand(.historyForward))
  }

  // MARK: - The interpreter

  func testATillReadsTheNextKeyAsItsCharacter() {
    let t = transition(chars: "t")
    XCTAssertNil(t.command)
    XCTAssertEqual(
      command(pending: t.pending, chars: ","), .cursor(.findCharacter(.tillNextChar, ",")))
    // A count carries over: `3t` then `x`.
    let three = transition(chars: "3")
    let counted = transition(pending: three.pending, chars: "t")
    let found = transition(pending: counted.pending, chars: "x")
    XCTAssertEqual(found.command, .cursor(.findCharacter(.tillNextChar, "x")))
    XCTAssertEqual(found.repeatCount, 3)
    // Even a key NORMAL maps is the character.
    XCTAssertEqual(
      command(pending: t.pending, chars: "f"), .cursor(.findCharacter(.tillNextChar, "f")))
    // Shifted characters count; Escape, Return and chords cancel.
    XCTAssertEqual(
      command(pending: t.pending, chars: "T", flags: [.shift]),
      .cursor(.findCharacter(.tillNextChar, "T")))
    XCTAssertNil(command(pending: t.pending, chars: "\u{1B}"))
    XCTAssertEqual(transition(pending: t.pending, chars: "\u{1B}").pending, "")
    XCTAssertNil(command(pending: t.pending, chars: "\r"))
    XCTAssertNil(command(pending: t.pending, chars: "x", flags: [.command]))
    XCTAssertEqual(
      command(pending: t.pending, chars: "\t"), .cursor(.findCharacter(.tillNextChar, "\t")))
  }

  /// `{count}G`, `{count}gg` and `{count}%` name a line, as in Vim; without
  /// a count `G` is the last line and `%` the matching bracket.
  func testACountNamesTheLine() {
    let five = transition(chars: "5")
    XCTAssertEqual(
      command(pending: five.pending, chars: "G", ignoring: "g", flags: [.shift]),
      .cursor(.line(index: 5)))
    let g = transition(pending: five.pending, chars: "g")
    XCTAssertEqual(command(pending: g.pending, chars: "g"), .cursor(.line(index: 5)))
    XCTAssertEqual(
      command(pending: five.pending, chars: "%", ignoring: "5", flags: [.shift]),
      .cursor(.percent(5)))
    XCTAssertEqual(
      command(chars: "G", ignoring: "g", flags: [.shift]), .cursor(.motion(.lastLine)))
    XCTAssertEqual(
      command(chars: "%", ignoring: "5", flags: [.shift]), .cursor(.motion(.matchingBracket)))
  }

  /// `0` is a motion at the start of a count and a digit inside one: `10j`
  /// is ten lines.
  func testZeroIsAMotionOnlyAtTheStartOfACount() {
    XCTAssertEqual(command(chars: "0"), .cursor(.motion(.lineStart)))
    let one = transition(chars: "1")
    let ten = transition(pending: one.pending, chars: "0")
    XCTAssertNil(ten.command)
    let down = transition(pending: ten.pending, chars: "j")
    XCTAssertEqual(down.command, .move(.down))
    XCTAssertEqual(down.repeatCount, 10)
  }

  // MARK: - Resolution

  func testEachCommandResolvesToTheEnginesMotion() {
    let search = TextCharacterSearch(character: "x", forward: true, till: true)
    func resolve(_ command: CursorCommand, last: TextCharacterSearch? = search)
      -> (TextMotion, Int?, Bool)?
    {
      CursorResolution.motion(for: command, count: 3, lastSearch: last).map {
        ($0.motion, $0.count, $0.isRepeat)
      }
    }
    XCTAssertEqual(resolve(.motion(.nextWord(big: false)))?.1, 3)
    // `G` and `gg` read their count as a line before this, so a repeat
    // count means nothing to them.
    XCTAssertNil(resolve(.motion(.lastLine))?.1)
    XCTAssertEqual(resolve(.motion(.lastLine))?.0, .lastLine)
    XCTAssertEqual(resolve(.line(index: 7))?.0, .firstLine)
    XCTAssertEqual(resolve(.line(index: 7))?.1, 7)
    XCTAssertEqual(resolve(.percent(40))?.0, .percent)
    XCTAssertNil(resolve(.findCharacter(.nextChar, nil)))
    XCTAssertEqual(
      resolve(.findCharacter(.previousChar, "y"))?.0,
      .find(TextCharacterSearch(character: "y", forward: false, till: false)))
    XCTAssertEqual(resolve(.repeatCharacterSearch(reversed: false))?.0, .find(search))
    XCTAssertEqual(resolve(.repeatCharacterSearch(reversed: false))?.2, true)
    XCTAssertEqual(resolve(.repeatCharacterSearch(reversed: true))?.0, .find(search.reversed))
    XCTAssertNil(resolve(.repeatCharacterSearch(reversed: false), last: nil))
  }

  /// The landing comes from the app's text; a secure field, or an app that
  /// gives no text, has none (its binding runs instead).
  func testTheLandingComesFromTheText() {
    let contents = FocusedText.Contents(selection: 0..<0, length: 11, text: "foo bar baz")
    XCTAssertEqual(
      CursorResolution.target(
        .nextWord(big: false), count: 2, isRepeat: false, in: contents, visible: nil), 8)
    XCTAssertEqual(
      CursorResolution.target(.lineEnd, count: 1, isRepeat: false, in: contents, visible: nil),
      10)
    // From where the selection starts.
    let selected = FocusedText.Contents(selection: 4..<7, length: 11, text: "foo bar baz")
    XCTAssertEqual(
      CursorResolution.target(
        .previousWord(big: false), count: 1, isRepeat: false, in: selected, visible: nil), 0)
    let secure = FocusedText.Contents(selection: 2..<2, length: 8, text: nil)
    XCTAssertNil(
      CursorResolution.target(.lineEnd, count: 1, isRepeat: false, in: secure, visible: nil))
    // `H` needs the visible range.
    let lines = FocusedText.Contents(selection: 0..<0, length: 11, text: "a\nb\nc\nd\ne\nf")
    XCTAssertNil(
      CursorResolution.target(.screenTop, count: 1, isRepeat: false, in: lines, visible: nil))
    XCTAssertEqual(
      CursorResolution.target(.screenTop, count: 1, isRepeat: false, in: lines, visible: 4..<9),
      4)
  }

  func testScrollingTheCursorLineIntoPlace() {
    let area = CGRect(x: 0, y: 100, width: 400, height: 300)
    let caret = CGRect(x: 10, y: 250, width: 8, height: 20)
    XCTAssertEqual(ScrollCursorPosition.top.scrollDelta(caret: caret, area: area), 150)
    XCTAssertEqual(ScrollCursorPosition.middle.scrollDelta(caret: caret, area: area), 10)
    XCTAssertEqual(ScrollCursorPosition.bottom.scrollDelta(caret: caret, area: area), -130)
  }

  // MARK: - Bindings

  /// Where an app gives no text, its chord for the motion runs: the macOS
  /// ones for `b`, `e`, `0`, `$`, `gg` and `G`; a terminal binds none.
  func testTheMacOSChordsAreTheFallback() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let expected: [String: String] = [
      "previous_word": "alt+left", "previous_big_word": "alt+left", "word_end": "alt+right",
      "big_word_end": "alt+right", "line_start": "cmd+left", "line_end": "cmd+right",
      "first_line": "cmd+up", "last_line": "cmd+down",
    ]
    let textEdit = PluginSelectorContext(bundleID: "com.apple.TextEdit")
    for (action, _) in CursorCommand.motionActions {
      let key = try XCTUnwrap(CommandBindingKey("cursor \(action)"))
      let binding = index.binding(key, in: textEdit)
      if let chord = expected[action] {
        guard case .chords(let chords)? = binding else {
          XCTFail(action)
          continue
        }
        XCTAssertEqual(
          chords.map(BindingChord.init),
          [BindingChord(try XCTUnwrap(HotkeySyntax.parse(hotkey: chord)))], action)
      } else {
        XCTAssertNil(binding, "\(action): macOS has no chord, so nothing is guessed")
      }
      for emulator in TerminalEmulatorFixture.official {
        XCTAssertEqual(
          SourceCommandFallback.resolve(
            key.name, binding: index.binding(key, in: PluginSelectorContext(bundleID: emulator))),
          SourceCommandFallback.none, "\(action) in \(emulator)")
      }
    }
  }

  // MARK: - Helpers

  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func command(
    pending: String = "", chars: String, ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = []
  ) -> URLCommand? {
    transition(pending: pending, chars: chars, ignoring: ignoring, flags: flags).command
  }

  private func transition(
    pending: String = "", chars: String, ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = []
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, repeatAnchor: nil, keyCode: 0xFFFF, modifierFlags: flags,
      characters: chars, charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: Config.default.mode.compiledText)
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}

import AppKit
import FlashCore
import XCTest

@testable import flash

/// VISUAL: `v` and `V` in editable text start a selection the motions grow
/// from an anchor; its operators copy it or paste over it with the app's own
/// keys, then NORMAL. Nothing cuts, deletes or changes it: Flash never edits
/// text. It ends whenever the focus moves.
final class VisualModeTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  // MARK: - The mode

  func testVisualStartsFromNormalAndSwitchesKind() {
    XCTAssertEqual(
      ModeReducer.reduce(.normal, .enterVisual(.charwise)).0, .visual(.charwise))
    XCTAssertEqual(ModeReducer.reduce(.normal, .enterVisual(.charwise)).1, [.renderSurface])
    XCTAssertEqual(
      ModeReducer.reduce(.visual(.charwise), .enterVisual(.linewise)).0, .visual(.linewise))
    for state in [
      Mode.insert, .disabled, .command(restoreTo: .normal), .hold, .hyper(restoreTo: .normal),
      .terminal(restoreTo: .normal, returnPID: nil),
      .layer(LayerMode(name: "resize", sticky: true, restoreTo: .normal)),
    ] {
      XCTAssertEqual(ModeReducer.reduce(state, .enterVisual(.charwise)).0, state, "\(state)")
    }
  }

  /// VISUAL ends in NORMAL: Escape, an operator, the focus moving to
  /// another app. Only a mapping of your own to `mode insert`, the one way
  /// in, leaves it for INSERT.
  func testVisualEndsInNormalOrThroughModeInsert() {
    for kind in VisualKind.allCases {
      let visual = Mode.visual(kind)
      XCTAssertEqual(ModeReducer.reduce(visual, .leaveVisual).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(visual, .leaveMode(hasHints: false)).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(visual, .focusedAppChanged(pid: 9)).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(visual, .enterNormal).0, .normal)
      XCTAssertEqual(ModeReducer.reduce(visual, .enterInsert(.explicitCommand)).0, .insert)
      XCTAssertEqual(ModeReducer.reduce(visual, .enterHyper).0, visual, "no HYPER over it")
      XCTAssertEqual(ModeReducer.reduce(visual, .buttonHeld(.hold)).0, visual)
      XCTAssertEqual(ModeReducer.reduce(visual, .advancedModeChanged(enabled: false)).0, .disabled)
      let command = ModeReducer.reduce(visual, .openCommand(restoreMode: true)).0
      XCTAssertEqual(command, .command(restoreTo: .normal))
    }
    XCTAssertEqual(ModeReducer.reduce(.normal, .leaveVisual).0, .normal)
    XCTAssertEqual(ModeReducer.reduce(.normal, .leaveVisual).1, [])
  }

  func testVisualProjectsLikeNormalWithItsOwnTableAndPill() {
    for kind in VisualKind.allCases {
      let mode = Mode.visual(kind)
      XCTAssertEqual(mode.flashMode, .normal)
      XCTAssertEqual(mode.asReturnMode, .normal)
      XCTAssertTrue(mode.ownsKeyboard(hasHints: false, activationInFlight: false))
      XCTAssertEqual(mode.overlayInputMode(hasHints: false, activationInFlight: false), .normal)
      XCTAssertEqual(mode.mappingScope, .visual)
      XCTAssertEqual(mode.label, .visual(kind))
      XCTAssertEqual(mode.badgeStyle, .visual)
      XCTAssertEqual(FlashStatusReport.modeName(mode), "visual")
      XCTAssertFalse(mode.canToggleHoldMode)
    }
    XCTAssertEqual(MappingScope.visual.name, "visual")
    XCTAssertTrue(Config.Mode.reservedLayerNames.contains("visual"))
    XCTAssertTrue(Config.Mode.reservedLayerNames.contains("text"))
  }

  // MARK: - Commands

  func testModeVisualAndTheSelectionOperatorsParse() {
    XCTAssertEqual(URLEventHandler.parse(words: ["mode", "visual"]), .visualMode(.charwise))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["mode", "visual", "--line"]), .visualMode(.linewise))
    XCTAssertEqual(URLCommand.visualMode(.linewise).argv, ["flash", "mode", "visual", "--line"])
    XCTAssertEqual(URLCommand.visualMode(.charwise).changesMode, true)
    XCTAssertNil(URLCommand.visualMode(.charwise).sourceCommand)
    XCTAssertEqual(
      URLEventHandler.parse(words: ["selection", "swap_ends"]), .selection(.swapEnds))
    XCTAssertNil(URLEventHandler.parse(words: ["selection", "swap_ends", "--register=a"]))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["selection", "paste", "--register=a"]),
      .selection(.paste, register: "a"))
    // VISUAL copies and pastes; it never cuts, deletes or changes the text.
    for words in [
      ["selection", "change"], ["selection", "cut"], ["selection", "delete"],
      ["mode", "insert", "--change=selection"],
    ] {
      XCTAssertNil(URLEventHandler.parse(words: words), words.joined(separator: " "))
    }
  }

  /// A register prefix reaches every operator that names one.
  func testARegisterPrefixReachesTheOperators() {
    for action in [SelectionAction.copy, .paste] {
      XCTAssertEqual(
        NormalModeInterpreter.applyingRegister("a", to: .flashCommand(.selection(action))),
        .flashCommand(.selection(action, register: "a")), "\(action)")
    }
    XCTAssertEqual(
      NormalModeInterpreter.applyingRegister("a", to: .flashCommand(.selection(.swapEnds))),
      .flashCommand(.selection(.swapEnds)))
    XCTAssertEqual(SelectionAction.allCases, [.copy, .paste, .swapEnds])
  }

  // MARK: - The VISUAL table

  func testVisualReadsItsOperatorsThenTheMotions() throws {
    let mode = Config.default.mode
    let visual = mode.compiledVisual
    let own: [(String, URLCommand)] = [
      ("y", .selection(.copy)), ("p", .selection(.paste)), ("P", .selection(.paste)),
      ("o", .selection(.swapEnds)), ("v", .visualMode(.charwise)),
      ("V", .visualMode(.linewise)), ("<esc>", .leaveMode),
    ]
    for (raw, command) in own {
      XCTAssertEqual(visual.mapping(for: key(raw))?.action, .flashCommand(command), raw)
    }
    XCTAssertEqual(mode.visual.count, own.count, "VISUAL binds nothing else of its own")
    // No cut, delete or change: those keys are swallowed. The app's own
    // copy and paste belong to INSERT, so VISUAL binds neither chord.
    for raw in ["d", "x", "c", "s", "C", "S", "cmd+x", "X", "D", "r", "R", "cmd+c", "cmd+v"] {
      XCTAssertNil(visual.mapping(for: key(raw)), raw)
    }
    // The motions grow the selection: NORMAL's moves and the text table's.
    for (raw, command) in [
      ("j", URLCommand.move(.down)), ("k", .move(.up)), ("h", .move(.left)),
      ("ctrl+d", .move(.halfPageDown)), ("w", .cursor(.motion(.nextWord(big: false)))),
      ("$", .cursor(.motion(.lineEnd))), ("G", .cursor(.motion(.lastLine))),
      ("t", .cursor(.findCharacter(.tillNextChar, nil))), ("zz", .scrollCursor(.middle)),
      ("ctrl+e", .scroll(.lineDown)),
    ] {
      XCTAssertEqual(visual.mapping(for: key(raw))?.action, .flashCommand(command), raw)
    }
    // Nothing else: tabs, hints and app commands are swallowed.
    for raw in ["f", "gt", "u", "r", "/", "i", "x", "s", "H"] {
      XCTAssertNotEqual(
        visual.mapping(for: key(raw))?.action, mode.compiledNormal.mapping(for: key(raw))?.action,
        raw)
    }
    XCTAssertNil(visual.mapping(for: key("f")))
    XCTAssertNil(visual.mapping(for: key("gt")))
    // The all-mode chords still act.
    XCTAssertEqual(
      visual.mapping(for: key("cmd+ctrl+h"))?.action, .flashCommand(.holdMode(.primary)))
    // NORMAL's own table starts VISUAL, so `v` and `V` work before a field
    // is engaged; the text table inherits them.
    for table in [mode.compiledNormal, mode.compiledText] {
      XCTAssertEqual(
        table.mapping(for: key("v"))?.action, .flashCommand(.visualMode(.charwise)))
      XCTAssertEqual(
        table.mapping(for: key("V"))?.action, .flashCommand(.visualMode(.linewise)))
    }
    XCTAssertEqual(AppDelegate.interpreterTable(for: .visual, in: mode), mode.compiledVisual)
  }

  /// A count reaches the motion; `q` is not a macro and `m` not a mark here.
  func testCountsAndRegistersInVisual() {
    let three = transition(chars: "3")
    let down = transition(pending: three.pending, chars: "j")
    XCTAssertEqual(down.command, .move(.down))
    XCTAssertEqual(down.repeatCount, 3)
    let quote = transition(chars: "\"", ignoring: "'", flags: [.shift])
    let named = transition(pending: quote.pending, chars: "a")
    XCTAssertEqual(
      transition(pending: named.pending, chars: "y").command,
      .selection(.copy, register: "a"))
    XCTAssertNil(transition(chars: "q").command)
    XCTAssertEqual(transition(chars: "q").pending, "")
    XCTAssertEqual(transition(chars: "m").pending, "")
  }

  func testTheVisualTableIsConfigurable() throws {
    let toml = try String(
      contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    let file = ConfigLoader.parse(toml)
    XCTAssertTrue(file.diagnostics.isEmpty, file.diagnostics.map(\.message).joined())
    XCTAssertEqual(
      Set(file.mode.visual.map(\.key)), Set(Config.default.mode.visual.map(\.key)),
      "config.default.toml lists VISUAL's defaults")
    XCTAssertEqual(file.mode.labels.visual, "VISUAL")
    XCTAssertEqual(file.mode.labels.visualLine, "V-LINE")
    let config = ConfigLoader.parse(
      """
      [mode]
      labels = { normal = "N", insert = "I", command = "C", visual = "VIS", visual_line = "VL" }
      [mode.visual.mappings]
      "d" = false
      "Y" = ["flash", "selection", "copy"]
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    XCTAssertEqual(config.mode.labels.visual, "VIS")
    XCTAssertEqual(config.mode.labels.visualLine, "VL")
    XCTAssertNil(config.mode.compiledVisual.mapping(for: key("d")))
    XCTAssertEqual(
      config.mode.compiledVisual.mapping(for: key("Y"))?.action,
      .flashCommand(.selection(.copy)))
  }

  // MARK: - The selection

  /// A caret at a line's end starts on its last character, as Vim's cursor
  /// never rests past it.
  func testTheAnchorIsVimsCursor() {
    let buffer = TextBuffer("abc\n\nde")
    XCTAssertEqual(VisualPlan.start(caret: 1, in: buffer), 1)
    XCTAssertEqual(VisualPlan.start(caret: 3, in: buffer), 2)
    XCTAssertEqual(VisualPlan.start(caret: 4, in: buffer), 4, "an empty line")
    XCTAssertEqual(VisualPlan.start(caret: 7, in: buffer), 6, "the text's end")
    let emoji = TextBuffer("a👍🏽")
    XCTAssertEqual(VisualPlan.start(caret: 5, in: emoji), 1)
  }

  /// `v` covers the characters through the cursor's; `V` whole lines with
  /// the last one's break.
  func testTheRangeCoversCharactersOrWholeLines() {
    let buffer = TextBuffer("one\ntwo\n\nlast")
    XCTAssertEqual(VisualPlan.range(.charwise, anchor: 1, cursor: 1, in: buffer), 1..<2)
    XCTAssertEqual(VisualPlan.range(.charwise, anchor: 5, cursor: 1, in: buffer), 1..<6)
    XCTAssertEqual(VisualPlan.range(.linewise, anchor: 1, cursor: 1, in: buffer), 0..<4)
    XCTAssertEqual(VisualPlan.range(.linewise, anchor: 5, cursor: 1, in: buffer), 0..<8)
    XCTAssertEqual(VisualPlan.range(.linewise, anchor: 8, cursor: 8, in: buffer), 8..<9)
    XCTAssertEqual(
      VisualPlan.range(.linewise, anchor: 10, cursor: 10, in: buffer), 9..<13,
      "a last line without a break ends at the text's end")
    XCTAssertEqual(
      VisualPlan.range(.charwise, anchor: 8, cursor: 8, in: buffer), 8..<9,
      "an empty line's break")
  }

  /// Each operator's steps through the app, and the mode it ends in: `o`
  /// stays in VISUAL, `y` and `p` end in NORMAL. A named register is Flash's
  /// when it has the text, the app's clipboard when not.
  func testOperatorsActThroughTheAppAndEndInTheirMode() {
    func session(_ kind: VisualKind, measured: Bool) -> VisualSession {
      VisualSession(
        pid: 1, kind: kind, anchor: 0, cursor: 2, desiredColumn: nil,
        selected: measured ? 0..<3 : nil, measured: measured)
    }
    let charwise = session(.charwise, measured: true)
    let linewise = session(.linewise, measured: true)
    let blind = session(.linewise, measured: false)
    func steps(_ action: SelectionAction, named: Bool = false, _ session: VisualSession)
      -> [VisualOperatorStep]
    {
      VisualPlan.operatorSteps(action, named: named, session: session)
    }
    XCTAssertEqual(steps(.swapEnds, charwise), [.swapEnds])
    XCTAssertEqual(
      steps(.copy, charwise), [.writeYankRegister, .appCopy, .collapseToStart, .leave],
      "a bare yank fills \"0 too")
    XCTAssertEqual(steps(.copy, blind), [.appCopy, .collapseToStart, .leave])
    XCTAssertEqual(steps(.copy, named: true, charwise), [.writeRegister, .collapseToStart, .leave])
    XCTAssertEqual(
      steps(.copy, named: true, blind), [.appCopy, .collapseToStart, .leave],
      "without the text a named register falls back to the app's clipboard")
    XCTAssertEqual(steps(.copy, named: true, linewise), [.writeRegister, .collapseToStart, .leave])
    XCTAssertEqual(steps(.paste, charwise), [.leave, .paste])
    XCTAssertEqual(steps(.paste, named: true, blind), [.leave, .paste])
    for action in SelectionAction.allCases {
      for session in [charwise, linewise, blind] {
        for named in [false, true] {
          let plan = steps(action, named: named, session)
          switch action {
          case .swapEnds: XCTAssertFalse(plan.contains(.leave))
          case .copy, .paste: XCTAssertTrue(plan.contains(.leave), "\(action) ends in NORMAL")
          }
        }
      }
    }
  }

  /// The moving end moves; the anchor stays; `j` keeps its column.
  func testAMotionMovesTheCursorEnd() throws {
    let buffer = TextBuffer("hello world\nhi\nlonger line")
    let session = VisualSession(
      pid: 1, kind: .charwise, anchor: 3, cursor: 3, desiredColumn: nil, selected: 3..<4,
      measured: true)
    let word = try XCTUnwrap(
      VisualPlan.step(session, motion: .nextWord(big: false), count: 1, in: buffer))
    XCTAssertEqual(word.anchor, 3)
    XCTAssertEqual(word.cursor, 6)
    let down = try XCTUnwrap(VisualPlan.step(session, motion: .down, count: 1, in: buffer))
    XCTAssertEqual(down.cursor, 14, "line 2 is shorter: its line break, inclusive in VISUAL")
    let twice = try XCTUnwrap(VisualPlan.step(down, motion: .down, count: 1, in: buffer))
    XCTAssertEqual(twice.cursor, 18, "the column it aimed for comes back")
    let end = try XCTUnwrap(VisualPlan.step(session, motion: .lineEnd, count: 1, in: buffer))
    XCTAssertEqual(end.cursor, 11, "in VISUAL `$` reaches the line's end")
    XCTAssertEqual(VisualPlan.range(.charwise, anchor: 3, cursor: end.cursor, in: buffer), 3..<12)
    XCTAssertNil(VisualPlan.step(session, motion: .up, count: 1, in: buffer))
  }

  func testMovesAreLinesAndCharactersInVisual() {
    func motion(_ move: MoveCommand) -> (TextMotion, Int?) {
      let resolved = VisualPlan.motion(for: move, count: 2, pageLines: 15)
      return (resolved.motion, resolved.count)
    }
    XCTAssertEqual(motion(.down).0, .down)
    XCTAssertEqual(motion(.down).1, 2)
    XCTAssertEqual(motion(.left).0, .left)
    XCTAssertEqual(motion(.halfPageDown).1, 30)
    XCTAssertEqual(motion(.pageUp).0, .up)
    XCTAssertEqual(motion(.pageUp).1, 60)
    XCTAssertEqual(motion(.top).0, .firstLine)
    XCTAssertNil(motion(.bottom).1)
  }

  /// Without the app's text VISUAL extends the app's own selection with its
  /// keys, and does nothing where no key is safe.
  func testWithoutTheTextTheAppsSelectionKeysExtend() {
    XCTAssertEqual(VisualPlan.fallback(for: .down, count: 3)?.0, .selectDown)
    XCTAssertEqual(VisualPlan.fallback(for: .down, count: 3)?.times, 3)
    XCTAssertEqual(VisualPlan.fallback(for: .nextWord(big: false), count: nil)?.0, .selectWordRight)
    XCTAssertEqual(VisualPlan.fallback(for: .previousWord(big: true), count: 1)?.0, .selectWordLeft)
    XCTAssertEqual(VisualPlan.fallback(for: .lineEnd, count: 4)?.times, 1)
    XCTAssertEqual(VisualPlan.fallback(for: .lastLine, count: nil)?.0, .selectDocumentEnd)
    XCTAssertNil(VisualPlan.fallback(for: .matchingBracket, count: nil))
    XCTAssertNil(VisualPlan.fallback(for: .screenTop, count: nil))
  }

  func testTheAppsSelectionKeysPerAppKind() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let expected: [InputMotion: String] = [
      .selectLeft: "shift+left", .selectRight: "shift+right", .selectUp: "shift+up",
      .selectDown: "shift+down", .selectWordLeft: "shift+alt+left",
      .selectWordRight: "shift+alt+right", .selectLineStart: "shift+cmd+left",
      .selectLineEnd: "shift+cmd+right", .selectDocumentStart: "shift+cmd+up",
      .selectDocumentEnd: "shift+cmd+down",
    ]
    for (motion, chord) in expected {
      let key = CommandBindingKey(motion.commandName)
      guard
        case .chords(let chords)? = index.binding(
          key, in: PluginSelectorContext(bundleID: "com.apple.TextEdit"))
      else {
        XCTFail("\(motion)")
        continue
      }
      XCTAssertEqual(
        chords.map(BindingChord.init),
        [BindingChord(try XCTUnwrap(HotkeySyntax.parse(hotkey: chord)))], "\(motion)")
      for emulator in TerminalEmulatorFixture.official {
        XCTAssertEqual(
          SourceCommandFallback.resolve(
            motion.commandName,
            binding: index.binding(key, in: PluginSelectorContext(bundleID: emulator))),
          SourceCommandFallback.none, "\(motion) in \(emulator)")
      }
    }
  }

  /// A focus reading that names another field or app ends VISUAL; one for
  /// the same field keeps it.
  func testTheSelectionSurvivesOnlyItsOwnField() {
    let session = VisualSession(
      pid: 4, kind: .charwise, anchor: 0, cursor: 0, desiredColumn: nil, selected: 0..<1,
      measured: true, element: 77)
    XCTAssertTrue(session.survives(focusIn: 4, element: 77))
    XCTAssertFalse(session.survives(focusIn: 4, element: 78))
    XCTAssertFalse(session.survives(focusIn: 5, element: 77))
    XCTAssertFalse(session.survives(focusIn: nil, element: nil))
  }

  // MARK: - Helpers

  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func transition(
    pending: String = "", chars: String, ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = []
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, repeatAnchor: nil, keyCode: 0xFFFF, modifierFlags: flags,
      characters: chars, charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: Config.default.mode.compiledVisual)
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }
}

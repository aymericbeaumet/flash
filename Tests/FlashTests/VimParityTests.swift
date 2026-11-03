import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// The Vim parity audit: each regression a Vim user hit typing NORMAL's
/// keys, and the Vim keys Flash adds that only navigate, select, copy or
/// paste (Flash never edits text).
final class VimParityTests: XCTestCase {
  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private var normal: CompiledMappings { Config.default.mode.compiledNormal }
  private var text: CompiledMappings { Config.default.mode.compiledText }
  private var visual: CompiledMappings { Config.default.mode.compiledVisual }

  /// One plain character, as the keyboard delivers it.
  private func press(
    _ char: String, after pending: String = "", in mappings: CompiledMappings? = nil,
    recording: Bool = false
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: 0, modifierFlags: [], characters: char,
      charactersIgnoringModifiers: char, mappings: mappings ?? normal, recordingMacro: recording)
  }

  /// A chord: `ctrl` plus a letter or `[`.
  private func control(
    _ char: String, keyCode: Int, characters: String, after pending: String = "",
    in mappings: CompiledMappings? = nil
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: UInt16(keyCode), modifierFlags: [.control],
      characters: characters, charactersIgnoringModifiers: char, mappings: mappings ?? normal)
  }

  private func escape(after pending: String, in mappings: CompiledMappings? = nil)
    -> NormalModeTransition
  {
    NormalModeInterpreter.interpret(
      pending: pending, keyCode: UInt16(kVK_Escape), modifierFlags: [], characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}", mappings: mappings ?? normal)
  }

  private func type(
    _ keys: String..., in mappings: CompiledMappings? = nil, recording: Bool = false
  ) -> NormalModeTransition {
    var transition = NormalModeTransition.consume
    for key in keys {
      transition = press(key, after: transition.pending, in: mappings, recording: recording)
    }
    return transition
  }

  /// A delegate in NORMAL whose mode effects do nothing and whose capture
  /// runs through the tap, so nothing it dispatches orders a window in.
  private func delegate() -> AppDelegate {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    delegate.overlay.keyboardCaptureActive = true
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    delegate.overlay.inputMode = .normal
    return delegate
  }

  private func runMainLoop(for seconds: TimeInterval) {
    let waited = expectation(description: "main loop")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { waited.fulfill() }
    wait(for: [waited], timeout: seconds + 5)
  }

  // MARK: - 1. A chord takes the count and is a NORMAL step

  /// The regression: `ctrl+d`, `ctrl+e`, `cmd+v` and every single-chord
  /// mapping fired natively, which dropped the count typed before it
  /// (`3 ctrl+d` scrolled once) and never reached `.` or a recording.
  func testANativeChordTakesTheCountAndIsANormalStep() {
    let delegate = delegate()
    defer { delegate.overlay.orderOut(nil) }
    let chord = MappingCommand.flashCommand(.dismissHints)
    delegate.overlay.normalModePending = "3"
    delegate.dispatchNativeMappingAction(chord)
    XCTAssertEqual(delegate.overlay.normalModePending, "")
    XCTAssertEqual(
      delegate.macros.lastStep, MacroStep(action: chord, repeatCount: 3),
      "the count typed before the chord, and `.` repeats it")
    delegate.macros.startRecording("z")
    delegate.dispatchNativeMappingAction(chord)
    XCTAssertEqual(delegate.macros.stopRecording()?.count, 1, "a macro records the chord")
  }

  // MARK: - 2. A dead-end key after a prefix aborts

  /// The regression: a key that continued no sequence was read again on its
  /// own, so `gx` and `]x` closed the tab, `z.` repeated and `gu` undid.
  /// Vim abandons the sequence and the key.
  func testADeadEndKeyAfterAPrefixAbortsTheSequence() {
    for (prefix, next) in [("g", "x"), ("]", "x"), ("z", "."), ("g", "u"), ("[", "u")] {
      let broken = type(prefix, next)
      XCTAssertNil(broken.action, "\(prefix)\(next)")
      XCTAssertEqual(broken.pending, "", "\(prefix)\(next)")
    }
    let window = control("w", keyCode: kVK_ANSI_W, characters: "\u{17}")
    XCTAssertNil(window.action)
    let closed = press("x", after: window.pending)
    XCTAssertNil(closed.action, "ctrl+w x closes nothing")
    XCTAssertEqual(closed.pending, "")
    XCTAssertEqual(type("g", "t").command, .tabNext, "a sequence still completes")
  }

  // MARK: - 3. A lone topic runs only an action that shows

  /// The regression: `:di` (Vim's registers) and `:display` turned the
  /// displays off, since a topic alone ran its only action. A topic alone
  /// still runs an action that only shows a page or a surface, in one
  /// Enter (`:logs`, `flash logs`), and never one that changes anything.
  func testALoneTopicRunsOnlyAShowingActionAndDiShowsTheRegisters() throws {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
    }
    let registers = try XCTUnwrap(URLEventHandler.parse(words: ["clipboard", "show"]))
    XCTAssertEqual(resolve(":di"), .commands([registers]), "vim's :di[splay] is :reg")
    XCTAssertEqual(resolve(":display"), .commands([registers]))
    XCTAssertEqual(resolve(":reg"), .commands([registers]))
    let sleep = try XCTUnwrap(URLEventHandler.parse(words: ["display", "sleep"]))
    XCTAssertEqual(resolve(":display sleep"), .commands([sleep]), "the full command still runs")
    XCTAssertEqual(resolve(":disp sleep"), .commands([sleep]), "words after it are the topic's")
    for topic in ["screen", "screensaver", "trash", "appearance", "hints", "input"] {
      XCTAssertEqual(resolve(":\(topic)"), .incomplete(topic), "\(topic) changes something")
    }
    XCTAssertEqual(resolve(":mappings"), .commands([.showMappings]))
    XCTAssertEqual(resolve(":logs"), .commands([.showLogs]))
    XCTAssertEqual(resolve(":about"), .commands([.showAbout]))
    XCTAssertEqual(resolve(":commands"), .commands([.showCommands]))
    XCTAssertEqual(
      NormalModeDispatcher.resolveCommandWords(["logs"], inventory: inventory),
      .commands([.showLogs]), "flash logs")
    XCTAssertEqual(resolve(":logs write"), .unknown, "logs write needs its message")
    XCTAssertEqual(resolve(":plugins"), .incomplete("plugins"), "plugins show is not implied")
  }

  /// Which lone topics run an action is a property of the action,
  /// `impliedByItsTopic`: an action that only shows. Every command of the
  /// catalog is either one of those or runs nothing alone, and a topic alone
  /// runs its one such action even beside others (`:logs` is `logs show`,
  /// never `logs write`).
  func testOnlyShowingActionsAreImpliedByTheirTopic() throws {
    var implied: Set<String> = []
    for name in URLEventHandler.commandNames {
      guard
        let command = URLEventHandler.parse(topic: name.topic, action: name.action, args: [:]),
        command.impliedByItsTopic
      else { continue }
      implied.insert(name.description)
    }
    XCTAssertEqual(
      implied,
      [
        "about show", "commands show", "help show", "logs show", "mappings show",
        "media status", "monitors show", "telemetry show",
      ])
    for words in [
      ["display", "sleep"], ["screen", "lock"], ["screensaver", "start"], ["trash", "empty"],
      ["appearance", "toggle"], ["hints", "dismiss"], ["input", "focus"], ["resident", "quit"],
      ["app", "quit"], ["tab", "close"], ["window", "close"],
    ] {
      let command = try XCTUnwrap(URLEventHandler.parse(words: words), words.joined())
      XCTAssertFalse(command.impliedByItsTopic, words.joined(separator: " "))
    }
  }

  // MARK: - 4. A count before a built-in prefix is kept

  /// The regression: a count before `"`, `'` or `q` was dropped and the
  /// keys after it ran on their own (`3"ap` pasted once).
  func testACountBeforeABuiltInPrefixIsKept() throws {
    let a = try XCTUnwrap(MarkSlot(parsing: "a"))
    let paste = type("3", "\"", "a", "p")
    XCTAssertEqual(paste.command, .paste(register: "a"))
    XCTAssertEqual(paste.repeatCount, 3, "3\"ap pastes three times")
    let multiplied = type("2", "\"", "a", "3", "p")
    XCTAssertEqual(multiplied.repeatCount, 6, "2\"a3p is six, as in Vim")
    XCTAssertEqual(type("3", "'", "a").command, .marks(.jump(a)), "3'a jumps to a")
    XCTAssertEqual(type("3", "`", "a").command, .marks(.jump(a)))
    XCTAssertEqual(type("3", "q", "a").command, .macro(.record(register: "a")))
    let play = type("3", "@", "a")
    XCTAssertEqual(play.command, .macro(.play(register: "a")))
    XCTAssertEqual(play.repeatCount, 3)
  }

  // MARK: - 5. An invalid name aborts; Escape only cancels

  /// The regression: a key that named no register, mark or macro ran as a
  /// command (`".` repeated, `":` opened the command line), and Escape
  /// after a bare `"`, `q`, `@`, `'` or `` ` `` disengaged the field.
  func testAnInvalidNameAbortsAndEscapeOnlyCancels() {
    for keys in [["\"", "."], ["\"", ":"], ["q", "."], ["@", "."], ["'", "/"], ["`", "."]] {
      var transition = NormalModeTransition.consume
      for key in keys { transition = press(key, after: transition.pending) }
      XCTAssertNil(transition.action, keys.joined())
      XCTAssertEqual(transition.pending, "", keys.joined())
    }
    for prefix in ["\"", "q", "@", "'", "`"] {
      let waiting = press(prefix, in: text)
      XCTAssertFalse(waiting.pending.isEmpty, prefix)
      XCTAssertEqual(escape(after: waiting.pending, in: text), .consume, "\(prefix) Escape")
    }
  }

  // MARK: - 6. A named yank leaves the clipboard alone

  /// The regression: `"ay` overwrote the clipboard, where the manual and
  /// Vim's `unnamedplus` leave `"+` as it was.
  func testANamedYankLeavesTheClipboardAlone() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)
    store.write("copied", register: nil)
    store.write("named", register: "a")
    store.write(" more", register: "A")
    XCTAssertEqual(store.read(register: "a"), "named more")
    XCTAssertEqual(store.read(register: nil), "copied", "the clipboard stays as it was")
    XCTAssertEqual(store.read(register: "0"), "copied", "a named yank leaves 0 alone")
    store.write("plus", register: "+")
    XCTAssertEqual(store.read(register: nil), "plus", "\"+y is the clipboard")
  }

  // MARK: - 7. `.` repeats no mode change; any count replaces

  /// The regression: `.` after `v` started VISUAL again, and `1.` ran with
  /// the old count, where any count typed before `.` replaces it.
  func testRepeatSkipsVisualAndAnyTypedCountReplaces() {
    XCTAssertFalse(MacroState.repeats(.flashCommand(.visualMode(.charwise))))
    XCTAssertFalse(MacroState.repeats(.flashCommand(.visualMode(.linewise))))
    var state = MacroState()
    let next = MacroStep(action: .flashCommand(.tabNext), repeatCount: 3)
    state.note(next)
    state.note(MacroStep(action: .flashCommand(.visualMode(.charwise)), repeatCount: 1))
    XCTAssertEqual(state.lastStep, next, "v is no change to repeat")
    XCTAssertEqual(type("1", ".").command, .macro(.repeatLast(count: 1)))
    XCTAssertEqual(type("5", ".").command, .macro(.repeatLast(count: 5)))
    XCTAssertEqual(type(".").command, .macro(.repeatLast(count: nil)))
  }

  // MARK: - 8. The palette waits for the key

  /// The regression: an ambiguous mapping (one that is also a prefix) ran
  /// its short form at the timeout while the which-key palette listed what
  /// could follow, where the manual says the palette waits.
  func testThePendingTimeoutWaitsWhileThePaletteShows() {
    let delegate = delegate()
    defer {
      delegate.whichKeyShown = false
      delegate.overlay.orderOut(nil)
    }
    delegate.config.mode.sequenceTimeoutMs = 20
    delegate.config.mode.whichKeyMs = 0
    delegate.overlay.normalModeMappings = CompiledMappings([
      ModeMapping(key: key("g"), action: .flashCommand(.dismissHints)),
      ModeMapping(key: key("gt"), action: .flashCommand(.tabNext)),
    ])
    delegate.overlay.normalModePending = key("g")
    delegate.overlayDidHandleNormalMode(nil, repeatCount: 1)
    delegate.whichKeyShown = true
    runMainLoop(for: 0.2)
    XCTAssertEqual(delegate.overlay.normalModePending, key("g"), "the palette waits")
    XCTAssertNil(delegate.macros.lastStep, "the short form never ran")
  }

  // MARK: - 9. A HYPER round trip keeps the engaged field

  /// The regression: holding the leader (HYPER), as a `<leader>` sequence
  /// typed in a field does, disengaged the field, so its keys were the
  /// page's after it.
  func testTheHyperAndCommandRoundTripsKeepTheEngagedField() {
    XCTAssertEqual(
      TextScope.effect(ofModeChange: .normal, to: .hyper(restoreTo: .normal)), .keep)
    XCTAssertEqual(
      TextScope.effect(ofModeChange: .hyper(restoreTo: .normal), to: .normal), .keep)
    XCTAssertEqual(
      TextScope.effect(ofModeChange: .normal, to: .command(restoreTo: .normal)), .keep,
      "`:42` goes to line 42 of the field the command line came from")
  }

  // MARK: - 10. Control-[ is Escape

  /// The regression: plain `ctrl+[`, Vim's Escape, did nothing in NORMAL
  /// and VISUAL.
  func testControlBracketIsEscape() {
    func bracket(after pending: String = "", in mappings: CompiledMappings) -> NormalModeTransition
    {
      control(
        "[", keyCode: kVK_ANSI_LeftBracket, characters: "\u{1B}", after: pending, in: mappings)
    }
    XCTAssertEqual(bracket(in: visual).command, .leaveMode, "VISUAL deselects")
    XCTAssertEqual(bracket(in: text).command, .leaveMode, "an engaged field disengages")
    XCTAssertEqual(bracket(in: normal).command, .appCancel, "NORMAL's own Escape")
    XCTAssertEqual(bracket(after: type("g").pending, in: text), .consume, "it abandons `g`")
    XCTAssertEqual(bracket(after: type("3").pending, in: text), .consume, "and a count")
  }

  // MARK: - 11. Macros

  /// The regression: `qA` replaced register `a`, where Vim appends.
  func testAnUppercaseRegisterAppendsToTheMacro() {
    XCTAssertEqual(type("q", "A").command, .macro(.record(register: "A")))
    var state = MacroState()
    let next = MacroStep(action: .flashCommand(.tabNext), repeatCount: 1)
    let prev = MacroStep(action: .flashCommand(.tabPrev), repeatCount: 1)
    state.startRecording("a")
    state.note(next)
    state.stopRecording()
    state.startRecording("A")
    state.note(prev)
    state.stopRecording()
    XCTAssertEqual(state.steps(for: "a")?.steps, [next, prev], "qA appends")
    XCTAssertEqual(
      URLEventHandler.parse(words: ["macro", "record", "--register=A"]),
      .macro(.record(register: "A")))
  }

  /// The regression: `@:` did nothing, and `:` in a recording recorded an
  /// empty `mode command`, so the replay opened a blank command line.
  func testAtColonRunsTheLastLineAndARecordingKeepsTheLine() {
    XCTAssertEqual(type("@", ":").command, .macro(.play(register: ":")))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["macro", "play", "--register=:"]),
      .macro(.play(register: ":")))
    var state = MacroState()
    state.startRecording("a")
    state.note(MacroStep(action: .flashCommand(.commandMode), repeatCount: 1))
    state.noteCommandLine(":tab next")
    state.stopRecording()
    XCTAssertEqual(state.steps(for: "a")?.steps, [.commandLine(":tab next")])
    XCTAssertEqual(state.steps(for: ":")?.steps, [.commandLine(":tab next")], "@:")
    XCTAssertEqual(state.steps(for: nil)?.register, ":", "@@ after @: runs it again")
  }

  /// The regression: `q` could not stop a recording in VISUAL.
  func testQStopsARecordingInVisual() {
    XCTAssertEqual(type("q", in: visual, recording: true).command, .macro(.stop))
    XCTAssertNil(type("q", in: visual).command, "VISUAL starts no recording")
  }

  // MARK: - 12. What Vim waits on never expires

  /// The regression: a count, a register, a mark, a macro name or a
  /// character search expired after `sequence_timeout_ms`; Vim waits for
  /// the key.
  func testBuiltInPendingStatesNeverExpire() {
    for keys in [["3"], ["\""], ["\"", "a"], ["3", "\""], ["'"], ["q"], ["@"]] {
      var transition = NormalModeTransition.consume
      for key in keys { transition = press(key, after: transition.pending) }
      XCTAssertEqual(
        NormalModeInterpreter.expiredPending(transition.pending, mappings: normal),
        transition.pending, keys.joined())
    }
    let till = press("t", in: text)
    XCTAssertEqual(NormalModeInterpreter.expiredPending(till.pending, mappings: text), till.pending)
    XCTAssertEqual(NormalModeInterpreter.expiredPending(type("g").pending, mappings: normal), "")
    XCTAssertEqual(
      NormalModeInterpreter.expiredPending(type("3", "g").pending, mappings: normal), "")
    let mark = NormalModeInterpreter.expiredPending(type("m").pending, mappings: normal)
    XCTAssertEqual(
      press("a", after: mark).command, .marks(.set(MarkSlot(parsing: "a")!)),
      "`m` past the timeout still waits for its mark")
  }

  // MARK: - Additions

  /// `P` outside text pastes at the cursor, as `p` does there.
  func testPOutsideTextPastes() {
    XCTAssertEqual(type("P").command, .paste(register: nil))
    XCTAssertEqual(type("\"", "a", "P").command, .paste(register: "a"))
    XCTAssertEqual(type("P", in: text).command, .paste(register: nil, after: false))
    XCTAssertEqual(type("p", in: text).command, .paste(register: nil, after: true))
  }

  /// `''` and ``` `` ``` go back to before the last jump (`movement back`).
  func testQuoteQuoteGoesBackBeforeTheLastJump() {
    XCTAssertEqual(type("'", "'").command, .movementBack)
    XCTAssertEqual(type("`", "`").command, .movementBack)
    XCTAssertEqual(type("'", "`").command, .movementBack)
  }

  /// `ctrl+e` / `ctrl+y` scroll exactly one line per press, a count
  /// multiplying it (`scroll line_down` / `line_up`, as Vim's), while `j` /
  /// `k` where they scroll keep `scroll_step_lines`, three lines, a step
  /// readable in a page.
  func testControlEScrollsOneLineWhileJKeepsTheStep() throws {
    XCTAssertEqual(Config.default.mode.scrollStepLines, 3)
    let saved = FlashTunables.scrollStepLines
    defer { FlashTunables.scrollStepLines = saved }
    FlashTunables.scrollStepLines = Int32(Config.default.mode.scrollStepLines)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .lineDown), -1)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .lineUp), 1)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .lineDown, repeatCount: 5), -5)
    XCTAssertEqual(NormalModeDispatcher.scrollLineDelta(for: .down), -3, "j in a page")
    XCTAssertEqual(MoveCommand.down.scroll, .down)
    XCTAssertEqual(MoveCommand.up.scroll, .up)
    let normal = Config.default.mode.compiledNormal
    XCTAssertEqual(normal.mapping(for: key("ctrl+e"))?.action, .flashCommand(.scroll(.lineDown)))
    XCTAssertEqual(normal.mapping(for: key("ctrl+y"))?.action, .flashCommand(.scroll(.lineUp)))
    for (words, kind) in [
      (["scroll", "line_down"], NormalModeDispatcher.ScrollKind.lineDown),
      (["scroll", "line_up"], .lineUp),
    ] {
      XCTAssertEqual(URLEventHandler.parse(words: words), .scroll(kind))
      XCTAssertEqual(URLCommand.scroll(kind).argv, ["flash"] + words)
    }
    let toml = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("config.default.toml"), encoding: .utf8)
    let file = ConfigLoader.parse(toml)
    XCTAssertEqual(file.mode.scrollStepLines, 3)
    XCTAssertEqual(
      file.mode.compiledNormal.mapping(for: key("ctrl+e"))?.action,
      .flashCommand(.scroll(.lineDown)))
  }

  /// `:{n}` and `:$` go to that line of the engaged field.
  func testColonNumberGoesToThatLine() {
    let inventory = NormalModeDispatcher.CommandLineInventory.core()
    func resolve(_ line: String) -> NormalModeDispatcher.CommandLineResolution {
      NormalModeDispatcher.resolveCommandLine(line, inventory: inventory)
    }
    XCTAssertEqual(resolve(":42"), .commands([.cursor(.line(index: 42))]))
    XCTAssertEqual(resolve(":1"), .commands([.cursor(.line(index: 1))]))
    XCTAssertEqual(resolve(":0"), .commands([.cursor(.line(index: 1))]), "vim's :0 is the top")
    XCTAssertEqual(resolve(":$"), .commands([.cursor(.motion(.lastLine))]))
    XCTAssertEqual(resolve(":42 x"), .unknown)
    XCTAssertEqual(resolve(":4x"), .unknown)
  }

  /// HOLD's `x` does nothing: NORMAL's tab close would close the tab the
  /// drag is in.
  func testHoldsXDoesNothing() throws {
    let mode = Config.default.mode
    XCTAssertNil(mode.compiledHold.mapping(for: key("x")))
    XCTAssertEqual(mode.compiledNormal.mapping(for: key("x"))?.action, .flashCommand(.tabClose))
    let toml = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("config.default.toml"), encoding: .utf8)
    XCTAssertEqual(ConfigLoader.parse(toml).mode.unmapped[.hold], [key("x")])
    let remapped = ConfigLoader.parse(
      """
      [mode.hold.mappings]
      "x" = ["flash", "tab", "close"]
      """)
    XCTAssertNotNil(remapped.mode.compiledHold.mapping(for: key("x")), "a config takes it back")
  }

  /// History recall steps through the entries that start with what was
  /// typed, as Vim's command line does.
  func testHistoryRecallIsFilteredByTheTypedPrefix() {
    var history = CommandLineHistory(entries: [":tab new", ":q", ":tab next", ":w"])
    XCTAssertEqual(history.step(-1, buffer: ":tab"), ":tab next")
    XCTAssertEqual(history.step(-1, buffer: ":tab next"), ":tab new")
    XCTAssertEqual(history.step(-1, buffer: ":tab new"), ":tab new", "the oldest match stays")
    XCTAssertEqual(history.step(1, buffer: ":tab new"), ":tab next")
    XCTAssertEqual(history.step(1, buffer: ":tab next"), ":tab", "past the newest: the stash")
    var empty = CommandLineHistory(entries: [":tab new", ":w"])
    XCTAssertEqual(empty.step(-1, buffer: ":"), ":w", "an empty line recalls every entry")
    var none = CommandLineHistory(entries: [":w"])
    XCTAssertNil(none.step(-1, buffer: ":tab"), "nothing starts with it")
  }
}

/// The seams behind the parity fixes: pure decisions the coordinator
/// applies.
final class VimParitySeamTests: XCTestCase {
  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  /// A native chord reads the pending state the way a typed key's mapping
  /// does: the count and register before it, nothing after a half-typed
  /// sequence, mark, macro or register name.
  func testANativeChordReadsThePendingCountAndRegister() {
    let paste = MappingCommand.flashCommand(.paste(register: nil))
    let down = MappingCommand.flashCommand(.move(.halfPageDown))
    XCTAssertEqual(NormalModeInterpreter.nativeChord(pending: "", action: down), .action(down))
    XCTAssertEqual(
      NormalModeInterpreter.nativeChord(pending: "3", action: down),
      .action(down, repeatCount: 3))
    XCTAssertEqual(
      NormalModeInterpreter.nativeChord(pending: "\"a", action: paste).command,
      .paste(register: "a"))
    for pending in [key("g"), "\"", "\u{11}q", "\u{12}'", "\u{13}t1"] {
      XCTAssertEqual(NormalModeInterpreter.nativeChord(pending: pending, action: down), .consume)
      XCTAssertTrue(NormalModeInterpreter.pendingReadsNextKey(pending), pending)
    }
    for pending in ["", "3", "\"a", "\"a2"] {
      XCTAssertFalse(NormalModeInterpreter.pendingReadsNextKey(pending), pending)
    }
  }

  /// `mode normal` out of VISUAL (Vim's ⌘⌃[ shortcut) deselects, as
  /// Escape does, where it used to leave the app's selection.
  func testModeNormalFromVisualDeselects() {
    XCTAssertTrue(AppDelegate.modeNormalDeselects(mode: .visual(.charwise), hintsActive: false))
    XCTAssertTrue(AppDelegate.modeNormalDeselects(mode: .visual(.linewise), hintsActive: false))
    XCTAssertFalse(AppDelegate.modeNormalDeselects(mode: .visual(.charwise), hintsActive: true))
    XCTAssertFalse(AppDelegate.modeNormalDeselects(mode: .normal, hintsActive: false))
    XCTAssertFalse(AppDelegate.modeNormalDeselects(mode: .hold, hintsActive: false))
  }

  /// VISUAL's bare `y` also fills `"0`, as every bare yank does; a named
  /// one writes its register alone.
  func testVisualYankFillsTheYankRegister() {
    let measured = VisualSession(
      pid: 7, kind: .charwise, anchor: 0, cursor: 2, desiredColumn: nil, selected: 0..<3,
      measured: true)
    var unmeasured = measured
    unmeasured.measured = false
    XCTAssertEqual(
      VisualPlan.operatorSteps(.copy, named: false, session: measured),
      [.writeYankRegister, .appCopy, .collapseToStart, .leave])
    XCTAssertEqual(
      VisualPlan.operatorSteps(.copy, named: true, session: measured),
      [.writeRegister, .collapseToStart, .leave])
    XCTAssertEqual(
      VisualPlan.operatorSteps(.copy, named: false, session: unmeasured),
      [.appCopy, .collapseToStart, .leave], "no text: the app's Copy alone")
  }

  /// `gv` selects the last VISUAL range again in its field, its ends
  /// brought back into the text as it is now.
  func testGvReselectsTheLastRangeInItsField() throws {
    let last = VisualSession(
      pid: 7, kind: .charwise, anchor: 2, cursor: 6, desiredColumn: 4, selected: 2..<7,
      measured: true, element: 11)
    let buffer = TextBuffer("one two three")
    let again = try XCTUnwrap(VisualPlan.reselect(last, element: 11, in: buffer))
    XCTAssertEqual(again.anchor, 2)
    XCTAssertEqual(again.cursor, 6)
    XCTAssertEqual(again.selected, 2..<7)
    XCTAssertNil(again.desiredColumn)
    XCTAssertNil(VisualPlan.reselect(last, element: 12, in: buffer), "another field")
    let shorter = try XCTUnwrap(VisualPlan.reselect(last, element: 11, in: TextBuffer("one")))
    XCTAssertEqual(shorter.cursor, 2, "an end past the text comes back into it")
    var unmeasured = last
    unmeasured.measured = false
    XCTAssertNil(VisualPlan.reselect(unmeasured, element: 11, in: buffer))
    XCTAssertNil(VisualPlan.reselect(last, element: 11, in: TextBuffer("")))
    XCTAssertEqual(
      Config.default.mode.compiledText.mapping(for: key("gv"))?.action,
      .flashCommand(.visualReselect))
    XCTAssertEqual(
      URLEventHandler.parse(words: ["mode", "visual", "--reselect"]), .visualReselect)
    XCTAssertNil(URLEventHandler.parse(words: ["mode", "visual", "--reselect", "--line"]))
    XCTAssertFalse(MacroState.repeats(.flashCommand(.visualReselect)))
  }

  /// `ctrl+w`, `ctrl+u` and `ctrl+r {x}` on the command line.
  func testCommandLineControlKeys() {
    typealias Line = CommandLineEditing.Line
    XCTAssertEqual(
      CommandLineEditing.deleteWordBackward(Line(text: ":tab next", cursor: 9)),
      Line(text: ":tab ", cursor: 5))
    XCTAssertEqual(
      CommandLineEditing.deleteWordBackward(Line(text: ":tab ", cursor: 5)),
      Line(text: ":", cursor: 1))
    XCTAssertEqual(
      CommandLineEditing.deleteWordBackward(Line(text: ":", cursor: 1)), Line(text: ":", cursor: 1),
      "the prompt stays")
    XCTAssertEqual(
      CommandLineEditing.deleteWordBackward(Line(text: ":window move --position", cursor: 13)),
      Line(text: ":window --position", cursor: 8))
    XCTAssertEqual(
      CommandLineEditing.deleteWordBackward(Line(text: ":x --a", cursor: 5)),
      Line(text: ":x a", cursor: 3), "a run of punctuation is a word")
    XCTAssertEqual(
      CommandLineEditing.deleteToStart(Line(text: ":tab next", cursor: 5)),
      Line(text: ":next", cursor: 1))
    XCTAssertEqual(
      CommandLineEditing.insert("one\ntwo", into: Line(text: ":open ", cursor: 6)),
      Line(text: ":open one two", cursor: 13))
    XCTAssertEqual(
      CommandLineEditing.registerName(
        typedInto: Line(text: ":open ", cursor: 6), giving: ":open a"),
      "a")
    XCTAssertNil(
      CommandLineEditing.registerName(typedInto: Line(text: ":open ", cursor: 6), giving: ":open"))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let registers = RegisterStore(pasteboard: pasteboard)
    registers.write("kept", register: "a")
    XCTAssertEqual(
      AppDelegate.commandLineRegisterText("a", registers: registers, lastCommandLine: nil), "kept")
    XCTAssertEqual(
      AppDelegate.commandLineRegisterText(":", registers: registers, lastCommandLine: ":tab next"),
      "tab next", "\": is the last command line")
    XCTAssertNil(
      AppDelegate.commandLineRegisterText("_", registers: registers, lastCommandLine: nil))
  }
}

import AppKit
import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

final class NormalModeTests: XCTestCase {
  func testDirectionalScrollKeys() {
    XCTAssertEqual(command(chars: "h"), .scroll(.left))
    XCTAssertEqual(command(chars: "j"), .scroll(.down))
    XCTAssertEqual(command(chars: "k"), .scroll(.up))
    XCTAssertEqual(command(chars: "l"), .scroll(.right))
    XCTAssertEqual(command(chars: "e", flags: [.control]), .scroll(.down))
    XCTAssertEqual(command(chars: "y", flags: [.control]), .scroll(.up))
  }

  func testHalfPageKeysUseControlFormsOnly() {
    XCTAssertEqual(command(chars: "u"), .undo)
    XCTAssertNil(command(chars: "d"))
    XCTAssertEqual(command(chars: "u", flags: [.control]), .scroll(.halfPageUp))
    XCTAssertEqual(command(chars: "d", flags: [.control]), .scroll(.halfPageDown))
  }

  func testUndoRedoKeys() {
    XCTAssertEqual(command(chars: "u"), .undo)
    XCTAssertEqual(command(chars: "r", flags: [.control]), .redo)
  }

  func testScrollWheelDeltasUseExpectedJumpSizes() {
    let down = NormalModeDispatcher.scrollWheelDelta(
      for: .down,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(down?.vertical, -60)
    XCTAssertEqual(down?.horizontal, 0)

    let up = NormalModeDispatcher.scrollWheelDelta(
      for: .up,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(up?.vertical, 60)
    XCTAssertEqual(up?.horizontal, 0)

    let halfDown = NormalModeDispatcher.scrollWheelDelta(
      for: .halfPageDown,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(halfDown?.vertical, -450)
    XCTAssertEqual(halfDown?.horizontal, 0)

    let halfUp = NormalModeDispatcher.scrollWheelDelta(
      for: .halfPageUp,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertEqual(halfUp?.vertical, 450)
    XCTAssertEqual(halfUp?.horizontal, 0)
  }

  func testTopBottomDoNotUseWheelDeltas() {
    XCTAssertNil(
      NormalModeDispatcher.scrollWheelDelta(
        for: .top,
        viewportSize: CGSize(width: 1200, height: 900)))
    XCTAssertNil(
      NormalModeDispatcher.scrollWheelDelta(
        for: .bottom,
        viewportSize: CGSize(width: 1200, height: 900)))
  }

  func testTopBottomUseMacDocumentNavigationKeys() {
    XCTAssertEqual(NormalModeDispatcher.scrollKeyEvents(for: .top).count, 1)
    XCTAssertEqual(NormalModeDispatcher.scrollKeyEvents(for: .top)[0].virtualKey, CGKeyCode(kVK_UpArrow))
    XCTAssertTrue(NormalModeDispatcher.scrollKeyEvents(for: .top)[0].flags.contains(.maskCommand))

    XCTAssertEqual(NormalModeDispatcher.scrollKeyEvents(for: .bottom).count, 1)
    XCTAssertEqual(
      NormalModeDispatcher.scrollKeyEvents(for: .bottom)[0].virtualKey,
      CGKeyCode(kVK_DownArrow))
    XCTAssertTrue(
      NormalModeDispatcher.scrollKeyEvents(for: .bottom)[0].flags.contains(.maskCommand))
  }

  func testTopBottomAndFrameSequences() {
    XCTAssertEqual(transition(chars: "g").pending, "g")
    XCTAssertEqual(command(pending: "g", chars: "g"), .scroll(.top))
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .scroll(.bottom))
    XCTAssertEqual(command(pending: "g", chars: "f"), .nextFrame)
    XCTAssertEqual(command(pending: "g", chars: "F", ignoring: "f", flags: [.shift]), .mainFrame)
    XCTAssertEqual(command(pending: "g", chars: "t"), .nextTab)
    XCTAssertEqual(command(pending: "g", chars: "T", ignoring: "t", flags: [.shift]), .previousTab)
  }

  func testRepeatCountsApplyToSingleAndMultiKeyCommands() {
    XCTAssertEqual(transition(chars: "1").pending, "1")
    XCTAssertEqual(transition(pending: "1", chars: "0").pending, "10")

    let undo = transition(pending: "10", chars: "u")
    XCTAssertEqual(undo.command, .undo)
    XCTAssertEqual(undo.repeatCount, 10)

    let previousTab = transition(pending: "2g", chars: "T", ignoring: "t", flags: [.shift])
    XCTAssertEqual(previousTab.command, .previousTab)
    XCTAssertEqual(previousTab.repeatCount, 2)

    let nextTab = transition(pending: "2g", chars: "t")
    XCTAssertEqual(nextTab.command, .nextTab)
    XCTAssertEqual(nextTab.repeatCount, 2)

    let leadingZero = transition(chars: "0")
    XCTAssertNil(leadingZero.command)
    XCTAssertEqual(leadingZero.pending, "")
  }

  func testCopySequences() {
    XCTAssertNil(command(chars: "y"))
    XCTAssertNil(command(pending: "y", chars: "y"))
  }

  func testMoveMouseSequence() {
    XCTAssertEqual(transition(chars: "m").pending, "m")
    XCTAssertEqual(command(pending: "m", chars: "f"), .mouseMove)
    XCTAssertNil(command(pending: "m", chars: "x"))
  }

  func testFIsHintModeAndShiftFIsUnmapped() {
    XCTAssertEqual(command(chars: "f"), .mouseClick(action: .leftClick))
    XCTAssertNil(command(chars: "F", ignoring: "f", flags: [.shift]))
  }

  func testRightAndDoubleClickHintModeSequences() {
    XCTAssertEqual(transition(chars: "r").pending, "r")
    XCTAssertEqual(
      NormalModeInterpreter.pendingCommand(pending: "r")?.command,
      .reload)
    XCTAssertEqual(command(pending: "r", chars: "f"), .mouseClick(action: .rightClick))
    XCTAssertEqual(transition(chars: "d").pending, "d")
    XCTAssertEqual(command(pending: "d", chars: "f"), .mouseClick(action: .doubleClick))
  }

  func testHintCommitInsertModeGateUsesCommittedTarget() {
    XCTAssertTrue(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "tmux",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: nil,
          providerID: "tmux")))
    XCTAssertTrue(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "input",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: "AXTextField",
          providerID: "accessibility")))
    XCTAssertFalse(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "button",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: "AXButton",
          providerID: "accessibility")))
  }

  func testHelpReloadCommandLineAndModifiedKeyConsumption() {
    XCTAssertNil(command(chars: "i"))
    XCTAssertEqual(command(chars: "?"), .showUsage)
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showUsage)
    XCTAssertEqual(
      NormalModeInterpreter.interpret(
        pending: "",
        keyCode: UInt16(kVK_Space),
        modifierFlags: [.command],
        characters: " ",
        charactersIgnoringModifiers: " ",
        mappings: Config.Mode.defaultNormalMappings
      ).command,
      .appFinder(all: true))
    XCTAssertEqual(transition(chars: "r").pending, "r")
    XCTAssertEqual(command(chars: ":"), .commandMode)
    XCTAssertEqual(command(chars: "x"), .close)
    XCTAssertEqual(command(chars: "/"), .find)
    XCTAssertEqual(command(chars: "o"), .appFinder(all: true))
    XCTAssertEqual(command(chars: "O", ignoring: "o", flags: [.shift]), .appFinder(all: true))
    let modified = transition(chars: "r", flags: [.command])
    XCTAssertNil(modified.command)
    XCTAssertFalse(modified.passThrough)
    XCTAssertEqual(modified.pending, "")
  }

  func testNormalModeMayOnlyEnterInsertFromHintCommit() {
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .hintCommit))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .explicitCommand))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .advancedModeDisabled))
  }

  func testCommandLineParser() {
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("q"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qu"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qui"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("quit"), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("  QUIT  "), .quit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("q!"), .quit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("qu!"), .quit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("quit!"), .quit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("w"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wr"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wri"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("write!"), .save)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("wq"), .saveAndQuit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("xit"), .saveAndQuit(force: false))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("x!"), .saveAndQuit(force: true))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("p"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("pr"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("print"), .print)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("e"), .open)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("edi"), .open)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("new"), .newWindow)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("tabnew"), .newTab)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("bd"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("bdel"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("cl"), .close)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("find"), .find)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("u"), .undo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("undo"), .undo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("red"), .redo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("redo"), .redo)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("y"), .copy)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("yank"), .copy)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("d"), .cut)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("delete"), .cut)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("put"), .paste)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand("%y"), .copyAll)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":%yan"), .copyAll)
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("qa"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("q!!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("p!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("qu!it"))
  }

  func testCommandLineOpenAppQuery() {
    XCTAssertNil(NormalModeDispatcher.commandLineOpenAppQuery("open"))
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenAppQuery("open "), "")
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenAppQuery(":open firefox"), "firefox")
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenAppQuery("  OPEN   Firefox  "), "Firefox")
    XCTAssertNil(NormalModeDispatcher.commandLineOpenAppQuery("opening firefox"))
    XCTAssertNil(NormalModeDispatcher.commandLineOpenAppQuery("edit firefox"))
  }

  func testFuzzyScoreMatchesOrderedCharacters() {
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "ff", candidate: "Firefox"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "alc", candidate: "Alacritty"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "firfox", candidate: "Firefox"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "slak", candidate: "Slack"))
    XCTAssertNotNil(NormalModeDispatcher.fuzzyScore(query: "pstico", candidate: "Postico 2"))
    XCTAssertNil(NormalModeDispatcher.fuzzyScore(query: "fx", candidate: "Safari"))

    let compact = NormalModeDispatcher.fuzzyScore(query: "saf", candidate: "Safari") ?? 0
    let spread = NormalModeDispatcher.fuzzyScore(query: "saf", candidate: "System Settings Safari") ?? 0
    XCTAssertGreaterThan(compact, spread)
  }

  func testFuzzyHighlightRangesUseVisibleTitleCharacters() {
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "fire", candidate: "Firefox"),
      [0..<4])
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "slak", candidate: "Slack"),
      [0..<3, 4..<5])
    XCTAssertEqual(
      NormalModeDispatcher.fuzzyHighlightRanges(query: "tm 2", candidate: "tmux work:2 server"),
      [0..<2, 10..<11])
  }

  func testTmuxFinderListsUnattachedSessionWindows() {
    let clients = AppDelegate.tmuxFinderClients(
      raw: "/dev/ttys001\twork\t123\n"
    ) { pid in
      pid == 123 ? 456 : nil
    }
    let windows = AppDelegate.tmuxFinderWindowSpecs(
      windowListRaw: "work\t0\tshell\nside\t2\tserver logs\n",
      clients: clients)

    XCTAssertEqual(windows.count, 2)
    XCTAssertEqual(windows[0].title, "work:0 shell")
    XCTAssertEqual(windows[0].target, "work:0")
    XCTAssertEqual(windows[0].tty, "/dev/ttys001")
    XCTAssertEqual(windows[0].terminalPID, 456)
    XCTAssertEqual(windows[1].title, "side:2 server logs")
    XCTAssertEqual(windows[1].target, "side:2")
    XCTAssertEqual(windows[1].tty, "/dev/ttys001")
    XCTAssertEqual(windows[1].terminalPID, 456)
  }

  func testAppFinderDisplayTitleIncludesSourceName() {
    XCTAssertEqual(
      AppDelegate.appFinderDisplayTitle(sourceName: "tmux", name: "scratch gors"),
      "[tmux] scratch gors")
    XCTAssertEqual(
      AppDelegate.appFinderDisplayTitle(sourceName: "firefox", name: "Gmail"),
      "[firefox] Gmail")
  }

  func testHelpTextListsNormalModeMappings() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: true)
    for mapping in ["h", "j", "k", "l", "ctrl-e", "ctrl-y", "ctrl-d", "ctrl-u",
      "gg", "G", "f", "rf", "df", "mf", "u", "ctrl-r", "x", "/", "o", "O", "cmd+space", "r", "MAPPINGS",
      "ctrl-o", "ctrl-i", "ACTION", "NORMAL", "INSERT", "i", ":", "gf", "gF", "gt", "gT", "N{mapping}",
      ":q[uit]", ":q[uit]!", ":w[rite]", ":wq", ":x[it]", ":p[rint]", ":e[dit]", ":new", ":tabnew",
      ":bd[elete]", ":cl[ose]", ":find", ":u[ndo]", ":red[o]", ":y[ank]", ":pu[t]",
      ":open <query>", "flash://mouse_click",
      "flash://app_open_finder?all=1", "flash://mouse_click?right=1",
      "flash://mouse_click?double=1", "flash://app_back", "flash://app_forward", "?"]
    {
      XCTAssertTrue(
        help.contains(mapping),
      "missing \(mapping)")
    }
    XCTAssertFalse(help.contains("flash://mode_normal"))
  }

  func testHelpTextIsDerivedFromConfiguredMappings() {
    var config = Config.default
    config.mode.normal = [
      ModeMapping(key: "zz", action: .flashCommand(.reload))
    ]
    let help = NormalModeDispatcher.helpText(config: config, showModes: true)
    XCTAssertTrue(help.contains("zz"))
    XCTAssertTrue(help.contains("flash://app_reload"))
    XCTAssertFalse(help.contains("flash://mouse_click"))
    XCTAssertFalse(help.contains(":q[uit]"))
  }

  func testHelpTextWithoutModeCellUsesSimpleMappingColumn() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: false)
    XCTAssertTrue(help.contains("ACTION"))
    XCTAssertTrue(help.contains("MAPPING"))
    XCTAssertTrue(help.contains("flash://mouse_click"))
    XCTAssertTrue(help.contains("f"))
    XCTAssertFalse(help.contains("NORMAL"))
    XCTAssertFalse(help.contains("INSERT"))
  }

  func testConfiguredMappingsOverrideDefaults() {
    let mappings = [
      ModeMapping(key: "j", action: .flashCommand(.scroll(.up))),
      ModeMapping(key: "zz", action: .flashCommand(.reload)),
    ]
    XCTAssertEqual(command(chars: "j", mappings: mappings), .scroll(.up))
    XCTAssertEqual(transition(chars: "z", mappings: mappings).pending, "z")
    XCTAssertEqual(command(pending: "z", chars: "z", mappings: mappings), .reload)
  }

  func testEscapeConsumesWithoutLeavingNormalMode() {
    let t = NormalModeInterpreter.interpret(
      pending: "",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil)
    XCTAssertNil(t.command)
    XCTAssertFalse(t.passThrough)
    XCTAssertEqual(t.pending, "")
  }

  func testEscapeClearsPendingSequence() {
    let t = NormalModeInterpreter.interpret(
      pending: "2g",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil)
    XCTAssertNil(t.command)
    XCTAssertFalse(t.passThrough)
    XCTAssertEqual(t.pending, "")
  }

  func testInstantScrollValueAdjustsByFractionAndClamps() {
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 50, lower: 0, upper: 100, deltaFraction: 0.5),
      100)
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 4, lower: 0, upper: 100, deltaFraction: -0.5),
      0)
    XCTAssertEqual(
      NormalModeDispatcher.adjustedScrollValue(
        current: 96, lower: 0, upper: 100, deltaFraction: 0.5),
      100)
  }

  func testInstantScrollEdgeValuesUseBounds() {
    XCTAssertEqual(
      NormalModeDispatcher.edgeScrollValue(lower: 10, upper: 90, edge: .minimum),
      10)
    XCTAssertEqual(
      NormalModeDispatcher.edgeScrollValue(lower: 10, upper: 90, edge: .maximum),
      90)
  }

  private func command(
    pending: String = "",
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  ) -> URLCommand? {
    transition(pending: pending, chars: chars, ignoring: ignoring, flags: flags, mappings: mappings)
      .command
  }

  private func transition(
    pending: String = "",
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      keyCode: 0,
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: mappings)
  }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders
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
    XCTAssertEqual(command(chars: "H", ignoring: "h", flags: [.shift]), .historyBack)
    XCTAssertEqual(command(chars: "L", ignoring: "l", flags: [.shift]), .historyForward)
    XCTAssertEqual(command(pending: "g", chars: "f"), .nextFrame)
    XCTAssertEqual(command(pending: "g", chars: "F", ignoring: "f", flags: [.shift]), .mainFrame)
    XCTAssertEqual(command(pending: "g", chars: "t"), .tabNext)
    XCTAssertEqual(command(pending: "g", chars: "T", ignoring: "t", flags: [.shift]), .tabPrev)
    XCTAssertEqual(command(pending: "g", chars: "N", ignoring: "n", flags: [.shift]), .tabSelect(index: nil))
    XCTAssertEqual(command(chars: "t"), .tabNewInsert)
  }

  func testRepeatCountsApplyToSingleAndMultiKeyCommands() {
    XCTAssertEqual(transition(chars: "1").pending, "1")
    XCTAssertEqual(transition(pending: "1", chars: "0").pending, "10")

    let undo = transition(pending: "10", chars: "u")
    XCTAssertEqual(undo.command, .undo)
    XCTAssertEqual(undo.repeatCount, 10)

    let previousTab = transition(pending: "2g", chars: "T", ignoring: "t", flags: [.shift])
    XCTAssertEqual(previousTab.command, .tabPrev)
    XCTAssertEqual(previousTab.repeatCount, 2)

    let nextTab = transition(pending: "2g", chars: "t")
    XCTAssertEqual(nextTab.command, .tabNext)
    XCTAssertEqual(nextTab.repeatCount, 2)

    let selectTab = transition(pending: "3g", chars: "N", ignoring: "n", flags: [.shift])
    XCTAssertEqual(selectTab.command, .tabSelect(index: nil))
    XCTAssertEqual(selectTab.repeatCount, 3)

    let leadingZero = transition(chars: "0")
    XCTAssertNil(leadingZero.command)
    XCTAssertEqual(leadingZero.pending, "")
  }

  func testPendingSequenceTimesOut() {
    let start = Date(timeIntervalSince1970: 1_000)
    XCTAssertFalse(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(0.5)))
    XCTAssertTrue(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(1.2)))
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

  func testHintCommitEntersInsertOnlyForTextInputLeftClickTargets() {
    XCTAssertTrue(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "tmux",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: nil,
          acceptsTextInput: true,
          providerID: "tmux")))
    XCTAssertTrue(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "input",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: "AXTextField",
          acceptsTextInput: true,
          providerID: "accessibility")))
    XCTAssertFalse(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "button",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: "AXButton",
          providerID: "accessibility")))
    XCTAssertFalse(
      AppDelegate.hintCommitShouldEnterInsertMode(
        JumpTarget(
          id: "input-right-click",
          frame: CGRect(x: 0, y: 0, width: 10, height: 10),
          role: "AXTextField",
          acceptsTextInput: true,
          providerID: "accessibility"),
        action: .rightClick))
  }

  func testHelpReloadCommandLineAndModifiedKeyConsumption() {
    XCTAssertEqual(command(chars: "i"), .insertMode)
    XCTAssertEqual(command(chars: "?"), .showUsage)
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showUsage)
    XCTAssertNil(
      NormalModeInterpreter.interpret(
        pending: "",
        keyCode: UInt16(kVK_Space),
        modifierFlags: [.command],
        characters: " ",
        charactersIgnoringModifiers: " ",
        mappings: Config.Mode.defaultNormalMappings
      ).command)
    XCTAssertEqual(transition(chars: "r").pending, "r")
    XCTAssertEqual(command(chars: ":"), .commandMode)
    XCTAssertEqual(command(chars: "x"), .close)
    XCTAssertEqual(command(chars: "/"), .find)
    XCTAssertEqual(transition(chars: "\\").pending, "\\")
    XCTAssertEqual(
      transition(pending: "\\", keyCode: kVK_Space, chars: " ").command,
      .flashlight)
    XCTAssertNil(command(chars: "o"))
    XCTAssertNil(command(chars: "O", ignoring: "o", flags: [.shift]))
    let modified = transition(chars: "r", flags: [.command])
    XCTAssertNil(modified.command)
    XCTAssertFalse(modified.passThrough)
    XCTAssertEqual(modified.pending, "")
  }

  func testNormalModeMayOnlyEnterInsertFromHintCommit() {
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .hintCommit))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .normalModeInput))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .pointerClick))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .explicitCommand))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .advancedModeDisabled))
  }

  func testExplicitNormalScrollSuppressionOnlyAppliesToIdleNormalModeBeforeDeadline() {
    let now = Date()
    let until = now.addingTimeInterval(0.5)
    XCTAssertTrue(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .normal,
        hasHints: false,
        suppressionUntil: until,
        now: now))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .normal,
        hasHints: true,
        suppressionUntil: until,
        now: now))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .insert,
        hasHints: false,
        suppressionUntil: until,
        now: now))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .normal,
        hasHints: false,
        suppressionUntil: until,
        now: until.addingTimeInterval(0.001)))
  }

  func testCommandLineEntryIsAllowedFromInsertAndNormalModeEvenWithTransientHints() {
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .insert,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .normal,
        hasHints: false,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .insert,
        hasHints: true,
        activationInFlight: false))
    XCTAssertTrue(
      AppDelegate.commandLineEntryIsAllowed(
        mode: .normal,
        hasHints: false,
        activationInFlight: true))
  }

  func testCommandLineExitAlwaysReturnsToNormalMode() {
    XCTAssertEqual(
      AppDelegate.commandLineExitMode(currentMode: .insert),
      .normal)
    XCTAssertEqual(
      AppDelegate.commandLineExitMode(currentMode: .normal),
      .normal)
  }

  func testModeOverlayCaptureIsOnlyPossibleInIdleNormalMode() {
    let labels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    XCTAssertEqual(
      AppDelegate.modeOverlaySnapshot(
        mode: .insert,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: true),
      ModeOverlaySnapshot(
        text: "INSERT",
        visible: true,
        captureInput: false,
        inputMode: .hints))
    XCTAssertEqual(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: true),
      ModeOverlaySnapshot(
        text: "NORMAL",
        visible: true,
        captureInput: true,
        inputMode: .normal))
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: false).captureInput)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: true,
        activationInFlight: false,
        captureOverride: true).captureInput)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: true,
        captureOverride: true).captureInput)
  }

  func testActiveWindowBorderIsHiddenDuringWindowGeometryChanges() {
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: true))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .normal,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: true,
        windowGeometryChangeInProgress: false))
  }

  func testActiveWindowBorderTrackerRunsWhileGeometryChangeIsInProgress() {
    XCTAssertTrue(
      AppDelegate.activeWindowBorderTrackingShouldRun(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderTrackingShouldRun(
        mode: .normal,
        modeBadgeEnabled: true,
        hasHints: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderTrackingShouldRun(
        mode: .insert,
        modeBadgeEnabled: false,
        hasHints: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderTrackingShouldRun(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: true))
  }

  func testActiveWindowBorderFrameComparisonIgnoresTinyJitter() {
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertTrue(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        CGRect(x: 10.5, y: 19.5, width: 299.5, height: 200.5),
        tolerance: 1))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        CGRect(x: 12, y: 20, width: 300, height: 200),
        tolerance: 1))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        frame,
        nil,
        tolerance: 1))
    XCTAssertTrue(
      AppDelegate.activeWindowBorderFramesApproximatelyEqual(
        nil,
        nil,
        tolerance: 1))
  }

  func testWindowGeometryNotificationsSuspendInsertBorder() {
    XCTAssertTrue(
      AppMonitor.windowGeometryNotificationRequiresBorderSuspension(kAXWindowMovedNotification))
    XCTAssertTrue(
      AppMonitor.windowGeometryNotificationRequiresBorderSuspension(kAXWindowResizedNotification))
    XCTAssertTrue(
      AppMonitor.windowGeometryNotificationRequiresBorderSuspension(kAXFocusedWindowChangedNotification))
    XCTAssertTrue(
      AppMonitor.windowGeometryNotificationRequiresBorderSuspension(kAXMainWindowChangedNotification))
    XCTAssertFalse(
      AppMonitor.windowGeometryNotificationRequiresBorderSuspension(kAXValueChangedNotification))
  }

  func testNormalModeRecaptureScheduleStartsImmediatelyAndRetriesAggressively() {
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.first, 0)
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.prefix(4), [0, 10, 30, 60])
    XCTAssertEqual(AppDelegate.normalModeRecaptureDelaysMs.last, 1_400)
  }

  func testCommandLineBufferIncludesPrompt() {
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: ""), ":")
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: "open "), ":open ")
    XCTAssertEqual(AppDelegate.commandLineBuffer(from: ":open "), ":open ")
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
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenAppQuery(":open tmux agentic"),
      "tmux agentic")
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenAppQuery("  OPEN   Firefox  "), "Firefox")
    XCTAssertNil(NormalModeDispatcher.commandLineOpenAppQuery("opening firefox"))
    XCTAssertNil(NormalModeDispatcher.commandLineOpenAppQuery("edit firefox"))
  }

  func testCommandLineCandidateQueryAcceptsFlashlight() {
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":open firefox"), "firefox")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":flashlight"), "")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":flashlight gmail.com"), "gmail.com")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery("  FLASHLIGHT   Slack  "), "Slack")
    XCTAssertNil(NormalModeDispatcher.commandLineCandidateQuery(":flashlightgmail"))
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

  func testFuzzyScoreMatchesSlackHashtagChannelByChannelName() {
    let candidate = CandidateFinder.prepare(
      Candidate(
        kind: .slackChannel,
        sourceID: "slack",
        source: "slack",
        pid: 123,
        name: "#schedule",
        subtitle: "Slack channel",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        url: nil,
        tmuxClientTTY: nil,
        tmuxTarget: nil,
        targetElement: nil))

    XCTAssertEqual(candidate.normalizedSearchText, "slack #schedule")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("#schedule"),
        normalizedCandidate: candidate.normalizedSearchText))
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("schedule"),
        normalizedCandidate: candidate.normalizedSearchText))
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
    let clients = TmuxProvider.tmuxFinderClients(
      raw: "/dev/ttys001\twork\t123\n"
    ) { pid in
      pid == 123 ? 456 : nil
    }
    let windows = TmuxProvider.tmuxFinderWindowSpecs(
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

  func testCandidateFinderDisplayTitleIncludesSourceName() {
    XCTAssertEqual(
      AppDelegate.candidateFinderDisplayTitle(source: "tmux", title: "scratch gors"),
      "[tmux] scratch gors")
    XCTAssertEqual(
      AppDelegate.candidateFinderDisplayTitle(source: "firefox", title: "Gmail"),
      "[firefox] Gmail")
  }

  func testCandidateFinderMergeKeepsRunningAppOverInstalledBundle() {
    let installed = candidateFinderCandidate(
      name: "Firefox",
      pid: nil,
      bundleIdentifier: "org.mozilla.firefox",
      path: "/Applications/Firefox.app")
    let running = candidateFinderCandidate(
      name: "Firefox",
      pid: 123,
      bundleIdentifier: "org.mozilla.firefox",
      path: "/Applications/Firefox.app")

    let merged = CandidateFinder.mergeAppCandidates(running: [running], installed: [installed])

    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].pid, 123)
    XCTAssertEqual(merged[0].url?.path, "/Applications/Firefox.app")
  }

  func testIgnoredAppMatcherMatchesCommonAppIdentifiers() {
    let flash = candidateFinderCandidate(
      name: "Flash",
      pid: nil,
      bundleIdentifier: "com.flash.app",
      path: "/Applications/Flash.app")
    let titledDifferently = candidateFinderCandidate(
      name: "Flash Helper",
      pid: nil,
      bundleIdentifier: "com.example.helper",
      path: "/Applications/Flash.app")

    XCTAssertTrue(IgnoredAppMatcher(["Flash"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["flash"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["com.flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["/Applications/Flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["Flash.app"]).contains(flash))
    XCTAssertTrue(IgnoredAppMatcher(["Flash"]).contains(titledDifferently))
    XCTAssertFalse(IgnoredAppMatcher(["Messages"]).contains(flash))
  }

  func testCandidateFinderPrepareBuildsDisplayAndSearchText() {
    let prepared = CandidateFinder.prepare(
      candidateFinderCandidate(
        name: "Postico 2",
        pid: nil,
        bundleIdentifier: "com.eggerapps.Postico",
        path: "/Applications/Postico 2.app"))

    XCTAssertEqual(prepared.displayTitle, "[app] Postico 2")
    XCTAssertEqual(prepared.normalizedSearchText, "app postico 2 applications postico 2 app")
  }

  func testCandidateFinderPreparedBrowserTabIncludesBrowserTitleAndURL() {
    let prepared = CandidateFinder.prepare(
      Candidate(
        kind: .browserTab,
        sourceID: "firefox-tabs",
        source: "firefox",
        pid: 123,
        name: BrowserTabSources.browserTabName(
          title: "Gmail",
          url: "https://mail.google.com/mail/u/0/#inbox"),
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/mail/u/0/#inbox"),
        tmuxClientTTY: nil,
        tmuxTarget: nil,
        targetElement: nil))

    XCTAssertEqual(prepared.displayTitle, "[firefox] Gmail (https://mail.google.com/mail/u/0/#inbox)")
    XCTAssertEqual(prepared.source, "firefox")
    XCTAssertEqual(prepared.name, "Gmail")
    XCTAssertEqual(prepared.url?.absoluteString, "https://mail.google.com/mail/u/0/#inbox")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("firefox inbox"),
        normalizedCandidate: prepared.normalizedSearchText))
  }

  func testCandidateFinderPreparedTmuxWindowMatchesSourcePrefixedQuery() {
    let prepared = CandidateFinder.prepare(
      Candidate(
        kind: .tmuxWindow,
        sourceID: "tmux",
        source: "tmux",
        pid: 123,
        name: "beside:1 beside-agentic",
        subtitle: "tmux window",
        bundleIdentifier: "",
        url: nil,
        tmuxClientTTY: "/dev/ttys001",
        tmuxTarget: "beside:1",
        targetElement: nil))

    XCTAssertEqual(prepared.displayTitle, "[tmux] beside:1 beside-agentic")
    XCTAssertNotNil(
      NormalModeDispatcher.fuzzyScore(
        normalizedQuery: NormalModeDispatcher.normalizedSearchText("tmux agentic"),
        normalizedCandidate: prepared.normalizedSearchText))
  }

  func testTerminalTargetsSuppressUndoRedoCommandKeyShortcuts() {
    XCTAssertTrue(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .undo,
        bundleIdentifier: "org.alacritty"))
    XCTAssertTrue(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .redo,
        bundleIdentifier: "com.apple.Terminal"))
    XCTAssertFalse(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .undo,
        bundleIdentifier: "org.mozilla.firefox"))
    XCTAssertFalse(
      AppDelegate.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        .copy,
        bundleIdentifier: "org.alacritty"))
  }

  func testHelpTextListsNormalModeMappings() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: true)
    for mapping in ["h", "j", "k", "l", "ctrl-e", "ctrl-y", "ctrl-d", "ctrl-u",
      "gg", "G", "H", "L", "f", "rf", "df", "mf", "u", "ctrl-r", "x", "/", "\\space", "r", "t", "MAPPINGS",
      "ctrl-o", "ctrl-i", "ACTION", "NORMAL", "INSERT", "i", ":", "gf", "gF", "gt", "gT", "gN", "N{mapping}",
      ":q[uit]", ":q[uit]!", ":w[rite]", ":wq", ":x[it]", ":p[rint]", ":e[dit]", ":new", ":tabnew",
      ":bd[elete]", ":cl[ose]", ":find", ":u[ndo]", ":red[o]", ":y[ank]", ":pu[t]",
      ":open <query>", ":flashlight <query>", "flash://mouse_click",
      "flash://flashlight", "flash://mouse_click?right=1",
      "flash://mouse_click?double=1", "flash://history_back", "flash://history_forward",
      "flash://movement_back", "flash://movement_forward",
      "flash://tab_select", "flash://tab_new_insert", "?"]
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

  func testHelpTextListsShellCommandMappings() {
    var config = Config.default
    config.mode.normal = [
      ModeMapping(key: "zz", action: .shellCommand(["sh", "~/bin/toggle-colors"]))
    ]
    let help = NormalModeDispatcher.helpText(config: config, showModes: true)
    XCTAssertTrue(help.contains("zz"))
    XCTAssertTrue(help.contains("[\"sh\", \"~/bin/toggle-colors\"]"))
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
      ModeMapping(key: "tab", action: .flashCommand(.movementForward)),
      ModeMapping(key: "delete_forward", action: .flashCommand(.scroll(.halfPageDown))),
      ModeMapping(key: "cmd+delete", action: .flashCommand(.scroll(.halfPageUp))),
    ]
    XCTAssertEqual(command(chars: "j", mappings: mappings), .scroll(.up))
    XCTAssertEqual(transition(chars: "z", mappings: mappings).pending, "z")
    XCTAssertEqual(command(pending: "z", chars: "z", mappings: mappings), .reload)
    XCTAssertEqual(
      transition(keyCode: kVK_Tab, chars: "\t", mappings: mappings).command,
      .movementForward)
    XCTAssertEqual(
      transition(keyCode: kVK_ForwardDelete, chars: "", mappings: mappings).command,
      .scroll(.halfPageDown))
    XCTAssertEqual(
      transition(
        keyCode: kVK_Delete,
        chars: "\u{7F}",
        flags: [.command],
        mappings: mappings).command,
      .scroll(.halfPageUp))
  }

  func testConfiguredShellMappingsProduceActions() {
    let action = MappingAction.shellCommand(["sh", "~/bin/toggle-colors"])
    let mappings = [
      ModeMapping(key: "zz", action: action)
    ]
    let first = transition(chars: "z", mappings: mappings)
    XCTAssertEqual(first.pending, "z")
    let second = transition(pending: "z", chars: "z", mappings: mappings)
    XCTAssertEqual(second.action, action)
    XCTAssertNil(second.command)
  }

  func testSpaceTokenCanBeUsedInNormalModeSequences() {
    let mappings = [
      ModeMapping(key: "spacec", action: .flashCommand(.reload))
    ]
    let first = transition(keyCode: kVK_Space, chars: " ", mappings: mappings)
    XCTAssertEqual(first.pending, "space")
    XCTAssertEqual(
      transition(pending: "space", chars: "c", mappings: mappings).command,
      .reload)
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
    keyCode: Int = 0,
    chars: String,
    ignoring: String? = nil,
    flags: NSEvent.ModifierFlags = [],
    mappings: [ModeMapping] = Config.Mode.defaultNormalMappings
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      keyCode: UInt16(keyCode),
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: mappings)
  }

  private func candidateFinderCandidate(
    name: String,
    pid: pid_t?,
    bundleIdentifier: String,
    path: String
  ) -> Candidate {
    Candidate(
      kind: .app,
      sourceID: "app",
      source: "app",
      pid: pid,
      name: name,
      subtitle: "app",
      bundleIdentifier: bundleIdentifier,
      url: URL(fileURLWithPath: path),
      tmuxClientTTY: nil,
      tmuxTarget: nil,
      targetElement: nil)
  }
}

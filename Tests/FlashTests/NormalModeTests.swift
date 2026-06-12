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

  func testTopBottomUseExtremeWheelDeltasForWheelFallback() {
    // AX scrollbar value-setters are the primary path for gg/G, but
    // they don't move every app (tmux has none, some Electron apps
    // ignore the AX-set). For those apps the dispatcher falls back to
    // a synthetic wheel event with a huge delta — large enough to
    // exceed any realistic document height while still fitting Int32.
    let top = NormalModeDispatcher.scrollWheelDelta(
      for: .top,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertNotNil(top)
    XCTAssertGreaterThanOrEqual(top?.vertical ?? 0, 100_000)
    XCTAssertEqual(top?.horizontal, 0)

    let bottom = NormalModeDispatcher.scrollWheelDelta(
      for: .bottom,
      viewportSize: CGSize(width: 1200, height: 900))
    XCTAssertNotNil(bottom)
    XCTAssertLessThanOrEqual(bottom?.vertical ?? 0, -100_000)
    XCTAssertEqual(bottom?.horizontal, 0)
  }

  func testTopBottomAndNavigationSequences() {
    XCTAssertEqual(transition(chars: "g").pending, "g")
    XCTAssertEqual(command(pending: "g", chars: "g"), .scroll(.top))
    XCTAssertEqual(command(chars: "G", ignoring: "g", flags: [.shift]), .scroll(.bottom))
    XCTAssertEqual(command(pending: "[", chars: "h"), .historyBack)
    XCTAssertEqual(command(pending: "]", chars: "h"), .historyForward)
    XCTAssertEqual(command(pending: "]", chars: "t"), .tabNext)
    XCTAssertEqual(command(pending: "[", chars: "t"), .tabPrev)
    XCTAssertEqual(command(pending: "[", chars: "a"), .appPrev)
    XCTAssertEqual(command(pending: "]", chars: "a"), .appNext)
    XCTAssertEqual(command(pending: "g", chars: "4"), .tabSelect(index: 4))
    XCTAssertEqual(command(chars: "n"), .newWindow)
    XCTAssertEqual(command(chars: "t"), .tabNew)
  }

  func testRepeatCountsApplyToSingleAndMultiKeyCommands() {
    XCTAssertEqual(transition(chars: "1").pending, "1")
    XCTAssertEqual(transition(pending: "1", chars: "0").pending, "10")

    let undo = transition(pending: "10", chars: "u")
    XCTAssertEqual(undo.command, .undo)
    XCTAssertEqual(undo.repeatCount, 10)

    let previousTab = transition(pending: "2[", chars: "t")
    XCTAssertEqual(previousTab.command, .tabPrev)
    XCTAssertEqual(previousTab.repeatCount, 2)

    let nextTab = transition(pending: "2]", chars: "t")
    XCTAssertEqual(nextTab.command, .tabNext)
    XCTAssertEqual(nextTab.repeatCount, 2)

    let selectTab = transition(pending: "g", chars: "3")
    XCTAssertEqual(selectTab.command, .tabSelect(index: 3))
    XCTAssertEqual(selectTab.repeatCount, 1)

    let leadingZero = transition(chars: "0")
    XCTAssertNil(leadingZero.command)
    XCTAssertEqual(leadingZero.pending, "")
  }

  func testPendingSequenceTimesOut() {
    let start = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(NormalModeInterpreter.sequenceTimeoutMs, 1000)
    XCTAssertFalse(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(0.999)))
    XCTAssertTrue(
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: "g",
        lastInputAt: start,
        now: start.addingTimeInterval(1.001)))
  }

  func testCopySequences() {
    XCTAssertNil(command(chars: "y"))
    XCTAssertNil(command(pending: "y", chars: "y"))
  }

  func testMoveMouseSequence() {
    XCTAssertEqual(transition(chars: "m").pending, "m")
    XCTAssertEqual(command(pending: "m", chars: "f"), .mouseTarget(.move))
    XCTAssertEqual(command(pending: "m", chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.move))
    // `m<letter>` now sets a vim-style mark instead of being unmapped.
    XCTAssertEqual(command(pending: "m", chars: "x"), .setMark(letter: "x"))
    XCTAssertEqual(command(pending: "`", chars: "x"), .jumpToMark(letter: "x"))
  }

  func testFIsMouseTargetAndShiftFIsMouseGrid() {
    XCTAssertEqual(command(chars: "f"), .mouseTarget(.click(.leftClick)))
    XCTAssertEqual(command(chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.click(.leftClick)))
    // `s` is now the secondary-click prefix (`sf`/`sF`), so it leaves a
    // pending sequence rather than yielding `nil`.
    XCTAssertEqual(transition(chars: "s").pending, "s")
  }

  func testSecondaryAndDoubleClickHintModeSequences() {
    // `r` stays bound to `reload`; the secondary-click prefix is `s`
    // (renamed from the old `r*` to drop the sequence-timeout delay on
    // a bare `r`).
    XCTAssertEqual(command(chars: "r"), .reload(force: false))
    XCTAssertEqual(command(chars: "R", ignoring: "r", flags: [.shift]), .reload(force: true))
    XCTAssertEqual(transition(chars: "s").pending, "s")
    XCTAssertEqual(command(pending: "s", chars: "f"), .mouseTarget(.click(.rightClick)))
    XCTAssertEqual(command(pending: "s", chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.click(.rightClick)))
    XCTAssertEqual(transition(chars: "d").pending, "d")
    XCTAssertEqual(command(pending: "d", chars: "f"), .mouseTarget(.click(.doubleClick)))
    XCTAssertEqual(command(pending: "d", chars: "F", ignoring: "f", flags: [.shift]), .mouseGrid(.click(.doubleClick)))
  }

  func testMouseTargetCommitEntersInsertOnlyForTypingSurfaces() {
    let textField = JumpTarget(
      id: "t", frame: .zero, role: "AXTextField",
      entersInsertMode: true, providerID: "ax")
    let link = JumpTarget(
      id: "l", frame: .zero, role: "AXLink",
      entersInsertMode: false, providerID: "ax")
    XCTAssertTrue(
      AppDelegate.mouseTargetCommitShouldEnterInsertMode(target: textField))
    XCTAssertFalse(
      AppDelegate.mouseTargetCommitShouldEnterInsertMode(target: link))
  }

  // `mouseGridCommitShouldEnterInsertMode` deleted: F clicks no longer
  // auto-enter insert. The post-click AX-input check
  // (`enterInsertModeIfClickedOnTextInput`) is the only path into
  // insert from a geometric click, and it's tested via behavior in
  // the manual-verification flow (clicking a search field → insert;
  // clicking a button → stays normal).

  func testHelpReloadCommandLineAndModifiedKeyConsumption() {
    XCTAssertEqual(command(chars: "i"), .insertMode)
    XCTAssertEqual(command(chars: "?"), .showUsage(topic: nil))
    XCTAssertEqual(command(chars: "?", ignoring: "/", flags: [.shift]), .showUsage(topic: nil))
    XCTAssertNil(
      NormalModeInterpreter.interpret(
        pending: "",
        keyCode: UInt16(kVK_Space),
        modifierFlags: [.command],
        characters: " ",
        charactersIgnoringModifiers: " ",
        mappings: CompiledMappings(Config.Mode.defaultNormalMappings)
      ).command)
    // With right-click hints moved to the `s` prefix, `r` no longer prefixes
    // any pending sequence — it resolves to reload on the first keystroke (no
    // sequence-timeout delay).
    XCTAssertEqual(command(chars: "r"), .reload(force: false))
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
    // Hermetic normal mode: any Cmd/Opt chord without an explicit
    // mapping is swallowed, never forwarded to the focused app.
    XCTAssertEqual(modified.pending, "")
  }

  func testPendingPrefixBrokenByUnmappableKeyFallsBackToFreshInterpretation() {
    // `g` is a prefix (gg/gt/g1…) but `gi` is unmapped — falling back
    // to interpreting `i` from scratch lands on insert mode instead of
    // silently swallowing the keystroke. Same for any other prefix.
    XCTAssertEqual(command(pending: "g", chars: "i"), .insertMode)
    XCTAssertEqual(command(pending: "[", chars: "i"), .insertMode)
    XCTAssertEqual(command(pending: "]", chars: "i"), .insertMode)
    XCTAssertEqual(command(pending: "g", chars: "n"), .newWindow)
    XCTAssertEqual(command(pending: "g", chars: "r"), .reload(force: false))
    // Valid sequence continuations still resolve to the mapped action.
    XCTAssertEqual(command(pending: "g", chars: "t"), .tabNext)
    XCTAssertEqual(command(pending: "m", chars: "i"), .setMark(letter: "i"))
    // No mapping at any depth — the prefix is dropped and the fresh
    // key is also unmapped, so the result is a clean consume (no
    // command, no carried-over pending).
    let unmappable = transition(pending: "g", chars: "z")
    XCTAssertNil(unmappable.command)
    XCTAssertEqual(unmappable.pending, "")
  }

  func testNormalModeMayOnlyEnterInsertFromHintCommit() {
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .hintCommit))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .normalModeInput))
    XCTAssertTrue(AppDelegate.normalModeMayEnterInsert(reason: .pointerClick))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .explicitCommand))
    XCTAssertFalse(AppDelegate.normalModeMayEnterInsert(reason: .advancedModeDisabled))
  }

  func testPointerScrollIsSuppressedInIdleNormalMode() {
    // Wheel ticks in normal mode always pass through to the focused app
    // (the overlay panel `ignoresMouseEvents`) and must never flip
    // Flash into insert. Hints visible is the one exception — there
    // the scroll dismisses the picker.
    XCTAssertTrue(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .normal,
        hasHints: false))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .normal,
        hasHints: true))
    XCTAssertFalse(
      AppDelegate.pointerScrollShouldBeSuppressed(
        mode: .insert,
        hasHints: false))
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
        visible: false,
        captureInput: false,
        inputMode: .hints,
        refreshActiveWindowBorder: true))
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
        inputMode: .normal,
        refreshActiveWindowBorder: true))
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

  func testInsertModeBadgeIsHidden() {
    let labels = Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND")
    // Insert mode swaps the badge for the active-window border, so the
    // badge stays hidden even when advanced mode (visible: true) is on.
    let snapshot = AppDelegate.modeOverlaySnapshot(
      mode: .insert,
      labels: labels,
      visible: true,
      hasHints: false,
      activationInFlight: false,
      captureOverride: nil)
    XCTAssertFalse(snapshot.visible)
    XCTAssertEqual(snapshot.text, "INSERT")
    // NORMAL keeps respecting the advanced-mode flag.
    XCTAssertTrue(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: true,
        hasHints: false,
        activationInFlight: false,
        captureOverride: nil).visible)
    XCTAssertFalse(
      AppDelegate.modeOverlaySnapshot(
        mode: .normal,
        labels: labels,
        visible: false,
        hasHints: false,
        activationInFlight: false,
        captureOverride: nil).visible)
  }

  func testActiveWindowBorderVisibility() {
    // Border shows in insert when advanced mode is on, no hints are up,
    // and no window-geometry transition is in flight.
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: false))
    // No advanced mode → no badge/border distinction to draw.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: false,
        hasHints: false,
        windowGeometryChangeInProgress: false))
    // Suspended while the window is moving/resizing so the stroke
    // doesn't visibly trail behind the chrome.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .insert,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: true))
    // Normal mode shows the badge instead.
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        mode: .normal,
        modeBadgeEnabled: true,
        hasHints: false,
        windowGeometryChangeInProgress: false))
    // Hints suppress the border so chips aren't double-framed.
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
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("%y"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":%yan"))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":plugins"), .plugins(.modal))
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCommand(":plugins list"), .plugins(.list))
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCommand(":plugins ls"), .plugins(.list))
    XCTAssertEqual(
      NormalModeDispatcher.commandLineCommand(":plugins reload"), .plugins(.reload))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":plugins bogus"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand(":plugins list extra"))
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":mappings"), .mappings)
    XCTAssertEqual(NormalModeDispatcher.commandLineCommand(":map"), .mappings)
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("qa"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("q!!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("p!"))
    XCTAssertNil(NormalModeDispatcher.commandLineCommand("qu!it"))
  }

  func testCommandLineClipboardModifierParser() {
    let plain = NormalModeDispatcher.commandLineClipboardModifier(":aws whoami")
    XCTAssertFalse(plain.capture)
    XCTAssertEqual(plain.raw, ":aws whoami")

    let afterColon = NormalModeDispatcher.commandLineClipboardModifier(":#aws whoami")
    XCTAssertTrue(afterColon.capture)
    XCTAssertEqual(afterColon.raw, ":aws whoami")

    let spaced = NormalModeDispatcher.commandLineClipboardModifier(": # aws whoami")
    XCTAssertTrue(spaced.capture)
    XCTAssertEqual(spaced.raw, ":aws whoami")

    let noColon = NormalModeDispatcher.commandLineClipboardModifier("#calc 2 + 2")
    XCTAssertTrue(noColon.capture)
    XCTAssertEqual(noColon.raw, "calc 2 + 2")
  }

  func testCommandLineHelpTopicParser() throws {
    XCTAssertEqual(try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":help")), nil)
    XCTAssertEqual(try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":h")), nil)
    XCTAssertEqual(
      try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic(":help plugins")),
      "plugins")
    XCTAssertEqual(
      try XCTUnwrap(NormalModeDispatcher.commandLineHelpTopic("  HELP   normal-mode  ")),
      "normal-mode")
    XCTAssertTrue(NormalModeDispatcher.commandLineHelpTopic(":hello") == nil)
  }

  func testHelpDocsRenderIndexAndTopic() {
    let index = HelpDocs.render(topic: nil, config: .default, showModes: true)
    XCTAssertTrue(index.contains("`plugins`"))
    XCTAssertTrue(index.contains("`normal-mode`"))
    XCTAssertTrue(index.contains("`marks`"), "marks topic should appear in the index")
    XCTAssertTrue(index.contains("`mark`"), "marks alias should be visible in the index")
    XCTAssertTrue(index.contains("`flashlight`"), "flashlight topic should appear in the index")

    let plugins = HelpDocs.render(topic: "plugins", config: .default, showModes: true)
    XCTAssertTrue(plugins.contains("# Plugins"))
    XCTAssertTrue(plugins.contains("manifest.json"))

    let marks = HelpDocs.render(topic: "marks", config: .default, showModes: true)
    XCTAssertTrue(marks.contains("# Marks"))
    XCTAssertTrue(marks.contains("m<letter>") || marks.contains("`ma`") || marks.contains("ma "))

    let mark = HelpDocs.render(topic: "mark", config: .default, showModes: true)
    XCTAssertEqual(
      mark, marks,
      ":help mark must resolve to the same body as :help marks")

    let unknown = HelpDocs.render(topic: "missing", config: .default, showModes: true)
    XCTAssertTrue(unknown.contains("Unknown Help Topic"))
  }

  func testMouseGridIsSquareWithLargestOddNAlphabetSquare() {
    // 16-letter alphabet → largest odd N with N² ≤ 16 is 3 → 3x3 (= 9
    // cells). The grid stays square regardless of region aspect ratio.
    let region = MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let hints = MouseGrid.hints(
      in: region,
      depth: 0,
      alphabet: Array("abcdefghijklmnop"))

    XCTAssertEqual(hints.count, 9)
    XCTAssertEqual(hints.first?.label, "a")
    XCTAssertEqual(hints.last?.label, "i")
    // 3x3 over a 400x200 region → cell ≈ 133.33 x 66.67. Cells touch
    // edge-to-edge (no gap).
    let cellW = 400.0 / 3.0
    let cellH = 200.0 / 3.0
    XCTAssertEqual(hints[0].target.frame.width, cellW, accuracy: 0.01)
    XCTAssertEqual(hints[0].target.frame.height, cellH, accuracy: 0.01)
  }

  func testMouseGridUses5x5For25LetterAlphabet() {
    // qwerty homerow + toprow = 20 letters; not enough for 5x5 (= 25).
    // A 25-letter alphabet (homerow+toprow with an extra) lands on 5x5.
    let alphabet = Array("abcdefghijklmnopqrstuvwxy")  // 25 letters
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
      alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 5, rows: 5))
  }

  func testMouseGridFinalStepRendersCompactClusterCenteredOnPastRect() {
    // 9-cell alphabet → 3x3. Past rectangle is small enough that tile
    // cells would be smaller than the chip — exactly the case the
    // compact-cluster layout exists to fix.
    let alphabet = Array("abcdefghi")
    let past = CGRect(x: 100, y: 200, width: 60, height: 40)
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: past), alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 3, rows: 3))
    let chip = CGSize(width: 14, height: 18)
    let hints = MouseGrid.hints(
      in: region,
      depth: MouseGrid.defaultSteps - 1,
      alphabet: alphabet,
      finalChipSize: chip)
    XCTAssertEqual(hints.count, 9)
    for hint in hints {
      XCTAssertEqual(hint.target.role, MouseGrid.finalChipRole)
      XCTAssertEqual(hint.target.frame.width, chip.width, accuracy: 0.01)
      XCTAssertEqual(hint.target.frame.height, chip.height, accuracy: 0.01)
    }
    // Adjacent chips never overlap: each chip's left edge is at least at
    // its row neighbour's right edge.
    let inRowOrder = hints.prefix(3).map(\.target.frame)
    XCTAssertGreaterThanOrEqual(inRowOrder[1].minX, inRowOrder[0].maxX)
    XCTAssertGreaterThanOrEqual(inRowOrder[2].minX, inRowOrder[1].maxX)
    // The cluster is centered on the past rectangle's midpoint.
    let union = hints.reduce(CGRect.null) { $0.union($1.target.frame) }
    XCTAssertEqual(union.midX, past.midX, accuracy: 0.01)
    XCTAssertEqual(union.midY, past.midY, accuracy: 0.01)
  }

  func testMouseGridIntermediateStepKeepsTileLayoutEvenWithChipSize() {
    // Sanity check: passing finalChipSize at a non-final depth does
    // *not* swap layouts — the compact cluster is the user-facing
    // "we've zoomed in enough" affordance, not an early replacement
    // for the tile path.
    let alphabet = Array("abcdefghi")
    let past = CGRect(x: 0, y: 0, width: 600, height: 600)
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: past), alphabet: alphabet)
    let hints = MouseGrid.hints(
      in: region,
      depth: 0,
      alphabet: alphabet,
      finalChipSize: CGSize(width: 14, height: 18))
    XCTAssertTrue(hints.allSatisfy { $0.target.role == MouseGrid.cellRole })
    XCTAssertEqual(hints[0].target.frame.width, past.width / 3, accuracy: 0.01)
  }

  func testMouseGridCommitsAfterThreeSelections() {
    let alphabet = Array("abcdefghijklmnop")  // 16 letters → 3x3
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
      alphabet: alphabet)
    XCTAssertEqual(region.grid, MouseGrid.Grid(columns: 3, rows: 3))
    let first = MouseGrid.hints(in: region, depth: 0, alphabet: alphabet)
    XCTAssertEqual(first.count, region.grid?.cellCount)
    let secondRegion = MouseGrid.Region(frame: first[0].target.frame, grid: region.grid)
    XCTAssertFalse(MouseGrid.shouldCommit(region: secondRegion, depth: 1))

    let second = MouseGrid.hints(in: secondRegion, depth: 1, alphabet: alphabet)
    XCTAssertEqual(second.count, region.grid?.cellCount)
    let finalRegion = MouseGrid.Region(frame: second[0].target.frame, grid: region.grid)
    XCTAssertTrue(MouseGrid.isFinalDisplayDepth(2))

    let final = MouseGrid.hints(in: finalRegion, depth: 2, alphabet: alphabet)
    XCTAssertEqual(final.count, region.grid?.cellCount)
    // After 3 steps, shouldCommit must return true so the next selection
    // synthesizes the click.
    for hint in final {
      XCTAssertTrue(
        MouseGrid.shouldCommit(
          region: MouseGrid.Region(frame: hint.target.frame, grid: region.grid),
          depth: 3))
    }
  }

  func testFinalMouseGridCellsTouchWithoutGaps() {
    // Adjacent final cells share an edge — no gap, no overlap. The
    // user's promise: clicking *anywhere* in a cell commits the hint.
    let alphabet = Array("abcdefghijklmnop")
    let region = MouseGrid.preparedRegion(
      MouseGrid.Region(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
      alphabet: alphabet)
    let first = MouseGrid.hints(in: region, depth: 0, alphabet: alphabet)
    XCTAssertGreaterThanOrEqual(first.count, 4)
    // Cells laid out left-to-right within a row share a vertical edge.
    let topLeft = first[0].target.frame
    let topMid = first[1].target.frame
    XCTAssertEqual(topLeft.maxX, topMid.minX, accuracy: 0.001)
    XCTAssertEqual(topLeft.minY, topMid.minY, accuracy: 0.001)
    XCTAssertEqual(topLeft.maxY, topMid.maxY, accuracy: 0.001)
  }

  func testPluginCommandLineInvocationParser() throws {
    let invocation = try XCTUnwrap(
      NormalModeDispatcher.pluginCommandLineInvocation(":spotify pause quiet now"))
    XCTAssertEqual(invocation.command, "spotify")
    XCTAssertEqual(invocation.subcommand, "pause")
    XCTAssertEqual(invocation.args, ["quiet", "now"])

    // A single token is a top-level command (`:copy`): the verb with an empty
    // subcommand and no args.
    let topLevel = try XCTUnwrap(NormalModeDispatcher.pluginCommandLineInvocation(":copy"))
    XCTAssertEqual(topLevel.command, "copy")
    XCTAssertEqual(topLevel.subcommand, "")
    XCTAssertEqual(topLevel.args, [])

    XCTAssertNil(NormalModeDispatcher.pluginCommandLineInvocation(":"))
  }

  func testCommandLineOpenForward() {
    // Bare `:open` (with or without trailing whitespace) forwards no args.
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenForward("open"), [])
    XCTAssertEqual(NormalModeDispatcher.commandLineOpenForward("open "), [])
    // Args are split on whitespace and forwarded verbatim to `open`.
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward(":open https://example.com"),
      ["https://example.com"])
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward(":open -a Firefox file.txt"),
      ["-a", "Firefox", "file.txt"])
    XCTAssertEqual(
      NormalModeDispatcher.commandLineOpenForward("  OPEN   Firefox  "), ["Firefox"])
    // Non-`open` lines are not forwarded.
    XCTAssertNil(NormalModeDispatcher.commandLineOpenForward("opening firefox"))
    XCTAssertNil(NormalModeDispatcher.commandLineOpenForward("edit firefox"))
  }

  func testCommandLineCompletionsTopLevelEmptyBody() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":",
        pluginCommands: ["spotify", "github"],
        pluginSubcommands: ["spotify": ["play", "pause"], "github": ["prs"]]))
    XCTAssertEqual(context.prefix, ":")
    XCTAssertEqual(context.query, "")
    let labels = context.items.map(\.label)
    XCTAssertTrue(labels.contains("quit"))
    XCTAssertTrue(labels.contains("write"))
    XCTAssertTrue(labels.contains("open"), "`:open` (dumb forward to /usr/bin/open)")
    XCTAssertTrue(labels.contains("edit"), "`:e[dit]` (Cmd+O document open) is its own command")
    XCTAssertTrue(labels.contains("help"))
    XCTAssertTrue(labels.contains("flashlight"))
    XCTAssertTrue(labels.contains("spotify"))
    XCTAssertTrue(labels.contains("github"))
    XCTAssertFalse(labels.contains { $0.hasPrefix("%") })
    XCTAssertFalse(labels.contains("tabedit"), "alias of tabnew should not appear")
    XCTAssertFalse(labels.contains("tabe"), "short alias of tabnew should not appear")
    XCTAssertFalse(labels.contains("grep"), "alias of find should not appear")
    XCTAssertFalse(labels.contains("vimgrep"), "alias of find should not appear")
    XCTAssertFalse(labels.contains("copy"), "alias of yank should not appear")
    XCTAssertFalse(labels.contains("cut"), "alias of delete should not appear")
    XCTAssertFalse(labels.contains("paste"), "alias of put should not appear")
    XCTAssertEqual(
      labels, labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
      "completions should be sorted alphabetically")
    let spotify = try XCTUnwrap(context.items.first { $0.label == "spotify" })
    XCTAssertEqual(spotify.insertion, "spotify ")
    XCTAssertEqual(spotify.kind, .acceptsArgs)
    let quit = try XCTUnwrap(context.items.first { $0.label == "quit" })
    XCTAssertEqual(quit.insertion, "quit")
    XCTAssertEqual(quit.kind, .terminal)
    let open = try XCTUnwrap(context.items.first { $0.label == "open" })
    XCTAssertEqual(open.insertion, "open ")
    XCTAssertEqual(open.kind, .acceptsArgs)
  }

  func testCommandLineCompletionsTopLevelWithPartialQuery() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":sp",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertEqual(context.prefix, ":")
    XCTAssertEqual(context.query, "sp")
  }

  func testCommandLineCompletionsPluginSubcommands() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify ",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play", "pause", "next"]]))
    XCTAssertEqual(context.prefix, ":spotify ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["play", "pause", "next"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
  }

  func testCommandLineCompletionsPluginSubcommandsWithFilter() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify pa",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play", "pause", "next"]]))
    XCTAssertEqual(context.prefix, ":spotify ")
    XCTAssertEqual(context.query, "pa")
  }

  func testCommandLineCompletionsReturnsNilWhenNoMatch() {
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        ":spotify play extra",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        ":unknown ",
        pluginCommands: ["spotify"],
        pluginSubcommands: ["spotify": ["play"]]))
    XCTAssertNil(
      NormalModeDispatcher.commandLineCompletions(
        "no colon",
        pluginCommands: [],
        pluginSubcommands: [:]))
  }

  func testCommandLineCompletionsPluginsBuiltinSubcommands() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":plugins ",
        pluginCommands: [],
        pluginSubcommands: [:]))
    XCTAssertEqual(context.prefix, ":plugins ")
    XCTAssertEqual(context.query, "")
    XCTAssertEqual(Set(context.items.map(\.label)), ["list", "ls", "reload"])
    XCTAssertTrue(context.items.allSatisfy { $0.kind == .pluginSubcommand })
  }

  func testCommandLineCompletionsTopLevelIncludesPlugins() throws {
    let context = try XCTUnwrap(
      NormalModeDispatcher.commandLineCompletions(
        ":",
        pluginCommands: [],
        pluginSubcommands: [:]))
    let plugins = try XCTUnwrap(context.items.first { $0.label == "plugins" })
    XCTAssertEqual(plugins.insertion, "plugins ")
    XCTAssertEqual(plugins.kind, .acceptsArgs)
  }

  func testCommandLineCandidateQueryAcceptsFlashlight() {
    // `:open` is a dumb forward, not a candidate finder — it must not feed
    // the candidate query path.
    XCTAssertNil(NormalModeDispatcher.commandLineCandidateQuery(":open firefox"))
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":flashlight"), "")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":flashlight gmail.com"), "gmail.com")
    // Trailing whitespace is preserved on purpose — `parseBangState`
    // uses it as the signal that the user committed to a bang. Leading
    // whitespace + tabs between the verb and the argument are still
    // collapsed because they're syntactic, not part of the query.
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery("  FLASHLIGHT   Slack  "), "Slack  ")
    XCTAssertNil(NormalModeDispatcher.commandLineCandidateQuery(":flashlightgmail"))
  }

  func testCommandLineCandidateQueryAcceptsEmojiPicker() {
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":emojis"), "")
    XCTAssertEqual(NormalModeDispatcher.commandLineCandidateQuery(":emojis fire"), "fire")
    XCTAssertEqual(NormalModeDispatcher.commandLineEmojiQuery("  EMOJIS   heart  "), "heart  ")
    XCTAssertNil(NormalModeDispatcher.commandLineEmojiQuery(":emojisheart"))
    XCTAssertNil(NormalModeDispatcher.commandLineEmojiQuery(":flashlight heart"))
  }

  func testCandidateFinderSourceFilterParsesLeadingFlag() {
    let withText = NormalModeDispatcher.candidateFinderSourceFilter("--notes inbox")
    XCTAssertEqual(withText.sourceFilters, ["notes"])
    XCTAssertEqual(withText.text, "inbox")

    let bare = NormalModeDispatcher.candidateFinderSourceFilter("--notes")
    XCTAssertEqual(bare.sourceFilters, ["notes"])
    XCTAssertEqual(bare.text, "")

    let none = NormalModeDispatcher.candidateFinderSourceFilter("inbox")
    XCTAssertEqual(none.sourceFilters, [])
    XCTAssertEqual(none.text, "inbox")

    let upper = NormalModeDispatcher.candidateFinderSourceFilter("  --Firefox   gmail ")
    XCTAssertEqual(upper.sourceFilters, ["firefox"])
    XCTAssertEqual(upper.text, "gmail")

    // `@<source>` is equivalent to `--<source>`.
    let at = NormalModeDispatcher.candidateFinderSourceFilter("@notes inbox")
    XCTAssertEqual(at.sourceFilters, ["notes"])
    XCTAssertEqual(at.text, "inbox")

    let atBare = NormalModeDispatcher.candidateFinderSourceFilter("  @Firefox ")
    XCTAssertEqual(atBare.sourceFilters, ["firefox"])
    XCTAssertEqual(atBare.text, "")
  }

  func testCandidateFinderSourceFilterSelectorsAnywhereAndMultiple() {
    // Selectors may appear before or after the query, in any order, and
    // several of them widen the pool. The two orderings must be identical.
    let leading = NormalModeDispatcher.candidateFinderSourceFilter("@tmux @slack test")
    XCTAssertEqual(leading.sourceFilters, ["tmux", "slack"])
    XCTAssertEqual(leading.text, "test")

    let trailing = NormalModeDispatcher.candidateFinderSourceFilter("test @slack @tmux")
    XCTAssertEqual(trailing.sourceFilters, ["slack", "tmux"])
    XCTAssertEqual(trailing.text, "test")

    // Interleaved selectors and multi-word text.
    let mixed = NormalModeDispatcher.candidateFinderSourceFilter("foo @notes bar --firefox baz")
    XCTAssertEqual(mixed.sourceFilters, ["notes", "firefox"])
    XCTAssertEqual(mixed.text, "foo bar baz")

    // A bare `@` / `--` with no name is literal search text, not a selector.
    let bareAt = NormalModeDispatcher.candidateFinderSourceFilter("@ -- hi")
    XCTAssertEqual(bareAt.sourceFilters, [])
    XCTAssertEqual(bareAt.text, "@ -- hi")
  }

  func testCandidateFinderSourceFilterParsesStructuredSelectorsWithLegacyFilters() {
    let parsed = NormalModeDispatcher.candidateFinderSourceFilter(
      "rust @source:firefox @url:*github* --tmux @kind:browser_tab repo")
    XCTAssertEqual(parsed.sourceFilters, ["tmux"])
    XCTAssertEqual(
      parsed.attributeFilters,
      [
        NormalModeDispatcher.AttributeFilter(field: "source", pattern: "firefox"),
        NormalModeDispatcher.AttributeFilter(field: "url", pattern: "*github*"),
        NormalModeDispatcher.AttributeFilter(field: "kind", pattern: "browser_tab"),
      ])
    XCTAssertEqual(parsed.text, "rust repo")
  }

  func testFlashlightAliasExpansionRequiresWordBoundaryAndTrailingWhitespace() {
    let aliases = [
      "!g": "!google",
      "@ft": "@firefox.tabs",
      "gh": "!github",
    ]

    XCTAssertNil(
      CandidateFinder.expandFlashlightAlias(
        text: ":flashlight !g", cursorIndex: 14, aliases: aliases),
      "alias should not expand until the user types whitespace")
    XCTAssertNil(
      CandidateFinder.expandFlashlightAlias(
        text: ":flashlight big ", cursorIndex: 16, aliases: aliases),
      "alias keys are whole words, not suffix matches")

    let bare = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight gh ", cursorIndex: 15, aliases: aliases)
    XCTAssertEqual(bare?.text, ":flashlight !github ")
    XCTAssertEqual(bare?.cursorIndex, 20)

    let source = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight @ft inbox", cursorIndex: 16, aliases: aliases)
    XCTAssertEqual(source?.text, ":flashlight @firefox.tabs inbox")
    XCTAssertEqual(source?.cursorIndex, 26)
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
        kind: .plugin("slack_channel"),
        sourceID: "slack",
        source: "slack",
        pid: 123,
        name: "#schedule",
        subtitle: "Slack channel",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        url: nil))

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

    XCTAssertEqual(prepared.displayTitle, "[core.apps] Postico 2")
    XCTAssertEqual(prepared.normalizedSearchText, "core apps postico 2 postico 2 com eggerapps postico")
  }

  func testCandidateFinderPreparedBrowserTabIncludesBrowserTitleAndURL() {
    let prepared = CandidateFinder.prepare(
      Candidate(
        kind: .plugin("browser_tab"),
        sourceID: "firefox-tabs",
        source: "firefox",
        pid: 123,
        name: BrowserTabSources.browserTabName(
          title: "Gmail",
          url: "https://mail.google.com/mail/u/0/#inbox"),
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))

    XCTAssertEqual(prepared.displayTitle, "[firefox] Gmail · https://mail.google.com/mail/u/0/#inbox")
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
        kind: .plugin("tmux_window"),
        sourceID: "tmux",
        source: "tmux",
        pid: 123,
        name: "beside:1 beside-agentic",
        subtitle: "tmux window",
        bundleIdentifier: "",
        url: nil))

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

  func testBrowserIndexedTabSelectionUsesNativeShortcut() {
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 1,
        bundleIdentifier: "org.mozilla.firefox"),
      CGKeyCode(kVK_ANSI_1))
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 3,
        bundleIdentifier: "com.apple.Safari"),
      CGKeyCode(kVK_ANSI_3))
    XCTAssertEqual(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 9,
        bundleIdentifier: "com.google.Chrome"),
      CGKeyCode(kVK_ANSI_9))
  }

  func testNativeBrowserIndexedTabSelectionDoesNotHandleOtherApps() {
    XCTAssertNil(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 1,
        bundleIdentifier: "org.alacritty"))
    XCTAssertNil(
      AppDelegate.nativeBrowserTabIndexKey(
        index: 10,
        bundleIdentifier: "org.mozilla.firefox"))
  }

  func testTabNewFallbackKeyUsesCmdNForAlacrittyAndCmdTOtherwise() {
    XCTAssertEqual(
      AppDelegate.tabNewFallbackKey(forBundleIdentifier: "org.alacritty"),
      CGKeyCode(kVK_ANSI_N))
    XCTAssertEqual(
      AppDelegate.tabNewFallbackKey(forBundleIdentifier: "io.alacritty"),
      CGKeyCode(kVK_ANSI_N))
    XCTAssertEqual(
      AppDelegate.tabNewFallbackKey(forBundleIdentifier: "com.apple.Terminal"),
      CGKeyCode(kVK_ANSI_T))
    XCTAssertEqual(
      AppDelegate.tabNewFallbackKey(forBundleIdentifier: "com.google.Chrome"),
      CGKeyCode(kVK_ANSI_T))
  }

  func testHelpTextListsNormalModeMappings() {
    let help = NormalModeDispatcher.helpText(config: .default, showModes: true)
    for mapping in ["h", "j", "k", "l", "ctrl-e", "ctrl-y", "ctrl-d", "ctrl-u",
      "gg", "G", "[h", "]h", "f", "sf", "df", "mf", "F", "sF", "dF", "mF", "u", "ctrl-r", "x", "n", "/", "\\space", "r", "R", "t", "MAPPINGS",
      "ctrl-o", "ctrl-i", "ACTION", "NORMAL", "INSERT", "i", ":", "g^", "g$", "[t", "]t", "[a", "]a", "g1", "g9", "N{mapping}",
      ":q[uit]", ":q[uit]!", ":w[rite]", ":wq", ":x[it]", ":p[rint]", ":e[dit]", ":new", ":tabnew",
      ":bd[elete]", ":cl[ose]", ":find", ":u[ndo]", ":red[o]", ":y[ank]", ":pu[t]",
      ":open <args>", ":flashlight <query>", "flash://mouse_target",
      "flash://flashlight", "flash://mouse_target?secondary=1",
      "flash://mouse_target?double=1", "flash://mouse_grid", "flash://history_back", "flash://history_forward",
      "flash://app_previous", "flash://app_next",
      "flash://app_reload?force=1", "flash://tab_select?index=1", "flash://tab_new", "?"]
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
      ModeMapping(key: "zz", action: .flashCommand(.reload(force: false)))
    ]
    let help = NormalModeDispatcher.helpText(config: config, showModes: true)
    XCTAssertTrue(help.contains("zz"))
    XCTAssertTrue(help.contains("flash://app_reload"))
    XCTAssertFalse(help.contains("flash://mouse_target"))
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
    XCTAssertTrue(help.contains("flash://mouse_target"))
    XCTAssertTrue(help.contains("f"))
    XCTAssertFalse(help.contains("NORMAL"))
    XCTAssertFalse(help.contains("INSERT"))
  }

  func testMappingsTextListsResolvedScopesAndLeaderMappings() {
    var config = Config.default
    config.mode.all = [
      ModeMapping(key: "cmd+space", action: .flashCommand(.flashlight))
    ]
    config.mode.normal = [
      ModeMapping(key: "\\c", action: .shellCommand(["sh", "/tmp/toggle_caffeinate.sh"]))
    ]
    config.mode.insert = [
      ModeMapping(key: "ctrl+space", action: .flashCommand(.mouseTarget(.click(.leftClick))))
    ]
    let text = NormalModeDispatcher.mappingsText(config: config)
    XCTAssertTrue(text.contains("# Mappings"))
    XCTAssertTrue(text.contains("Normal leader: `\\`"))
    XCTAssertTrue(text.contains("all"))
    XCTAssertTrue(text.contains("normal"))
    XCTAssertTrue(text.contains("insert"))
    XCTAssertTrue(text.contains("cmd+space"))
    XCTAssertTrue(text.contains("\\c"))
    XCTAssertTrue(text.contains("[\"sh\", \"/tmp/toggle_caffeinate.sh\"]"))
  }

  func testConfiguredMappingsOverrideDefaults() {
    let mappings = [
      ModeMapping(key: "j", action: .flashCommand(.scroll(.up))),
      ModeMapping(key: "zz", action: .flashCommand(.reload(force: false))),
      ModeMapping(key: "tab", action: .flashCommand(.movementForward)),
      ModeMapping(key: "delete_forward", action: .flashCommand(.scroll(.halfPageDown))),
    ]
    XCTAssertEqual(command(chars: "j", mappings: mappings), .scroll(.up))
    XCTAssertEqual(transition(chars: "z", mappings: mappings).pending, "z")
    XCTAssertEqual(command(pending: "z", chars: "z", mappings: mappings), .reload(force: false))
    XCTAssertEqual(
      transition(keyCode: kVK_Tab, chars: "\t", mappings: mappings).command,
      .movementForward)
    XCTAssertEqual(
      transition(keyCode: kVK_ForwardDelete, chars: "", mappings: mappings).command,
      .scroll(.halfPageDown))
  }

  func testCommandModifiedMappingsDispatchConfiguredActionsInNormalMode() {
    let mappings = [
      ModeMapping(key: "cmd+delete", action: .flashCommand(.scroll(.halfPageUp))),
      ModeMapping(key: "cmd+tab", action: .flashCommand(.movementForward)),
    ]
    XCTAssertEqual(
      transition(
        keyCode: kVK_Delete,
        chars: "\u{7F}",
        flags: [.command],
        mappings: mappings).command,
      .scroll(.halfPageUp))
    XCTAssertEqual(
      transition(
        keyCode: kVK_Tab,
        chars: "\t",
        flags: [.command],
        mappings: mappings).command,
      .movementForward)
  }

  func testConfiguredShellMappingsProduceActions() {
    let action = MappingCommand.shellCommand(["sh", "~/bin/toggle-colors"])
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
      ModeMapping(key: "spacec", action: .flashCommand(.reload(force: false)))
    ]
    let first = transition(keyCode: kVK_Space, chars: " ", mappings: mappings)
    XCTAssertEqual(first.pending, "space")
    XCTAssertEqual(
      transition(pending: "space", chars: "c", mappings: mappings).command,
      .reload(force: false))
  }

  func testBackslashLeaderShellMappingProducesAction() {
    let action = MappingCommand.shellCommand(["sh", "/tmp/toggle"])
    let mappings = [
      ModeMapping(key: "\\c", action: action),
      ModeMapping(key: "\\space", action: .flashCommand(.flashlight)),
    ]
    let first = transition(chars: "\\", mappings: mappings)
    XCTAssertEqual(first.pending, "\\")
    let second = transition(pending: "\\", chars: "c", mappings: mappings)
    XCTAssertEqual(second.action, action)
  }

  func testEscapeConsumesWithoutLeavingNormalMode() {
    let t = NormalModeInterpreter.interpret(
      pending: "",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil,
      mappings: CompiledMappings(Config.Mode.defaultNormalMappings))
    XCTAssertNil(t.command)
    XCTAssertEqual(t.pending, "")
  }

  func testEscapeClearsPendingSequence() {
    let t = NormalModeInterpreter.interpret(
      pending: "2g",
      keyCode: 53,
      modifierFlags: [],
      characters: nil,
      charactersIgnoringModifiers: nil,
      mappings: CompiledMappings(Config.Mode.defaultNormalMappings))
    XCTAssertNil(t.command)
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
    mappings: [ModeMapping] = Config.default.mode.normal
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
    mappings: [ModeMapping] = Config.default.mode.normal
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending,
      keyCode: UInt16(keyCode),
      modifierFlags: flags,
      characters: chars,
      charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
      mappings: CompiledMappings(mappings))
  }

  private func candidateFinderCandidate(
    name: String,
    pid: pid_t?,
    bundleIdentifier: String,
    path: String
  ) -> Candidate {
    Candidate(
      kind: .app,
      sourceID: "core.apps",
      source: "core.apps",
      pid: pid,
      name: name,
      subtitle: "app",
      bundleIdentifier: bundleIdentifier,
      url: URL(fileURLWithPath: path))
  }
}

import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class OverlayInputTests: XCTestCase {
  func testPlainLetterCommitsHintCharacter() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [],
        charactersIgnoringModifiers: "n"),
      .commit("n", []))
  }

  func testShiftLetterCommitsWithShiftClickModifierByDefault() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.shift]))
  }

  func testCommandLetterCommitsWithCommandClickModifier() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.command]))
  }

  func testControlLetterCommitsWithControlClickModifier() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.control],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.control]))
  }

  func testOptionLetterCommitsWithOptionClickModifier() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.option],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.option]))
  }

  func testShiftIsCarriedWithOtherMagicModifiersByDefault() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.command, .shift]))
  }

  func testShiftAlwaysRidesThroughToClickModifiersEvenWhenStrippedFromMagic() {
    // Shift is removed from `magicModifiers` automatically when the
    // alphabet contains non-letters (default `qwerty_toprow` digits) so
    // that `shift+1` doesn't fight with `!` at input time. But the
    // ambiguity doesn't apply at click time — a shift-modified mouse
    // event is unambiguous — so the synthesized click must still see
    // the shift modifier. Otherwise `f`+shift+hint stops being a real
    // shift+click, breaking the user's `[[mouse.bindings]]` config in
    // alacritty / firefox / etc.
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n",
        magicModifiers: [.command, .control, .option]),
      .commit("n", [.shift]))
  }

  func testCommandControlOptionLetterCommitsWithAllClickModifiers() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.command, .control, .option],
        charactersIgnoringModifiers: "n"),
      .commit("n", [.command, .control, .option]))
  }

  func testUnlistedModifierCancelsWhenMagicModifiersAreRestricted() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.option],
        charactersIgnoringModifiers: "n",
        magicModifiers: [.command]),
      .cancel)
  }

  func testEmptyMagicModifiersCancelsModifiedHintKey() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "n",
        magicModifiers: []),
      .cancel)
  }

  func testEmptyMagicModifiersStillAllowsPlainHintKey() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [],
        charactersIgnoringModifiers: "n",
        magicModifiers: []),
      .commit("n", []))
  }

  func testEmptyMagicModifiersStillPassesShiftThroughOnHintCommit() {
    // Same invariant as
    // `testShiftAlwaysRidesThroughToClickModifiersEvenWhenStrippedFromMagic`:
    // empty `magicModifiers` blocks cmd/ctrl/option (the cancel gate
    // above guards that) but never blocks shift on the click — input
    // ambiguity at the *character* level is what the strip protects
    // against, and the click event has no character.
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n",
        magicModifiers: []),
      .commit("n", [.shift]))
  }

  func testModifiedBackspaceCancelsInsteadOfEditingPrefix() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 51,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "\u{7f}"),
      .cancel)
  }

  func testUnmodifiedBackspaceEditsPrefix() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 51,
        modifierFlags: [],
        charactersIgnoringModifiers: "\u{7f}"),
      .backspace)
  }

  func testEscapeCancelsEvenWithModifiers() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 53,
        modifierFlags: [.command],
        charactersIgnoringModifiers: nil),
      .cancel)
  }

  func testCommandLineUsesNativeTextFieldResponder() {
    XCTAssertTrue(CommandLineTextField(frame: .zero).acceptsFirstResponder)
  }

  func testCommandLineArrowDirectionsMatchVisibleList() {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    let textView = NSTextView()

    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.moveUp(_:))))
    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.moveDown(_:))))

    XCTAssertEqual(coordinator.commandLineSelectionDeltas, [-1, 1])
  }

  func testCommandLineReturnSubmitsWithoutClearingCommandBufferFirst() {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.commandTextField.stringValue = ":flashlight @tmux"
    panel.commandLineText = ":flashlight @tmux"
    let textView = NSTextView()

    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.insertNewline(_:))))

    XCTAssertEqual(coordinator.submittedCommands, [":flashlight @tmux"])
    XCTAssertEqual(panel.commandLineText, ":flashlight @tmux")
  }

  func testCommandLineTabSyncsTextFieldBeforeAcceptingSelection() {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.commandTextField.stringValue = ":flashlight @tmux"
    panel.commandLineText = ":flashlight @old"
    let textView = NSTextView()

    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.insertTab(_:))))

    XCTAssertEqual(coordinator.insertSelectionCount, 1)
    XCTAssertEqual(panel.commandLineText, ":flashlight @tmux")
  }

  func testOverlayNoActionsCoverModeTransitionProperties() {
    for key in [
      "frame", "hidden", "backgroundColor", "sublayers", "colors",
      "shadowColor", "shadowOpacity", "shadowRadius", "shadowOffset", "shadowPath",
    ] {
      XCTAssertNotNil(OverlayPanel.noActions[key], "missing \(key)")
    }
  }

  func testReadOnlyModalTextViewConsumesQToDismiss() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .modal
    panel.modalSelectable = false
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "q",
        charactersIgnoringModifiers: "q",
        isARepeat: false,
        keyCode: 12))

    XCTAssertTrue(panel.consumeModalKeyDown(event))
    XCTAssertEqual(coordinator.cancelModalCount, 1)
    XCTAssertEqual(coordinator.passThroughModalCount, 0)
  }

  func testPointerIntentMonitorRunsForCapturingNormalModeBadge() {
    XCTAssertTrue(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .normal,
        modeBadgeVisible: true,
        modeBadgeCapturesInput: true))
    XCTAssertFalse(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .hints,
        modeBadgeVisible: true,
        modeBadgeCapturesInput: true))
    XCTAssertFalse(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .normal,
        modeBadgeVisible: false,
        modeBadgeCapturesInput: true))
    XCTAssertFalse(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .normal,
        modeBadgeVisible: true,
        modeBadgeCapturesInput: false))
  }

  func testPointerIntentMonitorRunsForCommandLineAndCandidateFinder() {
    // Clicking outside the command bar / candidate list must dismiss
    // them, regardless of mode-badge visibility — those input modes are
    // never on screen without a panel the user can click out of.
    XCTAssertTrue(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .commandLine,
        modeBadgeVisible: false,
        modeBadgeCapturesInput: false))
    XCTAssertTrue(
      OverlayPanel.pointerIntentMonitorShouldRun(
        inputMode: .candidateFinder,
        modeBadgeVisible: false,
        modeBadgeCapturesInput: false))
  }

  func testConfiguredModifiedNormalMappingDoesNotLockOutBracketTabSequence() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    coordinator.mappingEventsToHandle = 1
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let normalModeHotkey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .control],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "[",
        charactersIgnoringModifiers: "[",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_LeftBracket)))

    XCTAssertTrue(panel.performKeyEquivalent(with: normalModeHotkey))
    XCTAssertNil(panel.normalModeChordLockoutUntil)

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_LeftBracket, characters: "["))
    XCTAssertEqual(panel.normalModePending, "[")

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_T, characters: "t"))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertEqual(coordinator.normalModeActions.map(\.0?.command), [.tabPrev])
  }

  func testConfiguredModifiedNormalMappingDoesNotLockOutRightBracketTabSequence() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    coordinator.mappingEventsToHandle = 1
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let normalModeHotkey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .control],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "[",
        charactersIgnoringModifiers: "[",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_LeftBracket)))

    XCTAssertTrue(panel.performKeyEquivalent(with: normalModeHotkey))
    XCTAssertNil(panel.normalModeChordLockoutUntil)

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_RightBracket, characters: "]"))
    XCTAssertEqual(panel.normalModePending, "]")

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_T, characters: "t"))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertEqual(coordinator.normalModeActions.map(\.0?.command), [.tabNext])
  }

  func testActiveWindowBorderLocalRectTouchesWindowExteriorEdge() {
    let local = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: CGRect(x: 100, y: 80, width: 500, height: 300),
      panelFrame: CGRect(x: 40, y: 20, width: 800, height: 600),
      lineWidth: 2)

    XCTAssertEqual(local, CGRect(x: 61, y: 61, width: 498, height: 298))
    XCTAssertEqual(local.minX - 1, 60)
    XCTAssertEqual(local.minY - 1, 60)
    XCTAssertEqual(local.maxX + 1, 560)
    XCTAssertEqual(local.maxY + 1, 360)
  }

  func testModeBadgeWidthUsesLongestConfiguredLabel() {
    let compact = OverlayPanel.modeBadgeWidth(
      labels: Config.Mode.Labels(normal: "N", insert: "I", command: "C"),
      currentText: "N",
      fontSize: 12)
    let full = OverlayPanel.modeBadgeWidth(
      labels: Config.Mode.Labels(normal: "NORMAL", insert: "INSERT", command: "COMMAND"),
      currentText: "NORMAL",
      fontSize: 12)

    XCTAssertLessThan(compact, full)
  }

  func testCandidateFinderResultsHeightHugsLineCount() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    let rowHeight = OverlayPanel.candidateFinderResultRowHeight(font: font)
    let lineSpacing: CGFloat = 2

    let single = OverlayPanel.candidateFinderResultsHeight(
      lineCount: 1, font: font, lineSpacing: lineSpacing)
    XCTAssertEqual(single, rowHeight)

    let ten = OverlayPanel.candidateFinderResultsHeight(
      lineCount: 10, font: font, lineSpacing: lineSpacing)
    // 10 line heights + 9 inter-line gaps (no trailing gap).
    XCTAssertEqual(ten, rowHeight * 10 + lineSpacing * 9)

    // No silent inflation: the value never exceeds the exact-fit
    // formula, which is what fixes the empty band below the last row.
    XCTAssertEqual(
      OverlayPanel.candidateFinderResultsHeight(
        lineCount: 0, font: font, lineSpacing: lineSpacing),
      rowHeight)
  }

}

private func keyEvent(
  keyCode: Int,
  characters: String,
  charactersIgnoringModifiers: String? = nil,
  modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
  try XCTUnwrap(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifierFlags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
      isARepeat: false,
      keyCode: UInt16(keyCode)))
}

private final class SpyOverlayCoordinator: OverlayCoordinator {
  var cancelModalCount = 0
  var passThroughModalCount = 0
  var commandLineSelectionDeltas: [Int] = []
  var insertSelectionCount = 0
  var submittedCommands: [String] = []
  var mappingEventsToHandle = 0
  var normalModeActions: [(MappingCommand?, Int)] = []

  func overlayDidCancel() {}
  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {}
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {}
  func overlayDidUpdatePrefix(_ prefix: String) {}
  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int) {
    if action != nil {
      normalModeActions.append((action, repeatCount))
    }
  }
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    guard mappingEventsToHandle > 0 else { return false }
    mappingEventsToHandle -= 1
    return true
  }
  func overlayDidCancelModal() { cancelModalCount += 1 }
  func overlayDidPassThroughModalKey(_ event: NSEvent) { passThroughModalCount += 1 }
  func overlayDidCancelCommandLine() {}
  func overlayDidUpdateCommandLine(
    _ command: String,
    cursorIndex: Int,
    resetSelection: Bool
  ) {}
  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    commandLineSelectionDeltas.append(delta)
    return true
  }
  func overlayDidInsertCommandLineSelection() -> Bool {
    insertSelectionCount += 1
    return true
  }
  func overlayDidSubmitCommandLine(_ command: String) {
    submittedCommands.append(command)
  }
  func overlayDidForceSubmitCommandLineSelection() {}
  func overlayDidCancelCandidateFinder() {}
  func overlayDidUpdateCandidateFinderQuery(_ query: String) {}
  func overlayDidMoveCandidateFinderSelection(_ delta: Int) {}
  func overlayDidSubmitCandidateFinder() {}
  func overlayDidSubmitSelectableModal() {}
  func overlayExpandFlashlightAlias(
    _ text: String,
    cursorIndex: Int
  ) -> (text: String, cursorIndex: Int)? {
    nil
  }
}

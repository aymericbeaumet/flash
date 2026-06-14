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

  func testPointerIntentMonitorRunsOnlyForCapturingNormalModeBadge() {
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

  func testCandidateFinderTextHeightUsesMeasuredContent() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    let text = NSAttributedString(
      string: "  [app] Cursor\n> [app] Finder",
      attributes: [.font: font])

    let measured = OverlayPanel.candidateFinderTextHeight(text, fallbackFont: font)
    let singleLine = OverlayPanel.candidateFinderTextHeight(
      NSAttributedString(string: "  [app] Cursor", attributes: [.font: font]),
      fallbackFont: font)
    let expected = ceil(
      max(
        font.ascender - font.descender + font.leading,
        text.boundingRect(
          with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading]).height))

    XCTAssertEqual(measured, expected)
    XCTAssertGreaterThan(measured, singleLine * 1.5)
    XCTAssertLessThan(measured, (12 + 5) * 3)
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
  func overlayDidInsertCommandLineSelection() -> Bool { false }
  func overlayDidSubmitCommandLine(_ command: String) {}
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

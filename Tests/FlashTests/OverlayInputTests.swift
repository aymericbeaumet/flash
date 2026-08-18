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

  func testArrowKeysCancel() {
    for keyCode: UInt16 in [123, 124, 125, 126] {
      XCTAssertEqual(
        OverlayInputInterpreter.action(
          keyCode: keyCode,
          modifierFlags: [],
          charactersIgnoringModifiers: nil),
        .cancel,
        "arrow \(keyCode) must cancel")
    }
  }

  func testPlainSpaceRequestsCenterCommit() {
    // `<space>` no longer hard-cancels at the interpreter — it becomes the
    // fixed centre-of-grid key. The coordinator decides whether that's a
    // center commit (mouse-grid mode) or a cancel (plain hints).
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 49,
        modifierFlags: [],
        charactersIgnoringModifiers: " "),
      .commitCenter([]))
  }

  func testShiftSpaceRidesShiftIntoCenterClick() {
    // Same shift-pass-through invariant as the hint-commit path: shift
    // always rides the synthesized click, so `shift+<space>` is a
    // shift+click on the centre.
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 49,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: " "),
      .commitCenter([.shift]))
  }

  func testCommandSpaceCancelsWhenCommandNotMagic() {
    // The magic-modifier cancel gate still guards `<space>`: an unlisted
    // strict modifier cancels rather than slipping through as a center
    // commit.
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 49,
        modifierFlags: [.command],
        charactersIgnoringModifiers: " ",
        magicModifiers: []),
      .cancel)
  }

  func testSpaceInHintsCommitsCenterWhenCoordinatorHandlesIt() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    coordinator.commitCenterHandled = true  // mouse-grid mode active
    panel.coordinator = coordinator
    panel.inputMode = .hints
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49))

    panel.keyDown(with: event)

    XCTAssertEqual(coordinator.commitCenterModifiers, [[]])
    XCTAssertEqual(coordinator.cancelCount, 0)
  }

  func testSpaceInHintsCancelsWhenCoordinatorDeclinesCenter() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    coordinator.commitCenterHandled = false  // plain hints, not mouse grid
    panel.coordinator = coordinator
    panel.inputMode = .hints
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: false,
        keyCode: 49))

    panel.keyDown(with: event)

    XCTAssertEqual(coordinator.commitCenterModifiers.count, 1)
    XCTAssertEqual(coordinator.cancelCount, 1)
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

  func testCommandLineControlEMovesCaretToEndOfLine() {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.commandTextField.stringValue = ":flashlight 1 * 1"
    panel.commandLineText = panel.commandTextField.stringValue
    let textView = NSTextView()
    textView.string = panel.commandTextField.stringValue
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.moveToEndOfLine(_:))))

    XCTAssertEqual(
      textView.selectedRange, NSRange(location: textView.string.utf16.count, length: 0))
    XCTAssertEqual(panel.commandLineCursorIndex, panel.commandTextField.stringValue.count)

    textView.setSelectedRange(NSRange(location: 4, length: 0))
    XCTAssertTrue(
      panel.control(
        panel.commandTextField,
        textView: textView,
        doCommandBy: #selector(NSResponder.moveToRightEndOfLine(_:))))
    XCTAssertEqual(
      textView.selectedRange, NSRange(location: textView.string.utf16.count, length: 0))
  }

  func testCommandLineKarabinerCmdRightKeyEquivalentMovesCaret() throws {
    let panel = OverlayPanel()
    panel.inputMode = .commandLine
    panel.commandTextField.stringValue = ":flashlight 1 * 1"
    panel.commandLineText = panel.commandTextField.stringValue
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    XCTAssertTrue(panel.makeFirstResponder(panel.commandTextField))
    let editor = try XCTUnwrap(panel.commandTextField.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: 124))

    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertEqual(editor.selectedRange, NSRange(location: editor.string.utf16.count, length: 0))
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
    // Idle NORMAL runs the monitor even when keyboard capture is temporarily
    // suppressed, so a click on the focused app can still enter insert.
    XCTAssertTrue(
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

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_RightBracket, characters: "]"))
    XCTAssertEqual(panel.normalModePending, "]")

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_T, characters: "t"))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertEqual(coordinator.normalModeActions.map(\.0?.command), [.tabNext])
  }

  func testRepeatableBracketAppMappingRepeatsOnFinalKey() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    panel.processNormalModeKey(
      try keyEvent(keyCode: kVK_ANSI_LeftBracket, characters: "["))
    for _ in 0..<4 {
      panel.processNormalModeKey(
        try keyEvent(keyCode: kVK_ANSI_A, characters: "a"))
    }

    XCTAssertEqual(
      coordinator.normalModeActions.map(\.0?.command),
      [.appPrev, .appPrev, .appPrev, .appPrev])
    XCTAssertEqual(
      panel.normalModeRepeatAnchor,
      NormalModeInterpreter.canonicalizeMappingKey("[a"))
  }

  func testKeyWindowFallbackPassesUnmappedModifierChordWhenEnabled() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "'",
        charactersIgnoringModifiers: "'",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Quote)))

    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertTrue(coordinator.normalModeActions.isEmpty)
    XCTAssertEqual(coordinator.passthroughEvents.map(\.keyCode), [UInt16(kVK_ANSI_Quote)])
  }

  func testKeyWindowFallbackConsumesUnmappedModifierChordWhenDisabled() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal
    panel.normalModePassthroughModifiers = []

    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "'",
        charactersIgnoringModifiers: "'",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Quote)))

    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertTrue(coordinator.normalModeActions.isEmpty)
    XCTAssertTrue(coordinator.passthroughEvents.isEmpty)
  }

  func testKeyWindowFallbackKeepsExplicitShiftMappingInNormalMode() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let event = try keyEvent(
      keyCode: kVK_ANSI_A,
      characters: "A",
      charactersIgnoringModifiers: "a",
      modifierFlags: [.shift])

    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertEqual(coordinator.normalModeActions.map(\.0?.command), [.insertMode])
    XCTAssertTrue(coordinator.passthroughEvents.isEmpty)
  }

  func testKeyWindowFallbackPassesUnknownShiftShortcut() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let event = try keyEvent(
      keyCode: kVK_ANSI_Q,
      characters: "Q",
      charactersIgnoringModifiers: "q",
      modifierFlags: [.shift])

    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertTrue(coordinator.normalModeActions.isEmpty)
    XCTAssertEqual(coordinator.passthroughEvents.map(\.keyCode), [UInt16(kVK_ANSI_Q)])
  }

  func testNormalModeConsumesDeadKeyEventWithoutCharacters() throws {
    let panel = OverlayPanel()
    let coordinator = SpyOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .normal
    panel.normalModeMappings = Config.default.mode.compiledNormal

    let deadKey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Quote)))

    XCTAssertTrue(panel.performKeyEquivalent(with: deadKey))
    XCTAssertEqual(panel.normalModePending, "")
    XCTAssertTrue(coordinator.normalModeActions.isEmpty)
  }

  func testActiveWindowBorderLocalRectKeepsStrokeInsideWindow() {
    let local = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: CGRect(x: 100, y: 80, width: 500, height: 300),
      panelFrame: CGRect(x: 40, y: 20, width: 800, height: 600),
      lineWidth: 2)

    // Path inset by `lineWidth` (=2) so the stroke band (centered on the
    // path, lineWidth/2 outside + lineWidth/2 inside) sits one full
    // line-width inside the target frame. Target's left edge in
    // panel-local is 100-40 = 60; the stroke's outer pixel lands at 61,
    // never at 60, so a window flush against a screen boundary can't
    // leak the border onto an adjacent display.
    XCTAssertEqual(local, CGRect(x: 62, y: 62, width: 496, height: 296))
    XCTAssertEqual(local.minX - 1, 61)
    XCTAssertEqual(local.minY - 1, 61)
    XCTAssertEqual(local.maxX + 1, 559)
    XCTAssertEqual(local.maxY + 1, 359)
  }

  func testActiveWindowBorderLocalRectClampsToZeroForTinyWindows() {
    let local = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
      panelFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      lineWidth: 2)

    XCTAssertEqual(local.width, 0)
    XCTAssertEqual(local.height, 0)
  }

  func testActiveWindowBorderSharesOuterEdgeRegardlessOfWidth() {
    // The stroke's OUTER edge must sit at the same position whether the border
    // is 1px (normal) or 3px (insert) — only the inner edge grows. The stroke is
    // centered on the path, so the outer edge is `path-inset − lineWidth/2`.
    let target = CGRect(x: 100, y: 80, width: 500, height: 300)
    let panel = CGRect(x: 40, y: 20, width: 800, height: 600)
    let thin = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: target, panelFrame: panel, lineWidth: 1)
    let thick = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: target, panelFrame: panel, lineWidth: 3)
    XCTAssertEqual(thin.minX - 0.5, thick.minX - 1.5, accuracy: 0.001)
    XCTAssertEqual(thin.minY - 0.5, thick.minY - 1.5, accuracy: 0.001)
    XCTAssertEqual(thin.maxX + 0.5, thick.maxX + 1.5, accuracy: 0.001)
    XCTAssertEqual(thin.maxY + 0.5, thick.maxY + 1.5, accuracy: 0.001)
  }

  func testActiveWindowBorderStaysBehindCommandAndCandidateLayers() {
    let panel = OverlayPanel()
    panel.activeWindowBorderLayer.path = CGPath(
      rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    var layers: [CALayer] = [panel.commandPromptLayer, panel.candidateFinderResultsLayer]

    panel.appendActiveWindowBorderLayerIfNeeded(to: &layers)

    XCTAssertTrue(layers[0] === panel.activeWindowBorderLayer)
    XCTAssertTrue(layers[1] === panel.commandPromptLayer)
    XCTAssertTrue(layers[2] === panel.candidateFinderResultsLayer)
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
  var commandLineSelectionDeltas: [Int] = []
  var insertSelectionCount = 0
  var submittedCommands: [String] = []
  var mappingEventsToHandle = 0
  var passthroughEvents: [NSEvent] = []
  var normalModeActions: [(MappingCommand?, Int)] = []
  var cancelCount = 0
  var commitCenterModifiers: [ClickModifiers] = []
  /// What `overlayDidCommitCenter` reports back — `true` mimics being in
  /// mouse-grid mode (center handled), `false` mimics plain hints (the
  /// panel then cancels).
  var commitCenterHandled = false

  func overlayDidCancel() { cancelCount += 1 }
  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {}
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {}
  func overlayDidCommitCenter(clickModifiers: ClickModifiers) -> Bool {
    commitCenterModifiers.append(clickModifiers)
    return commitCenterHandled
  }
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
  func overlayDidPassthroughUnmappedModifier(_ event: NSEvent) {
    passthroughEvents.append(event)
  }
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
  func overlayExpandFlashlightAlias(
    _ text: String,
    cursorIndex: Int
  ) -> (text: String, cursorIndex: Int)? {
    nil
  }
}

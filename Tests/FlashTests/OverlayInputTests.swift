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

  func testShiftCanBeRemovedFromMagicModifiers() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n",
        magicModifiers: [.command, .control, .option]),
      .commit("n", []))
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

  func testEmptyMagicModifiersIgnoresShiftAsPlainHintKey() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n",
        magicModifiers: []),
      .commit("n", []))
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

  func testCommandLineEditsAtCursor() {
    let panel = OverlayPanel()
    let coordinator = RecordingOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .commandLine
    panel.commandLineText = "open fx"
    panel.commandLineCursorIndex = 5

    panel.keyDown(with: keyEvent(keyCode: kVK_ANSI_I, characters: "i"))

    XCTAssertEqual(panel.commandLineText, "open ifx")
    XCTAssertEqual(panel.commandLineCursorIndex, 6)
    XCTAssertEqual(coordinator.commandUpdates.last?.command, "open ifx")
    XCTAssertEqual(coordinator.commandUpdates.last?.cursorIndex, 6)
    XCTAssertEqual(coordinator.commandUpdates.last?.resetSelection, true)
  }

  func testCommandLineCursorMotionAndForwardDelete() {
    let panel = OverlayPanel()
    let coordinator = RecordingOverlayCoordinator()
    panel.coordinator = coordinator
    panel.inputMode = .commandLine
    panel.commandLineText = "open firefox"
    panel.commandLineCursorIndex = panel.commandLineText.count

    panel.keyDown(with: keyEvent(keyCode: kVK_LeftArrow, characters: "", ignoring: ""))
    XCTAssertEqual(panel.commandLineCursorIndex, "open firefo".count)
    XCTAssertEqual(coordinator.commandUpdates.last?.resetSelection, false)

    panel.keyDown(with: keyEvent(keyCode: kVK_ForwardDelete, characters: "\u{7f}"))
    XCTAssertEqual(panel.commandLineText, "open firefo")
    XCTAssertEqual(panel.commandLineCursorIndex, "open firefo".count)
    XCTAssertEqual(coordinator.commandUpdates.last?.resetSelection, true)
  }

  func testOverlayNoActionsCoverModeTransitionProperties() {
    for key in ["frame", "hidden", "backgroundColor", "sublayers", "colors"] {
      XCTAssertNotNil(OverlayPanel.noActions[key], "missing \(key)")
    }
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

  private func keyEvent(
    keyCode: Int,
    characters: String,
    ignoring: String? = nil,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: ignoring ?? characters,
      isARepeat: false,
      keyCode: UInt16(keyCode))!
  }
}

private final class RecordingOverlayCoordinator: OverlayCoordinator {
  var commandUpdates: [(command: String, cursorIndex: Int, resetSelection: Bool)] = []

  func overlayDidCancel() {}
  func overlayDidCancelByPointer() {}
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {}
  func overlayDidUpdatePrefix(_ prefix: String) {}
  func overlayDidHandleNormalMode(_ command: URLCommand?, repeatCount: Int) {}
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool { false }
  func overlayDidCancelHelp() {}
  func overlayDidCancelCommandLine() {}
  func overlayDidUpdateCommandLine(
    _ command: String,
    cursorIndex: Int,
    resetSelection: Bool
  ) {
    commandUpdates.append((command, cursorIndex, resetSelection))
  }
  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool { false }
  func overlayDidSubmitCommandLine(_ command: String) {}
  func overlayDidCancelAppFinder() {}
  func overlayDidUpdateAppFinderQuery(_ query: String) {}
  func overlayDidMoveAppFinderSelection(_ delta: Int) {}
  func overlayDidSubmitAppFinder() {}
}

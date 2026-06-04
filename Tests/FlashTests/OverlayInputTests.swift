import AppKit
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
}

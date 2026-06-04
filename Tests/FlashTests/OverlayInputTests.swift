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
      .commit("n"))
  }

  func testShiftLetterStillCommitsHintCharacter() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "n"),
      .commit("n"))
  }

  func testCommandLetterCancelsInsteadOfEatingPlainHint() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "n"),
      .cancel)
  }

  func testControlLetterCancelsInsteadOfEatingPlainHint() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.control],
        charactersIgnoringModifiers: "n"),
      .cancel)
  }

  func testOptionLetterCancelsInsteadOfEatingPlainHint() {
    XCTAssertEqual(
      OverlayInputInterpreter.action(
        keyCode: 45,
        modifierFlags: [.option],
        charactersIgnoringModifiers: "n"),
      .cancel)
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

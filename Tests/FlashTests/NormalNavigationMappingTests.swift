import AppKit
import FlashCore
import XCTest

@testable import flash

final class NormalNavigationMappingTests: XCTestCase {
  private func interpret(
    pending: String, character: String, repeatAnchor: String? = nil
  ) -> NormalModeTransition {
    NormalModeInterpreter.interpret(
      pending: pending, repeatAnchor: repeatAnchor, keyCode: 0, modifierFlags: [],
      characters: character, charactersIgnoringModifiers: character,
      mappings: Config.default.mode.compiledNormal)
  }

  func testNumberedTabDefaultsSendLiteralCommandDigitsInEveryTerminal() throws {
    for index in 1...9 {
      let transition = interpret(pending: "g", character: String(index))
      guard case .sendKey(let keys, let key, let flags) = transition.command else {
        XCTFail("g\(index) must directly send Cmd-\(index)")
        continue
      }
      XCTAssertEqual(keys, "cmd+\(index)")
      XCTAssertEqual(flags, CGEventFlags.maskCommand.rawValue)
      XCTAssertEqual(transition.pending, "")
      XCTAssertNil(transition.repeatAnchor)
      XCTAssertFalse(
        AppDelegate.commandChordTypesTextInTerminal(
          key: key, flags: CGEventFlags(rawValue: flags)
        ) { false },
        "g\(index) in a terminal")
    }
  }

  func testTabMoveDefaultsRepeatTheirFinalKeyWithoutChangingMode() {
    for (prefix, command) in [("[", URLCommand.tabMovePrev), ("]", .tabMoveNext)] {
      let first = interpret(pending: prefix, character: "m")
      XCTAssertEqual(first.command, command)
      XCTAssertEqual(first.pending, "")
      XCTAssertEqual(
        first.repeatAnchor, NormalModeInterpreter.canonicalizeMappingKey(prefix + "m"))
      let repeated = interpret(pending: "", character: "m", repeatAnchor: first.repeatAnchor)
      XCTAssertEqual(repeated.command, command)
      XCTAssertEqual(repeated.repeatAnchor, first.repeatAnchor)
      XCTAssertNotEqual(repeated.command, .insertMode)
    }
  }
}

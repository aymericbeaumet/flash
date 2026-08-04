import AppKit
import Carbon.HIToolbox
import XCTest

@testable import flash

final class KeyModifierTests: XCTestCase {
  func testParseKnownSpellingsAreCaseAndAliasInsensitive() {
    XCTAssertEqual(KeyModifier.parse("cmd"), .success(.command))
    XCTAssertEqual(KeyModifier.parse("Command"), .success(.command))
    XCTAssertEqual(KeyModifier.parse(" ⌘ "), .success(.command))
    XCTAssertEqual(KeyModifier.parse("CTRL"), .success(.control))
    XCTAssertEqual(KeyModifier.parse("opt"), .success(.option))
    XCTAssertEqual(KeyModifier.parse("option"), .success(.option))
    XCTAssertEqual(KeyModifier.parse("shift"), .success(.shift))
  }

  func testParseUnknownReturnsError() {
    XCTAssertEqual(KeyModifier.parse("hyper"), .failure(.unknown("hyper")))
    XCTAssertNil(KeyModifier(token: "hyper"))
  }

  func testParseListDedupesAndCollectsUnknown() {
    let (mods, unknown) = KeyModifier.parseList(["cmd", "command", "", "bogus", "ctrl"])
    XCTAssertEqual(mods, [.command, .control])
    XCTAssertEqual(unknown, ["bogus"])
  }

  func testFlagMappings() {
    XCTAssertEqual(KeyModifier.command.carbonFlag, UInt32(cmdKey))
    XCTAssertEqual(KeyModifier.option.carbonFlag, UInt32(optionKey))
    XCTAssertEqual(KeyModifier.command.cgEventFlag, .maskCommand)
    XCTAssertEqual(KeyModifier.option.cgEventFlag, .maskAlternate)
    XCTAssertEqual(KeyModifier.control.nsEventFlag, .control)
    XCTAssertEqual(
      KeyModifier.cgEventFlags(["cmd", "shift"]), [.maskCommand, .maskShift])
    XCTAssertEqual(
      KeyModifier.carbonFlags(["cmd", "ctrl"]), UInt32(cmdKey) | UInt32(controlKey))
  }

  func testClickModifiersRouteThroughKeyModifier() {
    XCTAssertEqual(ClickModifiers(names: ["cmd", "opt"]), [.command, .option])
    XCTAssertEqual(ClickModifiers(names: ["bogus"]), [])
  }
}

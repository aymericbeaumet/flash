import Carbon.HIToolbox
import XCTest

@testable import flash

final class HotkeySyntaxTests: XCTestCase {

  func testSingleModifier() {
    let r = HotkeySyntax.parse(hotkey: "cmd+h", target: "Safari")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey))
    XCTAssertEqual(r?.virtualKey, 0x04)  // h
    if case .launchApp(let t) = r?.action {
      XCTAssertEqual(t, "Safari")
    } else {
      XCTFail("expected launchApp")
    }
  }

  func testMultipleModifiersJoinedByPlus() {
    let r = HotkeySyntax.parse(hotkey: "cmd+ctrl+a", target: "Alacritty")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey | controlKey))
    XCTAssertEqual(r?.virtualKey, 0x00)  // a
  }

  func testAllFourModifiers() {
    let r = HotkeySyntax.parse(hotkey: "cmd+shift+ctrl+alt+1", target: "Finder")
    let expected = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    XCTAssertEqual(r?.modifiers, expected)
    XCTAssertEqual(r?.virtualKey, 0x12)  // 1
  }

  func testNamedKeys() {
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+return", target: "X")?.virtualKey,
      UInt32(kVK_Return))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "ctrl+alt+left", target: "X")?.virtualKey,
      UInt32(kVK_LeftArrow))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+escape", target: "X")?.virtualKey,
      UInt32(kVK_Escape))
  }

  func testCaseInsensitive() {
    let upper = HotkeySyntax.parse(hotkey: "CMD+CTRL+A", target: "X")
    let lower = HotkeySyntax.parse(hotkey: "cmd+ctrl+a", target: "X")
    XCTAssertEqual(upper?.modifiers, lower?.modifiers)
    XCTAssertEqual(upper?.virtualKey, lower?.virtualKey)
  }

  func testAliasesMapToSameFlag() {
    let a = HotkeySyntax.parse(hotkey: "command+option+control+a", target: "X")
    let b = HotkeySyntax.parse(hotkey: "cmd+opt+ctrl+a", target: "X")
    let c = HotkeySyntax.parse(hotkey: "cmd+alt+ctrl+a", target: "X")
    XCTAssertEqual(a?.modifiers, b?.modifiers)
    XCTAssertEqual(b?.modifiers, c?.modifiers)
  }

  func testRawHexKeyCode() {
    let r = HotkeySyntax.parse(hotkey: "cmd+0x32", target: "X")
    XCTAssertEqual(r?.virtualKey, 0x32)
  }

  func testInvalidKeyReturnsNil() {
    XCTAssertNil(HotkeySyntax.parse(hotkey: "cmd+nothing", target: "X"))
    XCTAssertNil(HotkeySyntax.parse(hotkey: "", target: "X"))
  }
}

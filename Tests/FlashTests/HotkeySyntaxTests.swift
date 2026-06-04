import Carbon.HIToolbox
import XCTest

@testable import flash

final class HotkeySyntaxTests: XCTestCase {

  func testSingleModifier() {
    let r = HotkeySyntax.parse(hotkey: "cmd+h")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey))
    XCTAssertEqual(r?.virtualKey, 0x04)  // h
  }

  func testMultipleModifiersJoinedByPlus() {
    let r = HotkeySyntax.parse(hotkey: "cmd+ctrl+a")
    XCTAssertEqual(r?.modifiers, UInt32(cmdKey | controlKey))
    XCTAssertEqual(r?.virtualKey, 0x00)  // a
  }

  func testAllFourModifiers() {
    let r = HotkeySyntax.parse(hotkey: "cmd+shift+ctrl+alt+1")
    let expected = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    XCTAssertEqual(r?.modifiers, expected)
    XCTAssertEqual(r?.virtualKey, 0x12)  // 1
  }

  func testNamedKeys() {
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "cmd+return")?.virtualKey,
      UInt32(kVK_Return))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "ctrl+alt+left")?.virtualKey,
      UInt32(kVK_LeftArrow))
    XCTAssertEqual(
      HotkeySyntax.parse(hotkey: "ctrl+space")?.virtualKey,
      UInt32(kVK_Space))
  }

  func testCaseInsensitive() {
    let upper = HotkeySyntax.parse(hotkey: "CMD+CTRL+A")
    let lower = HotkeySyntax.parse(hotkey: "cmd+ctrl+a")
    XCTAssertEqual(upper?.modifiers, lower?.modifiers)
    XCTAssertEqual(upper?.virtualKey, lower?.virtualKey)
  }

  func testAliasesMapToSameFlag() {
    let a = HotkeySyntax.parse(hotkey: "command+option+control+a")
    let b = HotkeySyntax.parse(hotkey: "cmd+opt+ctrl+a")
    let c = HotkeySyntax.parse(hotkey: "cmd+alt+ctrl+a")
    XCTAssertEqual(a?.modifiers, b?.modifiers)
    XCTAssertEqual(b?.modifiers, c?.modifiers)
  }

  func testRawHexKeyCode() {
    let r = HotkeySyntax.parse(hotkey: "cmd+0x32")
    XCTAssertEqual(r?.virtualKey, 0x32)
  }

  func testInvalidKeyReturnsNil() {
    XCTAssertNil(HotkeySyntax.parse(hotkey: "cmd+nothing"))
    XCTAssertNil(HotkeySyntax.parse(hotkey: ""))
  }

  // MARK: - Action parsing

  func testParseFlashShowHints() {
    let action = parseShortcutAction(rawString: "flash://show_hints")
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .showHints(let right) = cmd { XCTAssertFalse(right) } else {
      XCTFail("expected .showHints, got \(cmd)")
    }
  }

  func testParseFlashOpenApp() {
    let action = parseShortcutAction(rawString: "flash://open_app?name=Alacritty")
    guard case .flashCommand(let cmd) = action else {
      return XCTFail("expected .flashCommand")
    }
    if case .openApp(let name) = cmd { XCTAssertEqual(name, "Alacritty") } else {
      XCTFail("expected .openApp")
    }
  }

  func testParseFlashOpenAppWithSpaces() {
    let action = parseShortcutAction(rawString: "flash://open_app?name=Postico%202")
    guard case .flashCommand(.openApp(let name)) = action else {
      return XCTFail("expected .openApp")
    }
    XCTAssertEqual(name, "Postico 2")
  }

  func testNonFlashStringIsRejected() {
    // Strings must be `flash://...` URLs. Anything else is rejected
    // so the user reaches for the array form (which makes the cost
    // visible) instead of accidentally using the slow path.
    XCTAssertNil(parseShortcutAction(rawString: "https://example.com"))
    XCTAssertNil(parseShortcutAction(rawString: "/Applications/Safari.app"))
    XCTAssertNil(parseShortcutAction(rawString: "Safari"))
    XCTAssertNil(parseShortcutAction(rawString: "open -a Foo"))
  }

  func testInvalidFlashURLRejected() {
    XCTAssertNil(parseShortcutAction(rawString: "flash://unknown_command"))
    XCTAssertNil(parseShortcutAction(rawString: "flash://open_app"))  // no name
  }

  func testParseShellArgv() {
    let action = parseShortcutAction(rawArray: ["sh", "-c", "echo hi"])
    guard case .shell(let argv) = action else {
      return XCTFail("expected .shell")
    }
    XCTAssertEqual(argv, ["sh", "-c", "echo hi"])
  }

  func testParseOpenWithURLAsArgv() {
    // The escape hatch for non-flash URLs: pass them to `open`.
    let action = parseShortcutAction(
      rawArray: ["open", "https://example.com"])
    guard case .shell(let argv) = action else {
      return XCTFail("expected .shell")
    }
    XCTAssertEqual(argv, ["open", "https://example.com"])
  }

  func testEmptyShellArrayReturnsNil() {
    XCTAssertNil(parseShortcutAction(rawArray: []))
  }
}

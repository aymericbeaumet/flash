import Carbon.HIToolbox
import XCTest

@testable import flash

final class SKHDParserTests: XCTestCase {

  func testQuotedAppName() {
    let rule = SKHDParser.parseLine(#"cmd + shift - r : open -a "My App""#)
    XCTAssertNotNil(rule)
    XCTAssertEqual(rule?.modifiers, UInt32(cmdKey | shiftKey))
    XCTAssertEqual(rule?.virtualKey, 0x0F)  // R
    if case .launchApp(let target) = rule?.action {
      XCTAssertEqual(target, "My App")
    } else {
      XCTFail("expected launchApp, got \(String(describing: rule?.action))")
    }
  }

  func testUnquotedAppName() {
    let rule = SKHDParser.parseLine("cmd - h : open -a Safari")
    XCTAssertNotNil(rule)
    XCTAssertEqual(rule?.modifiers, UInt32(cmdKey))
    XCTAssertEqual(rule?.virtualKey, 0x04)  // H
    if case .launchApp(let target) = rule?.action {
      XCTAssertEqual(target, "Safari")
    } else {
      XCTFail("expected launchApp")
    }
  }

  func testBundleIdentifierTarget() {
    let rule = SKHDParser.parseLine("alt - t : open com.apple.Terminal")
    XCTAssertNotNil(rule)
    XCTAssertEqual(rule?.modifiers, UInt32(optionKey))
    if case .launchApp(let target) = rule?.action {
      XCTAssertEqual(target, "com.apple.Terminal")
    } else {
      XCTFail("expected launchApp for bundle ID")
    }
  }

  func testAllModifiers() {
    let rule = SKHDParser.parseLine(
      "cmd + shift + ctrl + alt - 1 : open -a Finder")
    let expected = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    XCTAssertEqual(rule?.modifiers, expected)
    XCTAssertEqual(rule?.virtualKey, 0x12)  // 1
  }

  func testNamedKeysReturnAndArrows() {
    let r1 = SKHDParser.parseLine("cmd - return : open -a Notes")
    XCTAssertEqual(r1?.virtualKey, UInt32(kVK_Return))

    let r2 = SKHDParser.parseLine("ctrl + alt - left : open -a Notes")
    XCTAssertEqual(r2?.virtualKey, UInt32(kVK_LeftArrow))

    let r3 = SKHDParser.parseLine("cmd - escape : open -a Notes")
    XCTAssertEqual(r3?.virtualKey, UInt32(kVK_Escape))
  }

  func testCommentsAndBlankLinesIgnored() {
    let text = """
      # full-line comment
      cmd - h : open -a Safari

      # another comment
      cmd - j : open -a Notes
      """
    let rules = SKHDParser.parse(text)
    XCTAssertEqual(rules.count, 2)
  }

  func testMalformedLinesSkipped() {
    let text = """
      cmd - h : open -a Safari
      this is not a valid line
      cmd - : missing key
      : missing modifier and key
      cmd - z : weird unrecognised command
      cmd - j : open -a Notes
      """
    let rules = SKHDParser.parse(text)
    // 3 valid lines parse: h (launchApp), z (unknown), j (launchApp).
    XCTAssertEqual(rules.count, 3)
    XCTAssertEqual(rules[0].virtualKey, 0x04)  // h
    if case .unknown = rules[1].action { /* ok */ } else {
      XCTFail("expected unknown action for unrecognised command")
    }
    XCTAssertEqual(rules[2].virtualKey, 0x26)  // j
  }

  func testRawHexKeyCode() {
    // backtick on US ANSI is 0x32 — accept the raw form for keys we
    // don't name.
    let rule = SKHDParser.parseLine("cmd - 0x32 : open -a Safari")
    XCTAssertEqual(rule?.virtualKey, 0x32)
  }

  func testLeftRightModifierVariantsCollapse() {
    let lcmd = SKHDParser.parseLine("lcmd + lshift - r : open -a Foo")
    let rcmd = SKHDParser.parseLine("rcmd + rshift - r : open -a Foo")
    XCTAssertEqual(lcmd?.modifiers, UInt32(cmdKey | shiftKey))
    XCTAssertEqual(rcmd?.modifiers, UInt32(cmdKey | shiftKey))
  }
}

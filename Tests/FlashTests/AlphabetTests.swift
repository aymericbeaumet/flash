import XCTest

@testable import flash

final class AlphabetTests: XCTestCase {
  private let qwerty = "sadfjklewcmpghvtbynruo"
  private let colemak = "arstneiogfplmuywvbckxjqzdh"

  func testQwertyDefault() {
    let r = Alphabet.resolve(nil)
    XCTAssertEqual(String(r.chars), qwerty)
    XCTAssertNil(r.warning)
  }

  func testColemakToken() {
    let r = Alphabet.resolve("<colemak>")
    XCTAssertEqual(String(r.chars), colemak)
    XCTAssertNil(r.warning)
  }

  func testQwertyToken() {
    let r = Alphabet.resolve("<qwerty>")
    XCTAssertEqual(String(r.chars), qwerty)
  }

  func testDvorakToken() {
    let r = Alphabet.resolve("<dvorak>")
    XCTAssertEqual(r.chars.first, "a")
  }

  func testUnknownPresetFallsBack() {
    let r = Alphabet.resolve("<klingon>")
    XCTAssertEqual(String(r.chars), qwerty)
    XCTAssertNotNil(r.warning)
  }

  func testLiteralAlphabet() {
    let r = Alphabet.resolve("asdfghjkl")
    XCTAssertEqual(String(r.chars), "asdfghjkl")
    XCTAssertNil(r.warning)
  }

  func testLiteralWithDuplicatesAndUppercase() {
    let r = Alphabet.resolve("ASDFFGH")
    XCTAssertEqual(String(r.chars), "asdfgh")
  }

  func testInvalidLiteralFallsBack() {
    let r = Alphabet.resolve("12!")
    XCTAssertEqual(String(r.chars), qwerty)
    XCTAssertNotNil(r.warning)
  }

  func testPresetsCarryLeftHandSet() {
    XCTAssertTrue(Alphabet.resolve("<qwerty>").leftHand.contains("a"))
    XCTAssertFalse(Alphabet.resolve("<qwerty>").leftHand.contains("j"))
    XCTAssertTrue(Alphabet.resolve("<colemak>").leftHand.contains("r"))
    XCTAssertFalse(Alphabet.resolve("<colemak>").leftHand.contains("n"))
  }
}

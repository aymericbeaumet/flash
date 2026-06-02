import XCTest
@testable import flash

final class AlphabetTests: XCTestCase {
    func testColemakDefault() {
        let (chars, warn) = Alphabet.resolve(nil)
        XCTAssertEqual(String(chars), "arstneiogfplmuywvbckxjqzdh")
        XCTAssertNil(warn)
    }

    func testColemakToken() {
        let (chars, warn) = Alphabet.resolve("<colemak>")
        XCTAssertEqual(String(chars).prefix(4), "arst")
        XCTAssertNil(warn)
    }

    func testQwertyToken() {
        let (chars, _) = Alphabet.resolve("<qwerty>")
        XCTAssertTrue(chars.starts(with: ["s","a","d","f"]))
    }

    func testDvorakToken() {
        let (chars, _) = Alphabet.resolve("<dvorak>")
        XCTAssertEqual(chars.first, "a")
    }

    func testUnknownPresetFallsBack() {
        let (chars, warn) = Alphabet.resolve("<klingon>")
        XCTAssertEqual(String(chars), "arstneiogfplmuywvbckxjqzdh")
        XCTAssertNotNil(warn)
    }

    func testLiteralAlphabet() {
        let (chars, warn) = Alphabet.resolve("asdfghjkl")
        XCTAssertEqual(String(chars), "asdfghjkl")
        XCTAssertNil(warn)
    }

    func testLiteralWithDuplicatesAndUppercase() {
        let (chars, _) = Alphabet.resolve("ASDFFGH")
        XCTAssertEqual(String(chars), "asdfgh")
    }

    func testInvalidLiteralFallsBack() {
        let (chars, warn) = Alphabet.resolve("12!")
        XCTAssertEqual(String(chars), "arstneiogfplmuywvbckxjqzdh")
        XCTAssertNotNil(warn)
    }
}

import FlashCore
import XCTest

/// The text snapshot NORMAL's motions read: UTF-16 offsets as Accessibility
/// counts them, lines ending at any line break (`\r\n` as one), characters as
/// grapheme clusters.
final class TextBufferTests: XCTestCase {
  private typealias Line = TextBuffer.Line

  func testUnitsAreUTF16() {
    let text = "a😀é\r\n"
    let buffer = TextBuffer(text)
    XCTAssertEqual(buffer.string, text)
    XCTAssertEqual(buffer.units, Array(text.utf16))
    XCTAssertEqual(buffer.length, 6)
    XCTAssertEqual(TextBuffer("").length, 0)
  }

  func testLinesEndAtTheirBreak() {
    let buffer = TextBuffer("ab\ncd\n\nef")
    let first = Line(start: 0, end: 2, next: 3)
    XCTAssertEqual(buffer.line(containing: 0), first)
    XCTAssertEqual(buffer.line(containing: 1), first)
    // The break belongs to the line it ends.
    XCTAssertEqual(buffer.line(containing: 2), first)
    XCTAssertEqual(buffer.line(containing: 3), Line(start: 3, end: 5, next: 6))
    XCTAssertEqual(buffer.line(containing: 6), Line(start: 6, end: 6, next: 7))
    XCTAssertEqual(buffer.line(containing: 7), Line(start: 7, end: 9, next: 9))
    XCTAssertEqual(buffer.line(containing: 9), Line(start: 7, end: 9, next: 9))
    XCTAssertEqual(buffer.line(containing: -4), first)
    XCTAssertEqual(buffer.line(containing: 99), Line(start: 7, end: 9, next: 9))
  }

  func testCarriageReturnLineFeedIsOneBreak() {
    let buffer = TextBuffer("ab\r\ncd")
    let first = Line(start: 0, end: 2, next: 4)
    XCTAssertEqual(buffer.line(containing: 0), first)
    XCTAssertEqual(buffer.line(containing: 2), first)
    // Between the `\r` and the `\n`: still on the break.
    XCTAssertEqual(buffer.line(containing: 3), first)
    XCTAssertEqual(buffer.line(containing: 4), Line(start: 4, end: 6, next: 6))
    XCTAssertEqual(buffer.lineStarting(at: 0), first)
  }

  func testLoneCarriageReturnsAndReversedPairsAreBreaksOfTheirOwn() {
    let buffer = TextBuffer("a\rb\n\rc")
    XCTAssertEqual(buffer.line(containing: 0), Line(start: 0, end: 1, next: 2))
    XCTAssertEqual(buffer.line(containing: 2), Line(start: 2, end: 3, next: 4))
    XCTAssertEqual(buffer.line(containing: 4), Line(start: 4, end: 4, next: 5))
    XCTAssertEqual(buffer.line(containing: 5), Line(start: 5, end: 6, next: 6))
  }

  func testTrailingBreakLeavesAnEmptyLastLine() {
    let buffer = TextBuffer("ab\n")
    let last = Line(start: 3, end: 3, next: 3)
    XCTAssertEqual(buffer.line(containing: 3), last)
    XCTAssertEqual(buffer.line(after: buffer.line(containing: 0)), last)
    XCTAssertNil(buffer.line(after: last))
    XCTAssertEqual(buffer.line(before: last), Line(start: 0, end: 2, next: 3))
    let crlf = TextBuffer("ab\r\n")
    XCTAssertEqual(crlf.line(containing: 3), Line(start: 0, end: 2, next: 4))
    XCTAssertEqual(crlf.line(containing: 4), Line(start: 4, end: 4, next: 4))
    XCTAssertEqual(crlf.line(before: Line(start: 4, end: 4, next: 4)), crlf.line(containing: 0))
  }

  func testEmptyText() {
    let buffer = TextBuffer("")
    let only = Line(start: 0, end: 0, next: 0)
    XCTAssertEqual(buffer.line(containing: 0), only)
    XCTAssertEqual(buffer.line(containing: 5), only)
    XCTAssertEqual(buffer.line(containing: -3), only)
    XCTAssertNil(buffer.line(after: only))
    XCTAssertNil(buffer.line(before: only))
    XCTAssertEqual(buffer.firstNonBlank(of: only), 0)
    XCTAssertEqual(buffer.characters(of: only), [])
    XCTAssertEqual(buffer.characterStart(atOrBefore: 0), 0)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 3), 0)
  }

  func testEveryLineBreak() {
    for separator in ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
      let buffer = TextBuffer("ab\(separator)cd")
      let name = separator.debugDescription
      XCTAssertEqual(buffer.line(containing: 1), Line(start: 0, end: 2, next: 3), name)
      XCTAssertEqual(buffer.line(containing: 3), Line(start: 3, end: 5, next: 5), name)
      XCTAssertTrue(TextBuffer.isLineBreak(separator.utf16.first!), name)
    }
    for unit: UInt16 in [0x20, 0x09, 0x61, 0x2027, 0x202A, 0x200B, 0x3000] {
      XCTAssertFalse(TextBuffer.isLineBreak(unit), String(unit, radix: 16))
    }
  }

  func testWalkingLinesForwardAndBackward() {
    let buffer = TextBuffer("ab\r\ncd\n\nef")
    let expected = [
      Line(start: 0, end: 2, next: 4), Line(start: 4, end: 6, next: 7),
      Line(start: 7, end: 7, next: 8), Line(start: 8, end: 10, next: 10),
    ]
    var forward: [Line] = []
    var line: Line? = buffer.lineStarting(at: 0)
    while let current = line {
      forward.append(current)
      line = buffer.line(after: current)
    }
    XCTAssertEqual(forward, expected)
    var backward: [Line] = []
    line = buffer.line(containing: buffer.length)
    while let current = line {
      backward.append(current)
      line = buffer.line(before: current)
    }
    XCTAssertEqual(backward, expected.reversed())
  }

  func testLineFlags() {
    XCTAssertTrue(Line(start: 3, end: 3, next: 4).isEmpty)
    XCTAssertTrue(Line(start: 3, end: 3, next: 4).hasBreak)
    XCTAssertFalse(Line(start: 3, end: 5, next: 5).isEmpty)
    XCTAssertFalse(Line(start: 3, end: 5, next: 5).hasBreak)
    XCTAssertTrue(Line(start: 0, end: 2, next: 4).hasBreak)
  }

  func testFirstNonBlank() {
    let buffer = TextBuffer("  \tab\n \u{A0}\u{3000}x\n   \n\ny")
    XCTAssertEqual(buffer.firstNonBlank(of: buffer.line(containing: 0)), 3)
    XCTAssertEqual(buffer.firstNonBlank(of: buffer.line(containing: 6)), 9)
    // A line of blanks has none: its end.
    XCTAssertEqual(buffer.firstNonBlank(of: buffer.line(containing: 11)), 14)
    XCTAssertEqual(buffer.firstNonBlank(of: buffer.line(containing: 15)), 15)
    XCTAssertEqual(buffer.firstNonBlank(of: buffer.line(containing: 16)), 16)
  }

  func testBlanksAreHorizontalSpaces() {
    for unit: UInt16 in [0x20, 0x09, 0xA0, 0x1680, 0x2000, 0x2005, 0x200A, 0x202F, 0x205F, 0x3000] {
      XCTAssertTrue(TextBuffer.isBlank(unit), String(unit, radix: 16))
    }
    for unit: UInt16 in [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029, 0x61, 0x5F, 0x200B] {
      XCTAssertFalse(TextBuffer.isBlank(unit), String(unit, radix: 16))
    }
  }

  func testCharactersAreGraphemeClusters() {
    // e + combining acute, a skin-toned thumbs-up, a flag, a ZWJ family.
    let buffer = TextBuffer("e\u{301}👍🏽🇫🇷👨‍👩‍👧日a")
    let spans = buffer.characters(of: buffer.line(containing: 0))
    XCTAssertEqual(spans.map(\.offset), [0, 2, 6, 10, 18, 19])
    XCTAssertEqual(spans.map(\.length), [2, 4, 4, 8, 1, 1])
    XCTAssertEqual(spans.map(\.end), [2, 6, 10, 18, 19, 20])
    XCTAssertEqual(spans.map(\.character), ["e\u{301}", "👍🏽", "🇫🇷", "👨‍👩‍👧", "日", "a"])
  }

  func testCharactersOfALineExcludeItsBreak() {
    let buffer = TextBuffer("ab\r\ncd")
    XCTAssertEqual(buffer.characters(of: buffer.line(containing: 0)).map(\.character), ["a", "b"])
    let all = buffer.characters(in: 0..<6)
    XCTAssertEqual(all.map(\.character), ["a", "b", "\r\n", "c", "d"])
    XCTAssertEqual(all.map(\.offset), [0, 1, 2, 4, 5])
    XCTAssertEqual(buffer.characters(in: 4..<99).map(\.offset), [4, 5])
    XCTAssertEqual(buffer.characters(in: 3..<3), [])
    XCTAssertEqual(
      buffer.characters(in: 1..<2), [TextBuffer.Span(offset: 1, length: 1, character: "b")])
  }

  func testCharacterStartSnapsIntoClusters() {
    // x, e + U+0301, a ZWJ family (8 units), \r\n, y.
    let buffer = TextBuffer("xe\u{301}👨‍👩‍👧\r\ny")
    XCTAssertEqual(buffer.characterStart(atOrBefore: 0), 0)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 1), 1)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 2), 1)
    for offset in 3...10 {
      XCTAssertEqual(buffer.characterStart(atOrBefore: offset), 3, "\(offset)")
    }
    // On the break, and between its `\r` and `\n`: the line's end.
    XCTAssertEqual(buffer.characterStart(atOrBefore: 11), 11)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 12), 11)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 13), 13)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 14), 14)
    XCTAssertEqual(buffer.characterStart(atOrBefore: -4), 0)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 99), 14)
  }

  func testCharacterStartKeepsFlagsPaired() {
    let buffer = TextBuffer("🇫🇷🇩🇪")
    XCTAssertEqual(buffer.characterStart(atOrBefore: 1), 0)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 2), 0)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 4), 4)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 6), 4)
    XCTAssertEqual(buffer.characterStart(atOrBefore: 8), 8)
  }
}

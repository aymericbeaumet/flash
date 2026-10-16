import CoreGraphics
import FlashCore
import XCTest

final class WordMatcherTests: XCTestCase {
  func testWordsAreRunsOfLettersDigitsAndUnderscores() {
    let words = WordMatcher.words(in: "let snake_case = foo(bar2, \"x\");")
    let text = "let snake_case = foo(bar2, \"x\");" as NSString
    XCTAssertEqual(
      words.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) },
      ["let", "snake_case", "foo", "bar2", "x"])
  }

  func testWordsKeepUnicodeLettersAndSurrogatePairsTogether() {
    let text = "héllo wörld 𝒳y 日本語 — fin" as NSString
    let words = WordMatcher.words(in: text as String)
    XCTAssertEqual(
      words.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) },
      ["héllo", "wörld", "𝒳y", "日本語", "fin"])
    XCTAssertEqual(words[2].length, 3, "a surrogate pair counts two UTF-16 units")
  }

  func testEmptyAndPunctuationOnlyStringsHaveNoWords() {
    XCTAssertEqual(WordMatcher.words(in: ""), [])
    XCTAssertEqual(WordMatcher.words(in: " ... --- "), [])
  }

  func testWordRectsFollowTheMeasuredLines() {
    let text = "ab cd\nefgh"
    let lines = [
      BigramMatcher.BigramLineBox(
        location: 0, length: 6, bounds: CGRect(x: 0, y: 20, width: 50, height: 10)),
      BigramMatcher.BigramLineBox(
        location: 6, length: 4, bounds: CGRect(x: 0, y: 10, width: 40, height: 10)),
    ]
    let placed = WordMatcher.wordRects(in: text, lines: lines)
    XCTAssertEqual(
      placed.map(\.occurrence),
      [
        BigramOccurrence(location: 0, length: 2), BigramOccurrence(location: 3, length: 2),
        BigramOccurrence(location: 6, length: 4),
      ])
    XCTAssertEqual(placed[0].rect, CGRect(x: 0, y: 20, width: 20, height: 10))
    XCTAssertEqual(placed[1].rect, CGRect(x: 30, y: 20, width: 20, height: 10))
    XCTAssertEqual(placed[2].rect, CGRect(x: 0, y: 10, width: 40, height: 10))
  }

  func testClickPointSitsJustInsideTheLeadingEdge() {
    XCTAssertEqual(
      WordMatcher.clickPoint(in: CGRect(x: 30, y: 20, width: 20, height: 10)),
      CGPoint(x: 31, y: 25))
    XCTAssertEqual(
      WordMatcher.clickPoint(in: CGRect(x: 30, y: 20, width: 1, height: 10)),
      CGPoint(x: 30.5, y: 25))
  }
}

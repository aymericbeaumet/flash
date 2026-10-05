import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class BigramMatchTests: XCTestCase {
  func testALowercaseLetterMatchesEveryCase() {
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "Aaa a", query: "a").map(\.location),
      [0, 1, 2, 4])
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "Aaa a", query: "A").map(\.location),
      [0])
  }

  func testUppercaseQueryIsExact() {
    XCTAssertTrue(BigramMatcher.isCaseSensitive("T"))
    XCTAssertFalse(BigramMatcher.isCaseSensitive("t"))
    XCTAssertEqual(
      BigramMatcher.occurrences(in: "th Th tH TH", query: "T").map(\.location),
      [3, 9])
  }

  func testAQueryThatIsNotOneCharacterMatchesNothing() {
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "").isEmpty)
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "th").isEmpty)
    XCTAssertTrue(BigramMatcher.occurrences(in: "the", query: "the").isEmpty)
  }

  func testOneEmojiIsACompleteQuery() {
    let mark = "👍"
    XCTAssertEqual(mark.count, 1)
    let hits = BigramMatcher.occurrences(in: "👍👍👍", query: mark)
    XCTAssertEqual(hits.map(\.location), [0, 2, 4])
    XCTAssertEqual(hits.map(\.length), [2, 2, 2])
  }

  func testSliceMatchUsesTheSameCaseRule() {
    XCTAssertTrue(BigramMatcher.sliceMatches(text: " The", location: 1, length: 2, query: "th"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "the", location: 0, length: 2, query: "Th"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "th", location: 0, length: 3, query: "th"))
    XCTAssertFalse(BigramMatcher.sliceMatches(text: "th", location: -1, length: 2, query: "th"))
  }

  func testProportionalFallbackIsSingleLineOnly() {
    let line = CGRect(x: 0, y: 0, width: 100, height: 64)
    XCTAssertTrue(BigramMatcher.allowsProportionalFallback(text: "hello", frame: line))
    XCTAssertFalse(
      BigramMatcher.allowsProportionalFallback(
        text: "hello", frame: CGRect(x: 0, y: 0, width: 100, height: 65)))
    XCTAssertFalse(BigramMatcher.allowsProportionalFallback(text: "hel\nlo", frame: line))
    XCTAssertFalse(
      BigramMatcher.allowsProportionalFallback(
        text: "hello", frame: CGRect(x: 0, y: 0, width: 100, height: 0)))
  }

  func testProportionalRectStaysInsideTheFrame() {
    let frame = CGRect(x: 10, y: 20, width: 100, height: 16)
    let head = BigramMatcher.proportionalRect(frame: frame, location: 0, length: 2, totalUTF16: 10)
    XCTAssertEqual(head, CGRect(x: 10, y: 20, width: 20, height: 16))
    let tail = BigramMatcher.proportionalRect(frame: frame, location: 8, length: 2, totalUTF16: 10)
    XCTAssertEqual(tail?.maxX, frame.maxX)
    XCTAssertEqual(tail?.width, 20)
    let thin = BigramMatcher.proportionalRect(
      frame: frame, location: 0, length: 1, totalUTF16: 1000)
    XCTAssertEqual(thin?.width, 4)
    XCTAssertNil(
      BigramMatcher.proportionalRect(frame: frame, location: 0, length: 2, totalUTF16: 0))
  }

  func testDedupeKeepsTheFirstOfTwoCloseCenters() {
    let first = CGRect(x: 0, y: 0, width: 10, height: 10)
    let same = CGRect(x: 1, y: 1, width: 10, height: 10)
    let other = CGRect(x: 30, y: 0, width: 10, height: 10)
    let kept = BigramMatcher.dedupe([
      (rect: first, value: "a"),
      (rect: same, value: "b"),
      (rect: other, value: "c"),
    ])
    XCTAssertEqual(kept.map(\.value), ["a", "c"])
  }

  func testOwnStringPrefersTheVisibleAttributeAndKeepsRawText() {
    XCTAssertEqual(
      BigramText.ownString(
        role: "AXStaticText", title: "title", value: "  th  ", descendantEmitted: false),
      "  th  ")
    XCTAssertEqual(
      BigramText.ownString(
        role: "AXButton", title: "OK", value: "value", descendantEmitted: false),
      "OK")
    XCTAssertEqual(
      BigramText.ownString(role: "AXButton", title: "x", value: "Go", descendantEmitted: false),
      "x")
    XCTAssertEqual(
      BigramText.ownString(role: "AXStaticText", title: nil, value: "a", descendantEmitted: false),
      "a")
    XCTAssertNil(
      BigramText.ownString(role: "AXButton", title: "OK", value: nil, descendantEmitted: true))
    XCTAssertNil(
      BigramText.ownString(role: "AXImage", title: "icon", value: nil, descendantEmitted: false))
    XCTAssertNil(
      BigramText.ownString(role: "AXStaticText", title: " ", value: " ", descendantEmitted: false))
  }

  func testQueryEchoShowsTheSearchLetter() {
    XCTAssertEqual(BigramQueryEcho.text(for: ""), "\u{00B7}")
    XCTAssertEqual(BigramQueryEcho.text(for: "t"), "t")
    XCTAssertEqual(BigramQueryEcho.text(for: "th"), "t")
  }

  func testABigramCommitAimsAtTheMatchCenter() {
    let frame = CGRect(x: 10, y: 20, width: 30, height: 10)
    let hint = AssignedHint(
      target: JumpTarget(id: "bigram-1-0", frame: frame, providerID: "bigram"),
      label: "a")
    XCTAssertEqual(
      AppDelegate.hintCommitPoint(for: hint, fontSize: 14),
      CGPoint(x: frame.midX, y: frame.midY))
  }

  func testDefaultLeaderSClicksABigram() {
    let config = Config.default
    let key = NormalModeInterpreter.canonicalizeMappingKey("\\s")
    let mapping = config.mode.normal.first { $0.key == key }
    XCTAssertEqual(
      mapping?.action,
      .flashCommand(.mouseBigram(.click(.leftClick, modifiers: []))))
  }
}

import FlashCore
import XCTest

/// Vim's motions over text snapshots. Fixtures read like Vim: `|` marks the
/// cursor (the caret before the character the cursor sits on), `‹` the
/// Visual anchor, `«` and `»` a range (the visible text, or the expected
/// selection). Offsets are UTF-16, as the markers are stripped scalar by
/// scalar. Expectations follow Vim 9.1 with its defaults (`-u NONE`); where
/// Vim has no such state (NORMAL's cursor past a line's last character, the
/// empty line after a trailing break) they follow the engine's documented
/// model.
final class TextMotionTests: XCTestCase {
  // MARK: h l

  func testLeftMovesWithinTheLine() {
    assertMotion(.left, "foo b|ar", "foo |bar", column: 4)
    assertMotion(.left, count: 3, "foo b|ar", "fo|o bar")
    assertMotion(.left, count: 99, "foo b|ar", "|foo bar")
    assertMotion(.left, "|foo", nil)
    assertMotion(.left, "foo\n|bar", nil)
    assertMotion(.left, "foo|\nbar", "fo|o\nbar")
    assertMotion(.left, "foo\r|\nbar", "fo|o\r\nbar")
  }

  func testRightStopsOnTheLastCharacter() {
    assertMotion(.right, "f|oo bar", "fo|o bar", column: 2)
    assertMotion(.right, count: 2, "f|oo bar", "foo| bar")
    assertMotion(.right, count: 99, "f|oo\nbar", "fo|o\nbar")
    assertMotion(.right, "fo|o\nbar", nil)
    assertMotion(.right, "foo|\nbar", nil)
    assertMotion(.right, "foo\n|\nbar", nil)
  }

  func testRightInVisualModeReachesTheLineBreak() {
    assertMotion(.right, "fo|o\nbar", "foo|\nbar", inVisual: true, column: 3)
    assertMotion(.right, count: 9, "f|oo\nbar", "foo|\nbar", inVisual: true)
    assertMotion(.right, "foo|\nbar", nil, inVisual: true)
  }

  func testLeftAndRightStepOverWholeCharacters() {
    // e + combining acute, a thumbs-up with a skin tone, a ZWJ family, flags.
    assertMotion(.right, "|e\u{301}x", "e\u{301}|x")
    assertMotion(.left, "e\u{301}|x", "|e\u{301}x")
    assertMotion(.right, "a|👍🏽 b", "a👍🏽| b")
    assertMotion(.left, "a👍🏽| b", "a|👍🏽 b")
    assertMotion(.right, "|x👨‍👩‍👧y", "x|👨‍👩‍👧y")
    assertMotion(.right, "x|👨‍👩‍👧y", "x👨‍👩‍👧|y")
    assertMotion(.right, "|🇫🇷🇩🇪", "🇫🇷|🇩🇪")
    assertMotion(.right, "|日本語", "日|本語")
    XCTAssertEqual(target(.right, from: 1, in: "x👨‍👩‍👧y")?.offset, 9)
    XCTAssertEqual(target(.right, from: 0, in: "🇫🇷🇩🇪")?.offset, 4)
  }

  func testCursorInsideAClusterCountsAsItsStart() {
    // Inside "é" (e + U+0301), inside a surrogate pair, inside a ZWJ family.
    assertMotion(.right, "e|\u{301}x", "e\u{301}|x")
    assertMotion(.left, "e|\u{301}x", nil)
    XCTAssertEqual(target(.right, from: 2, in: "a😀b")?.offset, 3)
    XCTAssertEqual(target(.left, from: 2, in: "a😀b")?.offset, 0)
    XCTAssertEqual(target(.right, from: 4, in: "x👨‍👩‍👧y")?.offset, 9)
    XCTAssertEqual(target(.left, from: 4, in: "x👨‍👩‍👧y")?.offset, 0)
    XCTAssertEqual(target(.right, from: 2, in: "🇫🇷🇩🇪")?.offset, 4)
    XCTAssertEqual(target(.lineEnd, from: 6, in: "x👨‍👩‍👧")?.offset, 1)
  }

  func testOffsetsOutsideTheTextAreClamped() {
    XCTAssertEqual(target(.left, from: 99, in: "abc")?.offset, 2)
    XCTAssertEqual(target(.right, from: -5, in: "abc")?.offset, 1)
  }

  func testEmptyTextNeverMoves() {
    let motions: [TextMotion] = [
      .left, .right, .down, .up, .nextWord(big: false), .previousWord(big: true),
      .wordEnd(big: false), .previousWordEnd(big: false), .lineStart, .firstNonBlank, .lineEnd,
      .lastNonBlank, .column, .firstLine, .lastLine, .percent, .matchingBracket, .nextParagraph,
      .previousParagraph, .nextSentence, .previousSentence, .nextLineFirstNonBlank,
      .previousLineFirstNonBlank, .lineFirstNonBlank, .screenTop, .screenMiddle, .screenBottom,
      .find(TextCharacterSearch(character: "a", forward: true, till: false)),
    ]
    for motion in motions {
      XCTAssertNil(
        TextMotionEngine.target(
          of: motion, count: 50, from: 0, in: TextBuffer(""), visible: 0..<0),
        "\(motion)")
    }
  }

  // MARK: j k

  func testDownKeepsTheColumn() {
    assertMotion(.down, "ab|cd\nefgh", "abcd\nef|gh", column: 2)
    assertMotion(.down, "abc|d\nef\nghij", "abcd\ne|f\nghij", column: 3)
    assertMotion(.down, "abcd\ne|f\nghij", "abcd\nef\nghi|j", desiredColumn: 3, column: 3)
    assertMotion(.down, "ab|c\n\nxyz", "abc\n|\nxyz", column: 2)
    assertMotion(.down, "abc\n|\nxyz", "abc\n\nxy|z", desiredColumn: 2, column: 2)
    assertMotion(.down, count: 2, "ab|c\n\nxyz", "abc\n\nxy|z")
    assertMotion(.down, count: 99, "ab|c\n\nxyz", "abc\n\nxy|z")
    assertMotion(.down, "ab|\nwxyz", "ab\nwx|yz", column: 2)
  }

  func testDownFailsOnTheLastLine() {
    assertMotion(.down, "abc\nx|yz", nil)
    // A trailing break ends the last line; it opens no line after it.
    assertMotion(.down, "abc\nx|yz\n", nil)
    assertMotion(.down, "abc\nxyz\n|", nil)
    // Two trailing breaks do make an empty last line.
    assertMotion(.down, "abc\nx|yz\n\n", "abc\nxyz\n|\n")
  }

  func testUpKeepsTheColumn() {
    assertMotion(.up, "abcd\nef\ngh|ij", "abcd\ne|f\nghij", column: 2)
    assertMotion(.up, "abcd\nef\nghi|j", "abcd\ne|f\nghij", column: 3)
    assertMotion(.up, count: 2, "abcd\nef\ngh|ij", "ab|cd\nef\nghij")
    assertMotion(.up, count: 99, "abcd\nef\ngh|ij", "ab|cd\nef\nghij")
    assertMotion(.up, "ab|cd\nef", nil)
    // From the empty line after a trailing break, onto the last line.
    assertMotion(.up, "abc\nxyz\n|", "abc\n|xyz\n", column: 0)
  }

  func testVerticalMovesCarryTheDesiredColumnAfterDollar() {
    XCTAssertEqual(target(.lineEnd, from: 0, in: "ab\nlonger")?.desiredColumn, Int.max)
    assertMotion(
      .down, "a|b\nlonger\nxyz", "ab\nlonge|r\nxyz", desiredColumn: Int.max, column: Int.max)
    assertMotion(
      .up, "ab\nlonger\nx|yz", "ab\nlonge|r\nxyz", desiredColumn: Int.max, column: Int.max)
    assertMotion(
      .down, "a|b\nlonger", "ab\nlonger|", desiredColumn: Int.max, inVisual: true,
      column: Int.max)
  }

  func testVerticalMovesInVisualModeMayEndPastTheLastCharacter() {
    assertMotion(.down, "abcd|ef\nab", "abcdef\nab|", inVisual: true, column: 4)
    assertMotion(.up, "ab\nabcd|ef", "ab|\nabcdef", inVisual: true, column: 4)
    assertMotion(.down, "a|bcd\nxyz", "abcd\nx|yz", inVisual: true, column: 1)
  }

  func testVerticalMovesCountCharactersNotUnits() {
    assertMotion(.down, "e\u{301}|xy\nabc", "e\u{301}xy\na|bc", column: 1)
    assertMotion(.down, "😀😀|x\nabcd", "😀😀x\nab|cd", column: 2)
    assertMotion(.up, "abcd\n👨‍👩‍👧b|c", "ab|cd\n👨‍👩‍👧bc", column: 2)
    assertMotion(.down, "ab|c\n日本語", "abc\n日本|語", column: 2)
    assertMotion(.down, "ab|c\r\nxyz", "abc\r\nxy|z")
    assertMotion(.down, "foo\r|\nbar", "foo\r\nba|r", column: 3)
  }

  func testLineBreaksOfEveryKind() {
    for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
      let text = "ab\(separator)cd"
      let width = separator.utf16.count
      let name = separator.debugDescription
      XCTAssertEqual(target(.down, from: 1, in: text)?.offset, 3 + width, name)
      XCTAssertEqual(target(.up, from: 3 + width, in: text)?.offset, 1, name)
      XCTAssertEqual(target(.lineEnd, from: 0, in: text)?.offset, 1, name)
      XCTAssertEqual(target(.nextWord(big: false), from: 0, in: text)?.offset, 2 + width, name)
      XCTAssertEqual(target(.lastLine, from: 0, in: text + separator)?.offset, 2 + width, name)
    }
  }

  // MARK: w W

  func testNextWord() {
    assertMotion(.nextWord(big: false), "foo |bar baz", "foo bar |baz", column: 8)
    assertMotion(.nextWord(big: false), "f|oo   bar", "foo   |bar")
    assertMotion(.nextWord(big: false), count: 2, "|a b c", "a b |c")
    assertMotion(.nextWord(big: false), "fo|o\n  bar", "foo\n  |bar")
    assertMotion(.nextWord(big: false), "fo|o\r\nbar", "foo\r\n|bar")
    assertMotion(.nextWord(big: false), "foo|\nbar", "foo\n|bar")
  }

  func testNextWordSeparatesKeywordsFromPunctuation() {
    assertMotion(.nextWord(big: false), "|foo.bar baz", "foo|.bar baz")
    assertMotion(.nextWord(big: false), "foo|.bar baz", "foo.|bar baz")
    assertMotion(.nextWord(big: false), "|foo->bar", "foo|->bar")
    assertMotion(.nextWord(big: false), "foo|->bar", "foo->|bar")
    assertMotion(.nextWord(big: false), "|snake_case2 x", "snake_case2 |x")
    assertMotion(.nextWord(big: true), "|foo.bar baz", "foo.bar |baz")
    assertMotion(.nextWord(big: true), "|foo->bar(x) y", "foo->bar(x) |y")
  }

  func testNextWordStopsOnEmptyLinesOnly() {
    assertMotion(.nextWord(big: false), "fo|o\n\nbar", "foo\n|\nbar")
    assertMotion(.nextWord(big: false), "foo\n|\nbar", "foo\n\n|bar")
    assertMotion(.nextWord(big: false), "foo\n|\n\nbar", "foo\n\n|\nbar")
    assertMotion(.nextWord(big: false), "fo|o\n   \nbar", "foo\n   \n|bar")
    assertMotion(.nextWord(big: true), "fo|o\r\n\r\nbar", "foo\r\n|\r\nbar")
  }

  func testNextWordAtTheEndLandsOnTheLastCharacter() {
    assertMotion(.nextWord(big: false), "foo |bar", "foo ba|r")
    assertMotion(.nextWord(big: false), "foo |bar\n", "foo ba|r\n")
    assertMotion(.nextWord(big: false), "foo |bar  ", "foo bar | ")
    assertMotion(.nextWord(big: false), count: 9, "|a b c", "a b |c")
    assertMotion(.nextWord(big: false), "foo ba|r", nil)
    assertMotion(.nextWord(big: false), "foo bar|", nil)
    assertMotion(.nextWord(big: false), "foo bar\n|", nil)
    assertMotion(.nextWord(big: false), "foo\n|\nbar\n\n", "foo\n\n|bar\n\n")
    assertMotion(.nextWord(big: false), "foo\nb|ar\n\n", "foo\nbar\n|\n")
    assertMotion(.nextWord(big: false), "foo\nbar\n|\n", nil)
  }

  func testNextWordInVisualModeReachesTheEndOfTheText() {
    assertMotion(.nextWord(big: false), "foo |bar", "foo bar|", inVisual: true)
    assertMotion(.nextWord(big: false), "foo ba|r", "foo bar|", inVisual: true)
    assertMotion(.nextWord(big: false), "foo bar|", nil, inVisual: true)
  }

  func testNextWordClassesAcrossScripts() {
    assertMotion(.nextWord(big: false), "|café bar", "café |bar")
    assertMotion(.nextWord(big: false), "|cafe\u{301} bar", "cafe\u{301} |bar")
    assertMotion(.nextWord(big: false), "|nai\u{308}ve x", "nai\u{308}ve |x")
    assertMotion(.nextWord(big: false), "|foo😀bar", "foo|😀bar")
    assertMotion(.nextWord(big: false), "foo|😀bar", "foo😀|bar")
    assertMotion(.nextWord(big: false), "|😀😁 x", "😀😁 |x")
    assertMotion(.nextWord(big: false), "|👍🏽 ok", "👍🏽 |ok")
    assertMotion(.nextWord(big: false), "a |👨‍👩‍👧 b", "a 👨‍👩‍👧 |b")
    assertMotion(.nextWord(big: false), "|🇫🇷🇩🇪 x", "🇫🇷🇩🇪 |x")
    assertMotion(.nextWord(big: false), "|abc日本語のテキスト", "abc|日本語のテキスト")
    assertMotion(.nextWord(big: false), "abc|日本語のテキスト", "abc日本語|のテキスト")
    assertMotion(.nextWord(big: false), "abc日本語|のテキスト", "abc日本語の|テキスト")
    assertMotion(.nextWord(big: false), "|한국어 text", "한국어 |text")
    assertMotion(.nextWord(big: false), "|日本語。次", "日本語|。次")
    assertMotion(.nextWord(big: false), "|price€5", "price|€5")
    assertMotion(.nextWord(big: false), "|x²+y", "x|²+y")
    assertMotion(.nextWord(big: false), "|a\u{3000}b", "a\u{3000}|b")
    assertMotion(.nextWord(big: false), "|a\u{A0}b", "a\u{A0}|b")
    assertMotion(.nextWord(big: true), "|abc日本語の😀 x", "abc日本語の😀 |x")
    XCTAssertEqual(target(.nextWord(big: false), from: 0, in: "a 👨‍👩‍👧 b")?.offset, 2)
    XCTAssertEqual(target(.nextWord(big: false), from: 2, in: "a 👨‍👩‍👧 b")?.offset, 11)
  }

  // MARK: b B

  func testPreviousWord() {
    assertMotion(.previousWord(big: false), "foo bar |baz", "foo |bar baz", column: 4)
    assertMotion(.previousWord(big: false), "foo ba|r", "foo |bar")
    assertMotion(.previousWord(big: false), "foo.ba|r", "foo.|bar")
    assertMotion(.previousWord(big: false), "foo.|bar", "foo|.bar")
    assertMotion(.previousWord(big: true), "x foo.ba|r", "x |foo.bar")
    assertMotion(.previousWord(big: false), "  |foo", "|  foo")
    assertMotion(.previousWord(big: false), count: 9, "a b |c", "|a b c")
    assertMotion(.previousWord(big: false), "|foo", nil)
    assertMotion(.previousWord(big: false), "foo bar|", "foo |bar")
    assertMotion(.previousWord(big: false), "foo bar\n|", "foo |bar\n")
    assertMotion(.previousWord(big: false), "foo\r\n|bar", "|foo\r\nbar")
  }

  func testPreviousWordStopsOnEmptyLines() {
    assertMotion(.previousWord(big: false), "foo\n|bar", "|foo\nbar")
    assertMotion(.previousWord(big: false), "foo\n\n|bar", "foo\n|\nbar")
    assertMotion(.previousWord(big: false), "foo\n|\nbar", "|foo\n\nbar")
    assertMotion(.previousWord(big: false), count: 2, "foo\n\n|bar", "|foo\n\nbar")
    assertMotion(.previousWord(big: true), "foo\n  \n|bar", "|foo\n  \nbar")
  }

  func testPreviousWordAcrossScripts() {
    assertMotion(.previousWord(big: false), "abc日本語|のテキスト", "abc|日本語のテキスト")
    assertMotion(.previousWord(big: false), "x 😀😁|", "x |😀😁")
    assertMotion(.previousWord(big: false), "a 👨‍👩‍👧 |b", "a |👨‍👩‍👧 b")
    assertMotion(.previousWord(big: false), "cafe\u{301} |bar", "|cafe\u{301} bar")
    assertMotion(.previousWord(big: true), "x abc日本語の😀|", "x |abc日本語の😀")
  }

  // MARK: e E

  func testWordEnd() {
    assertMotion(.wordEnd(big: false), "|foo bar", "fo|o bar", column: 2)
    assertMotion(.wordEnd(big: false), "fo|o bar", "foo ba|r")
    assertMotion(.wordEnd(big: false), "|foo.bar", "fo|o.bar")
    assertMotion(.wordEnd(big: false), "fo|o.bar", "foo|.bar")
    assertMotion(.wordEnd(big: true), "|foo.bar baz", "foo.ba|r baz")
    assertMotion(.wordEnd(big: false), "|a b", "a |b")
    assertMotion(.wordEnd(big: false), count: 2, "|foo bar baz", "foo ba|r baz")
    assertMotion(.wordEnd(big: false), count: 9, "|a bc d", "a bc |d")
    assertMotion(.wordEnd(big: false), "fo|o\r\nbar", "foo\r\nba|r")
  }

  func testWordEndSkipsEmptyLines() {
    assertMotion(.wordEnd(big: false), "fo|o\n\n  bar", "foo\n\n  ba|r")
    assertMotion(.wordEnd(big: true), "fo|o\n\n\nbar", "foo\n\n\nba|r")
  }

  func testWordEndAtTheEnd() {
    assertMotion(.wordEnd(big: false), "foo ba|r", nil)
    assertMotion(.wordEnd(big: false), "foo ba|r\n", nil)
    // Vim reaches the empty last line before it gives up.
    assertMotion(.wordEnd(big: false), "a b|c\n\n", "a bc\n|\n")
    assertMotion(.wordEnd(big: false), "foo ba|r", "foo bar|", inVisual: true)
  }

  func testWordEndAcrossScripts() {
    assertMotion(.wordEnd(big: false), "|cafe\u{301} bar", "caf|e\u{301} bar")
    assertMotion(.wordEnd(big: false), "|abc日本語", "ab|c日本語")
    assertMotion(.wordEnd(big: false), "ab|c日本語", "abc日本|語")
    assertMotion(.wordEnd(big: false), "|👍🏽 b", "👍🏽 |b")
    assertMotion(.wordEnd(big: false), "|x😀😁 y", "x😀|😁 y")
    assertMotion(.wordEnd(big: false), "x😀|😁 y", "x😀😁 |y")
  }

  // MARK: ge gE

  func testPreviousWordEnd() {
    assertMotion(.previousWordEnd(big: false), "foo |bar", "fo|o bar", column: 2)
    assertMotion(.previousWordEnd(big: false), "foo b|ar", "fo|o bar")
    assertMotion(.previousWordEnd(big: false), "foo.|bar", "foo|.bar")
    assertMotion(.previousWordEnd(big: true), "x foo.b|ar", "|x foo.bar")
    assertMotion(.previousWordEnd(big: false), count: 2, "a b |c", "|a b c")
    assertMotion(.previousWordEnd(big: false), "|foo", nil)
    // Inside the first word: the text's start.
    assertMotion(.previousWordEnd(big: false), "f|oo", "|foo")
    assertMotion(.previousWordEnd(big: false), "  |foo", "|  foo")
    assertMotion(.previousWordEnd(big: false), "foo\n|bar", "fo|o\nbar")
    assertMotion(.previousWordEnd(big: false), "foo bar|", "foo ba|r")
    assertMotion(.previousWordEnd(big: false), "foo bar\n|", "foo ba|r\n")
    assertMotion(.previousWordEnd(big: false), "x 👨‍👩‍👧 |b", "x |👨‍👩‍👧 b")
  }

  /// Vim's bckend_word() stops on an empty line: for `ge`, as for `b`, an
  /// empty line is a word (its end), while `e` skips empty lines.
  func testPreviousWordEndStopsOnEmptyLines() {
    assertMotion(.previousWordEnd(big: false), "foo\n\n|bar", "foo\n|\nbar")
    assertMotion(.previousWordEnd(big: false), "foo\n|\nbar", "fo|o\n\nbar")
    assertMotion(.previousWordEnd(big: true), "foo\n\n\n|bar", "foo\n\n|\nbar")
    assertMotion(.previousWordEnd(big: false), "foo\n  \n|bar", "fo|o\n  \nbar")
  }

  // MARK: 0 ^ $ g_ |

  func testLineStart() {
    assertMotion(.lineStart, "  foo b|ar", "|  foo bar", column: 0)
    assertMotion(.lineStart, "x\n  fo|o", "x\n|  foo")
    assertMotion(.lineStart, "|foo", "|foo")
    assertMotion(.lineStart, "x\r\nfoo|", "x\r\n|foo")
  }

  func testFirstNonBlank() {
    assertMotion(.firstNonBlank, "  foo b|ar", "  |foo bar", column: 2)
    assertMotion(.firstNonBlank, "|  foo", "  |foo")
    assertMotion(.firstNonBlank, "\t|\tfoo", "\t\t|foo")
    assertMotion(.firstNonBlank, "a\n|\nb", "a\n|\nb")
    // A line of blanks: its last character, as Vim's beginline(BL_FIX).
    assertMotion(.firstNonBlank, "a\n |   \nb", "a\n   | \nb")
    // Every Unicode space separator is a blank here.
    assertMotion(.firstNonBlank, "\u{3000}\u{A0}fo|o", "\u{3000}\u{A0}|foo")
  }

  func testLineEnd() {
    assertMotion(.lineEnd, "f|oo bar\nbaz", "foo ba|r\nbaz", column: Int.max)
    assertMotion(.lineEnd, count: 2, "f|oo bar\nbaz", "foo bar\nba|z", column: Int.max)
    assertMotion(.lineEnd, count: 99, "f|oo\nbar\nbaz", "foo\nbar\nba|z")
    assertMotion(.lineEnd, count: 2, "foo\nb|az", nil)
    assertMotion(.lineEnd, "foo\n|\nbar", "foo\n|\nbar", column: Int.max)
    assertMotion(.lineEnd, "f|oo\r\nbar", "fo|o\r\nbar")
    assertMotion(.lineEnd, "fo|o", "fo|o")
    assertMotion(.lineEnd, "|a😀", "a|😀")
  }

  func testLineEndInVisualModeLandsPastTheLastCharacter() {
    assertMotion(.lineEnd, "f|oo bar\nbaz", "foo bar|\nbaz", inVisual: true, column: Int.max)
    assertMotion(.lineEnd, "f|oo\r\nbar", "foo|\r\nbar", inVisual: true)
    assertMotion(.lineEnd, "f|oo", "foo|", inVisual: true)
    assertMotion(.lineEnd, "foo\n|\nbar", "foo\n|\nbar", inVisual: true)
  }

  func testLastNonBlank() {
    assertMotion(.lastNonBlank, "  foo b|ar  \nx", "  foo ba|r  \nx", column: 8)
    assertMotion(.lastNonBlank, count: 2, "|foo  \n  bar\t", "foo  \n  ba|r\t")
    assertMotion(.lastNonBlank, count: 2, "foo\nb|ar", nil)
    assertMotion(.lastNonBlank, "a\n|\nb", "a\n|\nb")
    // A line of blanks: its start (Vim backs up to column 0, unlike `^`).
    assertMotion(.lastNonBlank, "x\n  |  \ny", "x\n|    \ny", column: 0)
    assertMotion(.lastNonBlank, "foo😀 |\u{3000}", "foo|😀 \u{3000}")
  }

  /// `|` counts characters; Vim counts screen cells, so a tab or a wide
  /// character is one column here.
  func testColumn() {
    assertMotion(.column, count: 3, "abcdef|", "ab|cdef", column: 2)
    assertMotion(.column, "abc|def", "|abcdef", column: 0)
    assertMotion(.column, count: 99, "a|bc\nxyz", "ab|c\nxyz", column: 98)
    assertMotion(.column, count: 99, "a|bc\nxyz", "abc|\nxyz", inVisual: true, column: 98)
    assertMotion(.column, count: 3, "\t|\tab", "\t\t|ab", column: 2)
    assertMotion(.column, count: 2, "|日本語", "日|本語", column: 1)
    assertMotion(.column, count: 5, "x\n|\ny", "x\n|\ny", column: 4)
    // The desired column survives a short line for the next j.
    assertMotion(.down, "ab|c\nlong line", "abc\nlong |line", desiredColumn: 5, column: 5)
  }

  // MARK: gg G %

  func testFirstLine() {
    assertMotion(.firstLine, "  foo\nbar\nb|az", "  |foo\nbar\nbaz", column: 2)
    assertMotion(.firstLine, count: 2, "  foo\nbar\nb|az", "  foo\n|bar\nbaz")
    assertMotion(.firstLine, count: 99, "foo\n  bar\nb|az", "foo\n  bar\n|baz")
    assertMotion(.firstLine, "|foo", "|foo")
  }

  func testLastLine() {
    assertMotion(.lastLine, "f|oo\nbar\n  baz", "foo\nbar\n  |baz", column: 2)
    assertMotion(.lastLine, count: 1, "foo\nb|ar", "|foo\nbar")
    assertMotion(.lastLine, count: 99, "f|oo\n bar", "foo\n |bar")
    // A trailing break ends the last line; two make an empty last line.
    assertMotion(.lastLine, "f|oo\nbar\n", "foo\n|bar\n")
    assertMotion(.lastLine, "f|oo\nbar\n\n", "foo\nbar\n|\n")
    assertMotion(.lastLine, "f|oo\r\nbar\r\n", "foo\r\n|bar\r\n")
    assertMotion(.lastLine, "foo\n|", "|foo\n")
    assertMotion(.lastLine, "|\n", "|\n")
    // A line of blanks: its last character.
    assertMotion(.lastLine, "|foo\n   ", "foo\n  | ")
  }

  func testPercentGoesToALineByProportion() {
    let text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10"
    assertMotion(.percent, count: 50, "|" + text, "1\n2\n3\n4\n|5\n6\n7\n8\n9\n10")
    assertMotion(.percent, count: 1, "1\n2\n|3\n4\n5\n6\n7\n8\n9\n10", "|" + text)
    assertMotion(.percent, count: 100, "|" + text, "1\n2\n3\n4\n5\n6\n7\n8\n9\n|10")
    // (count * lines + 99) / 100, rounding up: 15% of 10 lines is line 2.
    assertMotion(.percent, count: 15, "|" + text, "1\n|2\n3\n4\n5\n6\n7\n8\n9\n10")
    assertMotion(.percent, count: 101, "|" + text, nil)
    assertMotion(.percent, "|" + text, nil)
    assertMotion(.percent, count: 50, "|a\nb\n", "|a\nb\n")
    assertMotion(.percent, count: 51, "|a\nb\n", "a\n|b\n")
  }

  func testMatchingBracket() {
    assertMotion(.matchingBracket, "|(a (b) c)", "(a (b) c|)", column: 8)
    assertMotion(.matchingBracket, "(a (b) c|)", "|(a (b) c)")
    assertMotion(.matchingBracket, "(a |(b) c)", "(a (b|) c)")
    assertMotion(.matchingBracket, "|x = [1, (2)]", "x = [1, (2)|]")
    assertMotion(.matchingBracket, "{\n  |foo(bar)\n}", "{\n  foo(bar|)\n}")
    assertMotion(.matchingBracket, "{\n  foo\n|}", "|{\n  foo\n}")
    assertMotion(.matchingBracket, "|{\r\n}", "{\r\n|}")
    assertMotion(.matchingBracket, "(foo)|", "|(foo)")
    // Only the same pair nests.
    assertMotion(.matchingBracket, "|( [ ) ]", "( [ |) ]")
    assertMotion(.matchingBracket, "|[[]][]", "[[]|][]")
    assertMotion(.matchingBracket, "|(é😀)", "(é😀|)")
  }

  func testMatchingBracketFails() {
    assertMotion(.matchingBracket, "|foo", nil)
    assertMotion(.matchingBracket, "|(foo", nil)
    assertMotion(.matchingBracket, "foo)|", nil)
    assertMotion(.matchingBracket, "a) |b", nil)
    assertMotion(.matchingBracket, "x\n|\n(y)", nil)
  }

  // MARK: } {

  func testNextParagraph() {
    let text = "a\nb\n\nc\nd\n\ne"
    assertMotion(.nextParagraph, "|" + text, "a\nb\n|\nc\nd\n\ne", column: 0)
    assertMotion(.nextParagraph, "a\nb\n|\nc\nd\n\ne", "a\nb\n\nc\nd\n|\ne")
    assertMotion(.nextParagraph, count: 2, "|" + text, "a\nb\n\nc\nd\n|\ne")
    assertMotion(.nextParagraph, "a\nb\n\nc\nd\n|\ne", "a\nb\n\nc\nd\n\n|e")
    assertMotion(.nextParagraph, "|a\n\n\n\nb", "a\n|\n\n\nb")
    assertMotion(.nextParagraph, "a\n|\n\n\nb", "a\n\n\n\n|b")
    assertMotion(.nextParagraph, "a\r\n|b\r\n\r\nc", "a\r\nb\r\n|\r\nc")
  }

  func testNextParagraphAtTheEnd() {
    // The last paragraph: its last character, with or without a trailing
    // break; a line of blanks is no boundary.
    assertMotion(.nextParagraph, "a\n\nfo|o bar", "a\n\nfoo ba|r")
    assertMotion(.nextParagraph, "|a\nb\n", "a\n|b\n")
    assertMotion(.nextParagraph, "|a\n  \nb", "a\n  \n|b")
    assertMotion(.nextParagraph, "|a\nb\n\n", "a\nb\n|\n")
    // Already there: Vim does not beep.
    assertMotion(.nextParagraph, "a\n\nfoo ba|r", "a\n\nfoo ba|r")
    // A count left over at the end fails the whole motion.
    assertMotion(.nextParagraph, count: 2, "|a\nb\n\nc", "a\nb\n\n|c")
    assertMotion(.nextParagraph, count: 3, "|a\nb\n\nc", nil)
  }

  func testPreviousParagraph() {
    assertMotion(.previousParagraph, "a\nb\n\nc\n|d", "a\nb\n|\nc\nd", column: 0)
    assertMotion(.previousParagraph, "a\nb\n|\nc\nd", "|a\nb\n\nc\nd")
    assertMotion(.previousParagraph, "a\n|b", "|a\nb")
    assertMotion(.previousParagraph, "|a\nb", "|a\nb")
    assertMotion(.previousParagraph, count: 2, "a\n\nb\n\n|c", "a\n|\nb\n\nc")
    assertMotion(.previousParagraph, count: 3, "a\n\nb\n|c", nil)
    assertMotion(.previousParagraph, "a\n\nb\n|", "a\n|\nb\n")
  }

  // MARK: ) (

  func testNextSentence() {
    let text = "Hello world. This is it. Foo"
    assertMotion(.nextSentence, "|" + text, "Hello world. |This is it. Foo", column: 13)
    assertMotion(.nextSentence, count: 2, "|" + text, "Hello world. This is it. |Foo")
    assertMotion(.nextSentence, "Hello |world. This", "Hello world. |This")
    assertMotion(.nextSentence, "|A b.  C d.", "A b.  |C d.")
    assertMotion(.nextSentence, "|First.\nSecond.", "First.\n|Second.")
    assertMotion(.nextSentence, "|Use e.g.this one. Next", "Use e.g.this one. |Next")
    assertMotion(.nextSentence, "|He said (hi.) Then", "He said (hi.) |Then")
    assertMotion(.nextSentence, "|Go! \"Now?\" Yes.", "Go! |\"Now?\" Yes.")
    assertMotion(.nextSentence, "Go! |\"Now?\" Yes.", "Go! \"Now?\" |Yes.")
    assertMotion(.nextSentence, "|Wait!  Really?\tYes", "Wait!  |Really?\tYes")
    assertMotion(.nextSentence, "|Hi.\r\nYo.", "Hi.\r\n|Yo.")
  }

  func testNextSentenceAtTheEnd() {
    // The last sentence: the text's last character (no beep when there).
    assertMotion(
      .nextSentence, "Hello world. This is it. F|oo", "Hello world. This is it. Fo|o")
    assertMotion(.nextSentence, "One. T|wo.", "One. Two|.")
    assertMotion(.nextSentence, "One. Two|.", "One. Two|.")
    assertMotion(.nextSentence, "One. T|wo.", "One. Two.|", inVisual: true)
    assertMotion(.nextSentence, count: 2, "Hello world. This is it. F|oo", nil)
  }

  func testEmptyLinesAreSentences() {
    assertMotion(.nextSentence, "|One two\n\nThree", "One two\n|\nThree")
    assertMotion(.nextSentence, "One two\n|\nThree", "One two\n\n|Three")
    assertMotion(.nextSentence, "One two\n|\n\n  Three", "One two\n\n\n  |Three")
    assertMotion(.previousSentence, "One two\n\n|Three", "One two\n|\nThree")
    assertMotion(.previousSentence, "One two\n|\nThree", "|One two\n\nThree")
  }

  func testPreviousSentence() {
    let text = "Hello world. This is it. Foo"
    assertMotion(
      .previousSentence, "Hello world. This i|s it. Foo", "Hello world. |This is it. Foo")
    assertMotion(.previousSentence, "Hello world. |This is it. Foo", "|" + text)
    assertMotion(.previousSentence, count: 2, "Hello world. This is it. |Foo", "|" + text)
    assertMotion(
      .previousSentence, "Hello world. This is it. Foo|", "Hello world. This is it. |Foo")
    assertMotion(.previousSentence, "One.\n|Two", "|One.\nTwo")
    assertMotion(.previousSentence, "|Hello", "|Hello")
    assertMotion(.previousSentence, count: 2, "Hello world. |This", nil)
  }

  // MARK: + - _ <CR>

  func testNextAndPreviousLineFirstNonBlank() {
    assertMotion(.nextLineFirstNonBlank, "f|oo\n  bar", "foo\n  |bar", column: 2)
    assertMotion(.nextLineFirstNonBlank, count: 2, "f|oo\n  bar\n\tbaz", "foo\n  bar\n\t|baz")
    assertMotion(.nextLineFirstNonBlank, count: 9, "|foo\nbar", "foo\n|bar")
    assertMotion(.nextLineFirstNonBlank, "foo\n  b|ar", nil)
    assertMotion(.nextLineFirstNonBlank, "foo\n  b|ar\n", nil)
    assertMotion(.nextLineFirstNonBlank, "|foo\n\nbar", "foo\n|\nbar")
    assertMotion(.previousLineFirstNonBlank, "  foo\nb|ar", "  |foo\nbar", column: 2)
    assertMotion(.previousLineFirstNonBlank, count: 9, "  foo\nbar\nb|az", "  |foo\nbar\nbaz")
    assertMotion(.previousLineFirstNonBlank, "f|oo\nbar", nil)
    assertMotion(.previousLineFirstNonBlank, "  foo\n|", "  |foo\n")
  }

  func testLineFirstNonBlank() {
    assertMotion(.lineFirstNonBlank, "  fo|o\nbar", "  |foo\nbar", column: 2)
    assertMotion(.lineFirstNonBlank, count: 2, "  fo|o\n  bar", "  foo\n  |bar")
    assertMotion(.lineFirstNonBlank, count: 9, "fo|o\n  bar", "foo\n  |bar")
    assertMotion(.lineFirstNonBlank, count: 2, "  fo|o", nil)
  }

  // MARK: H M L

  func testScreenLines() {
    let text = "l0\n«l1\n  l2\nl3\nl4\nl5»\nl6"
    assertMotion(.screenTop, "l0\n«l1\n  l2\nl3\nl4\nl5»\nl|6", "l0\n|l1\n  l2\nl3\nl4\nl5\nl6")
    assertMotion(.screenTop, count: 2, "|" + text, "l0\nl1\n  |l2\nl3\nl4\nl5\nl6", column: 2)
    assertMotion(.screenTop, count: 99, "|" + text, "l0\nl1\n  l2\nl3\nl4\n|l5\nl6")
    assertMotion(.screenBottom, "|" + text, "l0\nl1\n  l2\nl3\nl4\n|l5\nl6", column: 0)
    assertMotion(.screenBottom, count: 2, "|" + text, "l0\nl1\n  l2\nl3\n|l4\nl5\nl6")
    assertMotion(.screenBottom, count: 99, "|" + text, "l0\n|l1\n  l2\nl3\nl4\nl5\nl6")
    assertMotion(.screenMiddle, "|" + text, "l0\nl1\n  l2\n|l3\nl4\nl5\nl6")
    assertMotion(.screenMiddle, count: 5, "|" + text, "l0\nl1\n  l2\n|l3\nl4\nl5\nl6")
  }

  func testScreenMiddleOfAnEvenNumberOfLines() {
    assertMotion(.screenMiddle, "|«a\nb\nc\nd»", "a\n|b\nc\nd")
    assertMotion(.screenMiddle, "|«a\nb»", "|a\nb")
  }

  func testScreenLinesStartInsideTheVisibleRange() {
    // The first line's start is scrolled off: the next line is the top.
    assertMotion(.screenTop, "|lo«ng\nl1\nl2»", "long\n|l1\nl2")
    // A range ending right at a line's start leaves that line out.
    assertMotion(.screenBottom, "|«l0\nl1\n»l2", "l0\n|l1\nl2")
    // No line starts inside: the line holding the range.
    assertMotion(.screenTop, "a\n  lo«ng li»ne|", "a\n  |long line")
    assertMotion(.screenBottom, "|«a\nb\n»", "a\n|b\n")
  }

  func testScreenLinesNeedAVisibleRange() {
    assertMotion(.screenTop, "|a\nb", nil)
    assertMotion(.screenMiddle, "|a\nb", nil)
    assertMotion(.screenBottom, "|a\nb", nil)
  }

  // MARK: f F t T ; ,

  func testFind() {
    assertMotion(.find(search("o")), "|foo bar boo", "f|oo bar boo", column: 1)
    assertMotion(.find(search("o")), count: 3, "|foo bar boo", "foo bar b|oo")
    assertMotion(.find(search("o")), count: 5, "|foo bar boo", nil)
    assertMotion(.find(search("x")), "|foo", nil)
    assertMotion(.find(search("b")), "|foo\nbar", nil)
    assertMotion(.find(search("o", forward: false)), "foo bar bo|o", "foo bar b|oo")
    assertMotion(.find(search("o", forward: false)), count: 3, "foo bar bo|o", "f|oo bar boo")
    assertMotion(.find(search("f", forward: false)), "foo|", "|foo")
    assertMotion(.find(search("f", forward: false)), "|foo", nil)
    assertMotion(.find(search("o")), "fo|o", nil)
    assertMotion(.find(search("o")), "foo|", nil)
  }

  func testTill() {
    assertMotion(.find(search("b", till: true)), "|foo bar", "foo| bar")
    assertMotion(.find(search("f", forward: false, till: true)), "foo ba|r", "f|oo bar")
    assertMotion(.find(search("a", till: true)), count: 2, "|xaya", "xa|ya")
    // Next to the match, `t` stays where it is (Vim does not beep).
    assertMotion(.find(search("o", till: true)), "|foo", "|foo")
    // `T` from past the line's end onto its last character would not move.
    assertMotion(.find(search("o", forward: false, till: true)), "foo|", nil)
  }

  func testRepeatedTillSkipsTheAdjacentMatch() {
    let till = search(".", till: true)
    assertMotion(.find(till), "|a.b.c", "|a.b.c")
    assertMotion(.find(till), "|a.b.c", "a.|b.c", isRepeat: true)
    // `,` repeats the reversed search, skipping the adjacent match too.
    assertMotion(.find(till.reversed), "a.b.|c", "a.|b.c", isRepeat: true)
    assertMotion(.find(till.reversed), "a.b.|c", "a.b.|c")
    // Only a single repeat skips: `2;` counts the adjacent match.
    assertMotion(.find(till), count: 2, "|a.b.c.d", "a.|b.c.d", isRepeat: true)
    // `f` never skips.
    assertMotion(.find(search("o")), "f|oo", "fo|o", isRepeat: true)
    assertMotion(.find(till), "a.b|.c", nil, isRepeat: true)
  }

  func testFindComparesWholeCharacters() {
    // Precomposed é finds e + U+0301, which is canonically the same.
    assertMotion(.find(search("é")), "|cafe\u{301}!", "caf|e\u{301}!")
    assertMotion(.find(search("e")), "|cafe\u{301}!", nil)
    assertMotion(.find(search("👍🏽")), "|a👍b👍🏽c", "a👍b|👍🏽c")
    assertMotion(.find(search("😀")), count: 2, "|a😀b😀c", "a😀b|😀c")
    assertMotion(.find(search("😀", till: true)), "|a😀b😀c", "|a😀b😀c")
    assertMotion(.find(search("b", forward: false, till: true)), "ab😀|c", "ab|😀c")
    assertMotion(.find(search("F")), "|foo Foo", "foo |Foo")
  }

  func testCharacterSearchReversed() {
    let search = TextCharacterSearch(character: "x", forward: true, till: true)
    XCTAssertEqual(
      search.reversed, TextCharacterSearch(character: "x", forward: false, till: true))
    XCTAssertEqual(search.reversed.reversed, search)
  }

  // MARK: Desired columns and counts

  func testDesiredColumnFollowsTheLandingCharacter() {
    XCTAssertEqual(target(.nextWord(big: false), from: 0, in: "日本 語")?.desiredColumn, 3)
    XCTAssertEqual(target(.lineStart, from: 3, in: "abcd")?.desiredColumn, 0)
    XCTAssertEqual(target(.firstNonBlank, from: 0, in: "\t\tx")?.desiredColumn, 2)
    XCTAssertEqual(target(.lineEnd, from: 0, in: "abcd")?.desiredColumn, Int.max)
    XCTAssertEqual(target(.right, from: 0, in: "e\u{301}e\u{301}e")?.desiredColumn, 1)
  }

  func testZeroCountIsNoCount() {
    XCTAssertEqual(
      TextMotionEngine.target(of: .lastLine, count: 0, from: 0, in: TextBuffer("a\nb"))?.offset,
      2)
    XCTAssertEqual(
      TextMotionEngine.target(of: .right, count: 0, from: 0, in: TextBuffer("abc"))?.offset, 1)
    XCTAssertNil(
      TextMotionEngine.target(of: .percent, count: 0, from: 0, in: TextBuffer("a\nb")))
    XCTAssertEqual(
      TextMotionEngine.target(of: .column, count: 0, from: 2, in: TextBuffer("abc"))?.offset, 0)
  }

  // MARK: Selections

  func testCharwiseSelectionIncludesTheCursorCharacter() {
    assertCharwise("f‹oo b|ar", "f«oo ba»r")
    assertCharwise("f|oo b‹ar", "f«oo ba»r")
    assertCharwise("fo‹|o", "fo«o»")
    assertCharwise("fo‹o\nba|r", "fo«o\nbar»")
    assertCharwise("‹a|😀b", "«a😀»b")
    assertCharwise("‹|e\u{301}x", "«e\u{301}»x")
    assertCharwise("x‹|👨‍👩‍👧y", "x«👨‍👩‍👧»y")
  }

  func testCharwiseSelectionIncludesALineBreakUnderTheCursor() {
    assertCharwise("a\n‹|\nb", "a\n«\n»b")
    assertCharwise("‹foo|\nbar", "«foo\n»bar")
    assertCharwise("‹foo|\r\nbar", "«foo\r\n»bar")
    assertCharwise("|foo‹\nbar", "«foo\n»bar")
    assertCharwise("‹foo|", "«foo»")
    assertCharwise("foo\n‹|", "foo\n«»")
    assertCharwise("‹|", "«»")
  }

  func testLinewiseSelectionTakesWholeLines() {
    assertLinewise("fo‹o\nba|r\nbaz", "«foo\nbar\n»baz")
    assertLinewise("fo|o\nba‹r\nbaz", "«foo\nbar\n»baz")
    assertLinewise("foo\nb‹a|r", "foo\n«bar»")
    assertLinewise("a\n‹|\nb", "a\n«\n»b")
    assertLinewise("‹a|\r\nb", "«a\r\n»b")
    assertLinewise("x\n‹a\u{2028}b|\u{2029}c", "x\n«a\u{2028}b\u{2029}»c")
    // The empty line after a trailing break selects the last line.
    assertLinewise("foo\n‹|", "«foo\n»")
    assertLinewise("‹|", "«»")
  }

  // MARK: Large texts

  /// A call walks the lines it needs, so motions over a million UTF-16
  /// units stay far below a frame across many lines or within one huge line.
  func testLargeTextsStayFast() {
    let line = "lorem ipsum (dolor) sit amet, consectetur. Adipiscing 日本語 elit 😀.\n"
    let manyLines = TextBuffer(String(repeating: line, count: 16_000))
    let oneLine = TextBuffer(String(repeating: "word, ", count: 170_000))
    XCTAssertGreaterThan(manyLines.length, 1_000_000)
    XCTAssertGreaterThan(oneLine.length, 1_000_000)
    let motions: [(TextMotion, Int?)] = [
      (.nextWord(big: false), 3), (.previousWord(big: true), 3), (.wordEnd(big: false), nil),
      (.previousWordEnd(big: false), nil), (.down, 5), (.up, 5), (.lineEnd, nil),
      (.lastNonBlank, nil), (.firstNonBlank, nil), (.column, 40), (.firstLine, 8_000),
      (.lastLine, nil), (.percent, 50), (.matchingBracket, nil), (.nextParagraph, nil),
      (.previousParagraph, nil), (.nextSentence, 2), (.previousSentence, 2),
      (.nextLineFirstNonBlank, nil), (.screenMiddle, nil),
      (.find(TextCharacterSearch(character: "😀", forward: true, till: false)), nil),
      (.right, 20), (.left, 20),
    ]
    let clock = ContinuousClock()
    for buffer in [manyLines, oneLine] {
      for cursor in [0, buffer.length / 2 + 3, buffer.length - 2] {
        for (motion, count) in motions {
          let elapsed = clock.measure {
            _ = TextMotionEngine.target(
              of: motion, count: count, from: cursor, in: buffer,
              visible: cursor..<min(cursor + 4_000, buffer.length))
          }
          XCTAssertLessThan(elapsed, .milliseconds(250), "\(motion) from \(cursor)")
        }
      }
    }
  }

  // MARK: Helpers

  private func search(
    _ character: Character, forward: Bool = true, till: Bool = false
  ) -> TextCharacterSearch {
    TextCharacterSearch(character: character, forward: forward, till: till)
  }

  private func target(_ motion: TextMotion, from cursor: Int, in text: String)
    -> TextMotionTarget?
  {
    TextMotionEngine.target(of: motion, count: nil, from: cursor, in: TextBuffer(text))
  }

  /// A fixture's text without its markers, and where each marker sat.
  private struct Marked {
    var text = ""
    var cursor: Int?
    var anchor: Int?
    var lower: Int?
    var upper: Int?

    init(_ marked: String) {
      var scalars = String.UnicodeScalarView()
      var offset = 0
      for scalar in marked.unicodeScalars {
        switch scalar {
        case "|": cursor = offset
        case "‹": anchor = offset
        case "«": lower = offset
        case "»": upper = offset
        default:
          scalars.append(scalar)
          offset += UTF16.width(scalar)
        }
      }
      text = String(scalars)
    }

    var range: Range<Int>? {
      guard let lower, let upper else { return nil }
      return lower..<upper
    }
  }

  /// `text` with `|` at UTF-16 `offset`, for failure messages.
  private func render(_ text: String, _ offset: Int) -> String {
    var units = Array(text.utf16)
    units.insert(contentsOf: "|".utf16, at: min(max(offset, 0), units.count))
    return String(decoding: units, as: UTF16.self).debugDescription
  }

  private func assertMotion(
    _ motion: TextMotion, count: Int? = nil, _ input: String, _ expected: String?,
    desiredColumn: Int? = nil, isRepeat: Bool = false, inVisual: Bool = false,
    column: Int? = nil, file: StaticString = #filePath, line: UInt = #line
  ) {
    let given = Marked(input)
    guard let cursor = given.cursor else {
      return XCTFail("no cursor in \(input.debugDescription)", file: file, line: line)
    }
    let result = TextMotionEngine.target(
      of: motion, count: count, from: cursor, in: TextBuffer(given.text), visible: given.range,
      desiredColumn: desiredColumn, isRepeat: isRepeat, inVisual: inVisual)
    guard let expected else {
      XCTAssertNil(
        result, "expected no move, got \(result.map { render(given.text, $0.offset) } ?? "")",
        file: file, line: line)
      return
    }
    let want = Marked(expected)
    XCTAssertEqual(want.text, given.text, "fixture texts differ", file: file, line: line)
    guard let result else {
      return XCTFail("expected \(expected.debugDescription), got nil", file: file, line: line)
    }
    XCTAssertEqual(
      result.offset, want.cursor,
      "expected \(expected.debugDescription), got \(render(given.text, result.offset))",
      file: file, line: line)
    if let column {
      XCTAssertEqual(result.desiredColumn, column, "desired column", file: file, line: line)
    }
  }

  private func assertCharwise(
    _ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let given = Marked(input)
    let want = Marked(expected)
    XCTAssertEqual(want.text, given.text, "fixture texts differ", file: file, line: line)
    let range = TextSelection.charwise(
      anchor: given.anchor ?? 0, cursor: given.cursor ?? 0, in: TextBuffer(given.text))
    XCTAssertEqual(range, want.range, expected.debugDescription, file: file, line: line)
  }

  private func assertLinewise(
    _ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let given = Marked(input)
    let want = Marked(expected)
    XCTAssertEqual(want.text, given.text, "fixture texts differ", file: file, line: line)
    let range = TextSelection.linewise(
      anchor: given.anchor ?? 0, cursor: given.cursor ?? 0, in: TextBuffer(given.text))
    XCTAssertEqual(range, want.range, expected.debugDescription, file: file, line: line)
  }
}

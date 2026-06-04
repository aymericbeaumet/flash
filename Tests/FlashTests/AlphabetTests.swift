import XCTest

@testable import flash

final class AlphabetTests: XCTestCase {
  private enum TestRow: String, CaseIterable {
    case homerow
    case toprow
    case bottomrow
  }

  private enum TestHand: String, CaseIterable {
    case lefthand
    case righthand
  }

  private struct TestLayout {
    let rows: [TestRow: [Character]]
    let leftHand: Set<Character>
    let scores: [Character: Int]
  }

  private let layouts: [String: TestLayout] = [
    "colemak": TestLayout(
      rows: [
        .toprow: Array("qwfpgjluy"),
        .homerow: Array("arstdhneio"),
        .bottomrow: Array("zxcvbkm"),
      ],
      leftHand: Set("qwfpgarstdzxcvb"),
      scores: scoreGroups([
        ("arstneio", 100),
        ("dh", 94),
        ("wfpluy", 74),
        ("qgj", 62),
        ("zxcvbm", 54),
        ("k", 42),
      ])
    ),
    "qwerty": TestLayout(
      rows: [
        .toprow: Array("qwertyuiop"),
        .homerow: Array("asdfghjkl"),
        .bottomrow: Array("zxcvbnm"),
      ],
      leftHand: Set("qwertasdfgzxcvb"),
      scores: scoreGroups([
        ("sdfjkl", 100),
        ("agh", 92),
        ("erui", 76),
        ("wtyo", 66),
        ("cvbnm", 56),
        ("qzp", 38),
        ("x", 32),
      ])
    ),
    "dvorak": TestLayout(
      rows: [
        .toprow: Array("pyfgcrl"),
        .homerow: Array("aoeuidhtns"),
        .bottomrow: Array("qjkxbmwvz"),
      ],
      leftHand: Set("pyaoeuiqjkx"),
      scores: scoreGroups([
        ("aoeutns", 100),
        ("idh", 94),
        ("pyfcrl", 74),
        ("g", 62),
        ("qjkxbmwv", 54),
        ("z", 38),
      ])
    ),
  ]

  func testDefaultKeysAreQwertyHomeAndTopRows() {
    let r = Alphabet.resolve(nil)
    XCTAssertEqual(String(r.chars), expected(layout: "qwerty", rows: [.homerow, .toprow]))
    XCTAssertEqual(r.layoutName, "qwerty")
    XCTAssertNil(r.warning)
  }

  func testEveryLayoutSelectorCompositionIsRankedByLayoutScores() {
    for layoutName in layouts.keys.sorted() {
      XCTContext.runActivity(named: layoutName) { _ in
        assertToken("<\(layoutName)>", layout: layoutName, rows: [.homerow, .toprow, .bottomrow])

        for row in TestRow.allCases {
          XCTContext.runActivity(named: row.rawValue) { _ in
            assertToken("<\(layoutName)_\(row.rawValue)>", layout: layoutName, rows: [row])
            for hand in TestHand.allCases {
              assertToken(
                "<\(layoutName)_\(row.rawValue)_\(hand.rawValue)>",
                layout: layoutName,
                rows: [row],
                hand: hand
              )
            }
          }
        }

        for hand in TestHand.allCases {
          assertToken(
            "<\(layoutName)_\(hand.rawValue)>",
            layout: layoutName,
            rows: [.homerow, .toprow, .bottomrow],
            hand: hand
          )
        }
      }
    }
  }

  func testValidLayoutCombinationsAreUnionedDedupedAndGloballyRanked() {
    for layoutName in layouts.keys.sorted() {
      XCTContext.runActivity(named: layoutName) { _ in
        assertToken(
          "<\(layoutName)_homerow+\(layoutName)_toprow>",
          layout: layoutName,
          selectors: [
            ([.homerow], nil),
            ([.toprow], nil),
          ]
        )
        assertToken(
          "<\(layoutName)_homerow_lefthand+\(layoutName)_toprow_righthand>",
          layout: layoutName,
          selectors: [
            ([.homerow], .lefthand),
            ([.toprow], .righthand),
          ]
        )
        assertToken(
          "<\(layoutName)_homerow+\(layoutName)_homerow_lefthand>",
          layout: layoutName,
          selectors: [
            ([.homerow], nil),
            ([.homerow], .lefthand),
          ]
        )
      }
    }
  }

  func testInvalidLayoutsFallBackToDefaultWithWarning() {
    for token in [
      "<klingon>",
      "<colemakish_homerow>",
      "<_homerow>",
      "<>",
    ] {
      XCTContext.runActivity(named: token) { _ in
        assertFallback(token)
      }
    }
  }

  func testInvalidLayoutCombinationsFallBackToDefaultWithWarning() {
    for token in [
      "<colemak_homerow+qwerty_toprow>",
      "<colemak_homerow+>",
      "<+colemak_homerow>",
      "<colemak_homerow++colemak_toprow>",
      "<colemak_numberrow>",
      "<colemak_homerow_middlehand>",
      "<colemak_homerow_toprow>",
      "<colemak_lefthand_righthand>",
      "<colemak_lefthand_homerow>",
      "<colemak_homerow_lefthand_extra>",
    ] {
      XCTContext.runActivity(named: token) { _ in
        assertFallback(token)
      }
    }
  }

  func testManualLiteralKeysAreDedupedLowercasedAndRankedByWrittenOrder() {
    let r = Alphabet.resolve("ZsaZQ")
    XCTAssertEqual(String(r.chars), "zsaq")
    XCTAssertNil(r.layoutName)
    XCTAssertTrue(r.leftHand.isEmpty)
    XCTAssertEqual(r.keyScores["z"], 4)
    XCTAssertEqual(r.keyScores["s"], 3)
    XCTAssertEqual(r.keyScores["a"], 2)
    XCTAssertEqual(r.keyScores["q"], 1)
    XCTAssertNil(r.warning)
  }

  func testManualLiteralKeysDropInvalidCharactersButKeepValidOrder() {
    let r = Alphabet.resolve("a1s!d;f'")
    XCTAssertEqual(String(r.chars), "asd;f'")
    XCTAssertNil(r.layoutName)
    XCTAssertNotNil(r.warning)
    XCTAssertGreaterThan(r.keyScores["a"] ?? 0, r.keyScores["s"] ?? 0)
    XCTAssertGreaterThan(r.keyScores[";"] ?? 0, r.keyScores["f"] ?? 0)
  }

  func testManualLiteralWithTooFewValidKeysFallsBack() {
    for literal in ["1!", "aa", "A1"] {
      XCTContext.runActivity(named: literal.isEmpty ? "<empty>" : literal) { _ in
        assertFallback(literal)
      }
    }
  }

  func testResolvedLayoutExposesCorrectHandSetForAlternation() {
    XCTAssertTrue(Alphabet.resolve("<qwerty_homerow>").leftHand.contains("a"))
    XCTAssertFalse(Alphabet.resolve("<qwerty_homerow>").leftHand.contains("j"))
    XCTAssertTrue(Alphabet.resolve("<colemak_homerow>").leftHand.contains("r"))
    XCTAssertFalse(Alphabet.resolve("<colemak_homerow>").leftHand.contains("n"))
    XCTAssertTrue(Alphabet.resolve("<dvorak_homerow>").leftHand.contains("a"))
    XCTAssertFalse(Alphabet.resolve("<dvorak_homerow>").leftHand.contains("t"))
  }

  private func assertToken(
    _ token: String,
    layout layoutName: String,
    rows: [TestRow],
    hand: TestHand? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertToken(
      token,
      layout: layoutName,
      selectors: [(rows, hand)],
      file: file,
      line: line
    )
  }

  private func assertToken(
    _ token: String,
    layout layoutName: String,
    selectors: [([TestRow], TestHand?)],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let r = Alphabet.resolve(token)
    XCTAssertEqual(r.layoutName, layoutName, file: file, line: line)
    XCTAssertNil(r.warning, file: file, line: line)
    XCTAssertEqual(
      String(r.chars),
      expected(layout: layoutName, selectors: selectors),
      file: file,
      line: line
    )
    assertRankedByScores(r, file: file, line: line)
  }

  private func assertFallback(_ raw: String, file: StaticString = #filePath, line: UInt = #line) {
    let r = Alphabet.resolve(raw)
    XCTAssertEqual(r.layoutName, "qwerty", file: file, line: line)
    XCTAssertEqual(
      String(r.chars),
      expected(layout: "qwerty", rows: [.homerow, .toprow]),
      file: file,
      line: line
    )
    XCTAssertNotNil(r.warning, file: file, line: line)
  }

  private func assertRankedByScores(
    _ resolved: Alphabet.Resolved,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let scores = resolved.keyScores
    let chars = resolved.chars
    for idx in 1..<chars.count {
      XCTAssertGreaterThanOrEqual(
        scores[chars[idx - 1]] ?? 0,
        scores[chars[idx]] ?? 0,
        "Expected \(String(chars)) to be score-ranked",
        file: file,
        line: line
      )
    }
  }

  private func expected(
    layout layoutName: String,
    rows: [TestRow],
    hand: TestHand? = nil
  ) -> String {
    expected(layout: layoutName, selectors: [(rows, hand)])
  }

  private func expected(layout layoutName: String, selectors: [([TestRow], TestHand?)]) -> String {
    let layout = layouts[layoutName]!
    var seen = Set<Character>()
    var chars: [(Character, Int)] = []
    var ordinal = 0
    for (rows, hand) in selectors {
      for row in rows {
        for ch in layout.rows[row]! where includes(ch, hand: hand, layout: layout) {
          if seen.insert(ch).inserted {
            chars.append((ch, ordinal))
            ordinal += 1
          }
        }
      }
    }
    return String(
      chars
        .sorted {
          let lhs = layout.scores[$0.0] ?? 0
          let rhs = layout.scores[$1.0] ?? 0
          if lhs != rhs { return lhs > rhs }
          return $0.1 < $1.1
        }
        .map(\.0)
    )
  }

  private func includes(_ ch: Character, hand: TestHand?, layout: TestLayout) -> Bool {
    switch hand {
    case .none:
      return true
    case .lefthand:
      return layout.leftHand.contains(ch)
    case .righthand:
      return !layout.leftHand.contains(ch)
    }
  }

  private static func scoreGroups(_ groups: [(String, Int)]) -> [Character: Int] {
    var scores: [Character: Int] = [:]
    for (chars, base) in groups {
      for (offset, ch) in chars.enumerated() {
        scores[ch] = base - offset
      }
    }
    return scores
  }
}

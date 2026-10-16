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
  }

  private let layouts: [String: TestLayout] = [
    "colemak": TestLayout(
      rows: [
        .toprow: Array("qwfpgjluy"),
        .homerow: Array("arstdhneio"),
        .bottomrow: Array("zxcvbkm"),
      ],
      leftHand: Set("qwfpgarstdzxcvb")
    ),
    "qwerty": TestLayout(
      rows: [
        .toprow: Array("qwertyuiop"),
        .homerow: Array("asdfghjkl"),
        .bottomrow: Array("zxcvbnm"),
      ],
      leftHand: Set("qwertasdfgzxcvb")
    ),
    "dvorak": TestLayout(
      rows: [
        .toprow: Array("pyfgcrl"),
        .homerow: Array("aoeuidhtns"),
        .bottomrow: Array("qjkxbmwvz"),
      ],
      leftHand: Set("pyaoeuiqjkx")
    ),
    "bepo": TestLayout(
      rows: [
        .toprow: Array("bépoèvdlj"),
        .homerow: Array("auiectsrn"),
        .bottomrow: Array("àyxkqghf"),
      ],
      leftHand: Set("bépoèauieàyxk")
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
    XCTAssertTrue(r.keyRows.isEmpty)
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

  /// The letter rows and hands hint selectors use are derived from each
  /// layout's physical 4×10 matrix. Key ease is the same row-and-column
  /// formula on every layout.
  func testPhysicalLayoutsDeriveTheLetterRowsAndHands() throws {
    let rowMap: [TestRow: Alphabet.Row] = [
      .toprow: .toprow, .homerow: .homerow, .bottomrow: .bottomrow,
    ]
    XCTAssertEqual(Set(Alphabet.layouts.keys), Set(layouts.keys))
    for (name, expected) in layouts {
      let layout = try XCTUnwrap(Alphabet.layouts[name])
      XCTAssertEqual(layout.physical.count, 4, name)
      XCTAssertTrue(layout.physical.allSatisfy { $0.count == 10 }, name)
      for (testRow, row) in rowMap {
        XCTAssertEqual(layout.rows[row], expected.rows[testRow], "\(name) \(row)")
      }
      XCTAssertEqual(layout.leftHand, expected.leftHand, name)
      var formula: [Character: Int] = [:]
      for (row, keys) in layout.physical.enumerated() {
        for (column, key) in keys.enumerated() {
          formula[key] = Self.formulaScore(row: row, column: column)
        }
      }
      XCTAssertEqual(layout.keyScores, formula, name)
      var rows: [Character: Int] = [:]
      for (row, keys) in layout.physical.enumerated() {
        for key in keys { rows[key] = row }
      }
      XCTAssertEqual(layout.keyRows, rows, name)
      XCTAssertEqual(Alphabet.resolve("<\(name)>").keyRows, rows, name)
    }
    XCTAssertTrue(Alphabet.resolve("asdf").keyRows.isEmpty)
  }

  func testPhysicalKeyScoreRanksHomeThenBottomThenTop() {
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 2, column: 3), 331)
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 2, column: 6), 330)
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 2, column: 4), 316)
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 3, column: 3), 231)
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 1, column: 3), 131)
    XCTAssertEqual(Alphabet.physicalKeyScore(row: 0, column: 3), 31)
    let worstHome = Alphabet.physicalKeyScore(row: 2, column: 9)
    let bestBottom = Alphabet.physicalKeyScore(row: 3, column: 3)
    let worstBottom = Alphabet.physicalKeyScore(row: 3, column: 9)
    let bestTop = Alphabet.physicalKeyScore(row: 1, column: 3)
    XCTAssertGreaterThan(worstHome, bestBottom)
    XCTAssertGreaterThan(worstBottom, bestTop)
    for (name, layout) in layouts {
      let home = Set(layout.rows[.homerow]!)
      let bottom = Set(layout.rows[.bottomrow]!)
      let top = Set(layout.rows[.toprow]!)
      let scores = Alphabet.layouts[name]!.keyScores
      let homeMin = home.map { scores[$0]! }.min()!
      let bottomMax = bottom.map { scores[$0]! }.max()!
      let bottomMin = bottom.map { scores[$0]! }.min()!
      let topMax = top.map { scores[$0]! }.max()!
      XCTAssertGreaterThan(homeMin, bottomMax, name)
      XCTAssertGreaterThan(bottomMin, topMax, name)
    }
  }

  func testGridKeysAreTheLeftHandBlockOfEachLayout() {
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: "qwerty").map { String($0) },
      ["12345", "qwert", "asdfg", "zxcvb"])
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: "colemak").map { String($0) },
      ["12345", "qwfpg", "arstd", "zxcvb"])
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: "dvorak").map { String($0) },
      ["12345", "',.py", "aoeui", ";qjkx"])
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: "bepo").map { String($0) },
      ["$\"«»(", "bépoè", "auie,", "àyx.k"])
  }

  func testLiteralKeysHaveNoLayoutSoTheGridIsQwerty() {
    let literal = Alphabet.resolve("asdfjkl")
    XCTAssertNil(literal.layoutName)
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: literal.layoutName),
      Alphabet.gridKeys(layoutName: "qwerty"))
    XCTAssertEqual(
      Alphabet.gridKeys(layoutName: "klingon"), Alphabet.gridKeys(layoutName: "qwerty"))
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
    let scores = formulaScores(layoutName)
    return String(
      chars
        .sorted {
          let lhs = scores[$0.0] ?? 0
          let rhs = scores[$1.0] ?? 0
          if lhs != rhs { return lhs > rhs }
          return $0.1 < $1.1
        }
        .map(\.0)
    )
  }

  /// Independent copy of `Alphabet.physicalKeyScore`, so a drift in the
  /// layout tables fails here instead of following the production function.
  private static func formulaScore(row: Int, column: Int) -> Int {
    let rowBase = [0, 100, 300, 200][row]
    let finger = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0][column]
    let reach = column == 4 || column == 5 ? 1 : 0
    return rowBase + finger * 10 - reach * 15 + (column < 5 ? 1 : 0)
  }

  private func formulaScores(_ layoutName: String) -> [Character: Int] {
    let physical = Alphabet.layouts[layoutName]!.physical
    var scores: [Character: Int] = [:]
    for (row, keys) in physical.enumerated() {
      for (column, key) in keys.enumerated() {
        scores[key] = Self.formulaScore(row: row, column: column)
      }
    }
    return scores
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

}

import CoreGraphics
import FlashCore
import XCTest

@testable import flash

final class HintAssignerTests: XCTestCase {
  private let alphabet: [Character] = Array("arstneio")

  func testPrefixFreeSmall() {
    check(count: 1)
    check(count: 5)
    check(count: 8)
    check(count: 26)
    check(count: 200)
    check(count: 1000)
  }

  func testUniqueLabels() {
    let labels = HintAssigner.generateLabels(count: 200, alphabet: alphabet)
    XCTAssertEqual(labels.count, 200)
    XCTAssertEqual(Set(labels).count, 200)
  }

  func testMinLengthRespected() {
    let labels = HintAssigner.generateLabels(count: 3, alphabet: alphabet, minLength: 2)
    XCTAssertTrue(labels.allSatisfy { $0.count == 2 })
  }

  func testSinglesFirstWhenItFits() {
    // count = 8 → exactly fits in 1-char labels.
    let eight = HintAssigner.generateLabels(count: 8, alphabet: alphabet)
    XCTAssertTrue(
      eight.allSatisfy { $0.count == 1 }, "8 items in 8-char alphabet → all 1-char labels")
  }

  func testSinglesPackedFirstWhenCountExceedsAlphabet() {
    // 9 items in 8-char alphabet: should use as many single-char labels
    // as possible (with at least one alphabet char reserved as multi
    // prefix), then 2-char labels for the rest. The singles come FIRST
    // in the output so the earliest targets get the cheapest labels.
    let nine = HintAssigner.generateLabels(count: 9, alphabet: alphabet)
    XCTAssertEqual(nine.count, 9)
    XCTAssertEqual(Set(nine).count, 9, "labels are unique")
    let singles = nine.filter { $0.count == 1 }
    let doubles = nine.filter { $0.count == 2 }
    XCTAssertGreaterThan(singles.count, 0, "should use at least one single-char label")
    XCTAssertEqual(singles.count + doubles.count, 9, "every label is 1- or 2-char")
    // Singles must precede doubles in the output.
    let firstDouble = nine.firstIndex { $0.count == 2 } ?? nine.count
    let lastSingle = nine.lastIndex { $0.count == 1 } ?? -1
    XCTAssertLessThan(lastSingle, firstDouble, "singles come before doubles in output")
  }

  func testPrefixFreeOnMixedLengths() {
    // 200 items in 8-char alphabet — mixed-length output. Verify no
    // single label is a prefix of any double, and no double is a
    // prefix of another (which uniformity would otherwise guarantee).
    let labels = HintAssigner.generateLabels(count: 200, alphabet: alphabet)
    XCTAssertEqual(labels.count, 200)
    for (i, a) in labels.enumerated() {
      for (j, b) in labels.enumerated() where i != j {
        XCTAssertFalse(
          a.hasPrefix(b), "label \(a) at \(i) starts with label \(b) at \(j)")
      }
    }
  }

  func testMinLengthForcesUniform() {
    // When minLength >= 2, the user is explicitly pinning longer
    // labels — singles are off the table and every label has the
    // same length.
    let labels = HintAssigner.generateLabels(count: 9, alphabet: alphabet, minLength: 2)
    XCTAssertTrue(labels.allSatisfy { $0.count == 2 })
  }

  func testLargeCountFallsBackToUniform() {
    // 65 items in 8-char alphabet: 8 singles + (8-8)*8 = 8 doesn't
    // fit, so no singles work. Output is all 3-char labels.
    let labels = HintAssigner.generateLabels(count: 65, alphabet: alphabet)
    XCTAssertTrue(
      labels.allSatisfy { $0.count == 3 },
      "65 items in 8-char alphabet exceeds the 1+2-char capacity, "
        + "falls back to uniform 3-char labels")
  }

  func testHandAlternationPrefersAlternatingPairs() {
    // Alphabet split exactly half-and-half between hands.
    let alpha = Array("asdfjkl;")
    let leftHand: Set<Character> = ["a", "s", "d", "f"]
    // Force 2-char labels via minLength so the scoring path activates.
    // There are 4×4 = 16 alternating pairs out of 64 total candidates;
    // every one of the top-16 labels should be a hand-alternating pair.
    let labels = HintAssigner.generateLabels(
      count: 16, alphabet: alpha, leftHand: leftHand, minLength: 2)
    XCTAssertEqual(labels.count, 16)
    for label in labels {
      let chars = Array(label)
      XCTAssertEqual(chars.count, 2)
      let firstLeft = leftHand.contains(chars[0])
      let secondLeft = leftHand.contains(chars[1])
      XCTAssertNotEqual(firstLeft, secondLeft, "expected alternating-hand label, got \(label)")
    }
  }

  func testHandAlternationDominatesLayoutScoresForPairs() {
    let alpha = Array("asjk")
    let leftHand: Set<Character> = ["a", "s"]
    let keyScores: [Character: Int] = [
      "a": 100,
      "s": 99,
      "j": 20,
      "k": 10,
    ]

    XCTAssertGreaterThan(
      HintAssigner.scoreLabel("aj", leftHand: leftHand, keyScores: keyScores),
      HintAssigner.scoreLabel("as", leftHand: leftHand, keyScores: keyScores),
      "an alternating pair should outrank a higher-scored same-hand pair")

    let labels = HintAssigner.generateLabels(
      count: 4,
      alphabet: alpha,
      leftHand: leftHand,
      keyScores: keyScores,
      minLength: 2)
    XCTAssertTrue(
      labels.allSatisfy {
        let chars = Array($0)
        return leftHand.contains(chars[0]) != leftHand.contains(chars[1])
      },
      "expected the first full hand-balanced bucket before same-hand pairs, got \(labels)")
  }

  func testSingleLabelsUsePreparedAlphabetOrder() {
    let labels = HintAssigner.generateLabels(
      count: 4,
      alphabet: Array("qasz"),
      keyScores: [
        "s": 100,
        "a": 90,
        "q": 50,
        "z": 10,
      ])
    XCTAssertEqual(
      labels,
      ["q", "a", "s", "z"],
      "single-label assignment should consume the config-prepared alphabet without re-sorting")
  }

  func testPairsPreferHighScoredHomeRowKeys() {
    let resolved = Alphabet.resolve("<qwerty_homerow+qwerty_toprow>")
    let labels = HintAssigner.generateLabels(
      count: 6,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: 2)
    let homeRow: Set<Character> = Set("sdfjkl")
    XCTAssertTrue(
      labels.allSatisfy { Set($0).isSubset(of: homeRow) },
      "expected early pairs to stay on the strongest home-row keys, got \(labels)")
    XCTAssertEqual(labels.first, "sj")
  }

  func testPairsUseInferredLayoutScoresForLayoutTokens() {
    let qwerty = Alphabet.resolve("<qwerty_homerow>")
    let colemak = Alphabet.resolve("<colemak_homerow>")
    let qwertyLabels = HintAssigner.generateLabels(
      count: 4,
      alphabet: qwerty.chars,
      leftHand: qwerty.leftHand,
      keyScores: qwerty.keyScores,
      minLength: 2)
    let colemakLabels = HintAssigner.generateLabels(
      count: 4,
      alphabet: colemak.chars,
      leftHand: colemak.leftHand,
      keyScores: colemak.keyScores,
      minLength: 2)
    XCTAssertNotEqual(qwertyLabels, colemakLabels)
    XCTAssertTrue(colemakLabels[0].contains("a"))
  }

  func testLiteralPairsUseLiteralOrderScores() {
    let resolved = Alphabet.resolve("zsaq")
    let labels = HintAssigner.generateLabels(
      count: 3,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: 2)
    XCTAssertTrue(labels[0].contains("z"))
    XCTAssertFalse(labels[0].contains("q"))
  }

  func testEmpty() {
    XCTAssertTrue(HintAssigner.generateLabels(count: 0, alphabet: alphabet).isEmpty)
  }

  /// `--multi` discovers again after every click: a target that is still
  /// there keeps its label, so the next one the user reads stays valid.
  func testReassignmentKeepsLabelsOfTargetsThatPersist() {
    let before = HintAssigner.assign(
      targets: ["Save", "Open", "Close", "Help"].map(button), alphabet: alphabet)
    XCTAssertEqual(before.map(\.label), ["a", "r", "s", "t"])

    // The click closed "Open" and revealed "Undo" ahead of the others.
    let after = HintAssigner.assign(
      targets: ["Undo", "Save", "Close", "Help"].map(button), alphabet: alphabet,
      preserving: before)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: after.map { ($0.target.accessibilityLabel!, $0.label) }),
      ["Save": "a", "Close": "s", "Help": "t", "Undo": "r"])
  }

  func testReassignmentStaysPrefixFreeWhenTheLabelSetChanges() {
    let before = HintAssigner.assign(targets: (0..<9).map { button("b\($0)") }, alphabet: alphabet)
    XCTAssertEqual(before.prefix(7).map(\.label), ["a", "r", "s", "t", "n", "e", "i"])
    // Thirty targets leave room for four single letters only: `n`, `e` and
    // `i` now start two-letter labels, so their targets get fresh ones.
    let after = HintAssigner.assign(
      targets: (0..<30).map { button("b\($0)") }, alphabet: alphabet, preserving: before)
    let labels = after.map(\.label)
    XCTAssertEqual(Set(labels), Set(HintAssigner.generateLabels(count: 30, alphabet: alphabet)))
    for (i, a) in labels.enumerated() {
      for (j, b) in labels.enumerated() where i != j {
        XCTAssertFalse(a.hasPrefix(b), "label \(a) starts with label \(b)")
      }
    }
    XCTAssertEqual(Array(labels.prefix(4)), ["a", "r", "s", "t"])
    XCTAssertTrue(labels[4...6].allSatisfy { $0.count == 2 }, "\(labels[4...6])")
  }

  func testReassignmentMatchesTargetsByWhatTheyAreNotTheirWalkID() {
    let before = HintAssigner.assign(
      targets: [button("Save", id: "ax-1-r-1"), button("Save", x: 200, id: "ax-1-r-2")],
      alphabet: alphabet)
    // New walk ids, same controls; the second button moved.
    let after = HintAssigner.assign(
      targets: [button("Save", x: 300, id: "ax-1-r-9"), button("Save", id: "ax-1-r-7")],
      alphabet: alphabet, preserving: before)
    XCTAssertEqual(after.map(\.label), ["r", "a"])
  }

  private func button(_ label: String) -> JumpTarget {
    button(label, x: 0, id: label)
  }

  private func button(_ label: String, x: CGFloat = 0, id: String) -> JumpTarget {
    JumpTarget(
      id: id, frame: CGRect(x: x, y: 10, width: 80, height: 24), role: "AXButton",
      accessibilityLabel: label, providerID: "accessibility")
  }

  private func check(count: Int) {
    let labels = HintAssigner.generateLabels(count: count, alphabet: alphabet)
    XCTAssertEqual(labels.count, count, "expected \(count) labels")
    XCTAssertEqual(Set(labels).count, count, "labels should be unique")
    // Prefix-free is the load-bearing invariant: if "a" is a label, no
    // other label can start with "a" (typing "a" would otherwise be
    // ambiguous). Mixed-length labels (the singles-first packing) are
    // allowed as long as the prefix-free property holds.
    for (i, a) in labels.enumerated() {
      for (j, b) in labels.enumerated() where i != j {
        XCTAssertFalse(a.hasPrefix(b), "label \(a) at \(i) starts with label \(b) at \(j)")
      }
    }
  }
}

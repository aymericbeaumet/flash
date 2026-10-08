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
      keyRows: resolved.keyRows,
      minLength: 2)
    let homeRow: Set<Character> = Set("asdfghjkl")
    XCTAssertTrue(
      labels.allSatisfy { Set($0).isSubset(of: homeRow) },
      "expected early pairs to stay on the home row, got \(labels)")
    XCTAssertEqual(labels.first, "fj")
    for label in labels {
      let chars = Array(label)
      XCTAssertNotEqual(
        resolved.leftHand.contains(chars[0]),
        resolved.leftHand.contains(chars[1]),
        "expected an alternating pair, got \(label)")
    }
  }

  func testPairsUseInferredLayoutScoresForLayoutTokens() {
    let qwerty = Alphabet.resolve("<qwerty_homerow>")
    let colemak = Alphabet.resolve("<colemak_homerow>")
    let qwertyLabels = HintAssigner.generateLabels(
      count: 4,
      alphabet: qwerty.chars,
      leftHand: qwerty.leftHand,
      keyScores: qwerty.keyScores,
      keyRows: qwerty.keyRows,
      minLength: 2)
    let colemakLabels = HintAssigner.generateLabels(
      count: 4,
      alphabet: colemak.chars,
      leftHand: colemak.leftHand,
      keyScores: colemak.keyScores,
      keyRows: colemak.keyRows,
      minLength: 2)
    XCTAssertNotEqual(qwertyLabels, colemakLabels)
    XCTAssertEqual(qwertyLabels[0], "fj")
    XCTAssertEqual(colemakLabels[0], "tn")
  }

  /// Holding the best keys back as single-character labels used to leave
  /// one awkward prefix, so most two-key labels were the same hand.
  func testMixedLabelsKeepAlternatingHands() {
    let colemak = Alphabet.resolve("<colemak>")
    let labels = HintAssigner.generateLabels(
      count: 100,
      alphabet: colemak.chars,
      leftHand: colemak.leftHand,
      keyScores: colemak.keyScores,
      keyRows: colemak.keyRows)
    XCTAssertEqual(labels.count, 100)
    XCTAssertEqual(Set(labels).count, 100)
    let doubles = labels.filter { $0.count == 2 }
    XCTAssertFalse(doubles.isEmpty)
    XCTAssertLessThan(
      labels.lastIndex { $0.count == 1 } ?? -1, labels.firstIndex { $0.count == 2 }!)
    for label in doubles {
      let chars = Array(label)
      XCTAssertNotEqual(
        colemak.leftHand.contains(chars[0]),
        colemak.leftHand.contains(chars[1]),
        "same-hand label \(label) in \(doubles)")
    }
    XCTAssertEqual(labels[0], "t")
    XCTAssertEqual(doubles[0], "nt")
    for (index, label) in labels.enumerated() {
      for other in labels where other != label {
        XCTAssertFalse(label.hasPrefix(other), "\(label) at \(index) starts with \(other)")
      }
    }
  }

  func testMixedLabelsPreferTheBestSingleThenTheBestAlternation() {
    // Score order a…f. Left a b c, right d e f. Ten labels need two
    // prefixes; keeping `a` as a single beats spending it on a pair.
    let alphabet = Array("abcdef")
    let labels = HintAssigner.generateLabels(
      count: 10,
      alphabet: alphabet,
      leftHand: Set("abc"),
      keyScores: ["a": 100, "b": 90, "c": 80, "d": 70, "e": 60, "f": 50],
      minLength: 1)
    XCTAssertEqual(labels, ["a", "b", "c", "f", "da", "db", "ea", "dc", "eb", "ec"])
  }

  func testAlternationBeatsASameHandHomeRowPair() {
    let qwerty = Alphabet.resolve("<qwerty>")
    XCTAssertGreaterThan(
      HintAssigner.scoreLabel(
        "qp", leftHand: qwerty.leftHand, keyScores: qwerty.keyScores, keyRows: qwerty.keyRows),
      HintAssigner.scoreLabel(
        "sd", leftHand: qwerty.leftHand, keyScores: qwerty.keyScores, keyRows: qwerty.keyRows),
      "a weak alternating pair outranks the strongest same-hand home keys")
  }

  /// Hand changes rank first. Among alternating labels, each row of travel
  /// outranks any key-ease difference, including across a longer label.
  func testLessRowTravelOutranksKeyEase() {
    let alphabet = Array("abcde")
    // a and e are the left home keys, b the right home key. c is one row
    // away on the right, d is two rows away on the left.
    let leftHand: Set<Character> = ["a", "d", "e"]
    let keyScores: [Character: Int] = [
      "a": 40,
      "b": 30,
      "c": 100,
      "d": 400,
      "e": 5,
    ]
    let keyRows: [Character: Int] = [
      "a": 2,
      "b": 2,
      "c": 1,
      "d": 0,
      "e": 2,
    ]
    func score(_ label: String, rows: [Character: Int] = keyRows) -> Int {
      HintAssigner.scoreLabel(label, leftHand: leftHand, keyScores: keyScores, keyRows: rows)
    }

    XCTAssertGreaterThan(score("ab"), score("ac"))
    XCTAssertGreaterThan(score("ac"), score("bd"))
    XCTAssertGreaterThan(score("bd"), score("ae"))
    XCTAssertGreaterThan(score("aba"), score("abd"))
    XCTAssertGreaterThan(score("bd", rows: [:]), score("ac", rows: [:]))
    XCTAssertGreaterThan(score("ac", rows: [:]), score("ab", rows: [:]))
    XCTAssertGreaterThan(score("abd", rows: [:]), score("aba", rows: [:]))

    let labels = HintAssigner.generateLabels(
      count: 4,
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      minLength: 2)
    XCTAssertEqual(labels, ["ab", "ba", "be", "eb"])
  }

  /// On QWERTY, a weak same-row pair beats a strong one-row jump. A
  /// one-row jump stays ahead of a two-row jump, and that jump still
  /// beats a same-hand home pair. `fj` stays first, and the two-key list
  /// is grouped by row distance.
  func testLayoutPairsGroupByRowDistanceThenEase() {
    let qwerty = Alphabet.resolve("<qwerty>")
    func score(_ label: String, rows: [Character: Int]) -> Int {
      HintAssigner.scoreLabel(
        label, leftHand: qwerty.leftHand, keyScores: qwerty.keyScores, keyRows: rows)
    }
    XCTAssertGreaterThan(score("qp", rows: [:]), 0)
    XCTAssertGreaterThan(
      score("fm", rows: [:]),
      score("qp", rows: [:]),
      "key ease alone prefers the home-to-bottom index pair")
    XCTAssertGreaterThan(score("qp", rows: qwerty.keyRows), score("fm", rows: qwerty.keyRows))
    XCTAssertGreaterThan(score("fm", rows: qwerty.keyRows), score("rm", rows: qwerty.keyRows))
    XCTAssertGreaterThan(score("rm", rows: qwerty.keyRows), score("sd", rows: qwerty.keyRows))

    var sameRowPairs = 0
    for first in qwerty.chars {
      for second in qwerty.chars where first != second {
        guard qwerty.leftHand.contains(first) != qwerty.leftHand.contains(second) else { continue }
        guard qwerty.keyRows[first] == qwerty.keyRows[second] else { continue }
        sameRowPairs += 1
      }
    }
    let labels = HintAssigner.generateLabels(
      count: sameRowPairs + 2,
      alphabet: qwerty.chars,
      leftHand: qwerty.leftHand,
      keyScores: qwerty.keyScores,
      keyRows: qwerty.keyRows,
      minLength: 2)
    XCTAssertEqual(labels.first, "fj")
    func distance(_ label: String) -> Int {
      let chars = Array(label)
      return abs(qwerty.keyRows[chars[0]]! - qwerty.keyRows[chars[1]]!)
    }
    XCTAssertEqual(labels.prefix(sameRowPairs).filter { distance($0) == 0 }.count, sameRowPairs)
    XCTAssertEqual(distance(labels[sameRowPairs]), 1)
    XCTAssertEqual(distance(labels[sameRowPairs + 1]), 1)
    var previous = 0
    for label in labels {
      let rowDistance = distance(label)
      XCTAssertGreaterThanOrEqual(rowDistance, previous, label)
      previous = rowDistance
      let chars = Array(label)
      XCTAssertNotEqual(qwerty.leftHand.contains(chars[0]), qwerty.leftHand.contains(chars[1]))
    }
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

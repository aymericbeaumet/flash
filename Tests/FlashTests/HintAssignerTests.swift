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

  func testUniformLength() {
    // 8-char alphabet, count = 9 → 1 char isn't enough, all should be 2-char.
    let nine = HintAssigner.generateLabels(count: 9, alphabet: alphabet)
    XCTAssertTrue(
      nine.allSatisfy { $0.count == 2 }, "9 items in 8-char alphabet → all 2-char labels")

    // count = 8 → exactly fits in 1-char labels.
    let eight = HintAssigner.generateLabels(count: 8, alphabet: alphabet)
    XCTAssertTrue(
      eight.allSatisfy { $0.count == 1 }, "8 items in 8-char alphabet → all 1-char labels")

    // count = 65 → 1 and 2 chars aren't enough (8^2 = 64), need 3.
    let many = HintAssigner.generateLabels(count: 65, alphabet: alphabet)
    XCTAssertTrue(
      many.allSatisfy { $0.count == 3 }, "65 items in 8-char alphabet → all 3-char labels")
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

  func testEmpty() {
    XCTAssertTrue(HintAssigner.generateLabels(count: 0, alphabet: alphabet).isEmpty)
  }

  private func check(count: Int) {
    let labels = HintAssigner.generateLabels(count: count, alphabet: alphabet)
    XCTAssertEqual(labels.count, count, "expected \(count) labels")
    XCTAssertEqual(Set(labels).count, count, "labels should be unique")
    // Uniform length is a stronger invariant than prefix-free; verify both.
    let first = labels.first?.count ?? 0
    XCTAssertTrue(labels.allSatisfy { $0.count == first }, "all labels should share one length")
    for (i, a) in labels.enumerated() {
      for (j, b) in labels.enumerated() where i != j {
        XCTAssertFalse(a.hasPrefix(b), "label \(a) at \(i) starts with label \(b) at \(j)")
      }
    }
  }
}

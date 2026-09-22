import XCTest

@testable import FlashProviders

final class AccessibilityTraversalTests: XCTestCase {
  func testWorklistHandlesDeepSingleChildTreesWithoutRecursion() {
    let maximumDepth = 100_000
    var visited = 0
    var worklist = AXTraversalWorklist(root: 0)

    while let depth = worklist.pop() {
      visited += 1
      if depth < maximumDepth {
        worklist.appendForDepthFirstVisit([depth + 1]) { $0 }
      }
    }

    XCTAssertEqual(visited, maximumDepth + 1)
  }

  func testWorklistPreservesRecursiveDepthFirstSiblingOrder() {
    let children = [
      0: [1, 2, 3],
      1: [4, 5],
      2: [6],
    ]
    var visited: [Int] = []
    var worklist = AXTraversalWorklist(root: 0)

    while let node = worklist.pop() {
      visited.append(node)
      worklist.appendForDepthFirstVisit(children[node] ?? []) { $0 }
    }

    XCTAssertEqual(visited, [0, 1, 4, 5, 2, 6, 3])
  }
}

final class HintPointCandidateTests: XCTestCase {
  func testThePreferredPointIsAlwaysProbedFirst() {
    let frame = CGRect(x: 100, y: 200, width: 400, height: 40)
    let preferred = CGPoint(x: 300, y: 220)
    let candidates = AccessibilityProvider.hintPointCandidates(preferred: preferred, in: frame)
    XCTAssertEqual(candidates.first, preferred)
  }

  func testAWideRowOffersEdgeProbesAwayFromItsMidpoint() {
    // The failure this covers: a list row whose centre is covered by a button
    // or a link. One probe vetoed the whole gesture and the click vanished.
    let frame = CGRect(x: 0, y: 0, width: 600, height: 40)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 300, y: 20), in: frame)
    XCTAssertGreaterThan(candidates.count, 1)
    for candidate in candidates {
      XCTAssertTrue(frame.contains(candidate), "probe \(candidate) escaped \(frame)")
    }
    XCTAssertTrue(candidates.contains { $0.x < 100 }, "no probe near the leading edge")
    XCTAssertTrue(candidates.contains { $0.x > 500 }, "no probe near the trailing edge")
  }

  func testProbesStayInsideATinyTarget() {
    let frame = CGRect(x: 10, y: 10, width: 4, height: 4)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 12, y: 12), in: frame)
    for candidate in candidates {
      XCTAssertTrue(frame.contains(candidate), "probe \(candidate) escaped \(frame)")
    }
  }

  func testADegeneratedFrameFallsBackToThePreferredPointAlone() {
    let preferred = CGPoint(x: 5, y: 6)
    XCTAssertEqual(
      AccessibilityProvider.hintPointCandidates(preferred: preferred, in: .zero), [preferred])
  }

  func testDuplicateProbesAreDropped() {
    let frame = CGRect(x: 0, y: 0, width: 8, height: 8)
    let candidates = AccessibilityProvider.hintPointCandidates(
      preferred: CGPoint(x: 2, y: 4), in: frame)
    for (index, candidate) in candidates.enumerated() {
      for other in candidates[(index + 1)...] {
        XCTAssertFalse(
          abs(other.x - candidate.x) < 1 && abs(other.y - candidate.y) < 1,
          "duplicate probe \(candidate)")
      }
    }
  }
}

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

  /// A native table walks only its visible rows: every other child (columns,
  /// header, rows AX already dropped from `AXRows`) keeps its place, and the
  /// scrolled-off rows cost no batched read at all.
  func testTableWalksVisibleRowsInsteadOfEveryRow() {
    let rows = (0..<5_000).map { "row\($0)" }
    let children = ["header"] + rows + ["column"]
    let visible = Array(rows[40..<60])
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: rows, visibleRows: visible),
      ["header"] + visible + ["column"])
  }

  func testVirtualisedTableAppendsVisibleRowsItsChildrenLack() {
    // Some outlines expose their rows only through `AXVisibleRows`.
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(
        children: ["column"], rows: ["a", "b", "c"], visibleRows: ["b", "c"]),
      ["column", "b", "c"])
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(
        children: ["column", "b"], rows: nil, visibleRows: ["b", "c"]),
      ["column", "b", "c"], "unreadable AXRows keeps every child and adds the missing rows")
  }

  func testTableWithoutAVisibleRowListKeepsItsChildren() {
    // An empty or unreadable visible-row list is no evidence that a row is
    // off screen, so nothing is dropped.
    let children = ["header", "a", "b"]
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: ["a", "b"], visibleRows: nil),
      children)
    XCTAssertEqual(
      AccessibilityProvider.tableChildren(children: children, rows: ["a", "b"], visibleRows: []),
      children)
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

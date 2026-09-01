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

import CoreGraphics
import XCTest

@testable import flash

/// The tiling tree's transitions, against AeroSpace's i3-style model.
final class TilingTreeTests: XCTestCase {
  private func tree(_ windows: String..., orientation: TilingOrientation = .horizontal)
    -> TilingTree<String>
  {
    var tree = TilingTree<String>(orientation: orientation)
    for window in windows { tree.insert(window) }
    return tree
  }

  func testWindowsInsertAfterTheFocusedOneInItsContainer() {
    var tree = tree("a", "b", "c")
    XCTAssertEqual(tree.shape, "h_tiles[a, b, c]")
    tree.insert("d", after: "a")
    XCTAssertEqual(tree.shape, "h_tiles[a, d, b, c]")
    tree.insert("d", after: "c")
    XCTAssertEqual(tree.shape, "h_tiles[a, d, b, c]", "a window already in the tree stays")
    XCTAssertEqual(tree.windows, ["a", "d", "b", "c"])
  }

  func testRemovingAWindowNormalizesItsContainer() {
    var tree = tree("a", "b", "c")
    XCTAssertTrue(tree.join("c", .left))
    XCTAssertEqual(tree.shape, "h_tiles[a, v_tiles[b, c]]")
    tree.remove("c")
    XCTAssertEqual(tree.shape, "h_tiles[a, b]", "a one-child container is flattened")
    tree.remove("a")
    tree.remove("b")
    XCTAssertTrue(tree.isEmpty)
    XCTAssertEqual(tree.shape, "h_tiles[]", "the root stays")
  }

  func testMovePassesSiblingsAndStopsAtTheWorkspaceEdge() {
    var tree = tree("a", "b", "c")
    XCTAssertTrue(tree.move("a", .right))
    XCTAssertEqual(tree.shape, "h_tiles[b, a, c]")
    XCTAssertTrue(tree.move("a", .right))
    XCTAssertEqual(tree.shape, "h_tiles[b, c, a]")
    XCTAssertFalse(tree.move("a", .right), "at the right edge of the workspace")
  }

  func testMoveEntersASiblingContainerAtItsNearEnd() {
    var tree = tree("a", "b", "c")
    tree.join("c", .left)
    XCTAssertEqual(tree.shape, "h_tiles[a, v_tiles[b, c]]")
    XCTAssertTrue(tree.move("a", .right))
    XCTAssertEqual(
      tree.shape, "v_tiles[a, b, c]",
      "a enters the split at its top; the root then holds one container and becomes it")
  }

  func testMoveOutOfANestedContainerLandsBesideIt() {
    var tree = tree("a", "b", "c")
    tree.join("c", .left)
    XCTAssertEqual(tree.shape, "h_tiles[a, v_tiles[b, c]]")
    XCTAssertTrue(tree.move("c", .right), "c leaves the vertical split")
    XCTAssertEqual(tree.shape, "h_tiles[a, b, c]")
    tree.join("b", .left)
    XCTAssertEqual(tree.shape, "h_tiles[v_tiles[a, b], c]")
    XCTAssertTrue(tree.move("a", .right))
    XCTAssertEqual(tree.shape, "h_tiles[b, a, c]", "out of the split, between it and c")
  }

  func testMoveAcrossTheRootsAxisWrapsTheRoot() {
    var tree = tree("a", "b")
    XCTAssertTrue(tree.move("b", .down))
    XCTAssertEqual(tree.shape, "v_tiles[a, b]", "a new root along the axis, b below")
    XCTAssertFalse(tree.move("b", .down))
  }

  func testSwapExchangesTwoWindows() {
    var tree = tree("a", "b", "c")
    tree.join("c", .left)
    tree.swap("a", "c")
    XCTAssertEqual(tree.shape, "h_tiles[c, v_tiles[b, a]]")
  }

  func testJoinNeedsASiblingAlongTheParentsAxis() {
    var tree = tree("a", "b")
    XCTAssertFalse(tree.join("a", .left), "nothing to the left")
    XCTAssertFalse(tree.join("a", .down), "the parent is horizontal")
    XCTAssertTrue(tree.join("a", .right))
    XCTAssertEqual(tree.shape, "v_tiles[a, b]", "the root took over the joined container")
  }

  func testNestedContainersTakeTheOppositeOrientation() {
    var tree = tree("a", "b", "c")
    tree.join("c", .left)
    tree.setOrientation(.horizontal, around: "c")
    XCTAssertEqual(
      tree.shape, "v_tiles[a, h_tiles[b, c]]",
      "the nested container keeps what was asked; its parent flips")
    tree.setLayout(.accordion, around: "c")
    XCTAssertEqual(tree.shape, "v_tiles[a, h_accordion[b, c]]")
    XCTAssertEqual(tree.layout(around: "c").layout, .accordion)
    XCTAssertEqual(tree.layout(around: "a").orientation, .vertical)
  }

  func testResizeTradesLengthWithSiblingsAndBalanceEvensIt() {
    var tree = tree("a", "b", "c")
    XCTAssertTrue(tree.resize("a", along: .horizontal, by: 0.2))
    let weights = tree.containers[tree.root]!.weights
    XCTAssertEqual(weights.reduce(0, +), 3, accuracy: 1e-9, "the total is kept")
    XCTAssertEqual(weights[0], 1.6, accuracy: 1e-9)
    XCTAssertEqual(weights[1], 0.7, accuracy: 1e-9)
    XCTAssertFalse(tree.resize("a", along: .vertical, by: 0.2), "no vertical container")
    XCTAssertTrue(tree.resize("a", along: .horizontal, by: 5), "clamped, not refused")
    XCTAssertGreaterThan(tree.containers[tree.root]!.weights[1], 0)
    tree.balance()
    XCTAssertEqual(tree.containers[tree.root]!.weights, [1, 1, 1])
  }

  /// A dragged edge moves one boundary: the window's branch and the
  /// neighbor across that edge trade length, nobody else moves.
  func testADraggedEdgeTradesLengthWithTheNeighborAcrossIt() {
    var row = tree("a", "b", "c")
    XCTAssertEqual(row.resizeEdgeTarget("a", toward: .right), row.root)
    XCTAssertNil(row.resizeEdgeTarget("a", toward: .left), "nothing left of a")
    XCTAssertNil(row.resizeEdgeTarget("a", toward: .down), "no vertical container")
    XCTAssertTrue(row.resizeEdge("a", toward: .right, by: 0.1))
    var weights = row.containers[row.root]!.weights
    XCTAssertEqual(weights[0], 1.3, accuracy: 1e-9)
    XCTAssertEqual(weights[1], 0.7, accuracy: 1e-9)
    XCTAssertEqual(weights[2], 1, accuracy: 1e-9, "c is across no edge of a")
    XCTAssertFalse(row.resizeEdge("a", toward: .left, by: 0.1))
    XCTAssertFalse(row.resizeEdge("a", toward: .up, by: 0.1))
    XCTAssertTrue(row.resizeEdge("a", toward: .right, by: 5), "clamped, not refused")
    weights = row.containers[row.root]!.weights
    XCTAssertEqual(weights[1], 0.15, accuracy: 1e-9, "b keeps the 5% floor")
    XCTAssertEqual(weights.reduce(0, +), 3, accuracy: 1e-9, "the total is kept")

    var nested = tree("a", "b", "c")
    nested.join("c", .left)
    XCTAssertEqual(nested.shape, "h_tiles[a, v_tiles[b, c]]")
    XCTAssertTrue(nested.resizeEdge("c", toward: .left, by: 0.25), "c's left edge faces a")
    XCTAssertEqual(nested.containers[nested.root]!.weights, [0.5, 1.5])
    XCTAssertTrue(nested.resizeEdge("c", toward: .up, by: 0.1), "c's top edge faces b")
    let split = nested.parent(of: "c")!
    XCTAssertEqual(nested.containers[split]!.weights[0], 0.8, accuracy: 1e-9)
    XCTAssertEqual(nested.containers[split]!.weights[1], 1.2, accuracy: 1e-9)
    XCTAssertFalse(nested.resizeEdge("c", toward: .right, by: 0.1), "the workspace edge")
  }

  func testFlattenKeepsTheOrderInOneContainer() {
    var tree = tree("a", "b", "c", "d")
    tree.join("b", .right)
    tree.join("d", .left)
    XCTAssertEqual(tree.shape, "h_tiles[a, v_tiles[h_tiles[b, c], d]]")
    tree.flatten()
    XCTAssertEqual(tree.shape, "h_tiles[a, b, c, d]")
  }
}

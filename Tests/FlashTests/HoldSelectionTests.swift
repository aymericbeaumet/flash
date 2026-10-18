import CoreGraphics
import XCTest

@testable import flash

/// HOLD: a held button's selection follows motions the way Vim's visual
/// mode follows the cursor.
final class HoldSelectionTests: XCTestCase {
  /// The page moves under a still pointer; the drag is re-posted after the
  /// scroll's last wheel step and again once an app's own smooth scroll has
  /// settled, never before the scroll it follows.
  func testTheSelectionCatchesUpAfterTheScrollItFollows() {
    XCTAssertEqual(HoldSelection.catchUpDelays(scrollMs: 0), [16, 200])
    XCTAssertEqual(HoldSelection.catchUpDelays(scrollMs: 120), [136, 320])
  }

  /// `gg` / `G` extend to the first / last line: the pointer drags to the
  /// window's top / bottom edge, keeping its column inside the window.
  func testTopAndBottomExtendToTheWindowEdgeInThePointersColumn() {
    let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    XCTAssertEqual(
      HoldSelection.edgePoint(top: true, pointer: CGPoint(x: 400, y: 500), window: window),
      CGPoint(x: 400, y: 798))
    XCTAssertEqual(
      HoldSelection.edgePoint(top: false, pointer: CGPoint(x: 400, y: 500), window: window),
      CGPoint(x: 400, y: 202))
    // A pointer outside the window keeps to its columns.
    XCTAssertEqual(
      HoldSelection.edgePoint(top: true, pointer: CGPoint(x: 20, y: 500), window: window).x, 102)
    XCTAssertEqual(
      HoldSelection.edgePoint(top: true, pointer: CGPoint(x: 2000, y: 500), window: window).x,
      898)
  }
}

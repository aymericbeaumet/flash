import CoreGraphics
import FlashBrowserTestSupport
import FlashCore
import XCTest

final class OracleDiffTests: XCTestCase {
  func testMatchesSmallAXRectContainedByVimiumClickableRect() {
    let vimium = anchor(frame: CGRect(x: 100, y: 100, width: 360, height: 80))
    let flash = target(frame: CGRect(x: 120, y: 130, width: 140, height: 20))

    let result = OracleDiff.classify(
      vimium: [vimium],
      flash: [flash],
      allowList: .empty)

    XCTAssertEqual(result.matchedCount, 1)
    XCTAssertTrue(result.hardFailures.isEmpty)
  }

  func testDoesNotMatchBarelyOverlappingRects() {
    let vimium = anchor(frame: CGRect(x: 100, y: 100, width: 360, height: 80))
    let flash = target(frame: CGRect(x: 440, y: 165, width: 140, height: 20))

    let result = OracleDiff.classify(
      vimium: [vimium],
      flash: [flash],
      allowList: .empty)

    XCTAssertEqual(result.matchedCount, 0)
    XCTAssertEqual(result.hardFailures.count, 2)
  }

  func testMatchesSubstantiallyOverlappingShiftedRects() {
    let vimium = anchor(frame: CGRect(x: 8, y: 910, width: 100, height: 22))
    let flash = target(frame: CGRect(x: 28, y: 906, width: 100, height: 22))

    let result = OracleDiff.classify(
      vimium: [vimium],
      flash: [flash],
      allowList: .empty)

    XCTAssertEqual(result.matchedCount, 1)
    XCTAssertTrue(result.hardFailures.isEmpty)
  }

  private func anchor(frame: CGRect) -> VimiumAnchor {
    VimiumAnchor(
      tag: "a",
      role: "link",
      label: "Example",
      marker: "a",
      cssRect: frame,
      screenRect: frame)
  }

  private func target(frame: CGRect) -> JumpTarget {
    JumpTarget(
      id: "flash",
      frame: frame,
      role: "AXLink",
      providerID: "accessibility")
  }
}

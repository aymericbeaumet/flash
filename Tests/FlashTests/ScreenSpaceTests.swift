import CoreGraphics
import FlashCore
import XCTest

/// `ScreenPoint` and `ScreenRect` carry their coordinate space in their
/// type, and the one flip behind `toAX` / `toNS` converts between
/// Accessibility's top-left and AppKit's bottom-left origins about the
/// primary display's height.
final class ScreenSpaceTests: XCTestCase {
  func testTheFlipIsItsOwnInverse() {
    let topLeft = ScreenRect<AXSpace>(x: 40, y: 100, width: 300, height: 200)
    let bottomLeft = topLeft.toNS(primaryHeight: 1000)
    XCTAssertEqual(bottomLeft, ScreenRect<NSSpace>(x: 40, y: 700, width: 300, height: 200))
    XCTAssertEqual(bottomLeft.toAX(primaryHeight: 1000), topLeft)

    let point = ScreenPoint<NSSpace>(x: 300, y: 700)
    XCTAssertEqual(point.toAX(primaryHeight: 900), ScreenPoint<AXSpace>(x: 300, y: 200))
    XCTAssertEqual(point.toAX(primaryHeight: 900).toNS(primaryHeight: 900), point)
  }

  /// Two displays: the 1920×1080 primary at the origin and a 1440×2560
  /// portrait display to its left whose top edge sits 300 pt above the
  /// primary's. The pivot is the primary's height, never the taller
  /// display's, so a rect on either display converts both ways to the same
  /// place, negative origins included.
  func testAKnownRectConvertsBothWaysAcrossATwoDisplayLayout() {
    let primaryHeight: CGFloat = 1080
    let primaryNS = ScreenRect<NSSpace>(x: 0, y: 0, width: 1920, height: 1080)
    let leftNS = ScreenRect<NSSpace>(x: -1440, y: -1180, width: 1440, height: 2560)
    XCTAssertEqual(leftNS.maxY, primaryNS.maxY + 300)

    // The displays themselves, as the window server reports them.
    XCTAssertEqual(
      primaryNS.toAX(primaryHeight: primaryHeight),
      ScreenRect<AXSpace>(x: 0, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(
      leftNS.toAX(primaryHeight: primaryHeight),
      ScreenRect<AXSpace>(x: -1440, y: -300, width: 1440, height: 2560))

    // A 600×400 window 50 pt below the left display's top edge and 100 pt in
    // from its left edge.
    let windowAX = ScreenRect<AXSpace>(x: -1340, y: -250, width: 600, height: 400)
    let windowNS = windowAX.toNS(primaryHeight: primaryHeight)
    XCTAssertEqual(windowNS, ScreenRect<NSSpace>(x: -1340, y: 930, width: 600, height: 400))
    XCTAssertEqual(windowNS.maxY, leftNS.maxY - 50)
    XCTAssertTrue(leftNS.contains(windowNS))
    XCTAssertEqual(windowNS.toAX(primaryHeight: primaryHeight), windowAX)

    // The same window flipped about the taller display's height would land
    // 1480 pt away: the pivot has to be the primary's.
    XCTAssertNotEqual(windowAX.toNS(primaryHeight: leftNS.height), windowNS)

    // A control near the primary's bottom-right corner.
    let controlNS = ScreenRect<NSSpace>(x: 1800, y: 20, width: 100, height: 30)
    XCTAssertEqual(
      controlNS.toAX(primaryHeight: primaryHeight),
      ScreenRect<AXSpace>(x: 1800, y: 1030, width: 100, height: 30))
    XCTAssertEqual(
      controlNS.toAX(primaryHeight: primaryHeight).toNS(primaryHeight: primaryHeight), controlNS)

    // The pointer on the left display, 10 pt under its top edge.
    let pointerNS = ScreenPoint<NSSpace>(x: -700, y: 1370)
    XCTAssertEqual(
      pointerNS.toAX(primaryHeight: primaryHeight), ScreenPoint<AXSpace>(x: -700, y: -290))
    XCTAssertEqual(
      pointerNS.toAX(primaryHeight: primaryHeight).toNS(primaryHeight: primaryHeight), pointerNS)
  }

  func testGeometryHelpersStayInTheirSpace() {
    let rect = ScreenRect<NSSpace>(x: 10, y: 20, width: 100, height: 50)
    XCTAssertEqual(rect.center, ScreenPoint<NSSpace>(x: 60, y: 45))
    XCTAssertEqual(rect.origin, ScreenPoint<NSSpace>(x: 10, y: 20))
    XCTAssertEqual(rect.size, CGSize(width: 100, height: 50))
    XCTAssertTrue(rect.contains(ScreenPoint<NSSpace>(x: 15, y: 25)))
    XCTAssertFalse(rect.contains(ScreenPoint<NSSpace>(x: 5, y: 25)))
    XCTAssertEqual(
      rect.intersection(ScreenRect<NSSpace>(x: 50, y: 0, width: 100, height: 100)),
      ScreenRect<NSSpace>(x: 50, y: 20, width: 60, height: 50))
    XCTAssertEqual(
      ScreenRect<NSSpace>.null.union(rect), rect, "a union starts at .null, not .zero")
    XCTAssertEqual(
      rect.insetBy(dx: 5, dy: 5), ScreenRect<NSSpace>(x: 15, y: 25, width: 90, height: 40))
    XCTAssertTrue(ScreenRect<AXSpace>.null.isNull)
  }
}

import CoreGraphics
import FlashCore
import XCTest

/// One flip converts between AppKit's bottom-left and Accessibility's
/// top-left coordinates, both ways.
final class ScreenSpaceTests: XCTestCase {
  func testTheFlipIsItsOwnInverse() {
    let topLeft = CGRect(x: 40, y: 100, width: 300, height: 200)
    let bottomLeft = ScreenSpace.flip(topLeft, height: 1000)
    XCTAssertEqual(bottomLeft, CGRect(x: 40, y: 700, width: 300, height: 200))
    XCTAssertEqual(ScreenSpace.flip(bottomLeft, height: 1000), topLeft)
  }
}

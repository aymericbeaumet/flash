import CoreGraphics
import XCTest

@testable import flash

final class WindowMoverTests: XCTestCase {
  func testUsableFrameReturnsVisibleFrameWhenStatusBarIsHidden() {
    let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)

    XCTAssertEqual(
      WindowMover.usableFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: visibleFrame,
        statusBarReservesSpace: false,
        fontSize: 13,
        fallbackNativeStatusBarHeight: 22),
      visibleFrame)
  }

  func testUsableFrameReservesFallbackThicknessWhenVisibleFrameDoesNot() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1440, height: 878))
  }

  func testUsableFrameReservesMeasuredNativeMenuHeightWhenVisibleFrameDoesNot() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 30)

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1920, height: 1050))
  }

  func testUsableFrameUsesPerScreenReservedBandBeforeFallbackThickness() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1728, height: 1079))
  }

  func testWindowMoveSlotsUseReservedUsableFrame() {
    let usable = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)

    XCTAssertEqual(
      WindowMover.rectFor(position: .maximized, in: usable),
      CGRect(x: 0, y: 0, width: 1440, height: 878))
    XCTAssertEqual(
      WindowMover.rectFor(position: .topHalf, in: usable),
      CGRect(x: 0, y: 439, width: 1440, height: 439))
  }

  func testWindowMoveScreenRemapUsesReservedUsableFrames() {
    let source = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)
    let destination = WindowMover.usableFrame(
      screenFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
      visibleFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
      statusBarReservesSpace: true,
      fontSize: 13,
      fallbackNativeStatusBarHeight: 22)
    let frame = CGRect(x: 0, y: 0, width: 720, height: 878)

    XCTAssertEqual(
      WindowMover.remap(frame: frame, from: source, to: destination),
      CGRect(x: 1440, y: 0, width: 500, height: 778))
  }
}

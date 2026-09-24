import CoreGraphics
import XCTest

@testable import flash

/// `[overlay] hint_placement`: where a chip sits relative to its target,
/// kept on the target's screen. NSScreen coordinates (y grows upwards).
final class HintPlacementTests: XCTestCase {
  private let chip = CGSize(width: 20, height: 16)
  private let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)

  func testCornerIsTheLongStandingPlacement() {
    XCTAssertEqual(Config().overlay.hintPlacement, .corner)
    for target in [
      CGRect(x: 100, y: 200, width: 300, height: 40),  // wide and tall: top-left corner
      CGRect(x: 100, y: 200, width: 300, height: 18),  // short: vertically centred
      CGRect(x: 100, y: 200, width: 22, height: 18),  // small: centred
    ] {
      XCTAssertEqual(
        HintPlacement.corner.chipFrame(target: target, size: chip, screen: screen),
        OverlayPanel.chipFrame(target: target, width: chip.width, height: chip.height), "\(target)")
    }
    XCTAssertEqual(
      HintPlacement.corner.chipFrame(
        target: CGRect(x: 100, y: 200, width: 300, height: 40), size: chip, screen: screen),
      CGRect(x: 100, y: 224, width: 20, height: 16))
  }

  func testCenterSitsOnTheTargetsMiddle() {
    XCTAssertEqual(
      HintPlacement.center.chipFrame(
        target: CGRect(x: 100, y: 200, width: 300, height: 40), size: chip, screen: screen),
      CGRect(x: 240, y: 212, width: 20, height: 16))
  }

  /// Above and below align with the target's leading edge, or centre on a
  /// target barely wider than the chip.
  func testAboveAndBelowSitOutsideTheTargetsEdges() {
    let wide = CGRect(x: 100, y: 200, width: 300, height: 40)
    XCTAssertEqual(
      HintPlacement.above.chipFrame(target: wide, size: chip, screen: screen),
      CGRect(x: 100, y: 240, width: 20, height: 16))
    XCTAssertEqual(
      HintPlacement.below.chipFrame(target: wide, size: chip, screen: screen),
      CGRect(x: 100, y: 184, width: 20, height: 16))
    let narrow = CGRect(x: 100, y: 200, width: 22, height: 18)
    XCTAssertEqual(
      HintPlacement.above.chipFrame(target: narrow, size: chip, screen: screen),
      CGRect(x: 101, y: 218, width: 20, height: 16))
    XCTAssertEqual(
      HintPlacement.below.chipFrame(target: narrow, size: chip, screen: screen),
      CGRect(x: 101, y: 184, width: 20, height: 16))
  }

  /// A chip that would leave the target's screen is pushed back onto it.
  func testChipsStayOnTheTargetsScreen() {
    let topEdge = CGRect(x: 1400, y: 905, width: 112, height: 40)
    XCTAssertEqual(
      HintPlacement.above.chipFrame(target: topEdge, size: chip, screen: screen),
      CGRect(x: 1400, y: 929, width: 20, height: 16))
    let bottomEdge = CGRect(x: 0, y: 0, width: 300, height: 30)
    XCTAssertEqual(
      HintPlacement.below.chipFrame(target: bottomEdge, size: chip, screen: screen),
      CGRect(x: 0, y: 0, width: 20, height: 16))
    let tinyAtLeftEdge = CGRect(x: 0, y: 400, width: 10, height: 10)
    XCTAssertEqual(
      HintPlacement.corner.chipFrame(target: tinyAtLeftEdge, size: chip, screen: screen),
      CGRect(x: 0, y: 397, width: 20, height: 16))
    let rightEdge = CGRect(x: 1505, y: 400, width: 7, height: 10)
    XCTAssertEqual(
      HintPlacement.center.chipFrame(target: rightEdge, size: chip, screen: screen).maxX, 1512)
  }

  /// A second display, left of and below the primary.
  func testClampingUsesTheGivenScreenInGlobalCoordinates() {
    let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
    let target = CGRect(x: -1920, y: 740, width: 400, height: 40)
    XCTAssertEqual(
      HintPlacement.above.chipFrame(target: target, size: chip, screen: secondary),
      CGRect(x: -1920, y: 764, width: 20, height: 16))
  }

  func testWithoutAScreenNothingIsClamped() {
    let target = CGRect(x: 1400, y: 905, width: 112, height: 40)
    XCTAssertEqual(
      HintPlacement.above.chipFrame(target: target, size: chip, screen: nil),
      CGRect(x: 1400, y: 945, width: 20, height: 16))
  }

  /// The target's screen: the one holding its centre, else the one it
  /// overlaps most.
  func testTheTargetsScreenHoldsItsCentre() {
    let primary = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let screens = [primary, external]
    XCTAssertEqual(
      HintPlacement.screen(for: CGRect(x: 1450, y: 100, width: 200, height: 40), among: screens),
      external)
    XCTAssertEqual(
      HintPlacement.screen(for: CGRect(x: 1400, y: 100, width: 60, height: 40), among: screens),
      primary)
    XCTAssertEqual(
      HintPlacement.screen(for: CGRect(x: 1490, y: 940, width: 40, height: 20), among: screens),
      external, "centre off every screen: the largest overlap wins")
    XCTAssertNil(
      HintPlacement.screen(for: CGRect(x: 9000, y: 9000, width: 5, height: 5), among: screens))
  }

  func testConfigParsesValidatesAndResolves() throws {
    let config = ConfigLoader.parse("[overlay]\nhint_placement = \"below\"")
    XCTAssertEqual(config.diagnostics, [])
    XCTAssertEqual(config.overlay.hintPlacement, .below)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    XCTAssertEqual((json["overlay"] as? [String: Any])?["hint_placement"] as? String, "below")
    for invalid in ["\"top\"", "\"Center\"", "\"\"", "1", "true"] {
      let rejected = ConfigLoader.parse("[overlay]\nhint_placement = \(invalid)")
      XCTAssertEqual(rejected.diagnostics.count, 1, invalid)
      XCTAssertTrue(rejected.diagnostics[0].message.contains("overlay.hint_placement"), invalid)
      XCTAssertEqual(rejected.overlay.hintPlacement, .corner, invalid)
    }
  }
}

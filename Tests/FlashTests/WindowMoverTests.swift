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

  func testEveryRelativeLayoutRoundTripsFromItsFrame() {
    let usable = CGRect(x: 100, y: 24, width: 1727, height: 1059)

    for position in WindowPosition.allCases {
      let frame = WindowMover.rectFor(position: position, in: usable)
      XCTAssertEqual(
        WindowMover.position(matching: frame, in: usable),
        position,
        "failed to recover \(position.rawValue)")
    }
  }

  func testScreenOnlyMovePreservesEveryRelativeLayoutSemantically() {
    let source = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      usableFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085))
    let destination = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1728, y: -180, width: 2560, height: 1440),
      usableFrame: CGRect(x: 1728, y: -180, width: 2560, height: 1408))

    for position in WindowPosition.allCases {
      let plan = WindowMover.framePlan(
        currentFrame: WindowMover.rectFor(position: position, in: source.usableFrame),
        from: source,
        to: destination,
        requestedPosition: nil,
        screenChanged: true)

      XCTAssertEqual(plan?.position, position)
      XCTAssertEqual(
        plan?.frame,
        WindowMover.rectFor(position: position, in: destination.usableFrame),
        "failed to preserve \(position.rawValue)")
    }
  }

  func testRelativeLayoutMatchingToleratesAXRoundingButRejectsFreeformFrames() {
    let usable = CGRect(x: 0, y: 0, width: 1728, height: 1085)
    let roundedLeft = WindowMover.rectFor(position: .leftHalf, in: usable)
      .offsetBy(dx: 1, dy: -1)

    XCTAssertEqual(
      WindowMover.position(matching: roundedLeft, in: usable),
      .leftHalf)
    XCTAssertNil(
      WindowMover.position(
        matching: CGRect(x: 140, y: 90, width: 1100, height: 760),
        in: usable))
  }

  func testScreenLookupUsesLargestOverlapWhenWindowCentreIsOffScreen() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let secondary = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 1000, y: 0, width: 1000, height: 780))

    XCTAssertEqual(
      WindowMover.screenContaining(
        frame: CGRect(x: 1800, y: 100, width: 500, height: 400),
        screens: [primary, secondary]),
      secondary)
  }

  func testDisplayHandoffNotifiesAfterEveryLayoutRecoveryPass() {
    let manager = WindowLayoutManager(screenRecoveryDelaysMs: [0, 1, 2])
    let source = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      usableFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085))
    let destination = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
      usableFrame: CGRect(x: 0, y: 0, width: 2560, height: 1408))
    let recovered = expectation(description: "layout recovery repaints border")
    recovered.expectedFulfillmentCount = 3

    manager.screenParametersDidChange(screens: [source])
    manager.screenParametersDidChange(screens: [destination]) {
      XCTAssertTrue(Thread.isMainThread)
      recovered.fulfill()
    }

    wait(for: [recovered], timeout: 1)
  }

  func testEnhancedUserInterfaceAnimationToggleRequiresWritableTrueAttribute() {
    XCTAssertTrue(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        bundleIdentifier: "com.apple.TextEdit"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: false,
        bundleIdentifier: "com.apple.TextEdit"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: false,
        isSettable: true,
        bundleIdentifier: "com.apple.TextEdit"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: nil,
        isSettable: true,
        bundleIdentifier: "com.apple.TextEdit"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        bundleIdentifier: "org.mozilla.firefox"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        bundleIdentifier: "org.mozilla.firefoxdeveloperedition"))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        bundleIdentifier: "org.mozilla.nightly"))
  }
}

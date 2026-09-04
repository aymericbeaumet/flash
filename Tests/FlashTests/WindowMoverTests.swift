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

  func testPrimaryOnlyStatusBarReservesSpaceOnlyOnTheMainDisplay() {
    XCTAssertTrue(
      WindowMover.shouldReserveStatusBarSpace(
        statusBarVisible: true,
        monitor: .primary,
        isMainScreen: true))
    XCTAssertFalse(
      WindowMover.shouldReserveStatusBarSpace(
        statusBarVisible: true,
        monitor: .primary,
        isMainScreen: false))
    XCTAssertTrue(
      WindowMover.shouldReserveStatusBarSpace(
        statusBarVisible: true,
        monitor: .all,
        isMainScreen: false))
    XCTAssertFalse(
      WindowMover.shouldReserveStatusBarSpace(
        statusBarVisible: false,
        monitor: .all,
        isMainScreen: true))
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
        currentLayout: nil,
        requestedLayout: nil,
        screenChanged: true)

      XCTAssertEqual(plan?.layout, .position(position))
      XCTAssertEqual(
        plan?.frame,
        WindowMover.rectFor(position: position, in: destination.usableFrame),
        "failed to preserve \(position.rawValue)")
    }
  }

  func testProportionalLayoutUsesTopLeftPercentagesOfUsableFrame() {
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 20,
        widthPercent: 60,
        heightPercent: 50))

    XCTAssertEqual(
      WindowMover.rectFor(layout: layout, in: CGRect(x: 100, y: 20, width: 1000, height: 800)),
      CGRect(x: 200, y: 260, width: 600, height: 400))
  }

  func testRequestedProportionalLayoutAppliesWithoutChangingScreens() {
    let screen = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 10,
        widthPercent: 80,
        heightPercent: 80))
    let plan = WindowMover.framePlan(
      currentFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
      from: screen,
      to: screen,
      currentLayout: nil,
      requestedLayout: layout,
      screenChanged: false)

    XCTAssertEqual(plan?.layout, layout)
    XCTAssertEqual(plan?.frame, WindowMover.rectFor(layout: layout, in: screen.usableFrame))
  }

  func testObservedMatchingFrameRetainsProportionalIntent() {
    let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 10,
        widthPercent: 80,
        heightPercent: 80))

    XCTAssertEqual(
      WindowMover.semanticLayout(
        matching: WindowMover.rectFor(layout: layout, in: usable).offsetBy(dx: 1, dy: -1),
        in: usable,
        existing: layout),
      layout)
    XCTAssertNil(
      WindowMover.semanticLayout(
        matching: CGRect(x: 40, y: 50, width: 500, height: 600),
        in: usable,
        existing: layout))
  }

  func testScreenOnlyMovePreservesTrackedProportionalLayout() {
    let source = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let destination = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1000, y: -200, width: 1600, height: 1200),
      usableFrame: CGRect(x: 1000, y: -200, width: 1600, height: 1170))
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 15,
        widthPercent: 70,
        heightPercent: 60))
    let plan = WindowMover.framePlan(
      currentFrame: WindowMover.rectFor(layout: layout, in: source.usableFrame),
      from: source,
      to: destination,
      currentLayout: layout,
      requestedLayout: nil,
      screenChanged: true)

    XCTAssertEqual(plan?.layout, layout)
    XCTAssertEqual(plan?.frame, WindowMover.rectFor(layout: layout, in: destination.usableFrame))
  }

  func testScreenOnlyMoveDropsStaleTrackedProportionalLayout() {
    let source = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let destination = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 1000, y: 0, width: 1000, height: 780))
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 10,
        widthPercent: 80,
        heightPercent: 80))
    let freeform = CGRect(x: 40, y: 50, width: 500, height: 600)
    let plan = WindowMover.framePlan(
      currentFrame: freeform,
      from: source,
      to: destination,
      currentLayout: layout,
      requestedLayout: nil,
      screenChanged: true)

    XCTAssertNil(plan?.layout)
    XCTAssertEqual(
      plan?.frame,
      WindowMover.remap(frame: freeform, from: source.usableFrame, to: destination.usableFrame))
  }

  func testLayoutRecoveryKeepsIntentOnAResizedSecondaryDisplay() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let resizedSecondary = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1000, y: -100, width: 2000, height: 1400),
      usableFrame: CGRect(x: 1000, y: -100, width: 2000, height: 1370))
    let layout = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10,
        yPercent: 10,
        widthPercent: 80,
        heightPercent: 80))
    let plan = WindowMover.recoveryPlan(
      layout: layout,
      screenID: 2,
      currentFrame: nil,
      screens: [primary, resizedSecondary])

    XCTAssertEqual(plan?.screen, resizedSecondary)
    XCTAssertEqual(
      plan?.frame,
      WindowMover.rectFor(layout: layout, in: resizedSecondary.usableFrame))
  }

  func testLayoutRecoveryFallsBackToRelocatedScreenAfterUnplug() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let layout = WindowLayout.position(.rightHalf)
    let plan = WindowMover.recoveryPlan(
      layout: layout,
      screenID: 2,
      currentFrame: CGRect(x: 100, y: 100, width: 500, height: 500),
      screens: [primary])

    XCTAssertEqual(plan?.screen, primary)
    XCTAssertEqual(plan?.frame, WindowMover.rectFor(layout: layout, in: primary.usableFrame))
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

  func testSecondaryDisplayChangeNotifiesAfterEveryLayoutRecoveryPass() {
    let manager = WindowLayoutManager(screenRecoveryDelaysMs: [0, 1, 2])
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      usableFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085))
    let secondary = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080),
      usableFrame: CGRect(x: 1728, y: 0, width: 1920, height: 1048))
    let resizedSecondary = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
      usableFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1408))
    let recovered = expectation(description: "layout recovery repaints border")
    recovered.expectedFulfillmentCount = 3

    manager.screenParametersDidChange(screens: [primary, secondary])
    manager.screenParametersDidChange(screens: [primary, resizedSecondary]) { _ in
      XCTAssertTrue(Thread.isMainThread)
      recovered.fulfill()
    }

    wait(for: [recovered], timeout: 1)
  }

  func testScreenNotificationResnapshotsSettledGeometryForRecovery() {
    let initial = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 770))
    let settled = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 870))
    var snapshots = [[initial], [settled]]
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0],
      screenLayouts: { _, monitor in
        XCTAssertEqual(monitor, .primary)
        return snapshots.removeFirst()
      })
    let recovered = expectation(description: "settled geometry used")

    manager.screenParametersDidChange(screens: [initial])
    manager.screenParametersDidChange(
      statusBarReservesSpace: true,
      statusBarMonitor: .primary
    ) { screens in
      XCTAssertEqual(screens, [settled])
      recovered.fulfill()
    }

    wait(for: [recovered], timeout: 1)
    XCTAssertTrue(snapshots.isEmpty)
  }

  func testStatusBarMonitorChangeReconcilesSecondaryUsableFrame() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 770))
    let secondaryWithBar = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 1000, y: 0, width: 1000, height: 770))
    let secondaryWithoutBar = WindowScreenLayout(
      id: 2,
      frame: secondaryWithBar.frame,
      usableFrame: secondaryWithBar.frame)
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0],
      screenLayouts: { _, monitor in
        monitor == .all
          ? [primary, secondaryWithBar]
          : [primary, secondaryWithoutBar]
      })
    let recovered = expectation(description: "status-bar monitor policy reconciled")

    manager.screenParametersDidChange(screens: [primary, secondaryWithBar])
    manager.screenParametersDidChange(
      statusBarReservesSpace: true,
      statusBarMonitor: .primary,
      forceRecovery: false
    ) { screens in
      XCTAssertEqual(screens, [primary, secondaryWithoutBar])
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

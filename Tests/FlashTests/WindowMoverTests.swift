import CoreGraphics
import XCTest

@testable import flash

final class WindowMoverTests: XCTestCase {
  /// The bar band a one-display snapshot measures for `screenFrame`.
  private func band(screenFrame: CGRect, visibleFrame: CGRect, measured: CGFloat) -> CGFloat {
    OverlayPanel.makeScreenSnapshot(
      screens: [(scale: 2, frame: screenFrame, visibleFrame: visibleFrame, notch: nil)],
      nativeStatusBarFallbackHeight: measured
    ).statusBarHeight(forScreenFrame: screenFrame)
  }

  func testScreenRecoveryLadderReachesASlowReconnect() {
    let delays = WindowLayoutManager.defaultScreenRecoveryDelaysMs
    XCTAssertEqual(delays.sorted(), delays, "passes have to run in order")
    XCTAssertEqual(Set(delays).count, delays.count, "a repeated delay wastes a pass")
    // AppKit reports the change before NSScreen settles, so the first pass is
    // immediate ...
    XCTAssertLessThanOrEqual(delays.first ?? .max, 100)
    // ... and apps keep relocating their windows for seconds after a display
    // reconnects or wakes. Stopping at 1.5s left those moves uncorrected,
    // which is what made a restore need a manual redo.
    XCTAssertGreaterThanOrEqual(delays.last ?? 0, 3_000)
  }

  func testDefaultRecoveryIncludesLateSettlingPass() {
    XCTAssertGreaterThanOrEqual(
      WindowLayoutManager.defaultScreenRecoveryDelaysMs.last ?? 0,
      1_500,
      "macOS and target apps may relocate windows after the early display-change passes")
  }

  func testUsableFrameReturnsVisibleFrameWhenStatusBarIsHidden() {
    let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)

    XCTAssertEqual(
      WindowMover.usableFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: visibleFrame,
        statusBarHeight: nil),
      visibleFrame)
  }

  func testUsableFrameReservesFallbackThicknessWhenVisibleFrameDoesNot() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      statusBarHeight: band(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), measured: 22))

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1440, height: 878))
  }

  func testUsableFrameReservesMeasuredNativeMenuHeightWhenVisibleFrameDoesNot() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      statusBarHeight: band(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), measured: 30))

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1920, height: 1050))
  }

  func testUsableFrameUsesPerScreenReservedBandBeforeFallbackThickness() {
    let frame = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
      statusBarHeight: band(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079), measured: 22))

    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1728, height: 1079))
  }

  func testWindowMoveSlotsUseReservedUsableFrame() {
    let usable = WindowMover.usableFrame(
      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      statusBarHeight: band(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), measured: 22))

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
      statusBarHeight: band(
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), measured: 22))
    let destination = WindowMover.usableFrame(
      screenFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
      visibleFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
      statusBarHeight: band(
        screenFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800), measured: 22))
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
    let plan = WindowLayoutIntent(layout: layout, home: "display-2", screenID: 2).recoveryPlan(
      currentFrame: nil, screens: [primary, resizedSecondary])

    XCTAssertEqual(plan?.screen, resizedSecondary)
    XCTAssertEqual(
      plan?.frame,
      WindowMover.rectFor(layout: layout, in: resizedSecondary.usableFrame))
  }

  func testUnplugScalesTheFrontWindowOntoTheRemainingDisplay() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      usableFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050))
    let external = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
      usableFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1410))
    let filledExternal = external.usableFrame
    XCTAssertEqual(
      WindowMover.relocatedFrame(filledExternal, from: [primary, external], to: [primary]),
      primary.usableFrame)
    // Already on the remaining display.
    XCTAssertNil(
      WindowMover.relocatedFrame(
        primary.usableFrame, from: [primary, external], to: [primary]))
    // Origin moved, size still the departed display's.
    XCTAssertEqual(
      WindowMover.relocatedFrame(
        CGRect(x: 0, y: 0, width: 2560, height: 1440),
        from: [primary, external],
        to: [primary]),
      primary.usableFrame)
    // Parked off every display on purpose.
    XCTAssertNil(
      WindowMover.relocatedFrame(
        CGRect(x: -4000, y: -4000, width: 400, height: 300),
        from: [primary, external],
        to: [primary]))
  }

  /// The regression: a window stretched across two displays that both stay
  /// connected was shrunk onto one of them by any display change, a Dock or
  /// status bar change to a usable area included. Only a frame that leaves
  /// every connected display behind in part is the fit's to move.
  func testAWindowAcrossConnectedDisplaysIsLeftAlone() throws {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      usableFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050))
    let external = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
      usableFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1410))
    // The Dock autohid on the external: same displays, another usable area.
    let externalNoDock = WindowScreenLayout(
      id: 2,
      frame: external.frame,
      usableFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
    let spanning = CGRect(x: 1200, y: 100, width: 1600, height: 800)
    XCTAssertNil(
      WindowMover.relocatedFrame(
        spanning, from: [primary, external], to: [primary, externalNoDock]))
    XCTAssertNil(
      WindowMover.relocatedFrame(spanning, from: [primary, external], to: [primary, external]))
    // The same frame once the external is gone does leave a display behind.
    let placed = try XCTUnwrap(
      WindowMover.relocatedFrame(spanning, from: [primary, external], to: [primary]))
    XCTAssertTrue(primary.usableFrame.contains(placed), "\(placed)")
  }

  /// `--screen=+1` walks the displays as they are arranged, left to right
  /// then top to bottom, wrapping; `NSScreen.screens` only promises the
  /// primary first, so stepping through it jumped across a three-display row.
  func testARelativeScreenMoveWalksTheDisplaysLeftToRight() {
    func screen(_ id: CGDirectDisplayID, x: CGFloat, y: CGFloat = 0) -> WindowScreenLayout {
      let frame = CGRect(x: x, y: y, width: 1000, height: 800)
      return WindowScreenLayout(id: id, frame: frame, usableFrame: frame)
    }
    // NSScreen order: the primary (middle), then the right, then the left.
    let screens = [screen(1, x: 0), screen(2, x: 1000), screen(3, x: -1000)]
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 0, offset: 1, screens: screens), 1)
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 1, offset: 1, screens: screens), 2)
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 2, offset: 1, screens: screens), 0)
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 0, offset: -1, screens: screens), 2)
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 2, offset: -4, screens: screens), 1)
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 1, offset: 0, screens: screens), 1)
    // Stacked displays: the higher one first.
    let stacked = [screen(1, x: 0), screen(2, x: 0, y: 800)]
    XCTAssertEqual(WindowMover.relativeScreenIndex(from: 1, offset: 1, screens: stacked), 0)
  }

  func testLayoutRecoveryFallsBackToRelocatedScreenAfterUnplug() {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 780))
    let layout = WindowLayout.position(.rightHalf)
    let plan = WindowLayoutIntent(layout: layout, home: "display-2", screenID: 2).recoveryPlan(
      currentFrame: CGRect(x: 100, y: 100, width: 500, height: 500), screens: [primary])

    XCTAssertEqual(plan?.screen, primary)
    XCTAssertEqual(plan?.frame, WindowMover.rectFor(layout: layout, in: primary.usableFrame))
  }

  func testEveryManagedShortcutLayoutKeepsItsSizeAcrossUnplugAndReplug() throws {
    let primary = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 870))
    let external = WindowScreenLayout(
      id: 2,
      frame: CGRect(x: 1200, y: -180, width: 2560, height: 1440),
      usableFrame: CGRect(x: 1200, y: -180, width: 2560, height: 1408))
    let layouts: [WindowLayout] = [
      .position(.maximized),
      .position(.leftHalf),
      .position(.bottomHalf),
      .position(.topHalf),
      .position(.rightHalf),
      .proportional(
        ProportionalWindowFrame(
          xPercent: 10.6925,
          yPercent: 10.6925,
          widthPercent: 78.615,
          heightPercent: 78.615)),
    ]

    for layout in layouts {
      var intent = WindowLayoutIntent(layout: layout, placedOn: external)
      let unplugged = try XCTUnwrap(
        intent.recoveryPlan(
          currentFrame: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [primary]))
      XCTAssertEqual(
        unplugged.frame,
        WindowMover.rectFor(layout: layout, in: primary.usableFrame),
        "unplug changed \(WindowMover.description(of: layout))")
      intent.recovered(on: unplugged.screen)

      // The display it was placed on is back: so is the window, same layout.
      let replugged = try XCTUnwrap(
        intent.recoveryPlan(currentFrame: unplugged.frame, screens: [primary, external]))
      XCTAssertEqual(
        replugged.frame,
        WindowMover.rectFor(layout: layout, in: external.usableFrame),
        "replug changed \(WindowMover.description(of: layout))")
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

  func testPlacementIsExactToThePointWhileSlotRecognitionToleratesRounding() {
    let slot = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    let onePointTall = CGRect(x: 0, y: 0, width: 1728, height: 1085)

    XCTAssertEqual(WindowMover.position(matching: onePointTall, in: slot), .maximized)
    XCTAssertFalse(
      WindowMover.framesMatchPlacement(onePointTall, slot),
      "a restore that calls this done leaves the point the next window move closes")
    XCTAssertTrue(
      WindowMover.framesMatchPlacement(
        CGRect(x: 219, y: 120, width: 1610, height: 880),
        CGRect(x: 218.98, y: 119.65, width: 1610.04, height: 879.7)),
      "whole-point rounding of a fractional target has landed")
  }

  func testLayoutsLandOnWholePointsAndNeighbouringSlotsShareAnEdge() {
    // An odd-width display: the halves meet on one whole-point edge.
    let odd = CGRect(x: 0, y: 0, width: 1727, height: 1085)
    let left = WindowMover.rectFor(position: .leftHalf, in: odd)
    let right = WindowMover.rectFor(position: .rightHalf, in: odd)
    XCTAssertEqual(left.maxX, right.minX)
    XCTAssertEqual(left.width + right.width, odd.width)
    let top = WindowMover.rectFor(position: .topHalf, in: odd)
    let bottom = WindowMover.rectFor(position: .bottomHalf, in: odd)
    XCTAssertEqual(bottom.maxY, top.minY)
    XCTAssertEqual(top.height + bottom.height, odd.height)
    // alt+z on the 1920×1050 home display: whole points, same share of it.
    let centred = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10.6925, yPercent: 10.6925, widthPercent: 78.615, heightPercent: 78.615))
    let home = CGRect(x: 0, y: 0, width: 1920, height: 1050)
    let frame = WindowMover.rectFor(layout: centred, in: home)
    XCTAssertEqual(frame, CGRect(x: 205, y: 112, width: 1510, height: 826))
    XCTAssertEqual(frame.minY - home.minY, home.maxY - frame.maxY, "centred vertically")
    for rect in [left, right, top, bottom, frame] {
      XCTAssertEqual(rect, rect.integral, "\(rect)")
    }
  }

  func testDeclaredProportionalLayoutIsRecognizedWithoutBeingTracked() {
    let centred = WindowLayout.proportional(
      ProportionalWindowFrame(
        xPercent: 10.6925, yPercent: 10.6925, widthPercent: 78.615, heightPercent: 78.615))
    let usable = CGRect(x: 0, y: 0, width: 2048, height: 1122)
    let frame = WindowMover.rectFor(layout: centred, in: usable)
    // After a restart nothing is tracked: only the config's mappings know it.
    XCTAssertNil(WindowMover.semanticLayout(matching: frame, in: usable, existing: nil))
    XCTAssertEqual(
      WindowMover.semanticLayout(matching: frame, in: usable, existing: nil, declared: [centred]),
      centred)
    // A named slot still wins, and a free-form frame matches nothing.
    XCTAssertEqual(
      WindowMover.semanticLayout(
        matching: usable, in: usable, existing: nil, declared: [centred]),
      .position(.maximized))
    XCTAssertNil(
      WindowMover.semanticLayout(
        matching: CGRect(x: 100, y: 100, width: 900, height: 700), in: usable, existing: nil,
        declared: [centred]))
  }

  func testEachRecoveryPassSettlesTheNativeBandBeforeSnapshottingSlots() {
    let screen = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 2048, height: 1152),
      usableFrame: CGRect(x: 0, y: 0, width: 2048, height: 1122))
    var events: [String] = []
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0, 1],
      recoveryApplications: { [] },
      screenLayouts: { _, _ in
        events.append("slots")
        return [screen]
      })
    let recovered = expectation(description: "every pass ran")
    recovered.expectedFulfillmentCount = 2

    manager.screenParametersDidChange(screens: [screen])
    manager.screenParametersDidChange(
      statusBarReservesSpace: true,
      statusBarMonitor: .primary,
      beforeRecoveryPass: { events.append("settle") },
      afterRecoveryPass: { _ in recovered.fulfill() })

    wait(for: [recovered], timeout: 1)
    XCTAssertEqual(events, ["slots", "settle", "slots", "settle", "slots"])
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
    let applicationsRequested = expectation(description: "recovery uses isolated app discovery")
    applicationsRequested.expectedFulfillmentCount = 3
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0, 1, 2],
      recoveryApplications: {
        applicationsRequested.fulfill()
        return []
      })
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

    wait(for: [recovered, applicationsRequested], timeout: 1)
  }

  func testSuspendedScreenRecoveryNotifiesWithoutDiscoveringApplications() {
    let manager = WindowLayoutManager(
      screenRecoveryDelaysMs: [0],
      recoveryApplications: {
        XCTFail("a locked or sleeping session must not perform window discovery")
        return []
      })
    let initial = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
      usableFrame: CGRect(x: 0, y: 0, width: 1000, height: 770))
    let changed = WindowScreenLayout(
      id: 1,
      frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1200, height: 870))
    let recovered = expectation(description: "suspended recovery reports settled screens")

    manager.setSessionSuspended(true, statusBarReservesSpace: false, statusBarMonitor: .primary)
    manager.screenParametersDidChange(screens: [initial])
    manager.screenParametersDidChange(screens: [changed]) { screens in
      XCTAssertEqual(screens, [changed])
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
      recoveryApplications: { [] },
      screenLayouts: { _, monitor in
        XCTAssertEqual(monitor, .primary)
        return snapshots.removeFirst()
      })
    let recovered = expectation(description: "settled geometry used")

    manager.screenParametersDidChange(screens: [initial])
    manager.screenParametersDidChange(
      statusBarReservesSpace: true,
      statusBarMonitor: .primary,
      afterRecoveryPass: { screens in
        XCTAssertEqual(screens, [settled])
        recovered.fulfill()
      })

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
      recoveryApplications: { [] },
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
      forceRecovery: false,
      afterRecoveryPass: { screens in
        XCTAssertEqual(screens, [primary, secondaryWithoutBar])
        recovered.fulfill()
      })

    wait(for: [recovered], timeout: 1)
  }

  func testEnhancedUserInterfaceAnimationToggleRequiresWritableTrueAttribute() {
    XCTAssertTrue(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        engine: nil))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: false,
        engine: nil))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: false,
        isSettable: true,
        engine: nil))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: nil,
        isSettable: true,
        engine: nil))
    XCTAssertFalse(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        engine: .gecko))
    XCTAssertTrue(
      WindowMover.shouldTemporarilyDisableEnhancedUserInterface(
        currentValue: true,
        isSettable: true,
        engine: .chromium))
  }

  /// The catalog reads a window's frame, minimized state, role and subrole
  /// in one batch, and keeps only user windows: Finder's desktop, a
  /// full-screen `AXScrollArea` in its window list, would otherwise be
  /// adopted as a maximized window the status bar's inset then fights over.
  func testOneBatchReadsAUserWindowsFrameAndMinimizedState() throws {
    var point = CGPoint(x: 10, y: 20)
    var size = CGSize(width: 300, height: 200)
    let position = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
    let extent = try XCTUnwrap(AXValueCreate(.cgSize, &size))
    var failure = AXError.attributeUnsupported
    let error = try XCTUnwrap(AXValueCreate(.axError, &failure))
    let window = kAXWindowRole as String
    let standard = kAXStandardWindowSubrole as String
    func parse(_ values: [Any]) -> (frame: CGRect, minimized: Bool, subrole: String?)? {
      WindowMover.parseWindowGeometry(values, primaryHeight: 1000)
    }

    let minimized = try XCTUnwrap(
      parse([position, extent, kCFBooleanTrue as Any, window, standard]))
    XCTAssertTrue(minimized.minimized)
    XCTAssertEqual(minimized.frame, CGRect(x: 10, y: 780, width: 300, height: 200))
    XCTAssertEqual(minimized.subrole, standard, "tiling floats what is not a standard window")
    XCTAssertEqual(
      parse([position, extent, error, window, standard])?.minimized, false,
      "no minimized attribute: not minimized")
    XCTAssertNotNil(
      parse([position, extent, kCFBooleanFalse as Any, window, error]), "no subrole: kept")
    XCTAssertNil(
      parse([position, extent, kCFBooleanFalse as Any, "AXScrollArea", error]), "Finder's desktop")
    XCTAssertNil(
      parse([position, extent, kCFBooleanFalse as Any, window, kAXFloatingWindowSubrole as String]),
      "a palette")
    XCTAssertNil(parse([error, extent, kCFBooleanFalse as Any, window, standard]), "no position")
    XCTAssertNil(parse([position, extent, kCFBooleanFalse as Any]))

    // The stranded-window fit keeps every window subrole (a palette left on a
    // departed display is still rescued) but never Finder's desktop.
    func anyWindow(_ values: [Any]) -> (frame: CGRect, minimized: Bool, subrole: String?)? {
      WindowMover.parseWindowGeometry(values, primaryHeight: 1000, subroles: nil)
    }
    XCTAssertNotNil(
      anyWindow([
        position, extent, kCFBooleanFalse as Any, window, kAXFloatingWindowSubrole as String,
      ]))
    XCTAssertNil(anyWindow([position, extent, kCFBooleanFalse as Any, "AXScrollArea", error]))
  }
}

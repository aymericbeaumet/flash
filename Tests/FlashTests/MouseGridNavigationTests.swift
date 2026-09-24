import AppKit
import FlashCore
import XCTest

@testable import flash

final class MouseGridNavigationTests: XCTestCase {
  private let root = CGRect(x: 0, y: 0, width: 1500, height: 1000)
  private let qwerty = MouseGrid.Shape.keyboard(Alphabet.gridKeys(layoutName: "qwerty"))

  private func step(_ region: CGRect, _ depth: Int) -> MouseGrid.Navigation.Step {
    .init(region: region, depth: depth)
  }

  func testDrillCentreBackAndReset() {
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    XCTAssertEqual(navigation.current, step(root, 0))
    let cells = MouseGrid.cellFrames(of: root, shape: qwerty)
    navigation.drill(into: cells[0])
    XCTAssertEqual(navigation.current, step(cells[0], 1))
    navigation.centre(shape: qwerty)
    XCTAssertEqual(
      navigation.current, step(MouseGrid.centreCell(of: cells[0], shape: qwerty), 2))

    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.current, step(cells[0], 1))
    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.current, step(root, 0))
    XCTAssertFalse(navigation.back(), "nothing left to undo")

    navigation.drill(into: cells[7])
    navigation.centre(shape: qwerty)
    navigation.reset()
    XCTAssertEqual(navigation.current, step(root, 0))
    XCTAssertTrue(navigation.history.isEmpty)
  }

  func testMoveSlidesByTheRegionSizeClampsAtTheEdgeAndUndoes() {
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    // The top-left cell: x 0…300, y 750…1000.
    let topLeft = MouseGrid.cellFrames(of: root, shape: qwerty)[0]
    navigation.drill(into: topLeft)
    XCTAssertFalse(navigation.move(.left), "already at the left edge")
    XCTAssertFalse(navigation.move(.up), "already at the top edge")
    XCTAssertEqual(navigation.history.count, 1, "a no-op move leaves no history")

    XCTAssertTrue(navigation.move(.right))
    XCTAssertEqual(navigation.current, step(CGRect(x: 300, y: 750, width: 300, height: 250), 1))
    XCTAssertTrue(navigation.move(.down))
    XCTAssertEqual(navigation.current, step(CGRect(x: 300, y: 500, width: 300, height: 250), 1))

    XCTAssertTrue(navigation.back())
    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.current, step(topLeft, 1))
  }

  func testMoveClampsAPartialSlideInsideTheRoot() {
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    navigation.drill(into: CGRect(x: 1350, y: 20, width: 100, height: 60))
    XCTAssertTrue(navigation.move(.right))
    XCTAssertEqual(navigation.current.region, CGRect(x: 1400, y: 20, width: 100, height: 60))
    XCTAssertTrue(navigation.move(.down))
    XCTAssertEqual(navigation.current.region, CGRect(x: 1400, y: 0, width: 100, height: 60))
    XCTAssertFalse(navigation.move(.right))
    XCTAssertFalse(navigation.move(.down))
  }

  func testTheWholeScreenCannotMove() {
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    for direction: MouseGrid.Direction in [.left, .right, .up, .down] {
      XCTAssertFalse(navigation.move(direction))
    }
    XCTAssertTrue(navigation.history.isEmpty)
  }

  func testSwitchScreenCyclesThenBackRestoresEachScreen() {
    let screens = [
      root,
      CGRect(x: 1500, y: 0, width: 1920, height: 1050),
      CGRect(x: -1280, y: 0, width: 1280, height: 780),
    ]
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    let cell = MouseGrid.cellFrames(of: root, shape: qwerty)[3]
    navigation.drill(into: cell)

    XCTAssertTrue(navigation.switchScreen(1, roots: screens))
    XCTAssertEqual(navigation.screenIndex, 1)
    XCTAssertEqual(navigation.root, screens[1])
    XCTAssertEqual(navigation.current, step(screens[1], 0))
    XCTAssertTrue(navigation.switchScreen(-1, roots: screens))
    XCTAssertEqual(navigation.screenIndex, 0)
    XCTAssertTrue(navigation.switchScreen(-1, roots: screens), "wraps around")
    XCTAssertEqual(navigation.screenIndex, 2)
    XCTAssertEqual(navigation.root, screens[2])

    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.screenIndex, 0)
    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.screenIndex, 1)
    XCTAssertTrue(navigation.back())
    XCTAssertEqual(navigation.screenIndex, 0)
    XCTAssertEqual(navigation.root, root)
    XCTAssertEqual(navigation.current, step(cell, 1))

    var single = MouseGrid.Navigation(root: root, screenIndex: 0)
    XCTAssertFalse(single.switchScreen(1, roots: [root]))
    XCTAssertTrue(single.history.isEmpty)
  }

  func testZoomDrillsTowardThePointerAndLeavesOneSelection() {
    let pointer = CGPoint(x: 1234, y: 321)
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 0)
    navigation.zoom(toward: pointer, depth: 10, shape: qwerty, steps: 3)
    // Clamped: at depth 2 the next selection clicks, so zooming stops there.
    XCTAssertEqual(navigation.current.depth, 2)
    XCTAssertTrue(
      MouseGrid.selectionCommits(
        region: navigation.current.region, depth: 2, steps: 3, shape: qwerty))
    XCTAssertEqual(navigation.history.count, 2, "each zoom step is undoable")
    for region in navigation.history.map(\.current.region) + [navigation.current.region] {
      XCTAssertTrue(region.contains(pointer), "\(region) must contain the pointer")
    }

    var once = MouseGrid.Navigation(root: root, screenIndex: 0)
    once.zoom(toward: pointer, depth: 1, shape: qwerty, steps: 3)
    XCTAssertEqual(once.current.depth, 1)
    XCTAssertTrue(once.current.region.contains(pointer))

    // A pointer outside the usable area (the status-bar band) zooms toward
    // its nearest point inside it.
    var outside = MouseGrid.Navigation(root: root, screenIndex: 0)
    outside.zoom(toward: CGPoint(x: 10, y: 1020), depth: 1, shape: qwerty, steps: 3)
    XCTAssertEqual(outside.current.region, MouseGrid.cellFrames(of: root, shape: qwerty)[0])
  }

  func testRestartedKeepsTheScreenAndPointerOriginButDropsProgress() {
    var navigation = MouseGrid.Navigation(root: root, screenIndex: 2)
    navigation.pointerOrigin = CGPoint(x: 5, y: 6)
    navigation.drill(into: MouseGrid.cellFrames(of: root, shape: qwerty)[4])
    let restarted = navigation.restarted
    XCTAssertEqual(restarted.root, root)
    XCTAssertEqual(restarted.screenIndex, 2)
    XCTAssertEqual(restarted.current, step(root, 0))
    XCTAssertTrue(restarted.history.isEmpty)
    XCTAssertEqual(restarted.pointerOrigin, CGPoint(x: 5, y: 6))
  }

  // MARK: Initial region

  private let primaryFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private let secondaryFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

  /// Screens with an auto-hidden native menu bar (visible frame = frame), as
  /// when Flash's status bar is on, laid out like `WindowMover.screenLayouts`.
  private func layouts(statusBarMonitor monitor: Config.StatusBar.Monitor)
    -> [WindowScreenLayout]
  {
    [primaryFrame, secondaryFrame].enumerated().map { index, frame in
      WindowScreenLayout(
        id: CGDirectDisplayID(index + 1), frame: frame,
        usableFrame: WindowMover.usableFrame(
          screenFrame: frame, visibleFrame: frame,
          statusBarReservesSpace: WindowMover.shouldReserveStatusBarSpace(
            statusBarVisible: true, monitor: monitor, isMainScreen: index == 0),
          fontSize: 13, fallbackNativeStatusBarHeight: 22))
    }
  }

  private func context(window: CGRect) -> AppContext {
    AppContext(
      bundleIdentifier: "com.example", processID: 1, runningApp: .current,
      frontWindowFrame: window, allScreensFrame: .null)
  }

  func testInitialRegionIsTheFrontWindowScreenBelowTheStatusBar() throws {
    let all = layouts(statusBarMonitor: .all)
    let onSecondary = try XCTUnwrap(
      MouseGrid.initialRegion(
        context: context(window: CGRect(x: 1600, y: 100, width: 800, height: 600)),
        layouts: all, pointer: CGPoint(x: 10, y: 10)))
    XCTAssertEqual(onSecondary.screenIndex, 1)
    XCTAssertEqual(onSecondary.root, CGRect(x: 1440, y: 0, width: 1920, height: 1058))

    let onPrimary = try XCTUnwrap(
      MouseGrid.initialRegion(
        context: context(window: CGRect(x: 100, y: 100, width: 800, height: 600)),
        layouts: all, pointer: nil))
    XCTAssertEqual(onPrimary.screenIndex, 0)
    XCTAssertEqual(onPrimary.root, CGRect(x: 0, y: 0, width: 1440, height: 878))

    // A primary-only bar reserves the band on the main display alone.
    let primaryOnly = layouts(statusBarMonitor: .primary)
    let secondary = try XCTUnwrap(
      MouseGrid.initialRegion(
        context: context(window: CGRect(x: 1600, y: 100, width: 800, height: 600)),
        layouts: primaryOnly, pointer: nil))
    XCTAssertEqual(secondary.root, secondaryFrame)
    let primary = try XCTUnwrap(
      MouseGrid.initialRegion(
        context: context(window: CGRect(x: 100, y: 100, width: 800, height: 600)),
        layouts: primaryOnly, pointer: nil))
    XCTAssertEqual(primary.root, CGRect(x: 0, y: 0, width: 1440, height: 878))
  }

  func testInitialRegionFallsBackToThePointerScreenThenThePrimary() throws {
    let all = layouts(statusBarMonitor: .all)
    let pointerScreen = try XCTUnwrap(
      MouseGrid.initialRegion(context: nil, layouts: all, pointer: CGPoint(x: 2000, y: 500)))
    XCTAssertEqual(pointerScreen.screenIndex, 1)
    let emptyWindow = try XCTUnwrap(
      MouseGrid.initialRegion(
        context: context(window: .null), layouts: all, pointer: CGPoint(x: 2000, y: 500)))
    XCTAssertEqual(emptyWindow.screenIndex, 1)
    let primary = try XCTUnwrap(
      MouseGrid.initialRegion(context: nil, layouts: all, pointer: CGPoint(x: -500, y: 0)))
    XCTAssertEqual(primary.screenIndex, 0)
    XCTAssertNil(MouseGrid.initialRegion(context: nil, layouts: [], pointer: nil))
  }
}

/// The coordinator applies each grid key to the session and the overlay.
final class MouseGridCoordinatorTests: XCTestCase {
  func testGridKeysDrillMoveUndoResetAndCancel() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer {
      delegate.overlay.hide()
      delegate.overlay.orderOut(nil)
      delegate.hintSession = HintSession()
    }
    let root = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    let shape = MouseGrid.Shape.keyboard(Alphabet.gridKeys(layoutName: "qwerty"))
    delegate.hintSession.surface = .grid
    delegate.hintSession.gridShape = shape
    delegate.displayMouseGrid(MouseGrid.Navigation(root: root, screenIndex: 0))
    XCTAssertEqual(delegate.hintSession.hints.map(\.label).joined(), "12345qwertasdfgzxcvb")
    XCTAssertEqual(delegate.overlay.hintKeyRoute, .grid(shape, cursorFollows: false))

    // `t` is the right end of the top letter row.
    delegate.overlayDidGrid(.cell("t", []))
    let t = CGRect(x: 1200, y: 500, width: 300, height: 250)
    XCTAssertEqual(delegate.hintSession.grid?.current, .init(region: t, depth: 1))
    XCTAssertEqual(delegate.hintSession.hints.first?.target.frame.maxY, t.maxY)
    delegate.overlayDidGrid(.move(.left))
    XCTAssertEqual(
      delegate.hintSession.grid?.current.region, t.offsetBy(dx: -300, dy: 0))
    delegate.overlayDidGrid(.centre([]))
    XCTAssertEqual(delegate.hintSession.grid?.current.depth, 2)
    delegate.overlayDidGrid(.back)
    delegate.overlayDidGrid(.back)
    XCTAssertEqual(delegate.hintSession.grid?.current, .init(region: t, depth: 1))
    delegate.overlayDidGrid(.reset)
    XCTAssertEqual(delegate.hintSession.grid?.current, .init(region: root, depth: 0))
    XCTAssertEqual(delegate.hintSession.grid?.history, [])

    delegate.overlayDidGrid(.cancel)
    XCTAssertNil(delegate.hintSession.grid)
    XCTAssertTrue(delegate.hintSession.hints.isEmpty)
  }
}

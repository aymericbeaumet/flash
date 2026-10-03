import AppKit
import XCTest

@testable import flash

/// The band the status bar paints and the band `window_move` reserves are one
/// value, and the focus border never strokes under the bar.
final class StatusBarBandTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 2048, height: 1152)

  /// A snapshot taken while macOS still reserved a 32-pt native menu bar in
  /// the visible frame; the display's measured menu bar is 30 pt.
  private var snapshot: OverlayPanel.ScreenSnapshot {
    OverlayPanel.makeScreenSnapshot(
      screens: [
        (
          scale: 2, frame: screen, visibleFrame: CGRect(x: 0, y: 0, width: 2048, height: 1120),
          notch: nil
        )
      ],
      nativeStatusBarFallbackHeight: 30,
      nativeMenuBarHeights: [(screenFrame: screen, height: 30)])
  }

  /// Flash auto-hides the native menu bar once the bar is enabled, so the
  /// live visible frame stops reserving it while the bar is still painted
  /// from the snapshot. A maximized slot must still end exactly at the bar's
  /// bottom edge, or its top slides under the bar with the focus stroke.
  func testWindowMoveReservesExactlyTheBandTheBarPaints() {
    let bar = OverlayPanel.statusBarFrame(
      screenFrame: screen, height: snapshot.statusBarHeight(forScreenFrame: screen),
      panelFrame: screen)
    XCTAssertEqual(bar, CGRect(x: 0, y: 1120, width: 2048, height: 32))
    let layouts = WindowMover.screenLayouts(
      screens: [(id: 1, frame: screen, visibleFrame: screen)], snapshot: snapshot,
      statusBarReservesSpace: true, statusBarMonitor: .primary)
    XCTAssertEqual(layouts.map(\.usableFrame), [CGRect(x: 0, y: 0, width: 2048, height: 1120)])
    XCTAssertEqual(
      WindowMover.rectFor(position: .maximized, in: layouts[0].usableFrame).maxY, bar.minY)
  }

  /// Without a bar on a display, its slots follow the live visible frame.
  func testDisplaysWithoutTheBarKeepTheirLiveVisibleFrame() {
    let external = CGRect(x: 2048, y: 0, width: 1920, height: 1080)
    let externalVisible = CGRect(x: 2048, y: 0, width: 1920, height: 1055)
    let layouts = WindowMover.screenLayouts(
      screens: [
        (id: 1, frame: screen, visibleFrame: screen),
        (id: 2, frame: external, visibleFrame: externalVisible),
      ],
      snapshot: snapshot, statusBarReservesSpace: true, statusBarMonitor: .primary)
    XCTAssertEqual(layouts.map(\.usableFrame).last, externalVisible)
    XCTAssertEqual(
      WindowMover.screenLayouts(
        screens: [(id: 1, frame: screen, visibleFrame: screen)], snapshot: snapshot,
        statusBarReservesSpace: false, statusBarMonitor: .all
      ).map(\.usableFrame), [screen])
  }

  /// A window running under the bar (dragged there, or zoomed by the app to
  /// the whole visible frame) is outlined only below it; one flush with or
  /// clear of the bar, or on another display, is outlined whole.
  func testBorderTargetStopsAtTheBottomOfABarItRunsUnder() {
    let band = CGRect(x: 0, y: 1120, width: 2048, height: 32)
    let under = CGRect(x: 100, y: 200, width: 900, height: 952)
    XCTAssertEqual(
      OverlayPanel.activeWindowBorderTarget(under, clearing: [band]),
      CGRect(x: 100, y: 200, width: 900, height: 920))
    let flush = CGRect(x: 0, y: 0, width: 2048, height: 1120)
    XCTAssertEqual(OverlayPanel.activeWindowBorderTarget(flush, clearing: [band]), flush)
    let elsewhere = CGRect(x: 2100, y: 0, width: 1800, height: 1152)
    XCTAssertEqual(OverlayPanel.activeWindowBorderTarget(elsewhere, clearing: [band]), elsewhere)
    XCTAssertEqual(OverlayPanel.activeWindowBorderTarget(under, clearing: []), under)
    let hidden = CGRect(x: 100, y: 1125, width: 300, height: 20)
    XCTAssertEqual(
      OverlayPanel.activeWindowBorderTarget(hidden, clearing: [band]).height, 0,
      "a window wholly under the bar has nothing to outline")

    let local = OverlayPanel.activeWindowBorderLocalRect(
      targetFrame: OverlayPanel.activeWindowBorderTarget(under, clearing: [band]),
      panelFrame: screen, lineWidth: 2)
    XCTAssertLessThanOrEqual(local.maxY + 1, band.minY, "the stroke's outer edge clears the bar")
  }

  /// The panel outlines the focused window against the bar it actually
  /// painted, and re-strokes a shown border when the bar appears or moves.
  func testFocusBorderIsReStrokedClearOfTheBarWhenTheBarIsPainted() throws {
    let panel = OverlayPanel()
    let primary = try XCTUnwrap(
      OverlayPanel.currentScreenSnapshot().mainFrame, "needs a display at the origin")
    let window = CGRect(x: primary.minX, y: primary.minY, width: 600, height: primary.height)
    panel.setActiveWindowBorder(around: window)
    func strokeTop() throws -> CGFloat {
      let path = try XCTUnwrap(panel.activeWindowBorderLayer.path)
      return path.boundingBox.maxY + panel.activeWindowBorderLayer.lineWidth / 2 + panel.frame.minY
    }
    XCTAssertGreaterThan(
      try strokeTop(), primary.maxY - 2, "no bar yet: the window is outlined whole")

    let snapshot = OverlayPanel.makeScreenSnapshot(
      screens: [(scale: 2, frame: primary, visibleFrame: primary, notch: nil)],
      nativeStatusBarFallbackHeight: 30, nativeMenuBarHeights: [(screenFrame: primary, height: 30)])
    panel.setModeSurface(
      .init(label: "NORMAL", style: .normal, barVisible: true, capturesInput: false),
      render: false)
    panel.configureModeBadge(panelFrame: panel.frame, screenSnapshot: snapshot)
    XCTAssertLessThanOrEqual(try strokeTop(), primary.maxY - 30)
    XCTAssertEqual(panel.activeWindowBorderFrame, window, "the tracked frame stays the window's")
    panel.setActiveWindowBorder(around: nil)
  }
}

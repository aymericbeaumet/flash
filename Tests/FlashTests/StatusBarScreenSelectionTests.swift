import AppKit
import XCTest

@testable import flash

final class StatusBarScreenSelectionTests: XCTestCase {
  func testPrimaryScreenSnapshotIgnoresSecondaryScreenOrder() {
    let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let primaryVisible = CGRect(x: 0, y: 0, width: 1728, height: 1079)
    let secondary = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    let secondaryVisible = CGRect(x: -1920, y: 100, width: 1920, height: 1055)
    let snapshot = OverlayPanel.makeScreenSnapshot(
      screens: [
        (scale: 1, frame: secondary, visibleFrame: secondaryVisible, notch: nil),
        (scale: 2, frame: primary, visibleFrame: primaryVisible, notch: nil),
      ], nativeStatusBarFallbackHeight: 25)
    XCTAssertEqual(snapshot.mainFrame, primary)
    XCTAssertEqual(snapshot.mainVisibleFrame, primaryVisible)
    XCTAssertEqual(snapshot.mainScale, 2)
    XCTAssertEqual(snapshot.unionFrame, primary.union(secondary))
  }

  func testPrimaryOnlyRenderStaysOnOriginScreenAndRemovesSecondaryBars() {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer { panel.orderOut(nil) }
    let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let secondary = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    let snapshot = OverlayPanel.makeScreenSnapshot(
      screens: [
        (scale: 1, frame: secondary, visibleFrame: secondary, notch: nil),
        (scale: 2, frame: primary, visibleFrame: primary, notch: nil),
      ], nativeStatusBarFallbackHeight: 25)
    panel.statusBarMonitor = .all
    panel.configureModeBadge(panelFrame: snapshot.unionFrame, screenSnapshot: snapshot)
    XCTAssertEqual(panel.secondaryStatusBars.count, 1)
    panel.statusBarMonitor = .primary
    panel.configureModeBadge(panelFrame: snapshot.unionFrame, screenSnapshot: snapshot)
    XCTAssertTrue(panel.secondaryStatusBars.isEmpty)
    XCTAssertEqual(panel.modeBadgeLayer.frame.minX + snapshot.unionFrame.minX, primary.minX)
    XCTAssertEqual(panel.modeBadgeLayer.frame.width, primary.width)
    XCTAssertEqual(panel.modeBadgeLayer.frame.maxY + snapshot.unionFrame.minY, primary.maxY)
  }
}

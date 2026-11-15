import AppKit
import XCTest

@testable import flash

/// The status bar takes the native menu bar's place, so a full-screen app
/// covers it the way it covers the menu bar: the bar windows stay off native
/// full-screen Spaces, and the bar hides while the frontmost app hides the
/// menu bar outright.
final class MenuBarPresentationTests: XCTestCase {
  func testOnlyAnOutrightHiddenMenuBarHidesTheStatusBar() {
    XCTAssertTrue(MenuBarPresentationObserver.hidesMenuBar([.hideDock, .hideMenuBar]))
    XCTAssertTrue(
      MenuBarPresentationObserver.hidesMenuBar([.fullScreen, .hideDock, .hideMenuBar]))
    XCTAssertFalse(MenuBarPresentationObserver.hidesMenuBar([]))
    XCTAssertFalse(MenuBarPresentationObserver.hidesMenuBar([.hideDock]))
    XCTAssertFalse(MenuBarPresentationObserver.hidesMenuBar([.autoHideDock, .autoHideMenuBar]))
    // Native full screen auto-hides the menu bar; its Space leaves the bar
    // windows out instead, display by display.
    XCTAssertFalse(
      MenuBarPresentationObserver.hidesMenuBar([.fullScreen, .autoHideDock, .autoHideMenuBar]))
  }

  func testTheBarWindowsStayOffFullScreenSpaces() {
    _ = NSApplication.shared
    let bar = StatusBarWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
    let click = StatusBarClickPanel()
    defer {
      bar.close()
      click.close()
    }
    for window in [bar, click] as [NSWindow] {
      XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
      XCTAssertFalse(
        window.collectionBehavior.contains(.fullScreenAuxiliary),
        "a full-screen app covers the bar and receives clicks in its band")
    }
  }

  func testAnAppHidingTheMenuBarHidesTheBarButKeepsItsReservedBand() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    delegate.statusBarVisible = true
    defer {
      delegate.statusBarVisible = false
      delegate.applyModeOverlay()
      delegate.overlay.orderOut(nil)
    }
    delegate.applyModeOverlay()
    XCTAssertTrue(delegate.overlay.modeSurface.barVisible)
    XCTAssertTrue(delegate.overlay.statusBarWindow.isVisible)

    delegate.frontmostMenuBarPresentationDidChange(hidden: true)
    XCTAssertFalse(delegate.overlay.modeSurface.barVisible)
    XCTAssertFalse(delegate.overlay.statusBarWindow.isVisible)
    XCTAssertTrue(delegate.overlay.statusBarClickWindows.isEmpty)
    XCTAssertTrue(delegate.statusBarVisible, "windows keep the band the bar reserves")

    delegate.frontmostMenuBarPresentationDidChange(hidden: false)
    XCTAssertTrue(delegate.overlay.modeSurface.barVisible)
    XCTAssertTrue(delegate.overlay.statusBarWindow.isVisible)
  }

  /// Every key reaches an app that hides the menu bar, with no stop in
  /// Flash: the tap is switched off, no chord is registered and the overlay
  /// captures nothing. The mode is left alone, so NORMAL resumes with it
  /// when the app leaves.
  func testAnAppHidingTheMenuBarOwnsTheKeyboardWithoutAModeChange() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    delegate.overlay.keyboardCaptureActive = true
    let tap = KeyboardCaptureTap(shouldSwallow: { _ in .pass }, handle: { _ in })
    delegate.keyboardCaptureTap = tap
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    defer {
      delegate.frontmostMenuBarPresentationDidChange(hidden: false)
      delegate.overlay.orderOut(nil)
    }
    delegate.applyModeOverlay()
    XCTAssertEqual(delegate.modeStore.mode, .normal)
    XCTAssertTrue(delegate.overlay.modeSurface.capturesInput)
    XCTAssertTrue(delegate.shouldCaptureNormalModeInput)

    delegate.frontmostMenuBarPresentationDidChange(hidden: true)
    XCTAssertTrue(tap.isSuspended)
    XCTAssertTrue(delegate.mappings.isSuspended)
    XCTAssertFalse(delegate.overlay.modeSurface.capturesInput)
    XCTAssertFalse(delegate.shouldCaptureNormalModeInput)
    XCTAssertEqual(delegate.modeStore.mode, .normal, "suspension is not a mode change")

    delegate.frontmostMenuBarPresentationDidChange(hidden: false)
    XCTAssertFalse(tap.isSuspended)
    XCTAssertFalse(delegate.mappings.isSuspended)
    XCTAssertTrue(delegate.overlay.modeSurface.capturesInput)
    XCTAssertTrue(delegate.shouldCaptureNormalModeInput)
  }

  /// A suspended tap stays off: a disable notice arriving after Flash
  /// switched it off must not switch it back on.
  func testOnlyALiveTapReenablesAfterTheSystemDisablesIt() {
    XCTAssertTrue(KeyboardCaptureTap.reenablesAfterSystemDisable(suspended: false))
    XCTAssertFalse(KeyboardCaptureTap.reenablesAfterSystemDisable(suspended: true))
  }
}

import AppKit
import XCTest

@testable import flash

/// Flash steps aside for a full-screen app, native or a covering window that
/// hides the menu bar: the bar and the focus border are off screen, alerts
/// wait for it to leave, and it owns the keyboard. The mode is left alone, so
/// everything resumes with the app's departure.
final class FullScreenPresentationTests: XCTestCase {
  private static let coveringWindow: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]
  private static let nativeFullScreen: NSApplication.PresentationOptions = [
    .fullScreen, .autoHideDock, .autoHideMenuBar,
  ]

  func testFullScreenIsAnyTakeoverOfTheMenuBar() {
    XCTAssertTrue(FullScreenPresentationObserver.isFullScreen(Self.coveringWindow))
    XCTAssertTrue(FullScreenPresentationObserver.isFullScreen(Self.nativeFullScreen))
    // Another process may see native full screen only as its auto-hide.
    XCTAssertTrue(FullScreenPresentationObserver.isFullScreen([.autoHideDock, .autoHideMenuBar]))
    XCTAssertFalse(FullScreenPresentationObserver.isFullScreen([]))
    XCTAssertFalse(FullScreenPresentationObserver.isFullScreen([.hideDock]))
    XCTAssertFalse(FullScreenPresentationObserver.isFullScreen([.autoHideDock]))
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

  func testAFullScreenAppHidesTheBarButKeepsItsReservedBand() {
    let delegate = makeDelegate()
    delegate.statusBarVisible = true
    defer {
      delegate.statusBarVisible = false
      delegate.applyModeOverlay()
      delegate.overlay.orderOut(nil)
    }
    delegate.applyModeOverlay()
    XCTAssertTrue(delegate.overlay.modeSurface.barVisible)
    XCTAssertTrue(delegate.overlay.statusBarWindow.isVisible)

    for options in [Self.coveringWindow, Self.nativeFullScreen] {
      delegate.frontmostPresentationDidChange(options)
      XCTAssertFalse(delegate.overlay.modeSurface.barVisible)
      XCTAssertFalse(delegate.overlay.statusBarWindow.isVisible)
      XCTAssertTrue(delegate.overlay.statusBarClickWindows.isEmpty)
      XCTAssertTrue(delegate.statusBarVisible, "windows keep the band the bar reserves")

      delegate.frontmostPresentationDidChange([])
      XCTAssertTrue(delegate.overlay.modeSurface.barVisible)
      XCTAssertTrue(delegate.overlay.statusBarWindow.isVisible)
    }
  }

  /// Every key reaches a full-screen app with no stop in Flash: the tap is
  /// switched off, no chord is registered and the overlay captures nothing.
  func testAFullScreenAppOwnsTheKeyboardWithoutAModeChange() {
    let delegate = makeDelegate()
    delegate.overlay.keyboardCaptureActive = true
    let tap = KeyboardCaptureTap(shouldSwallow: { _ in .pass }, handle: { _ in })
    delegate.keyboardCaptureTap = tap
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    defer {
      delegate.frontmostPresentationDidChange([])
      delegate.overlay.orderOut(nil)
    }
    delegate.applyModeOverlay()
    XCTAssertEqual(delegate.modeStore.mode, .normal)
    XCTAssertTrue(delegate.overlay.modeSurface.capturesInput)
    XCTAssertTrue(delegate.shouldCaptureNormalModeInput)

    delegate.frontmostPresentationDidChange(Self.nativeFullScreen)
    XCTAssertTrue(tap.isSuspended)
    XCTAssertTrue(delegate.mappings.isSuspended)
    XCTAssertFalse(delegate.overlay.modeSurface.capturesInput)
    XCTAssertFalse(delegate.shouldCaptureNormalModeInput)
    XCTAssertEqual(delegate.modeStore.mode, .normal, "suspension is not a mode change")

    delegate.frontmostPresentationDidChange([])
    XCTAssertFalse(tap.isSuspended)
    XCTAssertFalse(delegate.mappings.isSuspended)
    XCTAssertTrue(delegate.overlay.modeSurface.capturesInput)
    XCTAssertTrue(delegate.shouldCaptureNormalModeInput)
  }

  func testAFullScreenAppHidesTheFocusBorder() {
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true, modeBadgeEnabled: true, hasHints: false, sessionActive: true,
        fullScreenAppFrontmost: false))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true, modeBadgeEnabled: true, hasHints: false, sessionActive: true,
        fullScreenAppFrontmost: true))

    let delegate = makeDelegate()
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { _, _, _ in }
    defer {
      delegate.overlay.setActiveWindowBorder(around: nil)
      delegate.overlay.orderOut(nil)
    }
    delegate.overlay.setActiveWindowBorder(around: CGRect(x: 100, y: 100, width: 400, height: 300))
    XCTAssertNotNil(delegate.overlay.activeWindowBorderFrame)
    delegate.frontmostPresentationDidChange(Self.coveringWindow)
    XCTAssertNil(delegate.overlay.activeWindowBorderFrame)
  }

  /// An alert waits for the full-screen app to leave, the latest one
  /// winning; a confirmation, which owns the keyboard for the command that
  /// asked, shows at once.
  func testAlertsWaitForAFullScreenAppToLeave() {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer {
      panel.dismissAlert()
      panel.orderOut(nil)
    }
    panel.fullScreenAppFrontmost = true
    panel.displayAlert(.message("first"))
    panel.displayAlert(.message("second", style: .warning))
    XCTAssertNil(panel.toast)
    XCTAssertEqual(panel.heldAlert?.title, "second")

    panel.displayAlert(.confirmation("Quit?"), heldWhileFullScreen: false)
    XCTAssertNotNil(panel.toast)
    panel.dismissAlert()

    panel.fullScreenAppFrontmost = false
    XCTAssertNotNil(panel.toast)
    XCTAssertNil(panel.heldAlert)
  }

  /// Native full screen (a browser's video, the green button) shows no
  /// presentation option to another process: the focused window's
  /// `AXFullScreen`, read again on each activation, Space change and resize,
  /// is what says so. Either signal alone makes the app full screen.
  func testNativeFullScreenStepsAsideLikeACoveringWindow() {
    let delegate = makeDelegate()
    delegate.statusBarVisible = true
    var reads: [(pid: pid_t, done: (Bool?) -> Void)] = []
    delegate.focusedWindowFullScreenReader = { pid, done in reads.append((pid, done)) }
    defer {
      delegate.statusBarVisible = false
      delegate.applyModeOverlay()
      delegate.overlay.orderOut(nil)
    }
    delegate.applyModeOverlay()

    delegate.refreshNativeFullScreen(pid: 42, reason: "space_changed")
    XCTAssertEqual(reads.map(\.pid), [42])
    reads[0].done(true)
    XCTAssertTrue(delegate.frontmostAppIsFullScreen)
    XCTAssertFalse(delegate.overlay.modeSurface.barVisible)
    XCTAssertTrue(delegate.mappings.isSuspended)

    // Still full screen while either signal holds.
    delegate.frontmostPresentationDidChange(Self.coveringWindow)
    delegate.refreshNativeFullScreen(pid: 42, reason: "window_resized")
    reads[1].done(false)
    XCTAssertTrue(delegate.frontmostAppIsFullScreen)
    delegate.frontmostPresentationDidChange([])
    XCTAssertFalse(delegate.frontmostAppIsFullScreen)
    XCTAssertTrue(delegate.overlay.modeSurface.barVisible)
    XCTAssertFalse(delegate.mappings.isSuspended)

    // A read that a newer request superseded changes nothing.
    delegate.refreshNativeFullScreen(pid: 42, reason: "app_activated")
    delegate.refreshNativeFullScreen(pid: 7, reason: "app_activated")
    reads[3].done(false)
    reads[2].done(true)
    XCTAssertFalse(delegate.frontmostAppIsFullScreen, "the superseded read is dropped")

    // No frontmost app to read: nothing is full screen.
    delegate.refreshNativeFullScreen(pid: 42, reason: "space_changed")
    reads[4].done(true)
    XCTAssertTrue(delegate.frontmostAppIsFullScreen)
    delegate.refreshNativeFullScreen(pid: nil, reason: "space_changed")
    XCTAssertEqual(reads.count, 5)
    XCTAssertFalse(delegate.frontmostAppIsFullScreen)
  }

  /// A resize reads `AXFullScreen` only when it can change it: into a whole
  /// display's frame, or any resize while full screen.
  func testOnlyAResizeThatCanChangeNativeFullScreenReadsIt() {
    let screens = [
      CGRect(x: 0, y: 0, width: 1920, height: 1080),
      CGRect(x: 1920, y: 0, width: 1440, height: 900),
    ]
    XCTAssertTrue(
      AppDelegate.resizeMayChangeNativeFullScreen(
        frame: CGRect(x: 1920, y: 0, width: 1440, height: 900), screens: screens,
        fullScreen: false))
    XCTAssertTrue(
      AppDelegate.resizeMayChangeNativeFullScreen(
        frame: CGRect(x: 0.5, y: 0, width: 1919.5, height: 1080), screens: screens,
        fullScreen: false))
    XCTAssertFalse(
      AppDelegate.resizeMayChangeNativeFullScreen(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1050), screens: screens,
        fullScreen: false))
    XCTAssertFalse(
      AppDelegate.resizeMayChangeNativeFullScreen(
        frame: nil, screens: screens, fullScreen: false))
    XCTAssertTrue(
      AppDelegate.resizeMayChangeNativeFullScreen(
        frame: CGRect(x: 100, y: 100, width: 800, height: 600), screens: screens,
        fullScreen: true))
  }

  func testOnlyALiveTapReenablesAfterTheSystemDisablesIt() {
    XCTAssertTrue(KeyboardCaptureTap.reenablesAfterSystemDisable(suspended: false))
    XCTAssertFalse(KeyboardCaptureTap.reenablesAfterSystemDisable(suspended: true))
  }

  private func makeDelegate() -> AppDelegate {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    return delegate
  }
}

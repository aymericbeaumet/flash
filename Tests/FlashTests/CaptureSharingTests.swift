import AppKit
import XCTest

@testable import flash

/// `[app] hide_from_capture`: every window Flash draws asks the window server
/// to stay out of screenshots, recordings and screen sharing
/// (`NSWindow.sharingType = .none`). Each covered window takes it, a reload
/// re-applies it to the windows already up, and a window created later takes
/// it on creation.
final class CaptureSharingTests: XCTestCase {
  func testTheKeyIsABooleanOffByDefault() {
    XCTAssertFalse(Config().app.hideFromCapture)
    XCTAssertFalse(Config.default.app.hideFromCapture)
    let config = ConfigLoader.parse("[app]\nhide_from_capture = true")
    XCTAssertEqual(config.diagnostics, [])
    XCTAssertTrue(config.app.hideFromCapture)
    for invalid in ["\"hide\"", "1", "\"true\""] {
      let rejected = ConfigLoader.parse("[app]\nhide_from_capture = \(invalid)")
      XCTAssertFalse(rejected.app.hideFromCapture, invalid)
      XCTAssertTrue(
        rejected.diagnostics.contains {
          $0.message.contains("app.hide_from_capture must be true or false")
        }, invalid)
    }
  }

  /// No alias for the retired `[overlay] screen_capture` spelling.
  func testTheOldOverlayKeyIsRejected() {
    let old = ConfigLoader.parse("[overlay]\nscreen_capture = \"hide\"")
    XCTAssertFalse(old.app.hideFromCapture)
    XCTAssertTrue(
      old.diagnostics.contains {
        $0.message.contains("overlay") && $0.message.contains("screen_capture")
      }, "\(old.diagnostics.map(\.message))")
  }

  func testEveryOverlayWindowTakesItAndAReloadReappliesIt() {
    let overlay = OverlayPanel()
    overlay.syncStatusBarClickWindows(
      bandRects: [CGRect(x: 0, y: 900, width: 800, height: 24)], links: [])
    defer { overlay.hideStatusBarClickWindows() }
    XCTAssertEqual(overlay.sharingType, .readOnly)
    XCTAssertEqual(overlay.statusBarClickWindows.map(\.sharingType), [.readOnly])

    // A reload turns it on: the hints, grid, command line, flashlight and
    // alerts (the overlay panel), the bar, its click windows and the popups.
    overlay.hidesFromCapture = true
    XCTAssertEqual(overlay.sharingType, .none)
    XCTAssertEqual(overlay.statusBarWindow.sharingType, .none)
    XCTAssertEqual(overlay.statusBarClickWindows.map(\.sharingType), [.none])
    XCTAssertEqual(overlay.statusPopupController.sharingType, .none)

    // A click window created later takes it on creation.
    overlay.syncStatusBarClickWindows(
      bandRects: [
        CGRect(x: 0, y: 900, width: 800, height: 24),
        CGRect(x: 800, y: 900, width: 800, height: 24),
      ], links: [])
    XCTAssertEqual(overlay.statusBarClickWindows.map(\.sharingType), [.none, .none])
  }

  /// The window server keeps a live window out of capture once asked: a
  /// later `.readOnly` reads back as `.none` (macOS 26). Turning the key off
  /// therefore reaches the windows created from then on, the popup panel
  /// before its first use among them; the rest wait for the next launch.
  func testTurningItOffReachesWindowsCreatedFromThenOn() {
    let overlay = OverlayPanel()
    overlay.hidesFromCapture = true
    overlay.hidesFromCapture = false
    XCTAssertEqual(overlay.statusPopupController.sharingType, .readOnly)
    overlay.syncStatusBarClickWindows(
      bandRects: [CGRect(x: 0, y: 900, width: 800, height: 24)], links: [])
    defer { overlay.hideStatusBarClickWindows() }
    XCTAssertEqual(overlay.statusBarClickWindows.map(\.sharingType), [.readOnly])
  }

  func testWidgetsTakeTheAppKeyOrTheirOwn() {
    let display = WindowScreenLayout(
      id: 7, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      usableFrame: CGRect(x: 0, y: 0, width: 1440, height: 870))
    let controller = WidgetController(
      setVisible: { _, _ in }, screenLayouts: { _, _ in [display] })
    defer { controller.stop() }
    var own = Config.Widget()
    own.hideFromCapture = true
    let widgets = ["own": own, "plain": Config.Widget()]
    func hidden() -> [String: Bool] {
      let windows = controller.diagnostics()["windows"] as? [[String: Any]] ?? []
      return Dictionary(
        uniqueKeysWithValues: windows.compactMap { window in
          (window["widget"] as? String).map { ($0, window["hidden_from_capture"] as? Bool) }
        }
      ).compactMapValues { $0 }
    }
    controller.apply(
      widgets: widgets, statusBarReservesSpace: false, statusBarMonitor: .all,
      hideFromCapture: false)
    XCTAssertEqual(hidden(), ["own": true, "plain": false])
    controller.apply(
      widgets: widgets, statusBarReservesSpace: false, statusBarMonitor: .all,
      hideFromCapture: true)
    XCTAssertEqual(hidden(), ["own": true, "plain": true], "a reload re-applies it")
  }

  func testTheAboutWindowTakesItWhenMadeAndOnReload() {
    let hidden = StatusItemController()
    hidden.hidesFromCapture = true
    // Never closed: closing About hands the app switcher back
    // (`aboutPanelWillClose`), which is no test's business.
    let made = hidden.aboutWindow()
    XCTAssertEqual(made.sharingType, .none)
    XCTAssertFalse(made.isVisible, "made, never shown")

    let controller = StatusItemController()
    let window = controller.aboutWindow()
    XCTAssertEqual(window.sharingType, .readOnly)
    controller.hidesFromCapture = true
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertTrue(controller.aboutWindow() === window, "one About window")
  }

  /// What a config load or reload calls: the overlay's windows and About.
  func testTheResidentAppliesItToEverySurfaceItOwns() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.applyCaptureSharing(hidden: true)
    XCTAssertTrue(delegate.overlay.hidesFromCapture)
    XCTAssertTrue(delegate.statusItemController.hidesFromCapture)
    XCTAssertEqual(delegate.overlay.sharingType, .none)
    XCTAssertEqual(delegate.overlay.statusBarWindow.sharingType, .none)
  }
}

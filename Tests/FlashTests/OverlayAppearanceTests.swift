import AppKit
import XCTest

@testable import flash

/// `[overlay.dark]`, `[overlay] click_feedback` and `[overlay] screen_capture`.
final class OverlayAppearanceTests: XCTestCase {
  func testAnEmptyDarkTableDrawsTheLightColours() {
    let overlay = Config().overlay
    XCTAssertEqual(overlay.dark, .init())
    XCTAssertEqual(overlay.hintColors(dark: true), overlay.hintColors(dark: false))
    XCTAssertEqual(
      overlay.hintColors(dark: false),
      Config.HintColors(
        fg: "#302505", bgTop: "#FFF785", bgBottom: "#FFC542", border: "#E3BE23",
        importantFG: "#ECEFF4", importantBGTop: "#BF616A", importantBGBottom: "#5C3940",
        importantBorder: "#BF616A"))
  }

  /// Each dark key replaces only its own light counterpart, and only under
  /// a dark appearance.
  func testDarkKeysOverrideOneAtATime() throws {
    let config = ConfigLoader.parse(
      """
      [overlay]
      hint_fg = "#111111"
      hint_bg_top = "#222222"

      [overlay.dark]
      hint_fg = "#EEEEEE"
      important_hint_border = "#12345678"
      """)
    XCTAssertEqual(config.diagnostics, [])
    let light = config.overlay.hintColors(dark: false)
    let dark = config.overlay.hintColors(dark: true)
    XCTAssertEqual(light.fg, "#111111")
    XCTAssertEqual(dark.fg, "#EEEEEE")
    XCTAssertEqual(dark.bgTop, "#222222", "unset dark keys keep the [overlay] colour")
    XCTAssertEqual(light.importantBorder, "#BF616A")
    XCTAssertEqual(dark.importantBorder, "#12345678")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    let darkJSON = try XCTUnwrap(
      (json["overlay"] as? [String: Any])?["dark"] as? [String: String])
    XCTAssertEqual(darkJSON["hint_fg"], "#EEEEEE")
    XCTAssertEqual(darkJSON["hint_bg_top"], "")
    XCTAssertEqual(darkJSON.count, 8)
  }

  func testDarkKeysAreValidatedAndUnknownOnesReported() {
    let invalid = ConfigLoader.parse("[overlay.dark]\nhint_fg = \"salmon\"")
    XCTAssertEqual(invalid.overlay.dark.hintFG, "")
    XCTAssertTrue(
      invalid.diagnostics.contains { $0.message.contains("overlay.dark.hint_fg") },
      "\(invalid.diagnostics.map(\.message))")
    let typo = ConfigLoader.parse("[overlay.dark]\nhint_fgg = \"#FFFFFF\"")
    XCTAssertTrue(
      typo.diagnostics.contains {
        $0.message.contains("unknown config key 'overlay.dark.hint_fgg'")
          && $0.message.contains("hint_fg")
      }, "\(typo.diagnostics.map(\.message))")
    let notATable = ConfigLoader.parse("[overlay]\ndark = \"#000000\"")
    XCTAssertTrue(
      notATable.diagnostics.contains { $0.message.contains("[overlay.dark] must be a table") },
      "\(notATable.diagnostics.map(\.message))")
    XCTAssertEqual(
      ConfigLoader.parse("[overlay.dark]\nhint_border = \"\"").diagnostics, [],
      "empty keeps the light colour")
  }

  func testAppearanceIsDarkOnlyForDarkAppearances() throws {
    XCTAssertTrue(AppearanceObserver.isDark(try XCTUnwrap(NSAppearance(named: .darkAqua))))
    XCTAssertTrue(
      AppearanceObserver.isDark(
        try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))))
    XCTAssertFalse(AppearanceObserver.isDark(try XCTUnwrap(NSAppearance(named: .aqua))))
    XCTAssertFalse(AppearanceObserver.isDark(try XCTUnwrap(NSAppearance(named: .vibrantLight))))
  }

  func testTheOverlayDrawsWithTheCurrentAppearancesColours() {
    let overlay = OverlayPanel()
    var config = Config.Overlay()
    config.dark.hintBGTop = "#000000"
    overlay.overlayConfig = config
    XCTAssertEqual(overlay.hintColors.bgTop, "#FFF785")
    overlay.darkAppearance = true
    XCTAssertEqual(overlay.hintColors.bgTop, "#000000")
  }

  func testClickFeedbackParsesAndResolves() throws {
    XCTAssertFalse(Config().overlay.clickFeedback, "off by default")
    let config = ConfigLoader.parse("[overlay]\nclick_feedback = true")
    XCTAssertEqual(config.diagnostics, [])
    XCTAssertTrue(config.overlay.clickFeedback)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    XCTAssertEqual((json["overlay"] as? [String: Any])?["click_feedback"] as? Bool, true)
    let invalid = ConfigLoader.parse("[overlay]\nclick_feedback = \"yes\"")
    XCTAssertFalse(invalid.overlay.clickFeedback)
    XCTAssertTrue(
      invalid.diagnostics.contains {
        $0.message.contains("overlay.click_feedback must be true or false")
      })
  }

  /// The ring is short and explicit: it never outlasts its budget.
  func testClickFeedbackRingIsAShortExplicitAnimation() {
    XCTAssertLessThanOrEqual(OverlayPanel.clickFeedbackDuration, 0.25)
    let animation = OverlayPanel.clickFeedbackAnimation()
    XCTAssertEqual(animation.duration, OverlayPanel.clickFeedbackDuration)
    XCTAssertFalse(animation.isRemovedOnCompletion)
    XCTAssertEqual(
      Set((animation.animations ?? []).compactMap { ($0 as? CABasicAnimation)?.keyPath }),
      ["transform.scale", "opacity"])
  }

  func testScreenCaptureParsesAndResolves() throws {
    XCTAssertEqual(Config().overlay.screenCapture, .show)
    let config = ConfigLoader.parse("[overlay]\nscreen_capture = \"hide\"")
    XCTAssertEqual(config.diagnostics, [])
    XCTAssertEqual(config.overlay.screenCapture, .hide)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    XCTAssertEqual((json["overlay"] as? [String: Any])?["screen_capture"] as? String, "hide")
    for invalid in ["\"none\"", "\"Hide\"", "false"] {
      let rejected = ConfigLoader.parse("[overlay]\nscreen_capture = \(invalid)")
      XCTAssertEqual(rejected.overlay.screenCapture, .show, invalid)
      XCTAssertTrue(
        rejected.diagnostics.contains {
          $0.message.contains("overlay.screen_capture must be \"show\" or \"hide\"")
        }, invalid)
    }
  }

  func testScreenCaptureSetsEveryFlashSurfacesSharingType() {
    XCTAssertEqual(ScreenCaptureVisibility.show.sharingType, .readOnly)
    XCTAssertEqual(ScreenCaptureVisibility.hide.sharingType, .none)
    let overlay = OverlayPanel()
    var config = Config.Overlay()
    config.screenCapture = .hide
    overlay.overlayConfig = config
    XCTAssertEqual(overlay.sharingType, .none)
    XCTAssertEqual(overlay.statusBarWindow.sharingType, .none)
    XCTAssertEqual(overlay.statusPopupController.sharingType, .none)
    // A click window created later takes the setting on creation.
    overlay.syncStatusBarClickWindows(
      bandRects: [CGRect(x: 0, y: 900, width: 800, height: 24)], links: [])
    XCTAssertEqual(overlay.statusBarClickWindows.map(\.sharingType), [.none])
    overlay.hideStatusBarClickWindows()
    // The window server keeps a live window out of capture once asked (a
    // later `.readOnly` reads back as `.none`), so only a window it has not
    // created yet, like the deferred popup panel, shows the way back.
    config.screenCapture = .show
    overlay.overlayConfig = config
    XCTAssertEqual(overlay.statusPopupController.sharingType, .readOnly)
  }
}

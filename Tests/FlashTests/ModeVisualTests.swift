import AppKit
import XCTest

@testable import flash

final class ModeVisualTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testNormalPillUsesDarkTextOnGreenFill() {
    let panel = OverlayPanel()
    panel.modeBadgeStyle = .normal
    let palette = panel.modeBadgePalette()
    XCTAssertEqual(palette.bottomCG, OverlayPanel.nordAuroraGreenCG)
    XCTAssertEqual(palette.foregroundCG, OverlayPanel.nordPolarNight0CG)
    XCTAssertNotEqual(palette.topCG, palette.bottomCG)
  }

  func testAllActiveModeBordersHaveEqualWeightAndGlow() {
    for (mode, color) in [
      (OverlayModeBadgeStyle.normal, OverlayPanel.nordAuroraGreenCG),
      (.command, OverlayPanel.nordAuroraPurpleCG), (.terminal, OverlayPanel.nordFrost2CG),
    ] {
      let style = AppDelegate.activeWindowBorderStyle(for: mode)
      XCTAssertEqual(style.color, color)
      XCTAssertEqual(style.lineWidth, 2)
      XCTAssertTrue(style.glow)
      let configured = AppDelegate.activeWindowBorderStyle(for: mode, sizeOverride: 4)
      XCTAssertEqual(configured.lineWidth, 4)
      XCTAssertTrue(configured.glow)
    }
  }

  func testPassthroughNeverShowsABorderEvenWithConfiguredOverrides() {
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true, modeBadgeEnabled: true, modeStyle: .passthrough,
        hasHints: false, sessionActive: true))
    let style = AppDelegate.activeWindowBorderStyle(
      for: .passthrough, sizeOverride: 4, colorOverride: NSColor.red.cgColor)
    XCTAssertEqual(style.lineWidth, 0)
    XCTAssertFalse(style.glow)
  }

  func testReturningToPassthroughClearsStrokeAndInvalidatesPendingGeometry() {
    let delegate = delegate()
    delegate.modeStore.dispatch(.enterNormal(targetPID: nil))
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    delegate.overlay.activeWindowBorderLayer.path = CGPath(rect: frame, transform: nil)
    delegate.activeWindowBorderTrackedFrame = frame
    let geometryGeneration = delegate.activeWindowBorderUpdateGeneration
    let reconciliationGeneration = delegate.activeWindowBorderReconciliationGeneration

    delegate.modeStore.dispatch(.enterPassthrough(targetPID: nil))
    delegate.updateActiveWindowBorder(reason: "test_passthrough")

    XCTAssertNil(delegate.overlay.activeWindowBorderLayer.path)
    XCTAssertNil(delegate.activeWindowBorderTrackedFrame)
    XCTAssertGreaterThan(delegate.activeWindowBorderUpdateGeneration, geometryGeneration)
    XCTAssertGreaterThan(
      delegate.activeWindowBorderReconciliationGeneration, reconciliationGeneration)
  }

  func testTerminalEmphasisUsesItsOwnPanelAndPreservesConfigurationOverrides() {
    let delegate = delegate()
    let popup = delegate.overlay.statusPopupController
    preview(popup)
    popup.focus()
    delegate.modeStore.dispatch(.openTerminal)
    let external = CGRect(x: 20, y: 30, width: 800, height: 600)
    delegate.overlay.activeWindowBorderLayer.path = CGPath(rect: external, transform: nil)
    delegate.activeWindowBorderTrackedFrame = external

    delegate.updateActiveWindowBorder(reason: "test_terminal")

    XCTAssertNil(delegate.overlay.activeWindowBorderLayer.path)
    XCTAssertNil(delegate.activeWindowBorderTrackedFrame)
    XCTAssertFalse(popup.modeBorderLayer.isHidden)
    XCTAssertEqual(popup.modeBorderLayer.frame, CGRect(origin: .zero, size: popup.frame.size))
    XCTAssertEqual(popup.modeBorderLayer.strokeColor, OverlayPanel.nordFrost2CG)
    XCTAssertEqual(popup.modeBorderLayer.lineWidth, 2)
    XCTAssertGreaterThan(popup.modeBorderLayer.shadowOpacity, 0)

    delegate.overlay.overlayConfig.windowBorderSize = 4
    delegate.overlay.overlayConfig.windowBorderColor = "#BF616A"
    delegate.updateActiveWindowBorder(reason: "test_config_reload")
    XCTAssertEqual(popup.modeBorderLayer.lineWidth, 4)
    XCTAssertEqual(
      popup.modeBorderLayer.strokeColor, delegate.overlay.nsColor(fromHex: "#BF616A")?.cgColor)
    XCTAssertGreaterThan(popup.modeBorderLayer.shadowOpacity, 0)

    delegate.overlay.overlayConfig.windowBorder = false
    delegate.updateActiveWindowBorder(reason: "test_disabled_border")
    XCTAssertTrue(popup.modeBorderLayer.isHidden)
    XCTAssertNil(popup.modeBorderLayer.path)
    popup.dismiss()
  }

  func testTerminalFocusBorderTracksPopupLayoutAndNeverHighlightsHoverPreviews() {
    let popup = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    preview(popup)
    popup.setActiveModeBorder(color: OverlayPanel.nordFrost2CG)
    XCTAssertTrue(popup.modeBorderLayer.isHidden)
    XCTAssertNil(popup.modeBorderLayer.path)

    popup.focus()
    let initialFrame = popup.modeBorderLayer.frame
    preview(popup, screen: CGRect(x: -600, y: 400, width: 400, height: 200), text: "Longer details")
    XCTAssertFalse(popup.modeBorderLayer.isHidden)
    XCTAssertEqual(popup.modeBorderLayer.frame, CGRect(origin: .zero, size: popup.frame.size))
    XCTAssertNotEqual(popup.modeBorderLayer.frame, initialFrame)
    XCTAssertTrue(popup.modeBorderLayer.animationKeys()?.isEmpty ?? true)

    popup.dismiss()
    XCTAssertNil(popup.modeBorderLayer.path)
    XCTAssertTrue(popup.modeBorderLayer.isHidden)
    preview(popup)
    popup.focus()
    XCTAssertTrue(popup.modeBorderLayer.isHidden)
    popup.dismiss()
  }

  func testTerminalBorderDoesNotRequireNormalModeBindingsButRespectsSessionSuspension() {
    XCTAssertTrue(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true, modeBadgeEnabled: false, modeStyle: .terminal,
        hasHints: false, sessionActive: true))
    XCTAssertFalse(
      AppDelegate.activeWindowBorderShouldBeVisible(
        configEnabled: true, modeBadgeEnabled: true, modeStyle: .terminal,
        hasHints: false, sessionActive: false))
  }

  private func delegate() -> AppDelegate {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    return delegate
  }

  private func preview(
    _ popup: StatusPopupController,
    screen: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400), text: String = "Details"
  ) {
    popup.preview(
      StatusBarPopupRegion(
        rect: .zero, name: "details", content: text,
        document: [FlashStatusTextSegment(text: text, foreground: .defaultForeground)]),
      pointer: CGPoint(x: screen.midX, y: screen.maxY), visibleFrame: screen,
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }
}

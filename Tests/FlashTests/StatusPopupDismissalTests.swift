import AppKit
import XCTest

@testable import flash

/// A hover preview is ephemeral: a click elsewhere or a focus change closes
/// it, and it stays shut under an unmoved pointer. Popups something else
/// holds (focused, pinned) are left alone.
final class StatusPopupDismissalTests: XCTestCase {
  private let region = StatusBarPopupRegion(
    rect: CGRect(x: 100, y: 800, width: 200, height: 25), name: "article", content: "Preview")

  private func panelShowingPreview() -> OverlayPanel {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    panel.statusPopupController.preview(
      region, pointer: CGPoint(x: 150, y: 812),
      visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 800), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    return panel
  }

  func testOnlyAPreviewIsEphemeral() {
    XCTAssertEqual(
      StatusPopupPresentation.preview(name: "article", anchor: .zero).ephemeralName, "article")
    XCTAssertNil(StatusPopupPresentation.focused(name: "article", anchor: .zero).ephemeralName)
    XCTAssertNil(StatusPopupPresentation.terminal(name: "terminal:shell").ephemeralName)
    XCTAssertNil(StatusPopupPresentation.hidden.ephemeralName)
  }

  func testAClickOrFocusChangeClosesThePreviewAndKeepsItShutUnderThePointer() {
    let panel = panelShowingPreview()
    defer { panel.hideStatusBarClickWindows() }
    XCTAssertTrue(panel.statusPopupController.isVisible)

    panel.dismissEphemeralStatusBarPopup(reason: "pointer_click")
    XCTAssertFalse(panel.statusPopupController.isVisible)
    XCTAssertEqual(panel.statusBarHoverGate, .dismissed("article"))

    // The pointer never left the anchor: hovering it again must not reopen.
    panel.showStatusBarPopup(region, at: CGPoint(x: 150, y: 812))
    XCTAssertFalse(panel.statusPopupController.isVisible)
  }

  func testAFocusedPopupIsNotEphemeral() {
    let panel = panelShowingPreview()
    defer { panel.hideStatusBarClickWindows() }
    panel.statusPopupController.focus()
    XCTAssertEqual(panel.statusPopupController.focusedName, "article")

    panel.dismissEphemeralStatusBarPopup(reason: "focus_changed")
    XCTAssertEqual(panel.statusPopupController.focusedName, "article")
    XCTAssertEqual(panel.statusBarHoverGate, .ready)
  }

  func testAPendingHoverDwellIsCancelled() {
    let panel = OverlayPanel()
    let work = DispatchWorkItem {}
    panel.statusBarHoverDwellName = "terminal:shell"
    panel.statusBarHoverDwellWork = work

    panel.dismissEphemeralStatusBarPopup(reason: "pointer_click")
    XCTAssertTrue(work.isCancelled)
    XCTAssertNil(panel.statusBarHoverDwellName)
    XCTAssertEqual(panel.statusBarHoverGate, .dismissed("terminal:shell"))
  }
}

import AppKit
import XCTest

@testable import flash

/// A hover preview hangs from its label, not from the pointer: centred on the
/// popup span's visible text, `offset` points below the bar, clamped to that
/// bar's screen. Only the span it hangs from moves it.
final class StatusPopupPlacementTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 2_000, height: 900)
  private let visible = CGRect(x: 0, y: 0, width: 2_000, height: 874)
  /// AppKit keeps a window's frame on whole points.
  private let wholePoint: CGFloat = 0.5

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  private func snapshot(_ screens: [CGRect]) -> OverlayPanel.ScreenSnapshot {
    OverlayPanel.ScreenSnapshot(
      screens: screens.map {
        (
          scale: 2, frame: $0,
          visibleFrame: CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height - 26),
          notch: nil
        )
      },
      unionFrame: screens.reduce(CGRect.null) { $0.union($1) }, mainFrame: screens.first,
      mainScale: 2, mainVisibleFrame: visible, nativeStatusBarFallbackHeight: 26)
  }

  private func makePanel() -> OverlayPanel {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    return panel
  }

  /// A popup span across the bar's full height, as the bar reports it.
  private func span(
    _ name: String = "metrics", x: CGFloat, width: CGFloat = 120, content: String = "CPU 12%"
  ) -> StatusBarPopupRegion {
    StatusBarPopupRegion(
      rect: CGRect(x: x, y: 874, width: width, height: 26), name: name, content: content)
  }

  private func pointer(in region: StatusBarPopupRegion, at fraction: CGFloat) -> CGPoint {
    CGPoint(x: region.rect.minX + region.rect.width * fraction, y: region.rect.midY)
  }

  private func assertHangs(
    _ frame: CGRect, from anchor: CGRect, offset: Double, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      frame.midX, anchor.midX, accuracy: wholePoint, "centred on its span", file: file, line: line)
    XCTAssertEqual(
      frame.maxY, anchor.minY - CGFloat(offset), accuracy: wholePoint, "offset below the bar",
      file: file, line: line)
  }

  func testPlacementCentresBelowTheSpanWhateverThePointer() {
    let frame = OverlayPanel.statusBarPopupFrame(
      span: CGRect(x: 450, y: 775, width: 100, height: 25),
      popupSize: CGSize(width: 200, height: 100),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 775), offset: 8)
    XCTAssertEqual(frame, CGRect(x: 400, y: 667, width: 200, height: 100))
    // With the native menu bar hidden, the visible frame reaches under the
    // bar; the popup still hangs `offset` below it.
    XCTAssertEqual(
      OverlayPanel.statusBarPopupFrame(
        span: CGRect(x: 450, y: 775, width: 100, height: 25),
        popupSize: CGSize(width: 200, height: 100),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), offset: 8),
      frame)
    XCTAssertEqual(
      OverlayPanel.statusBarPopupFrame(
        span: CGRect(x: 450, y: 775, width: 100, height: 25),
        popupSize: CGSize(width: 200, height: 100),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 775), offset: 0
      ).maxY, 775)
  }

  func testPlacementClampsToBothEdgesOfTheScreen() {
    let visible = CGRect(x: -1_200, y: 0, width: 1_200, height: 775)
    let size = CGSize(width: 300, height: 100)
    let leading = OverlayPanel.statusBarPopupFrame(
      span: CGRect(x: -1_195, y: 775, width: 10, height: 25), popupSize: size,
      visibleFrame: visible, offset: 8)
    XCTAssertEqual(leading, CGRect(x: -1_200, y: 667, width: 300, height: 100))
    let trailing = OverlayPanel.statusBarPopupFrame(
      span: CGRect(x: -15, y: 775, width: 10, height: 25), popupSize: size,
      visibleFrame: visible, offset: 8)
    XCTAssertEqual(trailing, CGRect(x: -300, y: 667, width: 300, height: 100))
    let oversized = OverlayPanel.statusBarPopupFrame(
      span: CGRect(x: -600, y: 775, width: 10, height: 25),
      popupSize: CGSize(width: 1_400, height: 900), visibleFrame: visible, offset: 8)
    XCTAssertEqual(oversized, visible)
  }

  func testRefreshFollowsTheNearestSameNamedSpan() {
    let current = span(x: 800)
    let elsewhere = span(x: 2_800)
    let moved = span(x: 830, width: 150)
    let other = span("other", x: 800)
    XCTAssertEqual(
      StatusPopupController.span(matching: current, in: [elsewhere, other, moved]), moved)
    XCTAssertEqual(
      StatusPopupController.span(matching: moved, in: [elsewhere, current]), current)
    XCTAssertNil(StatusPopupController.span(matching: current, in: [other]))
    let twin = span(x: 830, width: 150, content: "twin")
    XCTAssertEqual(
      StatusPopupController.span(matching: current, in: [moved, twin]), moved,
      "ties keep the earlier span")
  }

  func testHoverPreviewStaysPutWhileThePointerMovesAlongItsSpan() {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    let screens = snapshot([screen])
    let label = span(x: 800)
    var frames: [CGRect] = []
    for fraction in [0.05, 0.3, 0.5, 0.8, 0.97] as [CGFloat] {
      panel.showStatusBarPopup(
        label, at: pointer(in: label, at: fraction), screenSnapshot: screens)
      frames.append(panel.statusPopupController.frame)
    }
    XCTAssertTrue(panel.statusPopupController.isVisible)
    for frame in frames { XCTAssertEqual(frame, frames[0], "the pointer never moves the preview") }
    assertHangs(frames[0], from: label.rect, offset: panel.popupStyle.offset)
  }

  func testHoveringAnotherSpanReanchorsToThatSpan() {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    let screens = snapshot([screen])
    let first = span("first", x: 600)
    let second = span("second", x: 1_200)
    let again = span("first", x: 900, width: 60)
    panel.showStatusBarPopup(first, at: pointer(in: first, at: 0.9), screenSnapshot: screens)
    assertHangs(
      panel.statusPopupController.frame, from: first.rect, offset: panel.popupStyle.offset)
    panel.showStatusBarPopup(second, at: pointer(in: second, at: 0.1), screenSnapshot: screens)
    XCTAssertEqual(panel.activeStatusBarPopupName, "second")
    assertHangs(
      panel.statusPopupController.frame, from: second.rect, offset: panel.popupStyle.offset)
    // The same popup on another label hangs from that label.
    panel.showStatusBarPopup(again, at: pointer(in: again, at: 0.2), screenSnapshot: screens)
    XCTAssertEqual(panel.activeStatusBarPopupName, "first")
    assertHangs(
      panel.statusPopupController.frame, from: again.rect, offset: panel.popupStyle.offset)
  }

  func testRefreshAndResizeKeepThePreviewOnItsSpanAndFollowItsRelayout() {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    let screens = snapshot([screen])
    let label = span(x: 800)
    panel.showStatusBarPopup(label, at: pointer(in: label, at: 0.1), screenSnapshot: screens)
    let initial = panel.statusPopupController.frame

    let wider = span(
      x: 800, content: String(repeating: "wide ", count: 24) + "\nsecond\nthird")
    panel.refreshStatusBarPopup(
      popups: [wider], at: pointer(in: wider, at: 0.9), screenSnapshot: screens)
    let resized = panel.statusPopupController.frame
    XCTAssertGreaterThan(resized.width, initial.width)
    XCTAssertGreaterThan(resized.height, initial.height)
    assertHangs(resized, from: label.rect, offset: panel.popupStyle.offset)

    // A value got wider: the bar re-laid out and the label moved under a
    // pointer that still rests on it.
    let moved = span(x: 830, width: 150, content: wider.content)
    let resting = pointer(in: wider, at: 0.9)
    XCTAssertTrue(moved.rect.contains(resting))
    panel.refreshStatusBarPopup(popups: [moved], at: resting, screenSnapshot: screens)
    XCTAssertEqual(panel.statusPopupController.frame.size, resized.size)
    assertHangs(
      panel.statusPopupController.frame, from: moved.rect, offset: panel.popupStyle.offset)
  }

  func testPreviewIsClampedToBothEdgesOfItsBarsScreen() {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    let left = CGRect(x: -2_000, y: 0, width: 2_000, height: 900)
    let screens = snapshot([screen, left])
    let leading = span(x: -1_990, width: 40)
    panel.showStatusBarPopup(leading, at: pointer(in: leading, at: 0.5), screenSnapshot: screens)
    let frame = panel.statusPopupController.frame
    XCTAssertEqual(frame.minX, left.minX, accuracy: 0.001)
    XCTAssertEqual(
      frame.maxY, leading.rect.minY - CGFloat(panel.popupStyle.offset), accuracy: 0.001)

    let trailing = span("other", x: 1_960, width: 36)
    panel.showStatusBarPopup(trailing, at: pointer(in: trailing, at: 0.5), screenSnapshot: screens)
    XCTAssertEqual(panel.statusPopupController.frame.maxX, screen.maxX, accuracy: 0.001)
  }

  func testPinningFromHoverKeepsTheFrameAndFollowsItsOwnSpan() {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    let right = CGRect(x: 2_000, y: 0, width: 2_000, height: 900)
    let screens = snapshot([screen, right])
    let elsewhere = span(x: 800)
    let label = span(x: 2_800)
    panel.showStatusBarPopup(label, at: pointer(in: label, at: 0.1), screenSnapshot: screens)
    let hovered = panel.statusPopupController.frame
    panel.activateStatusBarPopup(
      label, at: pointer(in: label, at: 0.9), screenSnapshot: screens)
    XCTAssertEqual(panel.statusPopupController.focusedName, "metrics")
    XCTAssertEqual(panel.statusPopupController.frame, hovered, "pinning does not move it")

    // The same label on the other display comes first; the pinned popup
    // stays on its own label and follows it when the bar re-lays out.
    let moved = span(x: 2_840)
    panel.refreshStatusBarPopup(
      popups: [elsewhere, moved], at: pointer(in: label, at: 0.9), screenSnapshot: screens)
    XCTAssertEqual(panel.statusPopupController.focusedName, "metrics")
    assertHangs(
      panel.statusPopupController.frame, from: moved.rect, offset: panel.popupStyle.offset)
  }

  func testPreviewHangsFromTheWashedTextNotItsSeparatorSpaces() throws {
    let panel = makePanel()
    defer { panel.hideStatusBarPopup() }
    panel.setFrame(screen, display: false)
    let bar = CGRect(x: 0, y: 874, width: 2_000, height: 26)
    let surface = panel.primaryStatusBarSurface
    surface.render(
      document: StatusFormatDocument.parse(
        String(repeating: "x", count: 100) + "#[popup=clock]  12:34    #[nopopup]"),
      barFrame: bar, screenFrame: screen, scale: 2, notch: nil,
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), labels: .init(),
      palette: OverlayPanel.normalPalette, modeStyle: .normal, modeText: "NORMAL")
    let label = try XCTUnwrap(
      surface.interactionRects(
        panelFrame: screen, popupTexts: ["clock": "Monday"], popupDocuments: [:]
      ).popups.first)
    // The pointer rests on a trailing separator space.
    panel.hitTestStatusBarHover(
      popups: [label], links: [], at: CGPoint(x: label.rect.maxX - 1, y: label.rect.midY),
      screenSnapshot: snapshot([screen]))
    XCTAssertTrue(panel.statusPopupController.isVisible)
    let wash = surface.hoverHighlight.frame.offsetBy(dx: bar.minX, dy: bar.minY)
    XCTAssertEqual(label.anchor.midX, wash.midX, accuracy: 0.001, "the wash's text bounds")
    XCTAssertGreaterThan(abs(label.anchor.midX - label.rect.midX), 1, "not the spaces around it")
    let frame = panel.statusPopupController.frame
    XCTAssertEqual(frame.midX, wash.midX, accuracy: wholePoint)
    XCTAssertEqual(
      frame.maxY, bar.minY - CGFloat(panel.popupStyle.offset), accuracy: wholePoint)
  }
}

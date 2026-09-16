import AppKit
import XCTest

@testable import flash

final class CapturedStatusBarHintTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  func testPublicationsWaitForHintSelectionAndOnlyLatestIsApplied() {
    let panel = OverlayPanel()
    let original = model("Original")
    let latest = model("Latest")
    panel.setStatusBarModel(original)
    let revision = panel.statusBarLayoutRevision
    panel.captureStatusBarHintSnapshot()
    panel.setStatusBarModel(model("Intermediate"))
    panel.setStatusBarModel(latest)
    XCTAssertEqual(panel.statusBarModel, original)
    XCTAssertEqual(panel.statusBarLayoutRevision, revision)
    panel.releaseStatusBarHintSnapshot()
    XCTAssertEqual(panel.statusBarModel, latest)
    XCTAssertEqual(panel.statusBarLayoutRevision, revision + 1)
    panel.releaseStatusBarHintSnapshot()
    XCTAssertEqual(panel.statusBarLayoutRevision, revision + 1)
  }

  func testCapturedHostClickKeepsSelectedActionAcrossPublicationBeforeMouseDown() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let original = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "original"))
    let replacement = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "replacement"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.prepareHintClick(url: original, at: CGPoint(x: 30, y: 12), timestamp: 10)
    view.links = [(view.bounds, replacement)]
    try click(view, timestamp: 10.1, synthetic: true)
    XCTAssertEqual(actions, ["original"])
    try click(view, timestamp: 10.3, synthetic: true)
    XCTAssertEqual(actions, ["original", "replacement"], "The captured action is consumed once")
  }

  func testPhysicalClickUsesWhatIsUnderThePointerAndKeepsItUntilMouseUp() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let stale = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "stale hint"))
    let current = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "current"))
    let next = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "next"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.prepareHintClick(url: stale, at: CGPoint(x: 30, y: 12), timestamp: 10)
    view.links = [(view.bounds, current)]
    try click(view, timestamp: 10.1) { view.links = [(view.bounds, next)] }
    XCTAssertEqual(actions, ["current"])
  }

  func testExpiredCapturedGestureCancelsInsteadOfOpeningAReplacement() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let original = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "original"))
    let replacement = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "replacement"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.prepareHintClick(url: original, at: CGPoint(x: 30, y: 12), timestamp: 10)
    view.links = [(view.bounds, replacement)]
    try click(view, timestamp: 12, synthetic: true)
    XCTAssertTrue(actions.isEmpty)
  }

  func testPopupHintCarriesTheCapturedContentAndLinkProperties() {
    var segment = FlashStatusTextSegment(text: "Read original", foreground: .defaultForeground)
    segment.link = "https://example.com/original"
    let original = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 700, width: 200, height: 24), name: "article",
      content: "Original", document: [segment])
    let hints = OverlayPanel.statusBarHintRegions(links: [], popups: [original])
    XCTAssertEqual(hints, [StatusBarHintRegion(rect: original.rect, action: .hover(original))])
  }

  func testPopupSnapshotKeepsCapturedContentUntilLeavingItsAnchor() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    let original = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 700, width: 200, height: 24), name: "article", content: "Original")
    let replacement = StatusBarPopupRegion(
      rect: CGRect(x: 400, y: 700, width: 200, height: 24), name: "article", content: "Replacement")
    controller.preview(
      original, pointer: CGPoint(x: 110, y: 710),
      visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), preservingContent: true)
    controller.refresh([replacement])
    XCTAssertEqual(controller.content, "Original")
    XCTAssertTrue(controller.containsSnapshotAnchor(CGPoint(x: 110, y: 710)))
    XCTAssertFalse(controller.containsSnapshotAnchor(CGPoint(x: 410, y: 710)))
    controller.refresh([])
    XCTAssertTrue(controller.isVisible)
    controller.leaveAnchor()
    XCTAssertFalse(controller.isVisible)
    XCTAssertFalse(controller.isContentSnapshot)
  }

  private func model(_ text: String) -> FlashStatusBarModel {
    FlashStatusBarModel(
      appText: "", modeText: "", rightText: text,
      popupTexts: ["article": text])
  }

  private func click(
    _ view: StatusBarClickView, timestamp: TimeInterval, synthetic: Bool = false,
    between: () -> Void = {}
  ) throws {
    let point = CGPoint(x: 30, y: ActionDispatcher.primaryScreenHeight() - 12)
    let downCG = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left))
    let upCG = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left))
    downCG.timestamp = UInt64(timestamp * 1_000_000_000)
    upCG.timestamp = UInt64((timestamp + 0.1) * 1_000_000_000)
    if synthetic {
      downCG.setIntegerValueField(
        .eventSourceUserData, value: ActionDispatcher.syntheticMouseEventTag)
    }
    let down = try XCTUnwrap(NSEvent(cgEvent: downCG))
    let up = try XCTUnwrap(NSEvent(cgEvent: upCG))
    XCTAssertEqual(down.locationInWindow, CGPoint(x: 30, y: 12))
    view.mouseDown(with: down)
    between()
    view.mouseUp(with: up)
  }
}

import AppKit
import FlashCore
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

  /// A hinted link is followed from the URL the hint carried, so whatever the
  /// bar published between showing the hint and committing it cannot redirect
  /// the user somewhere else.
  func testAHintedLinkFollowsTheSelectedActionNotWhateverTheBarPublishedSince() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let selected = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "original"))
    let replacement = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "replacement"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.links = [(view.bounds, replacement)]
    view.activate(url: selected)
    XCTAssertEqual(actions, ["original"])
  }

  /// The previous design replayed the hint as a synthetic click into Flash's
  /// own menu-bar-band window and matched it back to an armed URL by timestamp
  /// and proximity. Every step was a way for the gesture to vanish, so there
  /// is no longer any arming to reconcile — following the link needs nothing
  /// but the hint.
  func testFollowingAHintedLinkDoesNotDependOnAMouseEvent() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let selected = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "picked"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    // No links published at all, and no click: the hint still resolves.
    view.links = []
    view.activate(url: selected)
    XCTAssertEqual(actions, ["picked"])
  }

  func testPhysicalClickUsesWhatIsUnderThePointerAndKeepsItUntilMouseUp() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    let stale = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "stale hint"))
    let current = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "current"))
    let next = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "next"))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    _ = stale
    view.links = [(view.bounds, current)]
    try click(view, timestamp: 10.1) { view.links = [(view.bounds, next)] }
    XCTAssertEqual(actions, ["current"])
  }

  func testAPhysicalClickOnEmptyBandDoesNothing() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    var actions: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.links = []
    try click(view, timestamp: 12)
    XCTAssertTrue(actions.isEmpty)
  }

  func testPopupHintCarriesTheCapturedContentAndLinkProperties() {
    var segment = FlashStatusTextSegment(text: "Read original", foreground: .defaultForeground)
    segment.link = "https://example.com/original"
    let original = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 700, width: 200, height: 24), name: "article",
      content: "Original", document: [segment])
    let hints = OverlayPanel.statusBarHintRegions(links: [], popups: [original]) { $0 }
    XCTAssertEqual(
      hints,
      [
        StatusBarHintRegion(
          rect: original.rect, textBounds: original.rect, action: .hover(original),
          popup: original)
      ])
  }

  func testPopupSnapshotKeepsCapturedContentUntilLeavingItsAnchor() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    let original = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 700, width: 200, height: 24), name: "article", content: "Original")
    let replacement = StatusBarPopupRegion(
      rect: CGRect(x: 400, y: 700, width: 200, height: 24), name: "article", content: "Replacement")
    controller.preview(
      original,
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
    let point = CGPoint(x: 30, y: ScreenSpace.primaryHeight - 12)
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

extension CapturedStatusBarHintTests {
  /// Following a hinted link must not depend on a status-bar click window
  /// existing or being mouse-enabled. Those windows are Flash's own, they come
  /// and go with the bar's layout, and requiring one was part of why a hinted
  /// link could silently do nothing.
  func testAHintedRangeActionReachesTheHandlerWithNoClickWindows() throws {
    let panel = OverlayPanel()
    let url = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "bat-prefs"))
    var actions: [String] = []
    panel.statusBarActionHandler = { actions.append($0) }
    XCTAssertTrue(panel.statusBarClickWindows.isEmpty)
    panel.activateStatusBarLink(url)
    XCTAssertEqual(actions, ["bat-prefs"])
  }
}

extension CapturedStatusBarHintTests {
  /// `f` and `mf` label the same status-bar spans at the same points; only the
  /// commit differs. A move used to get no status-bar hints at all.
  func testClickAndMoveHintsTargetTheSameStatusBarSpans() throws {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let cld = CGRect(x: 100, y: 776, width: 100, height: 24)
    let cdx = CGRect(x: 210, y: 776, width: 100, height: 24)
    let cpu = CGRect(x: 400, y: 776, width: 60, height: 24)
    let claude = try XCTUnwrap(URL(string: "https://claude.ai/new#settings/usage"))
    let codex = try XCTUnwrap(URL(string: "https://chatgpt.com/settings/usage?tab=overview"))
    let links = [(rect: cld, url: claude), (rect: cdx, url: codex)]
    let popups = [
      StatusBarPopupRegion(
        rect: CGRect(x: 100, y: 776, width: 210, height: 24), name: "ai-usage", content: "usage"),
      StatusBarPopupRegion(rect: cpu, name: "cpu", content: "CPU"),
    ]
    let interactions = StatusBarScreenInteractions(
      screenFrame: screen, links: links, popups: popups,
      hints: OverlayPanel.statusBarHintRegions(links: links, popups: popups) { span in
        // Glyphs fill each span except the space between the two links.
        span.minX >= 200 && span.maxX <= 210 ? nil : span
      })
    let window = CGRect(x: 0, y: 0, width: 800, height: 700)

    func targets(_ command: MouseCommand) -> [JumpTarget] {
      AppDelegate.statusBarHintTargets(
        for: command, screens: [interactions], activeWindowFrame: window
      ).map(\.target)
    }
    let click = targets(.click(.leftClick, modifiers: []))
    let move = targets(.move)
    XCTAssertEqual(click.count, 3)
    XCTAssertEqual(click.map(\.id), move.map(\.id))
    XCTAssertEqual(click.map(\.frame), move.map(\.frame))
    XCTAssertEqual(click.map(\.role), move.map(\.role))
    XCTAssertEqual(click.map(\.url), move.map(\.url))
    XCTAssertEqual(
      click.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) },
      [CGPoint(x: 150, y: 788), CGPoint(x: 260, y: 788), CGPoint(x: 430, y: 788)])
    let right = targets(.click(.rightClick, modifiers: []))
    XCTAssertEqual(right.map(\.frame), click.map(\.frame))
    XCTAssertEqual(right.map(\.url), click.map(\.url))
    XCTAssertEqual(
      targets(.click(.doubleClick, modifiers: [])).map(\.id), click.map(\.id))

    XCTAssertEqual(
      AppDelegate.statusBarHintCommit(command: .click(.leftClick, modifiers: []), url: claude),
      .follow(claude))
    XCTAssertEqual(AppDelegate.statusBarHintCommit(command: .move, url: claude), .hover)
    XCTAssertEqual(
      AppDelegate.statusBarHintCommit(command: .click(.leftClick, modifiers: []), url: nil),
      .hover)
    XCTAssertEqual(
      AppDelegate.statusBarHintCommit(command: .click(.rightClick, modifiers: []), url: claude),
      .pin)
    XCTAssertEqual(
      AppDelegate.statusBarHintCommit(command: .click(.rightClick, modifiers: []), url: nil),
      .pin)
    let glyph = CGRect(x: 100, y: 776, width: 8, height: 2)
    XCTAssertEqual(
      AppDelegate.statusBarHintPoint(glyph, bigram: true),
      CGPoint(x: glyph.midX - 1, y: glyph.midY))
    XCTAssertEqual(
      AppDelegate.statusBarHintPoint(glyph, bigram: false),
      CGPoint(x: glyph.midX, y: glyph.midY))
  }

  /// `s` then a letter labels that glyph on the status bar of the active
  /// window's screen. A glyph in a link follows the link; one in a popup
  /// opens it; one on plain text still jumps. `v` and `V` match the same cells.
  func testALetterJumpLabelsStatusBarGlyphsOnTheActiveWindow() throws {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let other = CGRect(x: 2_000, y: 0, width: 1_000, height: 800)
    let window = CGRect(x: 0, y: 0, width: 800, height: 700)
    let linkURL = try XCTUnwrap(URL(string: "https://example.com/v"))
    let cpu = StatusBarPopupRegion(
      rect: CGRect(x: 400, y: 776, width: 40, height: 24), name: "cpu", content: "CPU")
    let regions = [
      StatusBarHintRegion(
        rect: CGRect(x: 100, y: 776, width: 30, height: 24),
        textBounds: CGRect(x: 100, y: 776, width: 30, height: 24),
        action: .click(linkURL), popup: nil),
      StatusBarHintRegion(
        rect: cpu.rect, textBounds: cpu.rect, action: .hover(cpu), popup: cpu),
    ]
    let runs = [
      StatusBarLetterRun(
        text: "Vv", frame: CGRect(x: 100, y: 776, width: 20, height: 24),
        cellWidth: 10, centered: false),
      StatusBarLetterRun(
        text: "CPU", frame: CGRect(x: 400, y: 776, width: 30, height: 24),
        cellWidth: 10, centered: false),
      StatusBarLetterRun(
        text: "OK", frame: CGRect(x: 0, y: 776, width: 80, height: 24),
        cellWidth: 10, centered: true),
    ]
    let surface = StatusBarLetterSurface(screenFrame: screen, runs: runs, regions: regions)
    let elsewhere = StatusBarLetterSurface(
      screenFrame: other,
      runs: [
        StatusBarLetterRun(
          text: "V", frame: CGRect(x: 2_100, y: 776, width: 10, height: 24),
          cellWidth: 10, centered: false)
      ],
      regions: [])

    func letters(_ query: String) -> [(target: JumpTarget, popup: StatusBarPopupRegion?)] {
      AppDelegate.statusBarLetterTargets(
        query: query, command: .click(.leftClick, modifiers: []),
        surfaces: [surface, elsewhere], activeWindowFrame: window)
    }
    let lower = letters("v")
    let upper = letters("V")
    XCTAssertEqual(lower.map(\.target.frame), upper.map(\.target.frame))
    XCTAssertEqual(
      lower.map(\.target.frame),
      [
        CGRect(x: 100, y: 787, width: 10, height: 2),
        CGRect(x: 110, y: 787, width: 10, height: 2),
      ])
    XCTAssertEqual(lower.map(\.target.providerID), ["statusbar", "statusbar"])
    XCTAssertEqual(lower.map(\.target.role), ["AXLink", "AXLink"])
    XCTAssertEqual(lower.map(\.target.url), [linkURL.absoluteString, linkURL.absoluteString])
    XCTAssertTrue(lower.allSatisfy { $0.popup == nil })

    let cpuLetter = letters("u")
    XCTAssertEqual(cpuLetter.map(\.target.frame), [CGRect(x: 420, y: 787, width: 10, height: 2)])
    XCTAssertEqual(cpuLetter.map(\.target.role), [AppDelegate.statusBarHoverHintRole])
    XCTAssertEqual(cpuLetter.map { $0.popup?.name }, ["cpu"])

    // "OK" is centred in an 80pt run: the label starts at midX - 10.
    XCTAssertEqual(
      letters("k").map(\.target.frame), [CGRect(x: 40, y: 787, width: 10, height: 2)])
    XCTAssertEqual(letters("k").map { $0.popup?.name }, [nil])
    XCTAssertTrue(letters("vv").isEmpty)
    XCTAssertEqual(
      AppDelegate.statusBarLetterTargets(
        query: "v", command: .click(.rightClick, modifiers: []),
        surfaces: [surface], activeWindowFrame: window
      ).map(\.target.frame),
      lower.map(\.target.frame))
    XCTAssertTrue(
      AppDelegate.statusBarLetterTargets(
        query: "v", command: .move, surfaces: [elsewhere], activeWindowFrame: window
      ).isEmpty)
  }
}

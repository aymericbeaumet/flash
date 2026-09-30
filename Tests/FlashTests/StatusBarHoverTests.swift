import AppKit
import XCTest

@testable import flash

final class StatusBarHoverTests: XCTestCase {
  func testRightClickPinsLinkedPopupAndIgnoresDragsOrEmptySpace() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    view.popups = [.init(rect: view.bounds, name: "article", content: "Preview")]
    view.links = [(view.bounds, URL(string: "https://example.com/article")!)]
    var selected: [String] = []
    view.onPopupClick = { popup, _ in
      selected.append(popup.name)
    }
    func click(upX: CGFloat = 30) throws {
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: CGPoint(x: 30, y: 12), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .rightMouseUp, location: CGPoint(x: upX, y: 12), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
      view.rightMouseDown(with: down)
      view.rightMouseUp(with: up)
    }
    try click()
    XCTAssertEqual(selected, ["article"])
    try click(upX: 50)
    XCTAssertEqual(selected.count, 1)
    view.popups = []
    try click()
    XCTAssertEqual(selected.count, 1)
  }

  func testPopupClicksPreserveLinksAndAllowOptionToFocus() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    view.popups = [.init(rect: view.bounds, name: "article", content: "Preview")]
    var selected: [String] = []
    view.onPopupClick = { popup, _ in
      selected.append(popup.name)
    }
    func click(_ modifiers: NSEvent.ModifierFlags, upX: CGFloat = 30) throws {
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: CGPoint(x: 30, y: 12), modifierFlags: modifiers,
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseUp, location: CGPoint(x: upX, y: 12), modifierFlags: modifiers,
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
      view.mouseDown(with: down)
      view.mouseUp(with: up)
    }
    try click([])
    XCTAssertEqual(selected, ["article"])
    view.links = [(view.bounds, URL(string: "https://example.com/article")!)]
    try click(.option)
    XCTAssertEqual(selected, ["article", "article"])
    try click(.option, upX: 50)
    XCTAssertEqual(selected.count, 2, "Dragging must not focus a popup")
    XCTAssertFalse(StatusBarClickView.focusesPopup(overLink: true, modifiers: []))
    XCTAssertTrue(StatusBarClickView.focusesPopup(overLink: false, modifiers: []))
    XCTAssertTrue(StatusBarClickView.focusesPopup(overLink: true, modifiers: .option))
  }

  func testConfiguredLeftClickActionTakesPrecedenceWhileRightClickPins() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    view.popups = [.init(rect: view.bounds, name: "metrics", content: "Preview")]
    view.links = [
      (view.bounds, try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "metrics-action")))
    ]
    var actions: [String] = []
    var popups: [String] = []
    view.onStatusBarAction = { actions.append($0) }
    view.onPopupClick = { popup, _ in popups.append(popup.name) }
    for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown] {
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: CGPoint(x: 30, y: 12), modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type == .leftMouseDown ? .leftMouseUp : .rightMouseUp,
          location: CGPoint(x: 30, y: 12), modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
      if type == .leftMouseDown {
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        XCTAssertEqual(actions, ["metrics-action"])
        XCTAssertTrue(popups.isEmpty)
      } else {
        view.rightMouseDown(with: down)
        view.rightMouseUp(with: up)
        XCTAssertEqual(actions, ["metrics-action"])
        XCTAssertEqual(popups, ["metrics"])
      }
    }
  }

  func testPinnedPopupSurvivesOverlayRefreshPointerExitAndRepeatedClicks() {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    defer { panel.hideStatusBarClickWindows() }
    let region = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 800, width: 200, height: 25), name: "article", content: "Preview")
    let controller = panel.statusPopupController
    var focusTransitions = 0
    let focused = expectation(description: "pager file is ready for input focus")
    controller.willFocus = {
      focusTransitions += 1
      focused.fulfill()
    }
    controller.preview(
      region,
      visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 800), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    panel.activateStatusBarPopup(region, at: .zero)
    wait(for: [focused], timeout: 3)
    XCTAssertEqual(focusTransitions, 1)
    panel.syncStatusBarClickWindows(
      bandRects: [CGRect(x: 0, y: 800, width: 900, height: 25)], links: [], popups: [region])
    panel.statusBarClickWindows.first?.clickView.onPopupHover?(nil, .zero)
    XCTAssertEqual(panel.activeStatusBarPopupName, "article")
    XCTAssertEqual(controller.focusedName, "article")
    let frame = controller.frame
    panel.showStatusBarPopup(
      .init(rect: region.rect, name: "other", content: "Other"), at: .zero)
    XCTAssertEqual(controller.focusedName, "article")
    XCTAssertEqual(controller.frame, frame)
    panel.activateStatusBarPopup(region, at: .zero)
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(focusTransitions, 1, "Right-click must keep the focused popup open")
    let view = panel.statusBarClickWindows[0].clickView
    for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown] {
      let upType: NSEvent.EventType = type == .leftMouseDown ? .leftMouseUp : .rightMouseUp
      let down = NSEvent.mouseEvent(
        with: type, location: CGPoint(x: 150, y: 12), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
      let up = NSEvent.mouseEvent(
        with: upType, location: CGPoint(x: 150, y: 12), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
      if type == .leftMouseDown {
        view.mouseDown(with: down)
        view.mouseUp(with: up)
      } else {
        view.rightMouseDown(with: down)
        view.rightMouseUp(with: up)
      }
      XCTAssertTrue(controller.isVisible)
      XCTAssertEqual(controller.focusedName, "article")
      XCTAssertEqual(focusTransitions, 1, "Repeated clicks must not release or refocus the session")
    }
  }

  func testStandaloneTerminalSurvivesHiddenStatusBar() {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    panel.statusTerminals.apply(
      style: .init(),
      terminals: [
        "shell": Config.Terminal(
          command: ["/bin/cat"], size: Config.PopupSize(columns: .cells(40), rows: .cells(10)),
          lifecycle: .persistent)
      ])
    defer {
      panel.statusPopupController.dismiss()
      panel.statusTerminals.shutdown()
    }
    panel.statusPopupController.show(
      name: "shell", visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 800),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    panel.hideStatusBarClickWindows()
    XCTAssertEqual(panel.statusPopupController.focusedName, "shell")
    XCTAssertTrue(panel.statusPopupController.presentation.isStandalone)
  }

  func testExplicitDismissalWaitsForLeavingTheAnchorBeforeHoverReopens() {
    let gate = StatusBarHoverGate.dismissed("system")
    XCTAssertFalse(gate.hovering("system").permits("system"))
    XCTAssertTrue(gate.hovering(nil).permits("system"))
    XCTAssertTrue(gate.hovering("other").permits("system"))
  }

  func testChangingHoverAnchorReleasesPreviousTerminalBeforePreparingNext() {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [(scale: 1, frame: screen, visibleFrame: screen, notch: nil)],
      unionFrame: screen, mainFrame: screen, mainScale: 1, mainVisibleFrame: screen,
      nativeStatusBarFallbackHeight: 0)
    var events: [String] = []
    panel.statusBarTerminalPrepareHandler = { name in
      events.append("prepare " + name)
      return true
    }
    panel.statusPopupController.didDismiss = { name in events.append("release " + name) }
    for name in ["first", "second"] {
      panel.showStatusBarPopup(
        .init(rect: screen, name: name, content: name), at: CGPoint(x: 100, y: 790),
        screenSnapshot: snapshot)
    }
    XCTAssertEqual(events, ["prepare first", "release first", "prepare second"])
    panel.hideStatusBarPopup()
    XCTAssertEqual(events.last, "release second")
  }

  func testRegionDiagnosticsIgnoreBodyOnlyUpdates() {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source == "core:StatusBarClickView.regions" { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    for length in 1...20 {
      view.popups = [
        .init(rect: view.bounds, name: "metrics", content: String(repeating: "a", count: length))
      ]
    }
    XCTAssertEqual(records.count, 1, "Background telemetry must not flood hover-region diagnostics")
  }

  func testHoverLogsReentryWithoutLoggingArticleDataOrEveryMove() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    view.popups = [
      .init(rect: view.bounds, name: "private-popup-name", content: "Private article text")
    ]
    view.links = [(view.bounds, URL(string: "https://private.example/article")!)]
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source == "core:StatusBarClickView.hover" { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    let move = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved, location: CGPoint(x: 30, y: 12), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    for _ in 0..<10 { view.mouseMoved(with: move) }
    XCTAssertEqual(records.count, 1)
    view.mouseExited(with: move)
    view.mouseMoved(with: move)
    XCTAssertEqual(records.map { $0.fields["event"] }, ["moved", "exited", "moved"])
    let diagnostic = records.map { $0.message + String(describing: $0.fields) }.joined()
    for secret in ["private-popup-name", "Private article text", "private.example"] {
      XCTAssertFalse(diagnostic.contains(secret))
    }
  }

  func testClickWindowPreservesTypedPopupDocumentAndScreenConversion() {
    let panel = OverlayPanel()
    defer { panel.hideStatusBarClickWindows() }
    let band = CGRect(x: 100, y: 800, width: 800, height: 25)
    let rect = CGRect(x: 220, y: 800, width: 140, height: 25)
    let document = StatusFormatDocument.parse("#[bold]Opening#[default]\nLiteral ##[red]").runs
    panel.syncStatusBarClickWindows(
      bandRects: [band], links: [],
      popups: [
        .init(rect: rect, name: "article", content: "Opening\nLiteral #[red]", document: document)
      ])

    let popup = panel.statusBarClickWindows.first?.clickView.popups.first
    XCTAssertEqual(popup?.rect, CGRect(x: 120, y: 0, width: 140, height: 25))
    XCTAssertEqual(
      popup?.document, document,
      "Mouse-enter and stationary refresh must use the same already-compiled popup document")
  }

  func testStatusRefreshKeepsHoverWashAlignedUnderStationaryPointer() throws {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    defer { panel.hideStatusBarPopup() }
    let screen = CGRect(x: -900, y: 0, width: 900, height: 800)
    panel.setFrame(screen, display: false)
    let snapshot = OverlayPanel.ScreenSnapshot(
      screens: [(scale: 2, frame: screen, visibleFrame: screen, notch: nil)],
      unionFrame: screen, mainFrame: screen, mainScale: 2, mainVisibleFrame: screen,
      nativeStatusBarFallbackHeight: 0)
    let surface = panel.primaryStatusBarSurface
    func redraw(_ prefix: String) throws -> StatusBarPopupRegion {
      surface.render(
        document: StatusFormatDocument.parse(prefix + "#[popup=feed]AGGR#[nopopup]"),
        barFrame: CGRect(x: 0, y: 774, width: 900, height: 26), screenFrame: screen,
        scale: 2, notch: nil, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        labels: .init(), palette: OverlayPanel.normalPalette, modeStyle: .normal, modeText: "NORMAL"
      )
      return try XCTUnwrap(
        surface.interactionRects(
          panelFrame: screen, popupTexts: ["feed": "Preview"], popupDocuments: [:]
        ).popups.first)
    }
    let initial = try redraw("")
    let pointer = CGPoint(x: initial.rect.midX, y: initial.rect.midY)
    panel.setStatusBarHoverHighlight(initial.rect)
    let moved = try redraw(" ")
    panel.refreshStatusBarPopup(popups: [moved], at: pointer, screenSnapshot: snapshot)
    XCTAssertEqual(
      surface.hoverHighlight.frame.minX, moved.rect.minX - screen.minX - 5, accuracy: 0.001)
    panel.refreshStatusBarPopup(
      popups: [], links: [(moved.rect, URL(string: "https://example.com")!)], at: pointer,
      screenSnapshot: snapshot)
    XCTAssertEqual(surface.hoverHighlight.opacity, 1)
    panel.refreshStatusBarPopup(popups: [], at: pointer, screenSnapshot: snapshot)
    XCTAssertEqual(surface.hoverHighlight.opacity, 0)
  }

  /// A whole-row popup (a feed row shares one preview across its label, title,
  /// domain and arrow) must not wash the entire row when the pointer sits on
  /// one of its links: the wash follows the narrowest interactive span.
  func testHoverWashFollowsTheNarrowestSpanUnderThePointer() {
    let row = CGRect(x: 0, y: 0, width: 400, height: 25)
    let title = CGRect(x: 40, y: 0, width: 60, height: 25)
    XCTAssertEqual(StatusBarClickView.hoverWashRect(link: title, popup: row), title)
    XCTAssertEqual(StatusBarClickView.hoverWashRect(link: nil, popup: row), row)
    XCTAssertEqual(StatusBarClickView.hoverWashRect(link: title, popup: nil), title)
    XCTAssertNil(StatusBarClickView.hoverWashRect(link: nil, popup: nil))
    // A link wider than its popup region keeps the region.
    XCTAssertEqual(StatusBarClickView.hoverWashRect(link: row, popup: title), title)
  }

  /// A hover preview clips the blank last row a full-screen program keeps for
  /// its messages; a focused popup keeps it, and a program that fills the row
  /// keeps it either way. A process that has ended loses every blank trailing
  /// row, so a finished report fits its output.
  func testTerminalPopupsClipTheirBlankTrailingRows() {
    func clipped(
      _ lastRow: String?, rows: Int = 30, interactive: Bool = false, ended: Bool = false
    ) -> Int {
      StatusPopupController.clippedTrailingRows(
        lastRow.map { Array(repeating: "text", count: rows - 1) + [$0] }, rows: rows,
        interactive: interactive, ended: ended)
    }
    XCTAssertEqual(clipped(""), 1, "newsboat leaves its message row blank while idle")
    XCTAssertEqual(clipped("     "), 1, "a row of spaces is still blank")
    XCTAssertEqual(clipped("Error: feed contains no items!"), 0, "a message must stay visible")
    XCTAssertEqual(clipped("", interactive: true), 0, "a focused popup keeps its input row")
    XCTAssertEqual(clipped(nil), 0, "no frame yet means nothing to clip")
    XCTAssertEqual(clipped("", rows: 1), 0, "a one-row popup has nothing left to show")
    let report =
      ["Claude", "Session 90% left", "", "Codex", "Weekly 6% left"]
      + Array(
        repeating: "  ", count: 11)
    for interactive in [false, true] {
      XCTAssertEqual(
        StatusPopupController.clippedTrailingRows(
          report, rows: 16, interactive: interactive, ended: true), 11,
        "a finished report fits its output, blank line inside it kept")
    }
    XCTAssertEqual(
      StatusPopupController.clippedTrailingRows(
        report, rows: 16, interactive: false, ended: false), 1,
      "a live preview only drops the message row")
    XCTAssertEqual(
      StatusPopupController.clippedTrailingRows(
        Array(repeating: "", count: 28), rows: 28, interactive: false, ended: true), 27,
      "a command that never started keeps one row above its footer")
  }

  /// Committing a left-click that has a handler closes the popup the pointer
  /// is over: the click already answered why the popup was open. Drags and
  /// clicks with no handler leave it alone.
  func testLeftClickWithAHandlerClosesTheHoveredPopup() throws {
    let view = StatusBarClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 25))
    var opened: [String] = []
    var dismissals = 0
    view.onLinkActivated = { dismissals += 1 }
    view.onStatusBarAction = { opened.append($0) }
    func click(upX: CGFloat = 30) throws {
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: CGPoint(x: 30, y: 12), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseUp, location: CGPoint(x: upX, y: 12), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
      view.mouseDown(with: down)
      view.mouseUp(with: up)
    }
    // No link under the pointer: nothing was handled, so nothing closes.
    try click()
    XCTAssertEqual(dismissals, 0)
    // A plain link closes the popup exactly once per committed click.
    view.links = [(view.bounds, URL(string: "https://example.com/article")!)]
    try click()
    XCTAssertEqual(dismissals, 1)
    // A drag is not a click.
    try click(upX: 80)
    XCTAssertEqual(dismissals, 1)
    // A named range action is a handler too.
    let action = try XCTUnwrap(FlashStatusBarRenderer.rangeActionURL(name: "user|1"))
    view.links = [(view.bounds, action)]
    try click()
    XCTAssertEqual(dismissals, 2)
    XCTAssertEqual(opened, ["user|1"])
  }

  /// One popup segment on a bar along the top of the real main display (the
  /// click view places its preview on a live display), its click window, and
  /// a recorder for every preview a hover asks for. Declining the preview
  /// keeps the test from starting a pager.
  private struct HoverBar {
    let panel: OverlayPanel
    let surface: NativeStatusBarSurface
    let popup: StatusBarPopupRegion
    let window: StatusBarClickPanel
    let snapshot: OverlayPanel.ScreenSnapshot
    let previews: () -> [String]

    func hover(at point: CGPoint) throws {
      window.clickView.mouseMoved(
        with: try XCTUnwrap(
          NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)))
    }
  }

  private func makeHoverBar() throws -> HoverBar {
    let panel = OverlayPanel()
    panel.statusPopupController = StatusPopupController(
      terminals: panel.statusTerminals, windowActionsEnabled: false)
    addTeardownBlock {
      panel.hideStatusBarClickWindows()
      panel.hideStatusBarPopup()
    }
    let previews = PreviewRecorder()
    panel.statusBarTerminalPrepareHandler = { name in
      previews.names.append(name)
      return false
    }
    let snapshot = OverlayPanel.currentScreenSnapshot()
    guard let screen = snapshot.mainFrame else { throw XCTSkip("No display to host the bar") }
    panel.setFrame(screen, display: false)
    let barFrame = CGRect(x: 0, y: screen.height - 26, width: screen.width, height: 26)
    let surface = panel.primaryStatusBarSurface
    surface.render(
      document: StatusFormatDocument.parse("#[popup=feed]AGGR#[nopopup]"),
      barFrame: barFrame, screenFrame: screen, scale: 2, notch: nil,
      font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), labels: .init(),
      palette: OverlayPanel.normalPalette, modeStyle: .normal, modeText: "NORMAL")
    let popup = try XCTUnwrap(
      surface.interactionRects(
        panelFrame: screen, popupTexts: ["feed": "Preview"], popupDocuments: [:]
      ).popups.first)
    let band = barFrame.offsetBy(dx: screen.minX, dy: screen.minY)
    panel.statusBarInteractionsByScreen = [
      .init(screenFrame: screen, links: [], popups: [popup])
    ]
    panel.syncStatusBarClickWindows(bandRects: [band], links: [], popups: [popup])
    let window = try XCTUnwrap(panel.statusBarClickWindows.first)
    XCTAssertEqual(window.frame, band)
    // The click windows' own stationary re-hit-test used the real pointer.
    previews.names.removeAll()
    return HoverBar(
      panel: panel, surface: surface, popup: popup, window: window, snapshot: snapshot,
      previews: { previews.names })
  }

  private final class PreviewRecorder {
    var names: [String] = []
  }

  /// Once the native menu bar is revealed under the pointer the band is its:
  /// the wash showing when the reveal lands clears, and neither the click
  /// view's tracking events nor a stationary re-hit-test after a content
  /// refresh washes a segment or opens a preview. Folding the native bar away
  /// resumes hover under a parked pointer.
  func testRevealedNativeMenuBarSilencesStatusBarHoverUntilItFolds() throws {
    let bar = try makeHoverBar()
    let panel = bar.panel
    let pointer = CGPoint(x: bar.popup.rect.midX, y: bar.popup.rect.midY)

    try bar.hover(at: pointer)
    XCTAssertEqual(bar.previews(), ["feed"])
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 1)

    panel.nativeMenuBarRevealDidChange(true, pointer: pointer)
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 0, "The reveal clears the wash it lands on")
    try bar.hover(at: pointer)
    panel.refreshStatusBarPopup(popups: [bar.popup], at: pointer, screenSnapshot: bar.snapshot)
    XCTAssertEqual(
      bar.previews(), ["feed"], "No hover path may open a preview under the native menu bar")
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 0, "No hover path may wash under it either")

    panel.nativeMenuBarRevealDidChange(false, pointer: pointer)
    XCTAssertEqual(
      bar.previews(), ["feed", "feed"], "Folding away resumes hover under a parked pointer")
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 1)
  }

  /// A pointer thrown at the bar comes to rest on the display's top point
  /// row. That row belongs to the bar like the rest of the band: hovering
  /// there washes the label and asks for its preview, a stationary re-hit-test
  /// keeps it, and a spawn dwell arms. Only a reveal the probe confirms takes
  /// the band, clearing all of it.
  func testTopEdgeRowHoversLikeTheRestOfTheBand() throws {
    let bar = try makeHoverBar()
    let panel = bar.panel
    let edge = CGPoint(x: bar.popup.rect.midX, y: bar.popup.rect.maxY - 0.5)
    XCTAssertTrue(bar.popup.rect.contains(edge))

    try bar.hover(at: edge)
    XCTAssertEqual(bar.previews(), ["feed"], "The top row opens the label's preview")
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 1)
    panel.refreshStatusBarPopup(popups: [bar.popup], at: edge, screenSnapshot: bar.snapshot)
    XCTAssertEqual(bar.previews(), ["feed", "feed"], "A re-hit-test on the top row keeps it")
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 1)

    panel.statusBarTerminalNeedsSpawnHandler = { _ in true }
    try bar.hover(at: edge)
    XCTAssertEqual(panel.statusBarHoverDwellName, "feed")

    panel.nativeMenuBarRevealDidChange(true, pointer: edge)
    XCTAssertNil(panel.statusBarHoverDwellName, "A confirmed reveal drops the spawn dwell")
    XCTAssertNil(panel.statusBarHoverDwellWork)
    XCTAssertEqual(bar.surface.hoverHighlight.opacity, 0, "and clears the wash")
  }

  func testHoverEligibilityFollowsTheReveal() {
    var state = StatusBarHoverState()
    XCTAssertTrue(state.permitsHover)
    func apply(_ revealed: Bool) -> StatusBarHoverState.Effect {
      let (next, effect) = state.applying(nativeMenuBarRevealed: revealed)
      state = next
      return effect
    }
    XCTAssertEqual(apply(false), .none)
    XCTAssertEqual(apply(true), .suppress)
    XCTAssertFalse(state.permitsHover)
    XCTAssertEqual(apply(true), .none, "Repeated verdicts change nothing")
    XCTAssertEqual(apply(false), .resume)
    XCTAssertTrue(state.permitsHover)
    XCTAssertEqual(apply(false), .none)
    XCTAssertEqual(state, StatusBarHoverState())
  }

}

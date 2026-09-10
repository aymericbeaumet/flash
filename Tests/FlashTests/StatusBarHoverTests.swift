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
    controller.willFocus = { focusTransitions += 1 }
    controller.preview(
      region, pointer: CGPoint(x: 150, y: 812),
      visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 800), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    panel.activateStatusBarPopup(region, at: .zero)
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
    var config = Config()
    config.terminals["shell"] = .init(
      command: ["/bin/cat"], columns: 40, rows: 10, persistent: true)
    panel.statusTerminals.apply(config.statusBar, terminals: config.terminals)
    defer {
      panel.statusPopupController.dismiss()
      panel.statusTerminals.shutdown()
    }
    panel.statusPopupController.showTerminal(
      name: "shell", visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 800),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    panel.hideStatusBarClickWindows()
    panel.statusBarNativeMenuDidReveal()
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
}

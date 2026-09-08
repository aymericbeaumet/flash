import AppKit
import FlashTerminal
import XCTest

@testable import flash

final class StatusPopupControllerTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
    let ready = expectation(
      for: NSPredicate { _, _ in condition() }, evaluatedWith: nil,
      handler: nil)
    ready.expectationDescription = description
    wait(for: [ready], timeout: 5)
  }

  private func region(_ name: String = "details", text: String) -> StatusBarPopupRegion {
    StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 500, width: 100, height: 20), name: name,
      content: text, document: [FlashStatusTextSegment(text: text, foreground: .defaultForeground)])
  }

  private func preview(
    _ controller: StatusPopupController, region: StatusBarPopupRegion,
    screen: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)
  ) {
    controller.preview(
      region, pointer: CGPoint(x: screen.midX, y: screen.maxY), visibleFrame: screen,
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }

  func testTypedDocumentPreservesExtendedStylesAndSanitizesContent() {
    var segment = FlashStatusTextSegment(
      text: "界\u{1B}[2J", foreground: .rgb(0x010203),
      bold: true, italics: true, underline: true, dim: true, reverse: true, blink: true)
    segment.underlineStyle = .curly
    segment.underlineColor = .rgb(0x040506)
    segment.strikethrough = true
    segment.overline = true
    let document = TerminalDocument(columns: 20, rows: 2)
    let ready = expectation(description: "styled frame")
    document.onFrame = { frame in
      let cell = frame.cells[0]
      XCTAssertEqual(cell.text, "界")
      XCTAssertEqual(cell.width, 2)
      XCTAssertEqual(cell.flags, 1 | 2 | 4 | 8 | 16 | 64 | 128)
      XCTAssertEqual(cell.underline, 3)
      XCTAssertEqual(cell.underlineColor.red, 4)
      XCTAssertEqual(cell.underlineColor.green, 5)
      XCTAssertEqual(cell.underlineColor.blue, 6)
      XCTAssertTrue(frame.text.contains("界�[2J"))
      ready.fulfill()
    }
    document.replace(data: StatusPopupController.documentVT([segment]))
    wait(for: [ready], timeout: 5)
  }

  func testDocumentGridUsesTerminalWidthsAndWideCharacterWrap() {
    let grid = StatusPopupController.documentGrid(
      text: "aa界aa", availableColumns: 3, maximumRows: 10)
    XCTAssertEqual(grid.columns, 3)
    XCTAssertEqual(grid.rows, 3)
    let emoji = StatusPopupController.documentGrid(
      text: "👩🏽‍💻é", availableColumns: 10, maximumRows: 10)
    XCTAssertEqual(emoji.columns, 3)
    XCTAssertEqual(emoji.rows, 1)
  }

  func testSameDocumentRefreshPreservesScrollAndChangedTextClearsOldTail() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let text = (1...20).map { "row\($0)" }.joined(separator: "\n")
    let popup = region(text: text)
    let screen = CGRect(x: -600, y: 0, width: 600, height: 90)
    preview(controller, region: popup, screen: screen)
    waitUntil("document starts at top") {
      controller.terminalView.terminalFrame?.text.hasPrefix("row1\n") == true
    }
    controller.terminalView.scroll(lines: 8)
    waitUntil("document scrolled") {
      controller.terminalView.terminalFrame?.text.hasPrefix("row9\n") == true
    }
    controller.refresh([popup])
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    XCTAssertTrue(controller.terminalView.terminalFrame?.text.hasPrefix("row9\n") == true)
    controller.refresh([region(text: "x")])
    waitUntil("old document tail cleared") { controller.terminalView.terminalFrame?.text == "x" }
    XCTAssertGreaterThanOrEqual(controller.frame.minX, screen.minX)
    XCTAssertLessThanOrEqual(controller.frame.maxX, screen.maxX)
    controller.dismiss()
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
  }

  func testLeavingAnchorHidesPreviewAndPreservesFocusedTerminal() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config()
    status.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    defer { registry.shutdown() }
    waitUntil("terminal running") {
      if case .running = registry.sessions["system"]?.state { return true }
      return false
    }
    let session = registry.sessions["system"]
    for focused in [false, true] {
      preview(controller, region: region("system", text: ""))
      if focused { controller.focus() }
      var callbacks: [String] = []
      controller.willDismissFocus = { callbacks.append("flush") }
      controller.didDismissFocus = { callbacks.append("restore") }
      controller.leaveAnchor()
      XCTAssertEqual(controller.isVisible, focused)
      XCTAssertEqual(controller.terminalView.isRenderingEnabled, focused)
      XCTAssertEqual(callbacks, [])
      controller.dismiss()
      XCTAssertFalse(controller.isVisible)
      XCTAssertFalse(controller.terminalView.isRenderingEnabled)
      XCTAssertEqual(callbacks, focused ? ["flush", "restore"] : [])
      XCTAssertTrue(registry.sessions["system"] === session)
      guard case .running = session?.state else {
        XCTFail("Leaving the anchor must keep the terminal running")
        return
      }
    }
  }

  func testFocusedPopupIgnoresOtherHoverAndKeepsAnchorWhenContentRefreshes() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    let popup = region("article", text: "Original article")
    preview(controller, region: popup)
    controller.focus()
    let focused = controller.presentation
    let panelFrame = controller.frame
    preview(
      controller, region: region("other", text: "Other content"),
      screen: CGRect(x: -600, y: 0, width: 600, height: 400))
    controller.leaveAnchor()
    XCTAssertEqual(controller.presentation, focused)
    XCTAssertEqual(controller.content, "Original article")
    XCTAssertEqual(controller.frame, panelFrame)
    controller.refresh([
      region("other", text: "Other content"), region("article", text: "Updated article"),
    ])
    waitUntil("focused document refreshes") {
      controller.terminalView.terminalFrame?.text == "Updated article"
    }
    XCTAssertEqual(controller.presentation, focused)
    XCTAssertEqual(controller.content, "Updated article")
    XCTAssertTrue(controller.terminalView.isRenderingEnabled)
  }

  func testRemovingFocusedAnchorDismissesAndRestoresInput() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    preview(controller, region: region(text: "Article"))
    controller.focus()
    var callbacks: [String] = []
    controller.willDismissFocus = { callbacks.append("flush") }
    controller.didDismissFocus = { callbacks.append("restore") }
    controller.refresh([region("other", text: "Other content")])
    XCTAssertFalse(controller.isVisible)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(callbacks, ["flush", "restore"])
  }

  func testRepeatedHoverRestoresCachedDocumentAndPreservesItsRenderedFrame() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    let popup = region(text: "Article title\nFirst paragraph\nSecond paragraph")
    preview(controller, region: popup)
    waitUntil("article rendered") {
      controller.terminalView.terminalFrame?.text.contains("First paragraph") == true
    }
    let renderedText = controller.terminalView.terminalFrame?.text
    let renderedFrame = controller.terminalView.frame
    let panelFrame = controller.frame
    for _ in 0..<3 {
      controller.leaveAnchor()
      XCTAssertFalse(controller.isVisible)
      XCTAssertFalse(controller.terminalView.isRenderingEnabled)
      preview(controller, region: popup)
      XCTAssertTrue(controller.isVisible)
      XCTAssertTrue(controller.terminalView.isRenderingEnabled)
      XCTAssertEqual(controller.terminalView.terminalFrame?.text, renderedText)
      XCTAssertEqual(controller.terminalView.frame, renderedFrame)
      XCTAssertEqual(controller.frame, panelFrame)
    }
  }

  func testRepeatedHoverRendersUpdatedAndDifferentDocuments() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    for popup in [
      region("first", text: "First article\nOriginal paragraph"),
      region("first", text: "Updated article"),
      region("second", text: "Second article\nDifferent paragraph"),
      region("first", text: "Updated article"),
    ] {
      preview(controller, region: popup)
      waitUntil("current article rendered") {
        controller.terminalView.terminalFrame?.text == popup.content
      }
      XCTAssertTrue(controller.isVisible)
      XCTAssertTrue(controller.terminalView.isRenderingEnabled)
      controller.leaveAnchor()
    }
  }

  func testPopupDiagnosticsDescribeLifecycleWithoutContentOrMouseMoveDuplicates() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { record in
      if record.source.contains("StatusPopupController") { records.append(record) }
    }
    defer { FlashLog.removeSink(sink) }
    let popup = region("inline:private-encoded-body", text: "Private article text")
    preview(controller, region: popup)
    waitUntil("article frame ready") {
      controller.terminalView.terminalFrame?.text == popup.content
    }
    preview(controller, region: popup)
    let settledRecordCount = records.count
    for offset in 0..<10 {
      controller.preview(
        popup, pointer: CGPoint(x: 300 + offset, y: 400),
        visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400), style: .init(),
        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }
    XCTAssertEqual(records.count, settledRecordCount)
    controller.focus()
    controller.leaveAnchor()
    controller.dismiss(reason: "explicit_dismiss")
    XCTAssertTrue(records.contains { $0.fields["state"] == "focused" })
    XCTAssertTrue(
      records.contains {
        $0.fields["state"] == "hidden" && $0.fields["reason"] == "explicit_dismiss"
          && $0.fields["rendering_enabled"] == "false"
      })
    XCTAssertTrue(records.contains { $0.fields["document_cache"] == "reused" })
    XCTAssertTrue(records.contains { $0.fields["frame_ready"] == "true" })
    for record in records {
      let diagnostic = record.message + record.fields.values.joined()
      XCTAssertFalse(diagnostic.contains(popup.name))
      XCTAssertFalse(diagnostic.contains(popup.content))
    }
  }

  func testTerminalRemovalFlushesFocusedInputBeforeStoppingAndHiding() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config()
    status.terminals["system"] = .init(command: ["/bin/sleep", "30"], persistent: true)
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    defer { registry.shutdown() }
    waitUntil("terminal running") {
      if case .running = registry.sessions["system"]?.state { return true }
      return false
    }
    preview(controller, region: region("system", text: ""))
    controller.focus()
    var callbacks: [String] = []
    controller.willDismissFocus = {
      XCTAssertEqual(controller.focusedName, "system")
      XCTAssertNotNil(registry.sessions["system"])
      XCTAssertTrue(controller.terminalView.isRenderingEnabled)
      callbacks.append("flush")
    }
    controller.didDismissFocus = {
      XCTAssertNil(controller.focusedName)
      XCTAssertFalse(controller.terminalView.isRenderingEnabled)
      callbacks.append("restore")
    }
    status.terminals.removeAll()
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    XCTAssertEqual(callbacks, ["flush", "restore"])
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(registry.sessions["system"])
  }

  func testExitedTerminalFooterFitsScreenAndInvalidReloadPreservesSession() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config()
    status.terminals["system"] = .init(
      command: ["/bin/sh", "-c", "printf retained; exit 9"], rows: 100, persistent: true)
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    defer { registry.shutdown() }
    let original = registry.sessions["system"]!
    let stateChanged = original.onStateChange
    let exited = expectation(description: "exit footer before automatic retry")
    var observedExit = false
    original.onStateChange = { state in
      stateChanged?(state)
      guard state == .exited(code: 9), !observedExit else { return }
      observedExit = true
      let screen = CGRect(x: -600, y: -100, width: 400, height: 90)
      self.preview(controller, region: self.region("system", text: ""), screen: screen)
      XCTAssertTrue(controller.exitStatusText.contains("9"))
      XCTAssertTrue(controller.exitStatusText.contains("restarting automatically"))
      XCTAssertGreaterThanOrEqual(controller.terminalView.frame.minY, 0)
      XCTAssertLessThanOrEqual(controller.frame.height, screen.height)
      XCTAssertLessThanOrEqual(controller.terminalView.frame.maxY, controller.frame.height)
      status.terminals.removeAll()
      status.invalidTerminalNames = ["system"]
      registry.apply(
        status.statusBar, terminals: status.terminals,
        invalidTerminalNames: status.invalidTerminalNames)
      XCTAssertTrue(registry.sessions["system"] === original)
      XCTAssertTrue(controller.isVisible)
      exited.fulfill()
    }
    wait(for: [exited], timeout: 5)
    original.onStateChange = stateChanged
  }

  func testStandaloneTerminalCentersClampsAndSurvivesStatusBarChanges() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config()
    status.terminals["shell"] = .init(
      command: ["/bin/sleep", "30"], columns: 100, rows: 40, persistent: true)
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    defer { registry.shutdown() }
    let screen = CGRect(x: -750, y: -300, width: 600, height: 350)
    var callbacks: [String] = []
    controller.willFocus = { callbacks.append("focus") }
    controller.willDismissFocus = { callbacks.append("flush") }
    controller.didDismissFocus = { callbacks.append("restore") }
    controller.didDismiss = { name in
      XCTAssertEqual(name, "shell")
      XCTAssertNil(controller.focusedName)
      XCTAssertEqual(controller.presentation, .hidden)
      callbacks.append("release")
    }
    controller.showTerminal(
      name: "shell", visibleFrame: screen, style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    XCTAssertEqual(controller.presentation, .terminal(name: "shell"))
    XCTAssertEqual(controller.focusedName, "shell")
    XCTAssertEqual(controller.frame.midX, screen.midX, accuracy: 0.5)
    XCTAssertEqual(controller.frame.midY, screen.midY, accuracy: 0.5)
    XCTAssertTrue(screen.contains(controller.frame))
    XCTAssertTrue(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(callbacks, ["focus"])
    let originalFrame = controller.frame
    controller.showTerminal(
      name: "shell", visibleFrame: screen, style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    XCTAssertEqual(callbacks, ["focus"])
    controller.refresh([])
    preview(controller, region: region("shell", text: "Anchor replacement"))
    preview(controller, region: region("other", text: "Other hover"))
    controller.leaveAnchor()
    XCTAssertEqual(controller.presentation, .terminal(name: "shell"))
    XCTAssertEqual(controller.frame, originalFrame)
    XCTAssertEqual(controller.content, "")
    controller.dismiss(reason: "terminal_closed")
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(controller.focusedName)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(callbacks, ["focus", "flush", "restore", "release"])
    controller.dismiss()
    XCTAssertEqual(callbacks, ["focus", "flush", "restore", "release"])
  }

  func testStandaloneRepositionPreservesSessionAndFocusOnSmallerScreen() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config()
    status.terminals["shell"] = .init(
      command: ["/bin/sleep", "30"], columns: 100, rows: 40, persistent: true)
    registry.apply(
      status.statusBar, terminals: status.terminals,
      invalidTerminalNames: status.invalidTerminalNames)
    defer { registry.shutdown() }
    let session = registry.sessions["shell"]
    let generation = registry.inputGenerations["shell"]
    var focusCount = 0
    var dismissalCount = 0
    controller.willFocus = { focusCount += 1 }
    controller.didDismiss = { _ in dismissalCount += 1 }
    controller.showTerminal(
      name: "shell", visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 1000),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    let originalFrame = controller.frame
    let smallerScreen = CGRect(x: -600, y: -350, width: 500, height: 300)
    controller.repositionTerminal(visibleFrame: smallerScreen)
    XCTAssertEqual(controller.presentation, .terminal(name: "shell"))
    XCTAssertEqual(controller.focusedName, "shell")
    XCTAssertEqual(controller.frame.midX, smallerScreen.midX, accuracy: 0.5)
    XCTAssertEqual(controller.frame.midY, smallerScreen.midY, accuracy: 0.5)
    XCTAssertTrue(smallerScreen.contains(controller.frame))
    XCTAssertLessThan(controller.frame.width, originalFrame.width)
    XCTAssertLessThan(controller.frame.height, originalFrame.height)
    XCTAssertTrue(registry.sessions["shell"] === session)
    XCTAssertEqual(registry.inputGenerations["shell"], generation)
    XCTAssertTrue(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(focusCount, 1)
    XCTAssertEqual(dismissalCount, 0)
    controller.dismiss()
    let dismissedFrame = controller.frame
    controller.repositionTerminal(visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 1000))
    XCTAssertEqual(controller.presentation, .hidden)
    XCTAssertEqual(controller.frame, dismissedFrame)
  }

  func testStandaloneTerminalRequiresAnExistingRegistrySession() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    controller.showTerminal(
      name: "missing", visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    XCTAssertEqual(controller.presentation, .hidden)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
  }

  func testTerminalEnvironmentExpandsOverridesAgainstBaseThenArguments() {
    let definition = Config.Terminal(
      command: ["$BIN/tool", "${TOKEN}"],
      workingDirectory: "$PROJECT",
      environment: ["BIN": "$HOME/bin", "TOKEN": "value", "PATH": "$HOME/bin:$PATH"])
    let config = StatusTerminalRegistry.configuration(
      for: definition,
      environment: ["HOME": "/tmp/home", "PROJECT": "/tmp/project", "PATH": "/usr/bin"])
    XCTAssertEqual(config.command, ["/tmp/home/bin/tool", "value"])
    XCTAssertEqual(config.workingDirectory, "/tmp/project")
    XCTAssertEqual(config.environment["PATH"], "/tmp/home/bin:/usr/bin")
    XCTAssertEqual(
      StatusTerminalRegistry.expand("$MISSING/${BAD", environment: [:]), "$MISSING/${BAD")
  }
}

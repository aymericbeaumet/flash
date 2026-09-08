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

  func testLeavingAnchorHidesImmediatelyWithoutStoppingTerminal() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config.StatusBar()
    status.terminalPopups["system"] = .init(command: ["/bin/sleep", "30"])
    registry.apply(status)
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

  func testTerminalRemovalFlushesFocusedInputBeforeStoppingAndHiding() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config.StatusBar()
    status.terminalPopups["system"] = .init(command: ["/bin/sleep", "30"])
    registry.apply(status)
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
    status.terminalPopups.removeAll()
    registry.apply(status)
    XCTAssertEqual(callbacks, ["flush", "restore"])
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(registry.sessions["system"])
  }

  func testExitedTerminalFooterFitsScreenAndInvalidReloadPreservesSession() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var status = Config.StatusBar()
    status.terminalPopups["system"] = .init(
      command: ["/bin/sh", "-c", "printf retained; exit 9"], rows: 100)
    registry.apply(status)
    defer { registry.shutdown() }
    waitUntil("exit retained") { registry.sessions["system"]?.state == .exited(code: 9) }
    let original = registry.sessions["system"]
    let screen = CGRect(x: -600, y: -100, width: 400, height: 90)
    preview(controller, region: region("system", text: ""), screen: screen)
    XCTAssertTrue(controller.exitStatusText.contains("9"))
    XCTAssertGreaterThanOrEqual(controller.terminalView.frame.minY, 0)
    XCTAssertLessThanOrEqual(controller.frame.height, screen.height)
    XCTAssertLessThanOrEqual(controller.terminalView.frame.maxY, controller.frame.height)
    status.terminalPopups.removeAll()
    status.invalidTerminalPopupNames = ["system"]
    registry.apply(status)
    XCTAssertTrue(registry.sessions["system"] === original)
    XCTAssertTrue(controller.isVisible)
  }

  func testTerminalEnvironmentExpandsOverridesAgainstBaseThenArguments() {
    let definition = Config.StatusBar.TerminalPopup(
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

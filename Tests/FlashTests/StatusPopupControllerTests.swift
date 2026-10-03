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

  private func terminal(
    _ command: [String], persistent: Bool = false, size: Config.PopupSize = .default
  ) -> Config.Terminal {
    Config.Terminal(command: command, size: size, lifecycle: persistent ? .persistent : .fresh)
  }

  private func show(
    _ controller: StatusPopupController, _ name: String, document: [FlashStatusTextSegment]? = nil,
    screen: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)
  ) {
    controller.show(
      name: name, document: document, visibleFrame: screen, style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }

  private func preview(
    _ controller: StatusPopupController, region: StatusBarPopupRegion,
    screen: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)
  ) {
    controller.preview(
      region, visibleFrame: screen,
      style: .init(), font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
  }

  func testTypedPopupPreservesExtendedStylesAndSanitizesContent() throws {
    var segment = FlashStatusTextSegment(
      text: "界\u{1B}[2J", foreground: .rgb(0x010203),
      bold: true, italics: true, underline: true, dim: true, reverse: true, blink: true)
    segment.underlineStyle = .curly
    segment.underlineColor = .rgb(0x040506)
    segment.strikethrough = true
    segment.overline = true
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var popup = region(text: segment.text)
    popup.document = [segment]
    preview(controller, region: popup)
    waitUntil("styled pager frame") {
      controller.terminalView.terminalFrame?.text.contains("界�[2J") == true
    }
    let frame = try XCTUnwrap(controller.terminalView.terminalFrame)
    let cell = frame.cells[0]
    XCTAssertEqual(cell.text, "界")
    XCTAssertEqual(cell.width, 2)
    XCTAssertEqual(cell.flags, 1 | 2 | 4 | 8 | 16 | 64 | 128)
    XCTAssertEqual(cell.underline, 3)
    XCTAssertEqual(cell.underlineColor.red, 4)
    XCTAssertEqual(cell.underlineColor.green, 5)
    XCTAssertEqual(cell.underlineColor.blue, 6)
    controller.dismiss()
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

  func testTextPopupGrowsFromMinWidthToItsWidestLineAndWrapsPastMaxWidth() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let cell = TerminalView.cellSize(for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    let style = Config.PopupStyle()
    let inset = CGFloat(style.padding + style.borderWidth)
    func width(_ columns: Int) -> CGFloat { CGFloat(columns) * cell.width + inset * 2 }
    let minimum = Int((CGFloat(style.minWidth) - inset * 2) / cell.width)
    let maximum = Int((CGFloat(style.maxWidth) - inset * 2) / cell.width)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    preview(controller, region: region(text: "Monday\nTue"), screen: screen)
    XCTAssertEqual(controller.frame.width, width(minimum), "short text keeps min_width")
    controller.refresh([region(text: String(repeating: "x", count: minimum + 10))])
    XCTAssertEqual(controller.frame.width, width(minimum + 10), "a wider line widens it")
    XCTAssertEqual(controller.frame.height, cell.height + inset * 2, "without wrapping")
    controller.refresh([region(text: String(repeating: "x", count: 500))])
    XCTAssertEqual(controller.frame.width, width(maximum))
    XCTAssertEqual(
      controller.frame.height, CGFloat((500 + maximum - 1) / maximum) * cell.height + inset * 2,
      "longer lines wrap at max_width; the hover preview clips less's prompt row")

    preview(
      controller, region: region(text: "Monday"),
      screen: CGRect(x: 0, y: 0, width: 200, height: 400))
    XCTAssertLessThanOrEqual(controller.frame.width, 200, "the screen caps it too")
    controller.dismiss()
  }

  func testPopupLinkLabelsReachTerminalFramesWithoutControlInjection() throws {
    var linked = FlashStatusTextSegment(text: "Read", foreground: .defaultForeground)
    linked.link = "https://example.com/article"
    var invalid = FlashStatusTextSegment(text: " Plain", foreground: .defaultForeground)
    invalid.link = "https://example.com/\u{1B}[2J"
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var popup = region(text: "Read Plain")
    popup.document = [linked, invalid]
    preview(controller, region: popup)
    waitUntil("pager hyperlinks") {
      controller.terminalView.terminalFrame?.text.hasPrefix("Read Plain") == true
    }
    let frame = try XCTUnwrap(controller.terminalView.terminalFrame)
    XCTAssertTrue(frame.cells.prefix(4).allSatisfy { $0.hyperlink == linked.link })
    XCTAssertTrue(frame.cells.dropFirst(4).allSatisfy { $0.hyperlink == nil })
    controller.dismiss()
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
    registry.sessions["details"]?.send(Data("8j".utf8))
    waitUntil("document scrolled") {
      controller.terminalView.terminalFrame?.text.hasPrefix("row9\n") == true
    }
    controller.refresh([popup])
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    XCTAssertTrue(controller.terminalView.terminalFrame?.text.hasPrefix("row9\n") == true)
    controller.refresh([region(text: "x")])
    waitUntil("old document tail cleared") {
      let text = controller.terminalView.terminalFrame?.text ?? ""
      return text.hasPrefix("x") && !text.contains("row")
    }
    XCTAssertGreaterThanOrEqual(controller.frame.minX, screen.minX)
    XCTAssertLessThanOrEqual(controller.frame.maxX, screen.maxX)
    controller.dismiss()
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
  }

  func testTextPopupRunsAPTYChildAndDismissalReleasesItsSnapshot() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    preview(controller, region: region(text: "CPU\nTotal 42 %"))
    let session = try XCTUnwrap(registry.sessions["details"])
    waitUntil("popup child running") {
      if case .running = session.state { return true }
      return false
    }
    guard case .running(let pid) = session.state else { return XCTFail("Missing popup child") }
    waitUntil("popup terminal painted") {
      controller.terminalView.terminalFrame?.text.contains("Total 42 %") == true
    }
    let snapshotPath = try XCTUnwrap(session.configuration.command.last)
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath))
    controller.dismiss()
    waitUntil("popup resources released") {
      registry.sessions["details"] == nil && kill(pid, 0) == -1 && errno == ESRCH
        && !FileManager.default.fileExists(atPath: snapshotPath)
    }
  }

  func testFocusedPagerKeepsSearchStableAndExplicitRestartShowsLatestData() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let screen = CGRect(x: 0, y: 0, width: 600, height: 90)
    let original = (1...20).map { "row\($0)" }.joined(separator: "\n")
    preview(controller, region: region(text: original), screen: screen)
    waitUntil("initial pager") {
      controller.terminalView.terminalFrame?.text.hasPrefix("row1\n") == true
    }
    controller.focus()
    registry.sessions["details"]?.send(Data("/row17".utf8))
    waitUntil("pager search prompt") {
      controller.terminalView.terminalFrame?.text.contains("/row17") == true
    }
    let updated = (1...20).map { "new\($0)" }.joined(separator: "\n")
    controller.refresh([region(text: updated)])
    registry.sessions["details"]?.send(Data("\n".utf8))
    waitUntil("search survived data publication") {
      controller.terminalView.terminalFrame?.text.contains("row17") == true
    }
    XCTAssertFalse(controller.terminalView.terminalFrame?.text.contains("new") == true)
    registry.restart(name: "details")
    waitUntil("explicit refresh uses latest collected data") {
      controller.terminalView.terminalFrame?.text.hasPrefix("new1\n") == true
    }
    controller.dismiss()
    preview(controller, region: region("another", text: original), screen: screen)
    waitUntil("different popup starts at top") {
      controller.terminalView.terminalFrame?.text.hasPrefix("row1\n") == true
    }
    controller.dismiss()
  }

  func testLeavingAnchorHidesPreviewAndPreservesFocusedTerminal() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    registry.apply(
      style: .init(), terminals: ["system": terminal(["/bin/sleep", "30"], persistent: true)])
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
      controller.didDismissFocus = { _ in callbacks.append("restore") }
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

  func testCapturedPopupKeepsItsSnapshotUntilExplicitRestart() {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    controller.preview(
      region(text: "Captured article"),
      visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
      preservingContent: true)
    waitUntil("captured pager frame") {
      controller.terminalView.terminalFrame?.text.contains("Captured article") == true
    }
    controller.focus()
    controller.refresh([region(text: "Latest article")])
    controller.updateStyle(.init())
    XCTAssertEqual(controller.content, "Captured article")
    registry.restart(name: "details")
    waitUntil("explicit refresh leaves the captured publication") {
      controller.terminalView.terminalFrame?.text.contains("Latest article") == true
    }
    controller.dismiss()
  }

  func testFocusedPopupKeepsItsSnapshotAndAnchorDuringUpdates() {
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
    waitUntil("focused pager keeps its snapshot") {
      controller.terminalView.terminalFrame?.text.trimmingCharacters(in: .newlines)
        == "Original article"
    }
    XCTAssertEqual(controller.presentation, focused)
    XCTAssertEqual(controller.content, "Original article")
    XCTAssertTrue(controller.terminalView.isRenderingEnabled)
  }

  func testRemovingFocusedAnchorDismissesAndRestoresInput() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    preview(controller, region: region(text: "Article"))
    controller.focus()
    var callbacks: [String] = []
    controller.willDismissFocus = { callbacks.append("flush") }
    controller.didDismissFocus = { _ in callbacks.append("restore") }
    controller.refresh([region("other", text: "Other content")])
    XCTAssertFalse(controller.isVisible)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(callbacks, ["flush", "restore"])
  }

  func testRepeatedHoverStartsFreshPagerAtTheSameSize() {
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
      waitUntil("reopened pager rendered") {
        controller.terminalView.terminalFrame?.text == renderedText
      }
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
        controller.terminalView.terminalFrame?.text.trimmingCharacters(in: .newlines)
          == popup.content
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
      controller.terminalView.terminalFrame?.text.trimmingCharacters(in: .newlines) == popup.content
    }
    preview(controller, region: popup)
    let settledRecordCount = records.count
    // Every mouse move along the label repeats the preview.
    for _ in 0..<10 { preview(controller, region: popup) }
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
    XCTAssertTrue(records.contains { $0.fields["source_kind"] == "pager" })
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
    registry.apply(
      style: .init(), terminals: ["system": terminal(["/bin/sleep", "30"], persistent: true)])
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
    controller.didDismissFocus = { _ in
      XCTAssertNil(controller.focusedName)
      XCTAssertFalse(controller.terminalView.isRenderingEnabled)
      callbacks.append("restore")
    }
    registry.apply(style: .init(), terminals: [:])
    XCTAssertEqual(callbacks, ["flush", "restore"])
    XCTAssertFalse(controller.isVisible)
    XCTAssertNil(registry.sessions["system"])
  }

  func testExitedTerminalFooterFitsScreenAndInvalidReloadPreservesSession() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    registry.apply(
      style: .init(),
      terminals: [
        "system": terminal(
          ["/bin/sh", "-c", "printf retained; exit 9"], persistent: true,
          size: Config.PopupSize(columns: .cells(100), rows: .cells(100)))
      ])
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
      registry.apply(style: .init(), terminals: [:], invalid: ["system"])
      XCTAssertTrue(registry.sessions["system"] === original)
      XCTAssertTrue(controller.isVisible)
      exited.fulfill()
    }
    wait(for: [exited], timeout: 5)
    original.onStateChange = stateChanged
  }

  func testCrashedPersistentTerminalsRestartAndFreshOnesKeepTheirScreenInEveryPresentation() {
    for persistent in [false, true] {
      for presentation in ["preview", "pinned", "standalone"] {
        let registry = StatusTerminalRegistry()
        let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
        defer { registry.shutdown() }
        registry.apply(
          style: .init(),
          terminals: [
            "crash": terminal(
              ["/bin/sh", "-c", "printf 'ready-%s' \"$$\"; exec /bin/sleep 30"],
              persistent: persistent)
          ])
        let name = "crash"
        let session = registry.open(name)!
        if presentation == "standalone" {
          show(controller, name)
        } else {
          preview(controller, region: region(name, text: ""))
          if presentation == "pinned" { controller.focus() }
        }
        waitUntil("initial terminal frame") {
          guard case .running(let pid) = session.state else { return false }
          return controller.terminalView.terminalFrame?.text.contains("ready-\(pid)") == true
        }
        guard case .running(let originalPID) = session.state else {
          return XCTFail("Expected a running child")
        }
        let originalPresentation = controller.presentation
        let originalGeneration = registry.inputGenerations[name]
        var dismissals = 0
        controller.didDismissFocus = { _ in dismissals += 1 }
        XCTAssertEqual(kill(originalPID, SIGKILL), 0)
        if !persistent {
          // Nothing was typed into it: the popup keeps its last screen.
          waitUntil("crashed fresh terminal kept after \(presentation)") {
            session.state == .exited(code: 128 + SIGKILL)
              && controller.exitStatusText == "Exited (\(128 + SIGKILL))"
          }
          XCTAssertTrue(controller.isVisible)
          XCTAssertEqual(controller.presentation, originalPresentation)
          XCTAssertTrue(
            controller.terminalView.terminalFrame?.text.contains("ready-\(originalPID)") == true)
          XCTAssertTrue(registry.sessions[name] === session)
          XCTAssertTrue(registry.hasEnded(name))
          XCTAssertEqual(dismissals, 0)
          controller.dismiss()
          XCTAssertNil(registry.session(named: name))
          XCTAssertEqual(dismissals, presentation == "preview" ? 0 : 1)
          continue
        }
        waitUntil("crashed terminal replaced and rendered") {
          guard case .running(let pid) = session.state, pid != originalPID else { return false }
          return controller.terminalView.terminalFrame?.text.contains("ready-\(pid)") == true
        }
        XCTAssertTrue(registry.sessions[name] === session)
        XCTAssertNotEqual(registry.inputGenerations[name], originalGeneration)
        XCTAssertEqual(controller.presentation, originalPresentation)
        XCTAssertTrue(controller.terminalView.isRenderingEnabled)
        XCTAssertEqual(controller.exitStatusText, "")
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(kill(originalPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        controller.dismiss()
        XCTAssertEqual(registry.sessions[name] != nil, persistent)
      }
    }
  }

  func testStandaloneTerminalCentersClampsAndSurvivesStatusBarChanges() {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    registry.apply(
      style: .init(),
      terminals: [
        "shell": terminal(
          ["/bin/sleep", "30"], persistent: true,
          size: Config.PopupSize(columns: .cells(100), rows: .cells(40)))
      ])
    defer { registry.shutdown() }
    let screen = CGRect(x: -750, y: -300, width: 600, height: 350)
    var callbacks: [String] = []
    controller.willFocus = { callbacks.append("focus") }
    controller.willDismissFocus = { callbacks.append("flush") }
    controller.didDismissFocus = { _ in callbacks.append("restore") }
    controller.didDismiss = { name in
      XCTAssertEqual(name, "shell")
      XCTAssertNil(controller.focusedName)
      XCTAssertEqual(controller.presentation, .hidden)
      callbacks.append("release")
    }
    show(controller, "shell", screen: screen)
    XCTAssertEqual(controller.presentation, .standalone(name: "shell"))
    XCTAssertEqual(controller.focusedName, "shell")
    XCTAssertEqual(controller.frame.midX, screen.midX, accuracy: 0.5)
    XCTAssertEqual(controller.frame.midY, screen.midY, accuracy: 0.5)
    XCTAssertTrue(screen.contains(controller.frame))
    XCTAssertTrue(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(callbacks, ["focus"])
    let originalFrame = controller.frame
    show(controller, "shell", screen: screen)
    XCTAssertEqual(callbacks, ["focus"])
    controller.refresh([])
    preview(controller, region: region("shell", text: "Anchor replacement"))
    preview(controller, region: region("other", text: "Other hover"))
    controller.leaveAnchor()
    XCTAssertEqual(controller.presentation, .standalone(name: "shell"))
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
    registry.apply(
      style: .init(),
      terminals: [
        "shell": terminal(
          ["/bin/sleep", "30"], persistent: true,
          size: Config.PopupSize(columns: .cells(100), rows: .cells(40)))
      ])
    defer { registry.shutdown() }
    let session = registry.sessions["shell"]
    let generation = registry.inputGenerations["shell"]
    var focusCount = 0
    var dismissalCount = 0
    controller.willFocus = { focusCount += 1 }
    controller.didDismiss = { _ in dismissalCount += 1 }
    show(controller, "shell", screen: CGRect(x: 0, y: 0, width: 1400, height: 1000))
    let originalFrame = controller.frame
    let smallerScreen = CGRect(x: -600, y: -350, width: 500, height: 300)
    controller.repositionStandalone(visibleFrame: smallerScreen)
    XCTAssertEqual(controller.presentation, .standalone(name: "shell"))
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
    controller.repositionStandalone(visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 1000))
    XCTAssertEqual(controller.presentation, .hidden)
    XCTAssertEqual(controller.frame, dismissedFrame)
  }

  func testStandaloneTerminalRequiresAnExistingRegistrySession() {
    let controller = StatusPopupController(
      terminals: StatusTerminalRegistry(), windowActionsEnabled: false)
    show(controller, "missing")
    XCTAssertEqual(controller.presentation, .hidden)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
  }

  func testFreshWindowClosesWhenTypedInputEndsItsProcess() throws {
    let registry = StatusTerminalRegistry()
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    registry.apply(style: .init(), terminals: ["shell": terminal(["/bin/cat"])])
    let name = "shell"
    let session = try XCTUnwrap(registry.open(name))
    defer { registry.shutdown() }
    var dismissed: [TerminalSessionState] = []
    controller.didDismiss = { _ in dismissed.append(session.state) }
    var focusDismissalReasons: [String] = []
    controller.didDismissFocus = { focusDismissalReasons.append($0) }
    show(controller, name, screen: CGRect(x: 0, y: 0, width: 1200, height: 800))
    waitUntil("first child running") {
      if case .running = session.state { return true }
      return false
    }
    guard case .running(let pid) = session.state else { return XCTFail("Missing child") }
    // Control-D: end of input, so cat exits 0 because of what was typed.
    session.send(Data([4]))
    waitUntil("window closed with its process") {
      registry.sessions[name] == nil && controller.presentation == .hidden
    }
    XCTAssertEqual(dismissed, [.exited(code: 0)])
    XCTAssertEqual(focusDismissalReasons, ["terminal_removed"])
    XCTAssertNil(controller.focusedName)
    XCTAssertFalse(controller.terminalView.isRenderingEnabled)
    XCTAssertEqual(kill(pid, 0), -1)
  }

  func testOneShotReportKeepsItsOutputAndFootsOnlyAFailedExit() throws {
    for code in [0, 3] {
      for presentation in ["preview", "pinned", "standalone"] {
        let registry = StatusTerminalRegistry()
        defer { registry.shutdown() }
        let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
        let name = "report"
        registry.apply(
          style: .init(),
          terminals: [name: terminal(["/bin/sh", "-c", "printf report-body; exit \(code)"])])
        let session = try XCTUnwrap(registry.open(name))
        var dismissals: [String] = []
        controller.didDismiss = { dismissals.append($0) }
        if presentation == "standalone" {
          show(controller, name)
        } else {
          preview(controller, region: region(name, text: ""))
          if presentation == "pinned" { controller.focus() }
        }
        let shown = controller.presentation
        waitUntil("report finished in \(presentation)") {
          session.state == .exited(code: Int32(code))
            && controller.terminalView.terminalFrame?.text.contains("report-body") == true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.presentation, shown, "\(presentation) exit \(code)")
        XCTAssertTrue(controller.terminalView.isRenderingEnabled)
        XCTAssertEqual(controller.exitStatusText, code == 0 ? "" : "Exited (\(code))")
        XCTAssertTrue(registry.session(named: name) === session)
        XCTAssertEqual(dismissals, [])
        controller.dismiss()
        XCTAssertEqual(dismissals, [name])
        XCTAssertNil(registry.session(named: name))
      }
    }
  }

  func testExitFooterNamesAFailedFreshExitAndEveryPersistentOne() {
    XCTAssertEqual(StatusPopupController.exitFooter(.exited(code: 0), lifecycle: .fresh), "")
    XCTAssertEqual(
      StatusPopupController.exitFooter(.exited(code: 3), lifecycle: .fresh), "Exited (3)")
    XCTAssertEqual(
      StatusPopupController.exitFooter(.exited(code: 0), lifecycle: .persistent),
      "Exited (0) · restarting automatically")
    for lifecycle: Config.PopupLifecycle in [.fresh, .persistent] {
      XCTAssertEqual(
        StatusPopupController.exitFooter(.failed(.commandNotFound("btop")), lifecycle: lifecycle),
        "btop: command not found · install it, then Command-R")
    }
    XCTAssertEqual(
      StatusPopupController.exitFooter(
        .failed(.cannotExecute("/opt/tool", errno: EACCES)), lifecycle: .persistent),
      "/opt/tool: Permission denied · Command-R retries")
    XCTAssertEqual(
      StatusPopupController.exitFooter(.failed(.spawnFailed(errno: EAGAIN)), lifecycle: .fresh),
      "Resource temporarily unavailable")
    for state: TerminalSessionState in [.idle, .running(pid: 1), .stopped] {
      XCTAssertEqual(StatusPopupController.exitFooter(state, lifecycle: .fresh), "")
    }
  }

  func testAKeyPressClosesAnEndedPopupButReleasesModifiersAndCopyDoNot() throws {
    func key(
      _ type: NSEvent.EventType, _ characters: String, code: UInt16,
      modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: code))
    }
    for event in [
      try key(.keyDown, "q", code: 12), try key(.keyDown, "\u{1B}", code: 53),
      try key(.keyDown, "\r", code: 36), try key(.keyDown, "k", code: 40, modifiers: .command),
    ] {
      XCTAssertTrue(StatusPopupController.closesEndedPopup(event), "\(event)")
    }
    for event in [
      try key(.keyUp, "q", code: 12), try key(.keyDown, "c", code: 8, modifiers: .command),
      try key(.keyDown, "v", code: 9, modifiers: .command),
    ] {
      XCTAssertFalse(StatusPopupController.closesEndedPopup(event), "\(event)")
    }
    let shift = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 56))
    XCTAssertFalse(StatusPopupController.closesEndedPopup(shift))
  }

  func testTerminalEnvironmentExpandsOverridesAgainstBaseThenArguments() {
    let definition = Config.Terminal(
      command: ["$BIN/tool", "${TOKEN}"],
      workingDirectory: "$PROJECT",
      environment: ["BIN": "$HOME/bin", "TOKEN": "value", "PATH": "$HOME/bin:$PATH"])
    XCTAssertEqual(
      StatusTerminalRegistry.configuration(for: definition, environment: [:]).scrollbackLines,
      StatusTerminalRegistry.freshScrollbackLines)
    let config = StatusTerminalRegistry.configuration(
      for: definition,
      environment: [
        "HOME": "/tmp/home", "PROJECT": "/tmp/project", "PATH": "/usr/bin", "NO_COLOR": "1",
      ])
    XCTAssertEqual(config.command, ["/tmp/home/bin/tool", "value"])
    XCTAssertEqual(config.workingDirectory, "/tmp/project")
    XCTAssertEqual(config.environment["PATH"], "/tmp/home/bin:/usr/bin")
    XCTAssertNil(config.environment["NO_COLOR"])
    let explicitlyPlain = StatusTerminalRegistry.configuration(
      for: .init(command: ["/bin/sh"], environment: ["NO_COLOR": "1"]), environment: [:])
    XCTAssertEqual(explicitlyPlain.environment["NO_COLOR"], "1")
    XCTAssertEqual(
      CommandLaunchConfiguration.expand("$MISSING/${BAD", environment: [:]), "$MISSING/${BAD")
  }

  func testDocumentGridASCIIFastPathMatchesMeasuredGrid() {
    let samples = [
      "", "a", "abc\ndefghij\n\nk", String(repeating: "x", count: 25), "ab cd ef gh\n12345678901",
    ]
    for text in samples {
      for columns in [1, 3, 7, 10, 80] {
        let fast = StatusPopupController.documentGrid(
          text: text, availableColumns: columns, maximumRows: 100)
        let measured = StatusPopupController.measuredDocumentGrid(
          text: text, availableColumns: columns, maximumRows: 100)
        XCTAssertEqual(fast.columns, measured.columns, "\(text) at \(columns)")
        XCTAssertEqual(fast.rows, measured.rows, "\(text) at \(columns)")
      }
    }
    XCTAssertEqual(
      StatusPopupController.documentGrid(
        text: "abcdefghij\nxy", availableColumns: 4, maximumRows: 100
      ).rows, 4)
  }

  func testStandaloneTextPopupKeepsItsDocumentUntilAnExplicitRestart() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    var focused = 0
    controller.willFocus = { focused += 1 }
    show(
      controller, "date",
      document: [FlashStatusTextSegment(text: "Monday", foreground: .defaultForeground)])
    XCTAssertEqual(controller.presentation, .standalone(name: "date"))
    XCTAssertEqual(focused, 1)
    XCTAssertTrue(registry.isPager("date"))
    waitUntil("standalone pager drawn") {
      controller.terminalView.terminalFrame?.text.contains("Monday") == true
    }
    controller.stageStandalone([
      "date": [FlashStatusTextSegment(text: "Tuesday", foreground: .defaultForeground)]
    ])
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertFalse(controller.terminalView.terminalFrame?.text.contains("Tuesday") == true)
    registry.restart(name: "date")
    waitUntil("explicit restart shows the latest document") {
      controller.terminalView.terminalFrame?.text.contains("Tuesday") == true
    }
    let session = try XCTUnwrap(registry.session(named: "date"))
    controller.dismiss()
    XCTAssertNil(registry.session(named: "date"), "dismissal ends the pager")
    XCTAssertNotEqual(session.state, .idle)
  }

  func testPercentSizedPopupFollowsTheScreenItShowsOn() throws {
    let registry = StatusTerminalRegistry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let size = try XCTUnwrap(Config.PopupSize("50%x50%"))
    registry.apply(
      style: .init(),
      terminals: ["top": terminal(["/bin/sleep", "30"], persistent: true, size: size)])
    let session = try XCTUnwrap(registry.open("top"))
    let small = CGRect(x: 0, y: 0, width: 800, height: 600)
    show(controller, "top", screen: small)
    let cell = controller.terminalView.cellSize
    let inset = CGFloat(Config.PopupStyle().padding + Config.PopupStyle().borderWidth)
    let expected = size.grid(visible: small.size, cell: cell, inset: inset)
    waitUntil("grid follows the first screen") {
      session.frame?.columns == expected.columns && session.frame?.rows == expected.rows
    }
    XCTAssertEqual(controller.frame.width, small.width / 2, accuracy: cell.width + 1)
    let large = CGRect(x: 800, y: 0, width: 1600, height: 1000)
    controller.repositionStandalone(visibleFrame: large)
    let grown = size.grid(visible: large.size, cell: cell, inset: inset)
    XCTAssertGreaterThan(grown.columns, expected.columns)
    waitUntil("grid follows the new screen") {
      session.frame?.columns == grown.columns && session.frame?.rows == grown.rows
    }
    XCTAssertEqual(controller.frame.midX, large.midX, accuracy: 0.5)
    XCTAssertTrue(registry.session(named: "top") === session, "resizing keeps the process")
  }
}

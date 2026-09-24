import AppKit
import CFlashTerminal
import XCTest

@testable import FlashTerminal

final class TerminalTests: XCTestCase {
  func testANSIIndexedAndTruecolorForegroundsAndBackgroundsReachFrames() throws {
    let cells = try frameFromPTY(
      "\u{1B}[31;44mR\u{1B}[32mG"
        + "\u{1B}[38;5;196;48;5;21mI"
        + "\u{1B}[38;2;7;8;9;48;2;1;2;3mT",
      columns: 8, rows: 1
    ).cells
    XCTAssertGreaterThan(cells[0].foreground.red, cells[0].foreground.green)
    XCTAssertGreaterThan(cells[0].background.blue, cells[0].background.red)
    XCTAssertGreaterThan(cells[1].foreground.green, cells[1].foreground.red)
    XCTAssertEqual(cells[0].background, cells[1].background)
    func rgb(_ color: TerminalColor) -> [UInt8] { [color.red, color.green, color.blue] }
    XCTAssertEqual(rgb(cells[2].foreground), [255, 0, 0])
    XCTAssertEqual(rgb(cells[2].background), [0, 0, 255])
    XCTAssertEqual(rgb(cells[3].foreground), [7, 8, 9])
    XCTAssertEqual(rgb(cells[3].background), [1, 2, 3])
  }

  func testTerminalResponsesInputModesAndBracketedPaste() {
    let buffer = TerminalBuffer(columns: 20, rows: 3, scrollback: true)
    buffer.connectOutput()
    var output = Data()
    buffer.output = { output.append($0) }
    buffer.write(Data("\u{1B}[2;4H\u{1B}[6n".utf8))
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[2;4R")
    output.removeAll()
    flash_vt_key(buffer.handle, 126, 0, 1, nil, 0, 0)
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[A")
    output.removeAll()
    buffer.write(Data("\u{1B}[?1h".utf8))
    flash_vt_key(buffer.handle, 126, 0, 1, nil, 0, 0)
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}OA")
    output.removeAll()
    "c".withCString { flash_vt_key(buffer.handle, 8, 2, 1, $0, 1, 99) }
    XCTAssertEqual(output, Data([3]))
    output.removeAll()
    buffer.write(Data("\u{1B}[?2004h".utf8))
    var paste = Array("hello\nworld".utf8CString)
    let length = paste.count - 1
    paste.withUnsafeMutableBufferPointer { flash_vt_paste(buffer.handle, $0.baseAddress, length) }
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[200~hello\nworld\u{1B}[201~")
  }

  func testKittyModifierEventsEncodePressAndReleaseAndUseLocalInterceptor() {
    let buffer = TerminalBuffer(columns: 20, rows: 3, scrollback: true)
    buffer.connectOutput()
    var output = Data()
    buffer.output = { output.append($0) }
    buffer.write(Data("\u{1B}[>31u".utf8))
    flash_vt_key(buffer.handle, 56, 1, 1, nil, 0, 0)
    let pressed = String(decoding: output, as: UTF8.self)
    XCTAssertFalse(pressed.isEmpty)
    output.removeAll()
    flash_vt_key(buffer.handle, 56, 0, 0, nil, 0, 0)
    XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(":3u"))
    let view = TerminalView(frame: .zero)
    var events: [NSEvent.EventType] = []
    view.inputInterceptor = {
      events.append($0.type)
      return true
    }
    func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent
    {
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code)!
    }
    let leftShiftDown = event(
      .flagsChanged, 56, .init(rawValue: NSEvent.ModifierFlags.shift.rawValue | 2))
    let leftShiftUpWhileRightHeld = event(
      .flagsChanged, 56,
      .init(rawValue: NSEvent.ModifierFlags.shift.rawValue | 4))
    XCTAssertFalse(TerminalView.isKeyRelease(leftShiftDown))
    XCTAssertTrue(TerminalView.isKeyRelease(leftShiftUpWhileRightHeld))
    view.flagsChanged(with: leftShiftDown)
    view.keyUp(with: event(.keyUp, 5, []))
    XCTAssertEqual(events, [.flagsChanged, .keyUp])
  }

  func testPixelMouseEncodingUsesRenderedCellDimensions() {
    let buffer = TerminalBuffer(columns: 20, rows: 3, scrollback: true)
    buffer.connectOutput()
    var output = Data()
    buffer.output = { output.append($0) }
    flash_vt_cell_size(buffer.handle, 8, 16)
    buffer.write(Data("\u{1B}[?1000h\u{1B}[?1016h".utf8))
    flash_vt_mouse(buffer.handle, 0, 1, 0, 3.5, 1.5)
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[<0;28;24M")
    output.removeAll()
    buffer.write(Data("\u{1B}[?1003h".utf8))
    flash_vt_mouse(buffer.handle, 2, 0, 0, 3.75, 1.6875)
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "\u{1B}[<35;30;27M")
  }

  func testAlternateScreenRestoresPrimaryAndScrollback() {
    let buffer = TerminalBuffer(columns: 12, rows: 2, scrollback: true)
    buffer.write(Data("primary\u{1B}[?1049hother".utf8))
    XCTAssertTrue(buffer.snapshot()?.text.contains("other") == true)
    buffer.write(Data("\u{1B}[?1049l".utf8))
    XCTAssertTrue(buffer.snapshot()?.text.contains("primary") == true)
    buffer.write(Data("\r\nsecond\r\nthird".utf8))
    XCTAssertFalse(buffer.snapshot()?.text.contains("primary") == true)
    flash_vt_scroll(buffer.handle, -1)
    XCTAssertTrue(buffer.snapshot()?.text.contains("primary") == true)
  }

  func testPTYInterpretsStylesWideGraphemesAndClearsReplacedTail() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/bin/sh", "-c",
          "stty -echo; printf '%s' \"$1\"; read -r line; printf '%s' \"$2\"; read -r line",
          "terminal-fixture", "\u{1B}[38;2;1;2;3m界é long", "\u{1B}[0m\u{1B}[2J\u{1B}[Hx",
        ], columns: 12, rows: 2))
    defer { session.shutdown() }
    let first = expectation(
      for: NSPredicate { _, _ in session.frame?.text == "界é long\n" }, evaluatedWith: nil)
    session.start()
    wait(for: [first], timeout: 5)
    let frame = try XCTUnwrap(session.frame)
    XCTAssertEqual(frame.cells[0].text, "界")
    XCTAssertEqual(frame.cells[0].width, 2)
    XCTAssertEqual(frame.cells[1].width, 0)
    XCTAssertEqual(frame.cells[2].text, "é")
    XCTAssertEqual(frame.cells[0].foreground.red, 1)
    let replacement = expectation(
      for: NSPredicate { _, _ in session.frame?.text == "x\n" }, evaluatedWith: nil)
    session.send(Data("go\n".utf8))
    wait(for: [replacement], timeout: 5)
  }

  func testTerminalTextSanitizesLiteralControlSequencesAndLineEndings() {
    XCTAssertEqual(TerminalText.sanitize(text: "a\u{1B}[2J\u{9B}31m\n\t\0"), "a�[2J�31m\n\t�")
    XCTAssertEqual(TerminalText.sanitize(text: "first\r\nsecond\rlast"), "first\nsecond�last")
  }

  func testTerminalTextMeasuresWideAndCombiningGraphemes() {
    for (text, width) in [("", 0), ("a", 1), ("界", 2), ("é", 1), ("🚀", 2)] {
      XCTAssertEqual(TerminalText.cellWidth(of: text), width, text)
    }
  }

  func testControlChordsFromTheViewReachTheChildAsControlBytes() throws {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/bin/sh", "-c", "stty -echo; printf READY; cat; printf CAT_DONE"],
        columns: 30, rows: 4))
    defer { session.shutdown() }
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    view.isRenderingEnabled = true
    view.bind(session: session)
    session.start()
    func waitForText(_ text: String) {
      let ready = expectation(
        for: NSPredicate { _, _ in view.terminalFrame?.text.contains(text) == true },
        evaluatedWith: nil)
      wait(for: [ready], timeout: 5)
    }
    waitForText("READY")
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{04}", charactersIgnoringModifiers: "d",
        isARepeat: false, keyCode: 2))
    view.keyDown(with: event)
    waitForText("CAT_DONE")
  }

  func testPTYStartsBeforeAnyViewAndRetainsExitedScreen() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/bin/sh", "-c",
          "test -t 0 && test -t 1 && printf 'PTY:%s:%s' \"$TERM\" \"$(stty size)\"; exit 7",
        ], columns: 40, rows: 8))
    defer { session.shutdown() }
    let exited = expectation(description: "child exited")
    session.onStateChange = { state in
      if case .exited(let code) = state {
        XCTAssertEqual(code, 7)
        exited.fulfill()
      }
    }
    session.start()
    wait(for: [exited], timeout: 5)
    XCTAssertTrue(session.frame?.text.contains("PTY:xterm-256color:8 40") == true)
    let retained = session.frame
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(session.frame, retained)
  }

  func testSwitchingSessionsStopsPreviousFramesAndRebindingShowsLatestOutput() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/bin/sh", "-c", "stty -echo; printf READY; read line; printf LATEST"],
        columns: 20, rows: 3))
    defer { session.shutdown() }
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
    view.isRenderingEnabled = true
    view.bind(session: session)
    session.start()
    let ready = expectation(
      for: NSPredicate { _, _ in view.terminalFrame?.text.contains("READY") == true },
      evaluatedWith: nil)
    wait(for: [ready], timeout: 5)
    let replacement = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/bin/sh", "-c", "printf OTHER; read line"], columns: 20, rows: 3))
    defer { replacement.shutdown() }
    view.bind(session: replacement)
    replacement.start()
    let replaced = expectation(
      for: NSPredicate { _, _ in view.terminalFrame?.text.contains("OTHER") == true },
      evaluatedWith: nil)
    wait(for: [replaced], timeout: 5)
    let hiddenFrame = session.frame
    session.send(Data("go\n".utf8))
    let exited = expectation(
      for: NSPredicate { _, _ in session.state == .exited(code: 0) }, evaluatedWith: nil)
    wait(for: [exited], timeout: 5)
    XCTAssertEqual(session.frame?.generation, hiddenFrame?.generation)
    XCTAssertTrue(view.terminalFrame?.text.contains("OTHER") == true)
    XCTAssertFalse(view.terminalFrame?.text.contains("LATEST") == true)

    view.bind(session: session)
    let latest = expectation(
      for: NSPredicate { _, _ in view.terminalFrame?.text.contains("LATEST") == true },
      evaluatedWith: nil)
    wait(for: [latest], timeout: 5)
  }

  func testInputResizeAndExplicitRestart() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/bin/sh", "-c",
          "stty -echo; printf READY; read line; printf '\nGOT:%s:' \"$line\"; stty size; sleep 30",
        ], columns: 30, rows: 4))
    defer { session.shutdown() }
    let ready = expectation(description: "ready")
    var didSeeReady = false
    session.onFrame = { frame in
      if frame.text.contains("READY") && !didSeeReady {
        didSeeReady = true
        ready.fulfill()
      }
    }
    session.start()
    wait(for: [ready], timeout: 5)
    guard case .running(let firstPID) = session.state else { return XCTFail("No running PTY") }
    let received = expectation(description: "received resized input")
    var didReceive = false
    session.onFrame = { frame in
      if frame.text.contains("GOT:hello:9 60") && !didReceive {
        didReceive = true
        received.fulfill()
      }
    }
    session.resize(columns: 60, rows: 9)
    session.send(Data("hello\n".utf8))
    wait(for: [received], timeout: 5)
    XCTAssertEqual(session.state, .running(pid: firstPID))
    let restarted = expectation(description: "restarted")
    session.onStateChange = { state in
      if case .running(let pid) = state {
        XCTAssertNotEqual(pid, firstPID)
        restarted.fulfill()
      }
    }
    session.restart()
    wait(for: [restarted], timeout: 5)
  }

  func testShutdownKillsForegroundJobAndReapsChild() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(command: ["/bin/sh", "-c", "trap '' HUP TERM; sleep 30"])
    )
    let started = expectation(description: "started")
    var pid: Int32 = 0
    session.onStateChange = { state in
      if case .running(let child) = state {
        pid = child
        started.fulfill()
      }
    }
    session.start()
    wait(for: [started], timeout: 5)
    let before = Date()
    session.shutdown()
    XCTAssertLessThan(Date().timeIntervalSince(before), 1)
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testAsynchronousStopCompletionRunsOnMainAfterChildIsReaped() {
    let session = TerminalSession(configuration: .init(command: ["/bin/sleep", "30"]))
    let started = expectation(description: "started")
    var pid: Int32 = 0
    session.onStateChange = { state in
      if case .running(let child) = state {
        pid = child
        started.fulfill()
      }
    }
    session.start()
    wait(for: [started], timeout: 5)
    let stopped = expectation(description: "stopped and reaped")
    session.stop {
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(session.state, .stopped)
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 3)
  }

  func testReapWaitHasDeadlineWhenKernelDoesNotFinishExit() {
    let before = Date()
    var polls = 0
    let reaped = TerminalChildReaping.wait(pid: 42, timeoutMilliseconds: 20) { _ in
      polls += 1
      return false
    }
    XCTAssertFalse(reaped)
    XCTAssertGreaterThan(polls, 1)
    XCTAssertLessThan(Date().timeIntervalSince(before), 0.2)
  }

  func testDeferredReaperRetriesUntilChildIsReaped() {
    let completed = expectation(description: "deferred child reaped")
    var polls = 0
    TerminalChildReaping.reapLater(
      pid: 42,
      poll: { _ in
        polls += 1
        return polls == 3
      },
      completion: {
        XCTAssertEqual(polls, 3)
        completed.fulfill()
      })
    wait(for: [completed], timeout: 2)
  }

  func testImmediateStopAndRestartOfShortLivedChildrenCompletes() {
    let session = TerminalSession(configuration: .init(command: ["/bin/sh", "-c", "exit 9"]))
    let completed = expectation(description: "queued starts and stops completed")
    for _ in 0..<12 {
      session.restart()
      session.stop()
    }
    session.stop { completed.fulfill() }
    wait(for: [completed], timeout: 8)
    let before = Date()
    session.shutdown()
    XCTAssertLessThan(Date().timeIntervalSince(before), 1)
  }

  func testMissingExecutableReportsFailureWithoutChild() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(command: ["/missing-flash-terminal-test"]))
    defer { session.shutdown() }
    let failed = expectation(description: "failed")
    session.onStateChange = { state in if case .failed = state { failed.fulfill() } }
    session.start()
    wait(for: [failed], timeout: 5)
  }
}

final class TerminalSnapshotTests: XCTestCase {
  func testSnapshotsReportChangedRowsAndReuseCleanOnes() throws {
    let buffer = TerminalBuffer(columns: 10, rows: 4, scrollback: true)
    buffer.write(Data("one\r\ntwo\r\nthree".utf8))
    let first = try XCTUnwrap(buffer.snapshot())
    XCTAssertNil(first.changedRows, "the first frame rebuilds every row")
    XCTAssertEqual(first.generation, 1)
    buffer.write(Data("\u{1B}[2;1HTWO".utf8))
    let second = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(second.generation, 2)
    // The rewritten row and the rows the cursor left and entered are dirty.
    XCTAssertEqual(second.changedRows, [1, 2])
    XCTAssertEqual(second.text, "one\nTWO\nthree\n")
    XCTAssertEqual(second.cells[0..<10].map(\.text), first.cells[0..<10].map(\.text))
    // Nothing visible moved: the buffer hands back the same frame.
    let third = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(third.generation, second.generation)
    XCTAssertEqual(third.changedRows, second.changedRows)
    // Cursor motion alone touches only the rows it left and entered.
    buffer.write(Data("\u{1B}[4;1H".utf8))
    let fourth = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(fourth.generation, 3)
    XCTAssertEqual(fourth.changedRows, [1, 3])
    XCTAssertEqual(fourth.cursorY, 3)
    // Scrolling the viewport into scrollback or an explicit invalidation
    // rebuilds the whole grid.
    buffer.write(Data("\r\nfour\r\nfive\r\nsix".utf8))
    _ = buffer.snapshot()
    flash_vt_scroll(buffer.handle, -1)
    let scrolled = try XCTUnwrap(buffer.snapshot())
    XCTAssertNil(scrolled.changedRows)
    XCTAssertTrue(scrolled.text.hasPrefix("three"))
    buffer.invalidate()
    XCTAssertNil(try XCTUnwrap(buffer.snapshot()).changedRows)
  }

  func testWideCellsHyperlinksAndBlinkSurviveRowReuse() throws {
    let buffer = TerminalBuffer(columns: 12, rows: 3, scrollback: false)
    buffer.write(
      Data(
        ("界\u{1B}]8;;https://example.com/a\u{1B}\\A\u{1B}]8;;\u{1B}\\"
          + "\u{1B}]8;;https://example.com/b\u{1B}\\B\u{1B}]8;;\u{1B}\\\u{1B}[5mx\u{1B}[0m").utf8))
    let first = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(first.cells[0].text, "界")
    XCTAssertEqual(first.cells[0].width, 2)
    XCTAssertEqual(first.cells[1].width, 0)
    XCTAssertEqual(first.cells[2].hyperlink, "https://example.com/a")
    XCTAssertEqual(first.cells[3].hyperlink, "https://example.com/b")
    XCTAssertTrue(first.hasBlinkingCells)
    buffer.write(Data("\u{1B}[3;1Hlast".utf8))
    let second = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(second.changedRows, [0, 2], "the cursor left row 0; row 1 is reused")
    XCTAssertEqual(second.cells[2].hyperlink, "https://example.com/a")
    XCTAssertEqual(second.cells[3].hyperlink, "https://example.com/b")
    XCTAssertTrue(second.hasBlinkingCells, "blink state is carried by reused rows")
  }

  func testFirstOutputAfterIdlePublishesWithoutWaitingForTheFrameInterval() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/bin/sh", "-c", "stty -echo; printf READY; read line; printf ECHO"],
        columns: 20, rows: 2))
    defer { session.shutdown() }
    let ready = expectation(description: "ready")
    session.onFrame = { frame in
      if frame.text.contains("READY") { ready.fulfill() }
    }
    session.start()
    wait(for: [ready], timeout: 5)
    // Let the interval elapse so the reply is the first output after idle.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let echoed = expectation(description: "echo")
    var latency: TimeInterval = .infinity
    let sent = Date()
    session.onFrame = { frame in
      if frame.text.contains("ECHO"), latency == .infinity {
        latency = Date().timeIntervalSince(sent)
        echoed.fulfill()
      }
    }
    session.send(Data("go\n".utf8))
    wait(for: [echoed], timeout: 5)
    XCTAssertLessThan(latency, 0.030, "a leading-edge frame must not wait a coalescing window")
  }
}

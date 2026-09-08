import AppKit
import CFlashTerminal
import XCTest

@testable import FlashTerminal

final class TerminalTests: XCTestCase {
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

  func testDocumentInterpretsStylesWideGraphemesAndReplacesTail() {
    let document = TerminalDocument(columns: 12, rows: 2)
    let first = expectation(description: "first frame")
    document.onFrame = { frame in
      XCTAssertEqual(frame.cells[0].text, "界")
      XCTAssertEqual(frame.cells[0].width, 2)
      XCTAssertEqual(frame.cells[1].width, 0)
      XCTAssertEqual(frame.cells[2].text, "é")
      XCTAssertEqual(frame.cells[0].foreground.red, 1)
      first.fulfill()
    }
    document.replace(data: Data("\u{1B}[38;2;1;2;3m界é long".utf8))
    wait(for: [first], timeout: 3)
    let replacement = expectation(description: "replacement")
    document.onFrame = { frame in
      XCTAssertEqual(frame.text, "x\n")
      replacement.fulfill()
    }
    document.replace(data: Data("x".utf8))
    wait(for: [replacement], timeout: 3)
  }

  func testDocumentSanitizesLiteralControlSequences() {
    XCTAssertEqual(TerminalDocument.sanitize(text: "a\u{1B}[2J\u{9B}31m\n\t\0"), "a�[2J�31m\n\t�")
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

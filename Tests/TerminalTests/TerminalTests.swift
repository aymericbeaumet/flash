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
    let buffer = TerminalBuffer(
      columns: 20, rows: 3, scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
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
    let buffer = TerminalBuffer(
      columns: 20, rows: 3, scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
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
    let buffer = TerminalBuffer(
      columns: 20, rows: 3, scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
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
    let buffer = TerminalBuffer(
      columns: 12, rows: 2, scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
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
    for (text, width) in [
      ("", 0), ("a", 1), (" ", 1), ("~", 1), ("plain ascii", 11), ("a界", 3), ("界", 2), ("é", 1),
      ("🚀", 2),
    ] {
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

  func testDeferredReaperReapsWhenTheKernelReportsTheExit() throws {
    let pid = try spawnChild(["/bin/sleep", "0.3"])
    let started = Date()
    let completed = expectation(description: "deferred child reaped")
    TerminalChildReaping.reapLater(pid: pid) { completed.fulfill() }
    wait(for: [completed], timeout: 5)
    XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "reaped only after it exited")
    XCTAssertEqual(waitpid(pid, nil, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD)
  }

  func testDeferredReaperReapsAChildAlreadyAZombie() throws {
    let pid = try spawnChild(["/usr/bin/true"])
    // Block until it is a zombie without reaping it.
    var info = siginfo_t()
    XCTAssertEqual(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT), 0)
    let completed = expectation(description: "zombie reaped")
    TerminalChildReaping.reapLater(pid: pid) { completed.fulfill() }
    wait(for: [completed], timeout: 2)
    XCTAssertEqual(waitpid(pid, nil, WNOHANG), -1)
  }

  func testExitWaitsEndOnTheExitEventOrTheDeadline() throws {
    let quick = try spawnChild(["/bin/sleep", "0.2"])
    let started = Date()
    XCTAssertTrue(ProcessExit.waitForExit(quick, until: .now() + 5))
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    XCTAssertEqual(ProcessExit.reap(quick), 0)
    // An already-reaped pid is gone: nothing to wait for or reap.
    XCTAssertTrue(ProcessExit.waitForExit(quick, until: .now() + 5))
    XCTAssertNil(ProcessExit.reap(quick))

    let slow = try spawnChild(["/bin/sleep", "30"])
    XCTAssertFalse(ProcessExit.waitForExit(slow, until: .now() + .milliseconds(100)))
    kill(slow, SIGKILL)
    XCTAssertTrue(ProcessExit.waitForExit(slow, until: .now() + 5))
    XCTAssertEqual(ProcessExit.reap(slow), 128 + SIGKILL)
  }

  func testGroupWaitsCoverEveryMemberNotJustTheLeader() throws {
    // The leader exits after 0.1 s; its background child keeps the group
    // alive until 0.4 s.
    let leader = try spawnChild(["/bin/sh", "-c", "/bin/sleep 0.4 & /bin/sleep 0.1"], group: true)
    let started = Date()
    var exited: Set<pid_t> = []
    XCTAssertTrue(ProcessExit.waitForGroups([leader], until: .now() + 5, exited: &exited))
    XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.3)
    XCTAssertTrue(exited.contains(leader))
    XCTAssertEqual(ProcessExit.reap(leader), 0)
    XCTAssertTrue(ProcessExit.members(ofGroup: leader).isEmpty)
  }

  private func spawnChild(_ argv: [String], group: Bool = false) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    if group {
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
      posix_spawnattr_setpgroup(&attributes, 0)
    }
    var pid: pid_t = 0
    var arguments = argv.map { strdup($0) } + [nil]
    defer { for argument in arguments { free(argument) } }
    let error = posix_spawn(&pid, argv[0], nil, &attributes, &arguments, environ)
    guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    return pid
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

  func testShuttingDownSessionsTogetherOverlapsTheirGracePeriods() {
    let sessions = (0..<3).map { _ in
      TerminalSession(
        configuration: TerminalConfiguration(command: [
          "/bin/sh", "-c", "trap '' HUP TERM; sleep 30",
        ]))
    }
    var pids: [Int32] = []
    let started = expectation(description: "started")
    started.expectedFulfillmentCount = sessions.count
    for session in sessions {
      session.onStateChange = { state in
        if case .running(let pid) = state {
          pids.append(pid)
          started.fulfill()
        }
      }
      session.start()
    }
    wait(for: [started], timeout: 5)
    let before = Date()
    TerminalSession.shutdown(sessions)
    // Each child ignores hangup and termination, so each waits out its 200 ms
    // grace period before the kill; one after another would take 600 ms.
    XCTAssertLessThan(Date().timeIntervalSince(before), 0.5)
    for pid in pids {
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
  }

  func testChildrenInheritNoUnrelatedDescriptors() throws {
    var pipe: [Int32] = [0, 0]
    XCTAssertEqual(Darwin.pipe(&pipe), 0)
    // Neither end is close-on-exec; a copy sits far above the other
    // descriptors, on the lowest free number so nothing else is clobbered.
    let high = fcntl(pipe[1], F_DUPFD, 700)
    XCTAssertGreaterThanOrEqual(high, 700)
    defer {
      for descriptor in [pipe[0], pipe[1], high] { close(descriptor) }
    }
    let frame = try frameFromPTY(
      "", columns: 40, rows: 2,
      command: [
        "/bin/sh", "-c",
        "for fd in \(pipe[0]) \(pipe[1]) \(high); do [ -e /dev/fd/$fd ] && printf 'LEAK%s ' $fd; done; printf CLEAN",
      ])
    XCTAssertEqual(frame.text.trimmingCharacters(in: .whitespacesAndNewlines), "CLEAN")
  }

  func testUnchangedColorsDoNotRepublishTheGrid() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/bin/sh", "-c", "printf READY; sleep 30"], columns: 20, rows: 2))
    defer { session.shutdown() }
    var frames: [TerminalFrame] = []
    let ready = expectation(description: "ready")
    session.onFrame = { frame in
      frames.append(frame)
      if frame.text.contains("READY"), frames.filter({ $0.text.contains("READY") }).count == 1 {
        ready.fulfill()
      }
    }
    session.setColors(foreground: .white, background: .black)
    session.start()
    wait(for: [ready], timeout: 5)
    let published = frames.count
    for _ in 0..<5 { session.setColors(foreground: .white, background: .black) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(frames.count, published, "reapplying the same colors publishes nothing")
    let recolored = expectation(description: "recolored")
    session.onFrame = { frame in
      if frame.foreground.red == 0x12 { recolored.fulfill() }
    }
    session.setColors(
      foreground: NSColor(srgbRed: 0x12 / 255, green: 0, blue: 0, alpha: 1), background: .black)
    wait(for: [recolored], timeout: 5)
  }

  func testScrollBurstsShareFrameCoalescing() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/bin/sh", "-c", "i=0; while [ $i -lt 200 ]; do echo line$i; i=$((i+1)); done; sleep 30",
        ],
        columns: 20, rows: 4))
    defer { session.shutdown() }
    let ready = expectation(
      for: NSPredicate { _, _ in session.frame?.text.contains("line199") == true },
      evaluatedWith: nil)
    session.start()
    wait(for: [ready], timeout: 5)
    var published = 0
    session.onFrame = { _ in published += 1 }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    for _ in 0..<40 { session.scroll(lines: -1) }
    let settled = expectation(
      for: NSPredicate { _, _ in session.frame?.text.contains("line157") == true },
      evaluatedWith: nil)
    wait(for: [settled], timeout: 5)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(session.frame?.text.hasPrefix("line157") == true, session.frame?.text ?? "")
    // The leading scroll publishes at once and the rest of the burst settles
    // in one trailing frame, not one frame per wheel event.
    XCTAssertLessThanOrEqual(published, 3)
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

  /// A popup whose process ends by itself keeps its screen unless the user
  /// typed into it, so only input written to the child counts.
  func testOnlyInputWrittenToTheChildCountsAsReceived() {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        // Focus reports on, then a cursor-position query the terminal answers.
        command: ["/bin/sh", "-c", "printf '\\033[?1004h\\033[6nREADY'; exec /bin/sleep 30"],
        columns: 20, rows: 3))
    defer { session.shutdown() }
    func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
      let met = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
      met.expectationDescription = description
      wait(for: [met], timeout: 5)
    }
    session.start()
    waitUntil("ready") { session.frame?.text.contains("READY") == true }
    guard case .running(let firstPID) = session.state else { return XCTFail("No running PTY") }
    // A terminal reply, a focus report, scrolling and a legacy key release
    // write nothing the user typed.
    session.setFocused(true)
    session.scroll(lines: -3)
    session.key(code: 0, modifiers: 0, action: 0, text: "a", unshifted: 97)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertFalse(session.receivedInput)
    session.key(code: 0, modifiers: 0, action: 1, text: "a", unshifted: 97)
    waitUntil("a key press is input") { session.receivedInput }

    session.restart()
    waitUntil("a restart starts over") {
      guard case .running(let pid) = session.state else { return false }
      return pid != firstPID && !session.receivedInput
    }
    session.paste("pasted")
    waitUntil("a paste is input") { session.receivedInput }
  }
}

final class TerminalSnapshotTests: XCTestCase {
  func testSnapshotsReportChangedRowsAndReuseCleanOnes() throws {
    let buffer = TerminalBuffer(
      columns: 10, rows: 4, scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
    buffer.write(Data("one\r\ntwo\r\nthree".utf8))
    let first = try XCTUnwrap(buffer.snapshot())
    XCTAssertNil(first.changedRows, "the first frame rebuilds every row")
    XCTAssertEqual(first.generation, 1)
    buffer.write(Data("\u{1B}[2;1HTWO".utf8))
    let second = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(second.generation, 2)
    // Only the rewritten row changed. The row the cursor left is dirty in
    // libghostty but equal, so it keeps the previous frame's storage.
    XCTAssertEqual(second.changedRows, [1])
    XCTAssertEqual(second.text, "one\nTWO\nthree\n")
    XCTAssertEqual(second.cells[0..<10].map(\.text), first.cells[0..<10].map(\.text))
    for row in [0, 2, 3] {
      XCTAssertTrue(sharesStorage(second.grid[row], first.grid[row]), "row \(row)")
    }
    // Nothing visible moved: the buffer hands back the same frame.
    let third = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(third.generation, second.generation)
    XCTAssertEqual(third.changedRows, second.changedRows)
    // Cursor motion alone publishes a frame without changed rows.
    buffer.write(Data("\u{1B}[4;1H".utf8))
    let fourth = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(fourth.generation, 3)
    XCTAssertEqual(fourth.changedRows, [])
    XCTAssertEqual(fourth.cursorY, 3)
    // Scrolling the viewport into scrollback moves every row's contents.
    buffer.write(Data("\r\nfour\r\nfive\r\nsix".utf8))
    _ = buffer.snapshot()
    flash_vt_scroll(buffer.handle, -1)
    let scrolled = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(scrolled.changedRows, [0, 1, 2, 3])
    XCTAssertTrue(scrolled.text.hasPrefix("three"))
    // An explicit invalidation rereads every row but publishes nothing new.
    buffer.invalidate()
    XCTAssertEqual(try XCTUnwrap(buffer.snapshot()).generation, scrolled.generation)
    // A resize has no comparable predecessor.
    flash_vt_resize(buffer.handle, 12, 4)
    XCTAssertNil(try XCTUnwrap(buffer.snapshot()).changedRows)
  }

  private func sharesStorage(_ lhs: TerminalRow, _ rhs: TerminalRow) -> Bool {
    lhs.cells.withUnsafeBufferPointer { left in
      rhs.cells.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
    }
  }

  func testWideCellsHyperlinksAndBlinkSurviveRowReuse() throws {
    let buffer = TerminalBuffer(columns: 12, rows: 3, scrollbackLines: 0)
    buffer.write(
      Data(
        ("界\u{1B}]8;;https://example.com/a\u{1B}\\A\u{1B}]8;;\u{1B}\\"
          + "\u{1B}]8;;https://example.com/b\u{1B}\\B\u{1B}]8;;\u{1B}\\\u{1B}[5mx\u{1B}[0m"
          + "\r\n\u{1B}]8;;https://example.com/run\u{1B}\\run\u{1B}]8;;\u{1B}\\").utf8))
    let first = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(first.cells[0].text, "界")
    XCTAssertEqual(first.cells[0].width, 2)
    XCTAssertEqual(first.cells[1].width, 0)
    XCTAssertEqual(first.cells[2].hyperlink, "https://example.com/a")
    XCTAssertEqual(first.cells[3].hyperlink, "https://example.com/b")
    XCTAssertNil(first.cells[5].hyperlink)
    XCTAssertTrue(first.hasBlinkingCells)
    // One link run is one interned string, however many cells it spans.
    XCTAssertEqual(first.grid[1].links, ["https://example.com/run"])
    XCTAssertEqual(
      (12..<15).map { first.cells[$0].hyperlink },
      Array(repeating: "https://example.com/run", count: 3))
    buffer.write(Data("\u{1B}[3;1Hlast".utf8))
    let second = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(second.changedRows, [2], "rows 0 and 1 are reused")
    XCTAssertEqual(second.cells[2].hyperlink, "https://example.com/a")
    XCTAssertEqual(second.cells[3].hyperlink, "https://example.com/b")
    XCTAssertTrue(second.hasBlinkingCells, "blink state is carried by reused rows")
  }

  func testGraphemeClustersAndBackgroundOnlyCellsKeepTheirContent() throws {
    let buffer = TerminalBuffer(columns: 10, rows: 2, scrollbackLines: 0)
    buffer.write(Data("e\u{301}👩‍💻x\r\n\u{1B}[48;2;9;8;7m\u{1B}[K\u{1B}[0m".utf8))
    let frame = try XCTUnwrap(buffer.snapshot())
    XCTAssertEqual(frame.cells[0].text, "e\u{301}")
    XCTAssertEqual(frame.cells[1].text, "👩‍💻")
    XCTAssertEqual(frame.cells[1].width, 2)
    XCTAssertEqual(frame.cells[3].text, "x")
    XCTAssertEqual(frame.grid[0].clusters.count, 2)
    let erased = frame.cells[10]
    XCTAssertEqual(erased.text, " ")
    XCTAssertEqual(
      [erased.background.red, erased.background.green, erased.background.blue], [9, 8, 7])
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

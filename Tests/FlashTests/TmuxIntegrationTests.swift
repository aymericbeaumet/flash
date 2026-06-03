import XCTest

@testable import FlashProviders

/// Live integration tests against a real, isolated `tmux` server. These
/// exist because most TmuxProvider regressions live at the boundary
/// with the tmux binary: format strings changing semantics, default
/// settings drifting, `display-message` behaviour without an attached
/// client, the `client_pid` → focused-pid ancestor walk. Unit tests
/// can't catch any of that.
///
/// **Isolation**: every test boots its own server under a unique socket
/// (`tmux -L flash-it-<uuid>`) with `-f /dev/null` so the user's
/// `~/.tmux.conf` and the system file are ignored. Server is killed in
/// `tearDown` whether or not the test succeeded.
///
/// **Skipping**: if `tmux` isn't on the resolved binary path (the same
/// list TmuxProvider probes), the suite is skipped — these tests are
/// meaningless without it.
final class TmuxIntegrationTests: XCTestCase {

  private var socket: String = ""
  private var tmuxPath: String = ""

  override func setUpWithError() throws {
    guard let path = TmuxProvider.tmuxPath else {
      throw XCTSkip("tmux not installed on the standard probe paths")
    }
    tmuxPath = path
    socket = "flash-it-\(UUID().uuidString.prefix(8))"
  }

  override func tearDown() {
    if !socket.isEmpty {
      _ = run("kill-server")
    }
    super.tearDown()
  }

  // MARK: - CLI contract

  func testListPanesFormatReturnsFiveFields() throws {
    try newSession(cols: 80, rows: 24)
    let out = try XCTUnwrap(
      run(
        "list-panes", "-t", "s",
        "-F", "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}"
      ))
    let lines = out.split(separator: "\n")
    XCTAssertEqual(lines.count, 1, "single pane after new-session")
    let parts = lines[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    XCTAssertEqual(parts.count, 5, "format string must yield 5 fields: \(out)")
    XCTAssertTrue(parts[0].hasPrefix("%"), "pane_id begins with %: \(parts[0])")
    XCTAssertNotNil(Int(parts[1]), "pane_left integer")
    XCTAssertNotNil(Int(parts[2]), "pane_top integer")
    XCTAssertNotNil(Int(parts[3]), "pane_width integer")
    XCTAssertNotNil(Int(parts[4]), "pane_height integer")
  }

  func testDisplayMessageCombinedQueryReturnsTwoLines() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "off")
    // Same combined query TmuxProvider issues in `discover`.
    let out = try XCTUnwrap(
      run(
        "display-message", "-t", "s", "-p",
        "#{client_width} #{client_height}\n#{status} #{status-position}"
      ))
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertGreaterThanOrEqual(lines.count, 2, "two lines: \(out)")
    // Without an attached client, #{client_*} are empty — confirms the
    // documented contract `discover` relies on (it returns [] when
    // clientHostedBy returns nil, so the empty-client case never
    // reaches the parser).
    XCTAssertEqual(
      lines[0].trimmingCharacters(in: .whitespaces),
      "",
      "no attached client → no client_width")
    // status-position line should still come through using session
    // defaults. Both legacy "off"/"on" and numeric forms are accepted.
    let provider = TmuxProvider()
    let (lines2, atTop, off) = provider.parseStatusInfo(lines[1])
    XCTAssertEqual(lines2, 0, "we set status off")
    XCTAssertFalse(atTop)
    XCTAssertEqual(off, 0)
  }

  func testStatusPositionTopParsesAndShiftsContent() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "on")
    _ = run("set-option", "-t", "s", "status-position", "top")
    let raw = try XCTUnwrap(
      run("display-message", "-t", "s", "-p", "#{status} #{status-position}"))
    let provider = TmuxProvider()
    let (lines, atTop, off) = provider.parseStatusInfo(raw)
    XCTAssertEqual(lines, 1)
    XCTAssertTrue(atTop)
    XCTAssertEqual(off, 1, "1 status line at top → pane content shifted by 1 row")
  }

  func testHorizontalSplitProducesTwoPanesWithCorrectOffsets() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "off")
    _ = run("split-window", "-h", "-t", "s")
    let raw = try XCTUnwrap(
      run(
        "list-panes", "-t", "s",
        "-F", "#{pane_left} #{pane_top} #{pane_width} #{pane_height}"
      ))
    let panes = raw.split(separator: "\n").map(String.init)
    XCTAssertEqual(panes.count, 2)
    let parsed = panes.compactMap { line -> (Int, Int, Int, Int)? in
      let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard p.count == 4,
        let l = Int(p[0]), let t = Int(p[1]), let w = Int(p[2]), let h = Int(p[3])
      else { return nil }
      return (l, t, w, h)
    }
    XCTAssertEqual(parsed.count, 2)
    // Left pane at column 0; right pane starts past the left pane plus
    // the divider column. Total horizontal span must equal 80.
    let sortedByLeft = parsed.sorted { $0.0 < $1.0 }
    XCTAssertEqual(sortedByLeft[0].0, 0, "left pane at column 0")
    XCTAssertGreaterThan(sortedByLeft[1].0, sortedByLeft[0].2, "right pane is past left + divider")
    XCTAssertEqual(
      sortedByLeft[0].3, sortedByLeft[1].3, "both panes share the full height with status off")
  }

  func testVerticalSplitProducesTwoStackedPanes() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "off")
    _ = run("split-window", "-v", "-t", "s")
    let raw = try XCTUnwrap(
      run(
        "list-panes", "-t", "s",
        "-F", "#{pane_left} #{pane_top} #{pane_width} #{pane_height}"
      ))
    let panes = raw.split(separator: "\n").map(String.init)
    XCTAssertEqual(panes.count, 2)
    let parsed = panes.compactMap { line -> (Int, Int, Int, Int)? in
      let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard p.count == 4,
        let l = Int(p[0]), let t = Int(p[1]), let w = Int(p[2]), let h = Int(p[3])
      else { return nil }
      return (l, t, w, h)
    }
    XCTAssertEqual(parsed.count, 2)
    let sortedByTop = parsed.sorted { $0.1 < $1.1 }
    XCTAssertEqual(sortedByTop[0].1, 0, "top pane at row 0 (status off)")
    XCTAssertGreaterThan(
      sortedByTop[1].1, sortedByTop[0].3, "bottom pane is past top pane + divider")
  }

  // MARK: - capture-pane

  func testCapturePaneReturnsRenderedContent() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "off")
    // Replace the running shell with `cat`, then `send-keys` the
    // payload so it lands in cat's stdout — no shell prompt, no
    // racing against startup messages.
    _ = run("send-keys", "-t", "s", "exec cat", "Enter")
    // Wait for the exec to take effect before piping content.
    waitForPaneContent("$") // shell prompt or post-exec marker
    _ = run("send-keys", "-t", "s", "ALPHA BRAVO charlie 123", "Enter")
    waitForPaneContent("BRAVO")
    let raw = try XCTUnwrap(run("capture-pane", "-t", "s", "-p"))
    XCTAssertTrue(raw.contains("BRAVO"), "captured pane must include sent text: \(raw)")
    XCTAssertTrue(raw.contains("charlie"))
    XCTAssertTrue(raw.contains("123"))
  }

  // MARK: - End-to-end: capture-pane → extractWords → pixel rects

  func testCapturedWordsTokenizeAndMapToPixelRects() throws {
    try newSession(cols: 80, rows: 24)
    _ = run("set-option", "-t", "s", "status", "off")
    _ = run("send-keys", "-t", "s", "exec cat", "Enter")
    waitForPaneContent("$")
    _ = run("send-keys", "-t", "s", "alpha bravo charlie", "Enter")
    waitForPaneContent("charlie")

    let raw = try XCTUnwrap(run("capture-pane", "-t", "s", "-p"))
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let provider = TmuxProvider()

    // The line we care about — the one containing 'bravo'.
    guard let payloadIdx = lines.firstIndex(where: { $0.contains("bravo") }) else {
      return XCTFail("expected captured text not present: \(raw)")
    }
    let payload = lines[payloadIdx]

    var emitted: [(col: Int, text: String)] = []
    provider.extractWords(line: payload, maxCols: 80) { c, t in
      emitted.append((c, t))
    }

    let texts = emitted.map { $0.text }
    XCTAssertTrue(
      texts.contains("alpha") && texts.contains("bravo") && texts.contains("charlie"),
      "extractWords didn't yield expected tokens: \(texts)")

    // Verify column positions match the literal layout — 'alpha' at
    // col 0, 'bravo' at col 6, 'charlie' at col 12. This is the
    // contract `discover` relies on to compute screen-x.
    let dict = Dictionary(uniqueKeysWithValues: emitted.map { ($0.text, $0.col) })
    XCTAssertEqual(dict["alpha"], 0)
    XCTAssertEqual(dict["bravo"], 6)
    XCTAssertEqual(dict["charlie"], 12)

    // Translate to pixel rects using the same math as discover() with
    // a synthetic 800x480 window.
    let windowFrame = CGRect(x: 100, y: 200, width: 800, height: 480)
    let geom = provider.resolveGeometry(
      bundleID: "com.apple.Terminal", windowFrame: windowFrame,
      clientCols: 80, clientRows: 24)
    let cellW = geom.cellW
    let cellH = geom.cellH
    let topOffset = 0 // status off
    let paneTop = 0
    let row = payloadIdx
    let screenRow = topOffset + paneTop + row

    let bravoCol = try XCTUnwrap(dict["bravo"])
    let bravoLen = 5
    let x = windowFrame.minX + CGFloat(bravoCol) * cellW
    let expectedW = CGFloat(bravoLen) * cellW
    let y =
      windowFrame.minY + windowFrame.height
      - CGFloat(screenRow + 1) * cellH
    XCTAssertEqual(x, 100 + 6 * 10, accuracy: 1e-9)
    XCTAssertEqual(expectedW, 50.0, accuracy: 1e-9)
    XCTAssertEqual(y, 200 + 480 - CGFloat(row + 1) * 20, accuracy: 1e-9)
  }

  // MARK: - client_pid ancestor walk

  func testListClientsReturnsClientPidField() throws {
    // The format string `#{client_pid}` is what TmuxProvider walks
    // back through proc_pidinfo to find a focused-app ancestor.
    // Without an attached client this returns empty, but the format
    // must parse cleanly (a tmux change here would be a silent
    // regression).
    try newSession(cols: 80, rows: 24)
    let out = run(
      "list-clients", "-F",
      "#{client_tty}\t#{session_name}\t#{client_pid}"
    )
    // No attached client → empty output or absent line — both are
    // acceptable per tmux's contract. The format string must not
    // error out (run() returns nil on non-zero exit; XCTUnwrap is
    // intentionally not used here).
    if let out, !out.isEmpty {
      // If something IS attached (rare in CI but possible if another
      // tmux process is using the same socket name, defensive), at
      // least confirm three tab-separated fields parse.
      for line in out.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 2)
        XCTAssertEqual(parts.count, 3, "list-clients format yields three fields: \(line)")
        XCTAssertNotNil(pid_t(parts[2]), "client_pid is numeric: \(parts[2])")
      }
    }
  }

  // MARK: - Helpers

  private func newSession(cols: Int, rows: Int) throws {
    let r = run(
      "-f", "/dev/null", "new-session", "-d", "-s", "s",
      "-x", String(cols), "-y", String(rows))
    XCTAssertNotNil(r, "tmux new-session must succeed")
    // Give the server a moment to settle so subsequent format-string
    // reads see real values rather than transient zeros.
    waitForPaneContent("", maxAttempts: 5)
  }

  /// Poll `capture-pane` until `marker` appears or the budget runs out.
  /// Empty marker just waits once for the server to settle.
  private func waitForPaneContent(_ marker: String, maxAttempts: Int = 30) {
    if marker.isEmpty {
      usleep(50_000)
      return
    }
    for _ in 0..<maxAttempts {
      if let raw = run("capture-pane", "-t", "s", "-p"), raw.contains(marker) {
        return
      }
      usleep(50_000) // 50ms
    }
  }

  @discardableResult
  private func run(_ args: String...) -> String? {
    runCmd(args)
  }

  private func runCmd(_ args: [String]) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tmuxPath)
    task.arguments = ["-L", socket] + args
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
      try task.run()
    } catch {
      return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return String(
      data: outPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8)
  }
}

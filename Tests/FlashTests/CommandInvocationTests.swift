import AppKit
import XCTest

@testable import flash

/// `flash <words>` in a terminal and `:<words>` on the command line are one
/// grammar: the same resolver over the same inventory, one runner, and a
/// result each surface presents its own way.
final class CommandInvocationTests: XCTestCase {
  private typealias Resolution = NormalModeDispatcher.CommandLineResolution

  private let inventory = NormalModeDispatcher.CommandLineInventory.core(
    pluginCommands: ["screenshot": ["window", "screen"], "calc": ["*"]],
    helpTopics: ["plugins", "config"])

  private func words(_ line: String) -> Resolution {
    NormalModeDispatcher.resolveCommandWords(
      line.split(separator: " ").map(String.init), inventory: inventory)
  }

  // MARK: - One grammar

  func testTheCLIWordsResolveExactlyAsTheCommandLine() {
    for line in [
      "tab next", "ta nex", "q", "tabn", "wq", "qa!", "h plugins", "mou grid",
      "screensh w", "calc 2 + 2", "resident status", "resid st --json", "doctor",
      "config check --file=~/f.toml", "logs", "commands", "plugins reload", "open -a Firefox",
      "flashlight fire fox", "ta n", "tab", "zzz", "alert show --message=hello there",
    ] {
      XCTAssertEqual(
        words(line), NormalModeDispatcher.resolveCommandLine(":" + line, inventory: inventory),
        line)
    }
  }

  func testTheQueriesResolveOnBothSurfacesAndValidateTheirArguments() {
    XCTAssertEqual(words("resident status"), .query(.status, arguments: [:]))
    XCTAssertEqual(words("resid st --json"), .query(.status, arguments: ["json": "1"]))
    XCTAssertEqual(words("res st"), .ambiguous(["resident", "resource"]))
    XCTAssertEqual(words("resident doctor"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(words("doctor"), .query(.doctor, arguments: [:]))
    XCTAssertEqual(words("doctor --json"), .query(.doctor, arguments: ["json": "1"]))
    XCTAssertEqual(
      words("config check --file=x.toml"), .query(.configCheck, arguments: ["file": "x.toml"]))
    XCTAssertEqual(words("config"), .incomplete("config"), "check, edit and reload")
    XCTAssertEqual(words("resident status --file=x"), .unknown)
    XCTAssertEqual(words("config check --json"), .unknown)
    XCTAssertEqual(words("config check --file="), .unknown)
    XCTAssertEqual(words("resident"), .incomplete("resident"))
    XCTAssertEqual(words("resident quit"), .commands([.quit]))
  }

  func testOpenAndFlashlightTakeTheRestOfTheLine() {
    XCTAssertEqual(words("open https://example.com"), .open(["https://example.com"]))
    XCTAssertEqual(words("open -a Firefox file.txt"), .open(["-a", "Firefox", "file.txt"]))
    XCTAssertEqual(words("op ~/Downloads"), .open(["~/Downloads"]))
    XCTAssertEqual(words("open"), .incomplete("open"))
    XCTAssertEqual(words("flashlight fire fox"), .flashlight("fire fox"))
    XCTAssertEqual(words("flashlight"), .incomplete("flashlight"))
  }

  func testALeadingHashAsksForTheOutputOnTheClipboard() {
    let glued = CommandInvocation(words: ["#aws", "whoami"])
    XCTAssertEqual(glued.words, ["aws", "whoami"])
    XCTAssertTrue(glued.capturesOutput)
    let alone = CommandInvocation(words: ["#", "aws", "whoami"])
    XCTAssertEqual(alone.words, ["aws", "whoami"])
    XCTAssertTrue(alone.capturesOutput)
    let plain = CommandInvocation(words: ["tab", "next"], workingDirectory: "/tmp")
    XCTAssertFalse(plain.capturesOutput)
    XCTAssertEqual(plain.workingDirectory, "/tmp")
    XCTAssertEqual(plain.line, "tab next")
  }

  func testARejectionNamesWhatTheWordsCouldHaveBeen() {
    func rejection(_ line: String) -> String? {
      let split = line.split(separator: " ").map(String.init)
      return NormalModeDispatcher.resolveCommandWords(split, inventory: inventory)
        .rejection(of: split, inventory: inventory)
    }
    XCTAssertEqual(rejection("ta n"), "'ta n' is ambiguous: new, next")
    XCTAssertEqual(
      rejection("tab"),
      "'tab' needs an action: close, detach, duplicate, first, last, move_next, move_previous, "
        + "mute, new, next, pin, previous, reopen, select")
    XCTAssertEqual(rejection("screenshot"), "'screenshot' needs a subcommand: screen, window")
    XCTAssertEqual(rejection("open"), "'open' needs its words")
    XCTAssertEqual(rejection("zzz"), "unknown command or invalid arguments: zzz")
    XCTAssertEqual(
      rejection("enter_insert_mode"),
      "unknown command or invalid arguments: enter_insert_mode; did you mean `mode insert`?")
    XCTAssertNil(rejection("tab next"))
    XCTAssertNil(rejection("doctor"))
  }

  /// A command spelled the way an older Flash spelled it, or with its words
  /// run together, names the command it most likely is: every word of the
  /// suggestion appears in what was typed. Nothing is accepted under the old
  /// name; the suggestion only says what to write instead.
  func testAnUnknownCommandSuggestsTheCommandItsWordsName() {
    func suggest(_ line: String) -> [String] {
      URLEventHandler.suggestedCommands(for: line.split(separator: " ").map(String.init))
    }
    XCTAssertEqual(suggest("enter_insert_mode"), ["mode insert"])
    XCTAssertEqual(suggest("mouse_target"), ["mouse target"])
    XCTAssertEqual(suggest("window_move --position=lefthalf"), ["window move"])
    XCTAssertEqual(suggest("scroll_half_page_down"), ["scroll half_page_down"])
    XCTAssertEqual(suggest("send_keys"), ["key send"])
    XCTAssertEqual(suggest("about"), ["about show"])
    XCTAssertEqual(suggest("quit"), ["app quit", "popup quit", "resident quit"])
    XCTAssertEqual(suggest("zzz"), [])
    XCTAssertEqual(suggest("tab next"), [], "a known command needs no suggestion")
    XCTAssertEqual(suggest("--position=lefthalf"), [])
    XCTAssertTrue(
      URLEventHandler.rejectionMessage("flash enter_insert_mode").contains(
        "Did you mean `mode insert`?"))
    XCTAssertFalse(URLEventHandler.rejectionMessage("flash zzz").contains("Did you mean"))
    let config = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+shift+space" = ["flash", "mouse_target"]
      """)
    XCTAssertTrue(
      config.loadingDiagnostics.contains { $0.message.contains("Did you mean `mouse target`?") },
      "\(config.loadingDiagnostics.map(\.message))")
  }

  // MARK: - Results

  func testAResultCrossesTheWireAsJSONAndMapsToAnExitStatus() throws {
    for result in [
      CommandInvocationResult.succeeded("out"), .succeeded(), .failed("no", output: "report"),
      .rejected("'ta n' is ambiguous: new, next"),
      .local(.configCheck, arguments: ["file": "x.toml"]),
    ] {
      XCTAssertEqual(CommandInvocationResult(json: result.json), result)
    }
    XCTAssertEqual(CommandInvocationResult.succeeded("x").exitCode, 0)
    XCTAssertEqual(CommandInvocationResult.failed("x").exitCode, 1)
    XCTAssertEqual(CommandInvocationResult.rejected("x").exitCode, 2)
    XCTAssertNil(CommandInvocationResult.succeeded("").output)
    let local = CommandInvocationResult.local(.configCheck, arguments: [:])
    XCTAssertEqual(local.query, "config check")
    XCTAssertEqual(FlashQuery(name: try XCTUnwrap(local.query)), .configCheck)
  }

  func testAnOutcomeOfTheFocusedAppIsTheCLIsResult() {
    func result(_ outcome: NormalModeCommandOutcome) -> CommandInvocationResult {
      AppDelegate.invocationResult(outcome, output: "o", command: "tab next")
    }
    XCTAssertEqual(result(.performed), .succeeded("o"))
    XCTAssertEqual(result(.chordSent), .succeeded("o"))
    XCTAssertEqual(result(.failed).status, .failed)
    XCTAssertEqual(result(.unavailable), .failed("the focused app has no tab next"))
    XCTAssertEqual(result(.noTarget), .failed("no app to run tab next in"))
    XCTAssertEqual(result(.refused).status, .failed)
  }

  // MARK: - The CLI's end

  /// A transport that records what it sends and answers with `result`, or
  /// as if no resident were running (and none could be started).
  final class StubTransport {
    var sent: [(words: [String], directory: String)] = []
    var watched: [(patterns: [String], count: Int?)] = []
    /// Each `open`'s `launching`.
    var opens: [Bool] = []
    var result: CommandInvocationResult?
    var openFailure: FlashCLI.OpenFailure?
    var requestFailure: IPCClient.Failure?

    private final class Channel: FlashCLI.Channel {
      unowned let stub: StubTransport

      init(_ stub: StubTransport) {
        self.stub = stub
      }

      func request(words: [String], directory: String) throws -> CommandInvocationResult {
        stub.sent.append((words, directory))
        if let failure = stub.requestFailure { throw failure }
        return stub.result ?? .failed("no result")
      }

      func watch(patterns: [String], count: Int?, emit: (Data) -> Bool) throws -> Int32 {
        stub.watched.append((patterns, count))
        return 0
      }
    }

    var transport: FlashCLI.Transport {
      FlashCLI.Transport(open: { [self] launching in
        opens.append(launching)
        if let openFailure { return .failure(openFailure) }
        guard result != nil || requestFailure != nil else { return .failure(.notRunning) }
        return .success(Channel(self))
      })
    }
  }

  func testTheCLISendsItsWordsAndExitsWithTheResult() {
    let stub = StubTransport()
    stub.result = .succeeded()
    XCTAssertEqual(FlashCLI.run(args: ["ta", "nex"], transport: stub.transport), 0)
    XCTAssertEqual(stub.sent.first?.words, ["ta", "nex"])
    XCTAssertEqual(stub.sent.first?.directory, FileManager.default.currentDirectoryPath)
    stub.result = .failed("the focused app has no tab next")
    XCTAssertEqual(FlashCLI.run(args: ["tab", "next"], transport: stub.transport), 1)
    stub.result = .rejected("'ta n' is ambiguous: new, next")
    XCTAssertEqual(FlashCLI.run(args: ["ta", "n"], transport: stub.transport), 2)
  }

  /// `--json` prints the reply object the resident sent; the exit status is
  /// the same.
  func testJSONRepliesKeepTheExitStatus() {
    let stub = StubTransport()
    stub.result = .failed("the focused app has no tab next")
    XCTAssertEqual(FlashCLI.run(args: ["--json", "tab", "next"], transport: stub.transport), 1)
    XCTAssertEqual(stub.sent.first?.words, ["tab", "next"])
    XCTAssertEqual(FlashCLI.run(args: ["--json"], transport: stub.transport), 2)
  }

  func testWithoutAResidentTheCLIStillNamesWhatItCouldNotResolve() {
    let stub = StubTransport()
    XCTAssertEqual(FlashCLI.run(args: ["ta", "n"], transport: stub.transport), 2)
    XCTAssertEqual(FlashCLI.run(args: ["mode", "leave", "typo"], transport: stub.transport), 2)
    XCTAssertEqual(FlashCLI.run(args: ["tab", "next"], transport: stub.transport), 1)
    XCTAssertEqual(FlashCLI.run(args: ["q"], transport: stub.transport), 1)
  }

  /// Words that need the resident start it; quitting it, and words Flash's
  /// own topics reject, never do.
  func testOnlyWordsThatCanRunStartTheResident() {
    let stub = StubTransport()
    _ = FlashCLI.run(args: ["tab", "next"], transport: stub.transport)
    _ = FlashCLI.run(args: ["screenshot", "window"], transport: stub.transport)
    _ = FlashCLI.run(args: ["resident", "status"], transport: stub.transport)
    _ = FlashCLI.run(args: ["events", "watch"], transport: stub.transport)
    XCTAssertEqual(stub.opens, [true, true, true, true])
    stub.opens = []
    _ = FlashCLI.run(args: ["resident", "quit"], transport: stub.transport)
    _ = FlashCLI.run(args: ["mode", "leave", "typo"], transport: stub.transport)
    _ = FlashCLI.run(args: ["events", "watch", "--name=nope"], transport: stub.transport)
    XCTAssertEqual(stub.opens, [false, false, false])
  }

  func testTheCLIReportsWhyItCouldNotReachTheResident() {
    let stub = StubTransport()
    stub.openFailure = .failed("Flash did not answer on /x within 15 s of starting")
    XCTAssertEqual(FlashCLI.run(args: ["tab", "next"], transport: stub.transport), 1)
    stub.openFailure = nil
    stub.requestFailure = .closed
    XCTAssertEqual(FlashCLI.run(args: ["tab", "next"], transport: stub.transport), 1)
    XCTAssertEqual(stub.sent.count, 1)
  }

  /// `events watch` subscribes on the CLI's own connection, spelled out or
  /// handed back by the resident for an abbreviation.
  func testEventsWatchSubscribesOnTheConnection() {
    let stub = StubTransport()
    stub.result = .local(.eventsWatch, arguments: ["count": "2"])
    XCTAssertEqual(
      FlashCLI.run(
        args: ["events", "watch", "--name=core:mode.changed,core:hints.*"],
        transport: stub.transport), 0)
    XCTAssertTrue(stub.sent.isEmpty)
    XCTAssertEqual(stub.watched.first?.patterns, ["core:mode.changed", "core:hints.*"])
    XCTAssertNil(stub.watched.first?.count)
    XCTAssertEqual(FlashCLI.run(args: ["ev", "wa"], transport: stub.transport), 0)
    XCTAssertEqual(stub.sent.count, 1)
    XCTAssertEqual(stub.watched.last?.patterns, ["core:*"])
    XCTAssertEqual(stub.watched.last?.count, 2)
  }

  func testConfigCheckRunsInTheCLIWhereverItResolves() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-check-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("[hints]\nmin_length = 0\n".utf8).write(to: url)
    let stub = StubTransport()
    // Spelled out, it never asks the resident.
    XCTAssertEqual(
      FlashCLI.run(args: ["config", "check", "--file=\(url.path)"], transport: stub.transport), 1)
    XCTAssertTrue(stub.sent.isEmpty)
    XCTAssertTrue(stub.opens.isEmpty)
    // Abbreviated, the resident resolves it and hands it back.
    stub.result = .local(.configCheck, arguments: ["file": url.path])
    XCTAssertEqual(FlashCLI.run(args: ["conf", "ch"], transport: stub.transport), 1)
    XCTAssertEqual(stub.sent.count, 1)
    // Without a resident, an abbreviation still resolves here.
    stub.result = nil
    try Data("[mode.normal.mappings]\n\"t\" = false\n".utf8).write(to: url)
    XCTAssertEqual(
      FlashCLI.run(args: ["conf", "ch", "--file=\(url.path)"], transport: stub.transport), 0)
  }

  /// A command that fails leaves a line for a script that ran unattended:
  /// `[command] failed` with the line and the reason the CLI printed.
  func testAFailedInvocationLogsItsLineAndReason() {
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    let lock = NSLock()
    var failures: [[String: String]] = []
    let sink = FlashLog.addSink { record in
      guard record.message == "[command] failed" else { return }
      lock.lock()
      failures.append(record.fields)
      lock.unlock()
    }
    defer { FlashLog.removeSink(sink) }
    let done = expectation(description: "macro repeat finished")
    var result: CommandInvocationResult?
    delegate.runInvocation(CommandInvocation(words: ["macro", "repeat"]), surface: .cli) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(result?.status, .failed)
    lock.lock()
    defer { lock.unlock() }
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(failures.first?["line"], "macro repeat")
    XCTAssertEqual(failures.first?["reason"], "no command to repeat yet")
    XCTAssertEqual(failures.first?["surface"], "cli")
  }
}

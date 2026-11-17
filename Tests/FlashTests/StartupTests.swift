import AppKit
import FlashCore
import Foundation
import XCTest

@testable import flash

/// `[startup] run`: the commands Flash runs once each time it launches, and
/// again on `startup run`. It replaced `[macos]`, which a file may no longer
/// declare.
final class StartupTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static let caffeinate = URLEventHandler.parse(
    words: ["caffeinate", "on", "--minutes=60"])!

  // MARK: Configuration

  func testRunIsAListOfCommandsInOrder() {
    let config = ConfigLoader.parse(
      """
      [startup]
      run = [
        ["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"],
        ["killall", "Dock"],
        ["flash", "caffeinate", "on", "--minutes=60"],
      ]
      timeout = 30
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      config.startup.run,
      [
        .shellCommand(["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"]),
        .shellCommand(["killall", "Dock"]),
        .flashCommand(Self.caffeinate),
      ])
    XCTAssertEqual(config.startup.timeoutSeconds, 30)
  }

  func testByDefaultNothingRunsAndEachCommandGetsAMonitorRunsTimeout() {
    XCTAssertEqual(Config().startup, Config.Startup(run: [], timeoutSeconds: 600))
    XCTAssertEqual(Config().startup.timeoutSeconds, MonitorRunDefaults.timeoutSeconds)
    let empty = ConfigLoader.parse("[startup]\nrun = []")
    XCTAssertEqual(empty.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(empty.startup.run, [])
  }

  func testOneMalformedCommandRejectsTheWholeList() {
    for value in [
      #"[["killall", "Dock"], []]"#, #"[["killall", 3]]"#, #""killall Dock""#,
      #"[["flash", "nope", "nope"]]"#, #"[["killall", "Dock"], "Finder"]"#, "false",
      #"[["flash", "tab"]]"#,
    ] {
      let config = ConfigLoader.parse("[startup]\nrun = \(value)")
      XCTAssertEqual(config.startup.run, [], value)
      let messages = config.loadingDiagnostics.map(\.message)
      XCTAssertEqual(messages.count, 1, "\(value): \(messages)")
      XCTAssertTrue(
        messages.allSatisfy { $0.hasPrefix("startup.run must be a list of commands") },
        "\(value): \(messages)")
      XCTAssertEqual(config.loadingDiagnostics.first?.location?.line, 2, value)
    }
  }

  func testALaterLayerReplacesTheWholeListAndAMalformedOneKeepsTheEarlier() {
    let base = ConfigLoader.Layer(text: #"[startup]\#nrun = [["killall", "Dock"], ["true"]]"#)
    let replaced = ConfigLoader.parseLayers([
      base, ConfigLoader.Layer(text: #"[startup]\#nrun = [["killall", "Finder"]]"#),
    ])
    XCTAssertEqual(replaced.startup.run, [.shellCommand(["killall", "Finder"])])
    let cleared = ConfigLoader.parseLayers([
      base, ConfigLoader.Layer(text: "[startup]\nrun = []"),
    ])
    XCTAssertEqual(cleared.startup.run, [])
    let malformed = ConfigLoader.parseLayers([
      base, ConfigLoader.Layer(text: #"[startup]\#nrun = [["killall", 1]]"#),
    ])
    XCTAssertEqual(
      malformed.startup.run, [.shellCommand(["killall", "Dock"]), .shellCommand(["true"])])
  }

  func testStartupRunCannotRunItself() {
    let config = ConfigLoader.parse(
      """
      [startup]
      run = [["killall", "Dock"], ["flash", "startup", "run"]]
      """)
    XCTAssertEqual(config.startup.run, [])
    XCTAssertEqual(
      config.loadingDiagnostics.map(\.message),
      ["startup.run cannot run startup run: it would start itself again"])
  }

  func testTheTimeoutIsWholeSecondsPerCommandInTheMonitorsRange() {
    for (value, expected) in [
      ("1", 1), ("86400", 86_400), ("45.0", 45), ("0", 600), ("86401", 600), ("2.5", 600),
      ("\"10\"", 600),
    ] {
      let config = ConfigLoader.parse("[startup]\ntimeout = \(value)")
      XCTAssertEqual(config.startup.timeoutSeconds, expected, value)
      XCTAssertEqual(
        config.loadingDiagnostics.map(\.message),
        expected == 600
          ? ["startup.timeout must be an integer between 1 and 86400 (seconds per command)"] : [],
        value)
    }
  }

  /// Only the executable resolves against the file's directory; every
  /// argument stays as written, slashes and tildes included.
  func testOnlyTheExecutableResolvesItsArgumentsStayOpaque() {
    let source = URL(fileURLWithPath: "/tmp/flash-startup-\(UUID().uuidString)/flash.toml")
    let config = ConfigLoader.parse(
      """
      [startup]
      run = [["bin/setup", "sub/dir", "~/x", "--path=a/b"], ["/usr/bin/true", "c/d"]]
      """, sourceURL: source)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let resolved = source.deletingLastPathComponent().appendingPathComponent("bin/setup")
      .standardizedFileURL.path
    XCTAssertEqual(
      config.startup.run,
      [
        .shellCommand([resolved, "sub/dir", "~/x", "--path=a/b"]),
        .shellCommand(["/usr/bin/true", "c/d"]),
      ])
  }

  func testUnknownKeysAreReported() {
    let config = ConfigLoader.parse("[startup]\ncommands = []")
    XCTAssertEqual(
      config.loadingDiagnostics.map(\.message), ["unknown config key 'startup.commands'"])
  }

  func testTheInspectorSeesTheList() throws {
    let config = ConfigLoader.parse(#"[startup]\#nrun = [["killall", "Dock"]]\#ntimeout = 9"#)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8)) as? [String: Any])
    let startup = try XCTUnwrap(json["startup"] as? [String: Any])
    XCTAssertEqual(startup["run"] as? [[String]], [["killall", "Dock"]])
    XCTAssertEqual(startup["timeout"] as? Int, 9)
  }

  // MARK: The retired [macos] section

  func testAMacOSSectionIsRejectedWhereItIsNamingStartupRun() throws {
    let file = URL(fileURLWithPath: "/tmp/flash-startup-check/flash.toml")
    let defaults = try String(
      contentsOf: Self.root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    for (text, line) in [
      ("[app]\nmenu_bar_icon = true\n\n[macos.dock]\nautohide = true\n", 4),
      ("# keys\n[macos]\nrestart = \"auto\"\n", 2),
      ("[macos.defaults.NSGlobalDomain]\nQLPanelAnimationDuration = 0.0\n", 1),
    ] {
      let check = ConfigCheck.run(
        fileURL: file, text: text,
        defaultLayer: ConfigLoader.Layer(text: defaults, diagnosticLabel: "config.default.toml"))
      XCTAssertEqual(check.exitCode, 1, text)
      XCTAssertEqual(check.lines.count, 1, "\(text): \(check.lines)")
      let output = try XCTUnwrap(check.lines.first)
      XCTAssertTrue(output.hasPrefix("\(file.path):\(line):1: [macos] was removed; "), output)
      XCTAssertTrue(output.contains("[startup] run"), output)
      XCTAssertTrue(output.contains("defaults write"), output)
      XCTAssertFalse(output.contains("unknown config key"), output)
    }
    XCTAssertNil(URLEventHandler.parse(words: ["macos", "apply"]))
    XCTAssertNil(URLEventHandler.parse(words: ["macos", "diff"]))
    XCTAssertNil(URLEventHandler.parse(words: ["macos", "revert"]))
  }

  // MARK: The command

  func testStartupRunIsTwoWordsOnTheCLIAndTheCommandLine() {
    XCTAssertEqual(URLEventHandler.parse(words: ["startup", "run"]), .startup(.run))
    XCTAssertNil(URLEventHandler.parse(words: ["startup", "run", "--now"]))
    XCTAssertNil(URLEventHandler.parse(words: ["startup"]))
    XCTAssertEqual(URLCommand.startup(.run).argv, ["flash", "startup", "run"])
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "startup", "run"]), .flashCommand(.startup(.run)))
    XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(":startup run"), .startup(.run))
  }

  // MARK: Running

  /// Records each command it is handed and answers on another queue, after
  /// noting the answer, with the result set for that command.
  private final class FakeExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var timeouts: [TimeInterval] = []
    var results: [String: MonitorStepResult] = [:]

    var events: [String] { locked { recorded } }
    var started: [String] {
      events.filter { $0.hasPrefix("start ") }.map { String($0.dropFirst(6)) }
    }
    var receivedTimeouts: [TimeInterval] { locked { timeouts } }

    private func locked<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }

    func execute(
      _ command: MappingCommand, _ timeout: TimeInterval,
      _ completion: @escaping (MonitorStepResult, String) -> Void
    ) {
      let text = MonitorRunner.describe(command)
      locked {
        recorded.append("start \(text)")
        timeouts.append(timeout)
      }
      let result = results[text] ?? .succeeded
      DispatchQueue.global().async { [self] in
        locked { recorded.append("end \(text)") }
        completion(result, "output of \(text)")
      }
    }
  }

  private func makeRunner(
    _ fake: FakeExecutor, grace: TimeInterval = 10,
    whenReady: @escaping StartupRunner.ReadyGate = { queue, body in queue.async(execute: body) }
  ) -> StartupRunner {
    StartupRunner(
      queue: DispatchQueue(label: "test.startup"), unansweredGraceSeconds: grace,
      whenReady: whenReady, execute: fake.execute)
  }

  private func run(_ runner: StartupRunner, _ startup: Config.Startup) -> StartupReport? {
    let done = expectation(description: "startup report")
    var report: StartupReport?
    runner.run(startup) {
      report = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return report
  }

  private static let mixed = Config.Startup(
    run: [
      .shellCommand(["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"]),
      .shellCommand(["false"]),
      .flashCommand(caffeinate),
      .shellCommand(["killall", "Dock"]),
    ], timeoutSeconds: 7)

  func testEveryCommandRunsInOrderOneAtATimeEvenAfterAFailure() throws {
    let fake = FakeExecutor()
    fake.results = ["false": .exited(1), "flash caffeinate on --minutes=60": .commandFailed]
    let report = try XCTUnwrap(run(makeRunner(fake), Self.mixed))
    let names = Self.mixed.run.map(MonitorRunner.describe)
    XCTAssertEqual(fake.events, names.flatMap { ["start \($0)", "end \($0)"] })
    XCTAssertEqual(fake.receivedTimeouts, [7, 7, 7, 7], "each command gets the whole timeout")
    XCTAssertEqual(
      report.outcomes.map(\.result), [.succeeded, .exited(1), .commandFailed, .succeeded])
    XCTAssertEqual(report.outcomes.map(\.command), names)
    XCTAssertFalse(report.succeeded)
    XCTAssertEqual(report.failures.count, 2)
    XCTAssertEqual(
      report.text,
      """
      Ran 4 startup commands; 2 failed.
      ok      defaults write com.apple.dock autohide -bool true
      failed  false (exited 1)
              output of false
      failed  flash caffeinate on --minutes=60 (failed)
              output of flash caffeinate on --minutes=60
      ok      killall Dock
      """)
  }

  func testTheReplySummarizesWhatRan() throws {
    let fake = FakeExecutor()
    let one = Config.Startup(run: [.shellCommand(["true"])], timeoutSeconds: 5)
    XCTAssertEqual(
      try XCTUnwrap(run(makeRunner(fake), one)).text,
      "Ran 1 startup command; it succeeded.\nok      true")
    fake.results = ["true": .timedOut]
    let timedOut = try XCTUnwrap(run(makeRunner(fake), one))
    XCTAssertEqual(timedOut.summary, "Ran 1 startup command; it failed.")
    XCTAssertTrue(timedOut.text.contains("failed  true (timed out after 5 s)"), timedOut.text)
    let none = try XCTUnwrap(run(makeRunner(fake), Config.Startup()))
    XCTAssertTrue(none.succeeded)
    XCTAssertEqual(none.text, "[startup] run has no commands.")
    XCTAssertEqual(fake.started, ["true", "true"], "an empty list runs nothing")
    // A failed command's reply keeps the end of its output; the log keeps all.
    let long = StartupReport(
      outcomes: [
        StartupOutcome(
          command: "x", result: .exited(2),
          output: (1...9).map(String.init).joined(separator: "\n"),
          durationMs: 1)
      ], timeoutSeconds: 1)
    XCTAssertEqual(
      long.text,
      "Ran 1 startup command; it failed.\nfailed  x (exited 2)\n"
        + "        5\n        6\n        7\n        8\n        9")
  }

  func testARunWhileOneIsGoingIsRefused() throws {
    let fake = FakeExecutor()
    // The first run waits for the login environment until released; later
    // ones find it resolved.
    var release: (() -> Void)?
    var resolved = false
    let runner = makeRunner(
      fake,
      whenReady: { queue, body in
        if resolved { return queue.async(execute: body) }
        release = { queue.async(execute: body) }
      })
    let first = expectation(description: "first run")
    var firstReport: StartupReport?
    runner.run(Self.mixed) {
      firstReport = $0
      first.fulfill()
    }
    runner.drain()
    let second = try XCTUnwrap(run(runner, Self.mixed))
    XCTAssertEqual(second.refusal, "The startup commands are already running.")
    XCTAssertFalse(second.succeeded)
    XCTAssertEqual(second.text, "The startup commands are already running.")
    XCTAssertEqual(fake.started, [], "nothing runs before the login environment resolved")
    resolved = true
    release?()
    wait(for: [first], timeout: 5)
    XCTAssertEqual(firstReport?.outcomes.count, 4)
    XCTAssertEqual(try XCTUnwrap(run(runner, Self.mixed)).outcomes.count, 4, "then it runs again")
  }

  /// Launch runs the list once; a reload that asked again would run nothing,
  /// and only `startup run` runs it again.
  func testLaunchRunsTheListExactlyOnce() throws {
    let fake = FakeExecutor()
    let runner = makeRunner(fake)
    let launched = expectation(description: "launch run")
    var reports = 0
    runner.runAtLaunch(Self.mixed) { _ in
      reports += 1
      launched.fulfill()
    }
    runner.runAtLaunch(Self.mixed) { _ in reports += 1 }
    wait(for: [launched], timeout: 5)
    runner.runAtLaunch(Self.mixed) { _ in reports += 1 }
    runner.drain()
    XCTAssertEqual(reports, 1)
    XCTAssertEqual(fake.started.count, 4)
    _ = try XCTUnwrap(run(runner, Self.mixed))
    XCTAssertEqual(fake.started.count, 8)
  }

  /// Quitting stops the list: the command running ends with Flash's process
  /// shutdown, and none after it starts.
  func testQuittingStartsNoFurtherCommand() throws {
    var answerFirst: ((MonitorStepResult, String) -> Void)?
    var started: [String] = []
    let runner = StartupRunner(
      queue: DispatchQueue(label: "test.startup.stop"),
      whenReady: { queue, body in queue.async(execute: body) },
      execute: { command, _, completion in
        started.append(MonitorRunner.describe(command))
        if answerFirst == nil { answerFirst = completion } else { completion(.succeeded, "") }
      })
    let done = expectation(description: "stopped run")
    var report: StartupReport?
    runner.run(Self.mixed) {
      report = $0
      done.fulfill()
    }
    runner.drain()
    runner.drain()
    runner.stop()
    answerFirst?(.cancelled("Flash quit"), "")
    wait(for: [done], timeout: 5)
    XCTAssertEqual(started, [MonitorRunner.describe(Self.mixed.run[0])])
    XCTAssertEqual(report?.outcomes.count, 4)
    XCTAssertEqual(
      report?.outcomes.map(\.result), Array(repeating: .cancelled("Flash quit"), count: 4))
  }

  func testACommandThatNeverAnswersEndsAtItsTimeoutAndTheNextOneRuns() throws {
    let runner = StartupRunner(
      queue: DispatchQueue(label: "test.startup.backstop"), unansweredGraceSeconds: 0.05,
      whenReady: { queue, body in queue.async(execute: body) },
      execute: { command, _, completion in
        if case .flashCommand = command { return }
        completion(.succeeded, "")
      })
    let report = try XCTUnwrap(
      run(
        runner,
        Config.Startup(
          run: [.flashCommand(Self.caffeinate), .shellCommand(["true"])], timeoutSeconds: 0)))
    XCTAssertEqual(report.outcomes.map(\.result), [.timedOut, .succeeded])
  }

  /// The resident's runner: real processes in their own group, with their
  /// output and exit status, and the next one running after a failure.
  func testTheResidentRunsExecutablesThroughTheMonitorsExecutor() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let runner = delegate.makeStartupRunner()
    let report = try XCTUnwrap(
      run(
        runner,
        Config.Startup(
          run: [
            .shellCommand(["/bin/sh", "-c", "echo to stdout; echo to stderr >&2; exit 3"]),
            .shellCommand(["/nonexistent/flash-startup-test"]),
            .shellCommand(["/bin/pwd", "-P"]),
          ], timeoutSeconds: 5)))
    XCTAssertEqual(report.outcomes.count, 3)
    XCTAssertEqual(report.outcomes[0].result, .exited(3))
    XCTAssertEqual(report.outcomes[0].output, "to stdout\nto stderr")
    guard case .notStarted = report.outcomes[1].result else {
      return XCTFail("\(report.outcomes[1].result)")
    }
    XCTAssertEqual(report.outcomes[2].result, .succeeded)
    XCTAssertEqual(
      report.outcomes[2].output,
      URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path,
      "it runs in the home directory")
  }

  func testStartupRunAnswersWithEachCommandsOutcome() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    let fake = FakeExecutor()
    fake.results = ["false": .exited(1)]
    delegate.startupRunner = makeRunner(fake)
    delegate.config.startup = Self.mixed
    let done = expectation(description: "startup run")
    var answer: (NormalModeCommandOutcome, String?)?
    delegate.handleURLCommand(.startup(.run)) { outcome, text in
      answer = (outcome, text)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(answer?.0, .failed)
    XCTAssertEqual(
      answer?.1?.components(separatedBy: "\n").first, "Ran 4 startup commands; 1 failed.")
    XCTAssertEqual(fake.started.count, 4)
  }
}

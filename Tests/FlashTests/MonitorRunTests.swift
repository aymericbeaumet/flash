import Foundation
import XCTest

@testable import flash

/// A monitor's `run` as a sequence of steps: parsed strictly, run one at a
/// time per monitor, in order, stopping at the first failure, bounded by a
/// timeout, held back by a cooldown that outlives a restart, and reported
/// with the failing step's output.
final class MonitorRunTests: XCTestCase {
  private func load(_ toml: String) -> Config { ConfigLoader.parse(toml) }

  private func messages(_ config: Config) -> [String] {
    config.loadingDiagnostics.map(\.message)
  }

  // MARK: Configuration

  func testARunIsOneCommandOrAListOfCommandsInOrder() throws {
    let config = load(
      """
      [monitors.cleanup]
      value = "#{flash.plugin.sysinfo.disks_percent}"
      warning = 90
      alert = false
      timeout = 1800
      cooldown = 3600
      run = [
        ["bonsai", "clean", "--all", "--force"],
        ["flash", "caffeinate", "off"],
        ["mo", "clean"],
      ]

      [monitors.single]
      value = "1"
      warning = 1
      run = ["/usr/bin/true"]
      """)
    XCTAssertEqual(messages(config), [])
    let cleanup = try XCTUnwrap(config.monitors["cleanup"])
    XCTAssertEqual(
      cleanup.run,
      [
        .shellCommand(["bonsai", "clean", "--all", "--force"]),
        try XCTUnwrap(parseMappingCommand(argv: ["flash", "caffeinate", "off"])),
        .shellCommand(["mo", "clean"]),
      ])
    XCTAssertEqual(cleanup.timeoutSeconds, 1800)
    XCTAssertEqual(cleanup.cooldownSeconds, 3600)
    XCTAssertEqual(config.monitorSpecs["cleanup"]?.fires, .onRise)
    XCTAssertEqual(config.monitorSpecs["cleanup"]?.alerts, false)
    XCTAssertEqual(config.monitors["single"]?.run, [.shellCommand(["/usr/bin/true"])])
    XCTAssertEqual(config.monitors["single"]?.timeout, MonitorRunDefaults.timeoutSeconds)
    XCTAssertEqual(config.monitors["single"]?.cooldown, 0)
  }

  func testAMalformedRunIsRejectedWithItsLocation() {
    let config = load(
      """
      [monitors.empty]
      value = "1"
      warning = 1
      run = []

      [monitors.mixed]
      value = "1"
      warning = 1
      run = [["/usr/bin/true"], "/usr/bin/false"]

      [monitors.blank]
      value = "1"
      warning = 1
      run = [["/usr/bin/true"], []]

      [monitors.slow]
      value = "1"
      warning = 1
      run = ["/usr/bin/true"]
      timeout = 0
      cooldown = -1

      [monitors.idle]
      value = "1"
      warning = 1
      cooldown = 60
      """)
    let found = messages(config)
    for expected in [
      "monitors.empty.run must be a command array",
      "monitors.mixed.run must be a command array",
      "monitors.blank.run must be a command array",
      "monitors.slow.timeout must be an integer between 1 and 86400",
      "monitors.slow.cooldown must be an integer between 0 and 604800",
      "monitors.idle has a timeout or a cooldown, which only a run has",
    ] {
      XCTAssertTrue(found.contains { $0.hasPrefix(expected) }, "\(expected) in \(found)")
    }
    XCTAssertEqual(config.monitors["empty"]?.run, [], "a rejected run sets nothing")
  }

  func testFalseRemovesTheWholeRun() {
    let config = load(
      """
      [monitors.disk]
      run = false
      """)
    XCTAssertEqual(messages(config), [])
    XCTAssertEqual(config.monitors["disk"]?.run, [])
    XCTAssertEqual(config.monitorSpecs["disk"]?.fires, .never)
  }

  // MARK: The gate

  func testARunWaitsForTheOneInProgressAndForItsCooldown() {
    XCTAssertEqual(
      MonitorRunGate.decide(running: false, lastStartMs: nil, cooldownSeconds: 60, nowMs: 0),
      .start)
    XCTAssertEqual(
      MonitorRunGate.decide(running: true, lastStartMs: nil, cooldownSeconds: 0, nowMs: 0),
      .skip(.running))
    XCTAssertEqual(
      MonitorRunGate.decide(
        running: false, lastStartMs: 1_000, cooldownSeconds: 60, nowMs: 31_000),
      .skip(.cooldown(remainingSeconds: 30)))
    XCTAssertEqual(
      MonitorRunGate.decide(
        running: false, lastStartMs: 1_000, cooldownSeconds: 60, nowMs: 61_000),
      .start)
    XCTAssertEqual(
      MonitorRunGate.decide(running: false, lastStartMs: 1_000, cooldownSeconds: 0, nowMs: 1_001),
      .start, "no cooldown, no wait")
  }

  func testTheOutputTailKeepsTheLastBytesOnLineBoundaries() {
    var tail = MonitorOutputTail(limit: 16)
    tail.append(Data("first line\nsecond line\nthird\n".utf8))
    XCTAssertEqual(tail.text, "third")
    var short = MonitorOutputTail(limit: 64)
    short.append(Data("a\n".utf8))
    short.append(Data("b".utf8))
    XCTAssertEqual(short.text, "a\nb")
    XCTAssertLessThanOrEqual(tail.byteCount, 16)
  }

  // MARK: The runner

  private final class Steps {
    var started: [MappingCommand] = []
    var finish: [(MonitorStepResult, String) -> Void] = []
    var cancelled: [String] = []
  }

  private final class Store: MonitorRunStoring {
    var starts: [String: Int64]
    var saved: [[String: Int64]] = []
    init(_ starts: [String: Int64] = [:]) { self.starts = starts }
    func load() -> [String: Int64] { starts }
    func save(_ starts: [String: Int64]) {
      self.starts = starts
      saved.append(starts)
    }
  }

  private func runner(_ steps: Steps, store: Store = Store(), now: @escaping () -> Int64 = { 0 })
    -> MonitorRunner
  {
    MonitorRunner(
      store: store,
      execute: { step, _, _, completion in
        steps.started.append(step)
        steps.finish.append(completion)
        return { reason in steps.cancelled.append(reason) }
      },
      wallClock: now)
  }

  private let a = MappingCommand.shellCommand(["/bin/a"])
  private let b = MappingCommand.shellCommand(["/bin/b"])

  func testStepsRunInOrderEachAfterThePreviousSucceeded() throws {
    let steps = Steps()
    let runner = runner(steps)
    XCTAssertEqual(
      runner.start(
        "cleanup", steps: [a, b], environment: [:], timeoutSeconds: 60,
        cooldownSeconds: 0), .start)
    XCTAssertEqual(steps.started, [a], "the second waits for the first")
    XCTAssertEqual(runner.records["cleanup"]?.status, .running)
    steps.finish[0](.succeeded, "")
    XCTAssertEqual(steps.started, [a, b])
    steps.finish[1](.succeeded, "freed 2 GB")
    let record = try XCTUnwrap(runner.records["cleanup"])
    XCTAssertEqual(record.status, .succeeded)
    XCTAssertNil(record.failedStep)
    XCTAssertEqual(record.output, "freed 2 GB")
    XCTAssertEqual(runner.counts["cleanup"], 1)
  }

  func testTheFirstFailureStopsTheRunAndReportsOnce() throws {
    let steps = Steps()
    let runner = runner(steps)
    var failures: [(String, MonitorRunRecord)] = []
    runner.didFail = { failures.append(($0, $1)) }
    runner.start(
      "cleanup", steps: [a, b], environment: [:], timeoutSeconds: 60, cooldownSeconds: 0)
    steps.finish[0](.exited(3), "error: disk busy")
    XCTAssertEqual(steps.started, [a], "the second never starts")
    let record = try XCTUnwrap(runner.records["cleanup"])
    XCTAssertEqual(record.status, .failed)
    XCTAssertEqual(record.failedStep, 1)
    XCTAssertEqual(record.failedCommand, "/bin/a")
    XCTAssertEqual(record.reason, "exited 3")
    XCTAssertEqual(record.output, "error: disk busy")
    XCTAssertEqual(failures.count, 1)
    steps.finish[0](.succeeded, "late")
    XCTAssertEqual(steps.started, [a], "a step answers once")
    XCTAssertEqual(failures.count, 1)
  }

  func testAFireWhileRunningIsSkippedAndACooldownOutlivesARestart() {
    let steps = Steps()
    let store = Store()
    var now: Int64 = 1_000
    let first = runner(steps, store: store, now: { now })
    first.start("cleanup", steps: [a], environment: [:], timeoutSeconds: 60, cooldownSeconds: 600)
    XCTAssertEqual(
      first.start(
        "cleanup", steps: [a], environment: [:], timeoutSeconds: 60,
        cooldownSeconds: 600), .skip(.running))
    XCTAssertEqual(steps.started.count, 1)
    XCTAssertEqual(store.saved.last, ["cleanup": 1_000], "the start is recorded before it runs")
    steps.finish[0](.succeeded, "")

    // Flash restarted: the cooldown is read back.
    now = 301_000
    let second = runner(steps, store: store, now: { now })
    XCTAssertEqual(
      second.start(
        "cleanup", steps: [a], environment: [:], timeoutSeconds: 60,
        cooldownSeconds: 600), .skip(.cooldown(remainingSeconds: 300)))
    now = 601_000
    XCTAssertEqual(
      second.start(
        "cleanup", steps: [a], environment: [:], timeoutSeconds: 60,
        cooldownSeconds: 600), .start)
  }

  /// A reload that removes a monitor, disables it or changes its steps
  /// stops its run: the step in progress is cancelled, the run fails once
  /// saying why, and the cancelled step's late answer is ignored. A run whose
  /// monitor is unchanged goes on.
  func testAReloadStopsTheRunOfAMonitorThatChanged() throws {
    let steps = Steps()
    let runner = runner(steps)
    var failures: [String] = []
    runner.didFail = { name, _ in failures.append(name) }
    runner.start(
      "cleanup", steps: [a, b], environment: [:], timeoutSeconds: 60, cooldownSeconds: 0)
    runner.start("kept", steps: [a], environment: [:], timeoutSeconds: 60, cooldownSeconds: 0)
    runner.reconcile(["cleanup": [a], "kept": [a]])
    XCTAssertEqual(steps.cancelled, ["the monitor changed"])
    let record = try XCTUnwrap(runner.records["cleanup"])
    XCTAssertEqual(record.status, .failed)
    XCTAssertEqual(record.reason, "was stopped: the monitor changed")
    XCTAssertEqual(runner.records["kept"]?.status, .running)
    steps.finish[0](.succeeded, "late")
    XCTAssertEqual(steps.started, [a, a], "the cancelled run never goes on")
    runner.reconcile([:])
    XCTAssertEqual(runner.records["kept"]?.reason, "was stopped: the monitor changed")
    XCTAssertEqual(failures, ["cleanup", "kept"])
  }

  func testATimedOutStepNamesTheRunsTimeout() throws {
    let steps = Steps()
    let runner = runner(steps)
    runner.start(
      "cleanup", steps: [a, b], environment: [:], timeoutSeconds: 90, cooldownSeconds: 0)
    steps.finish[0](.timedOut, "")
    XCTAssertEqual(runner.records["cleanup"]?.reason, "timed out after 90 s")
    XCTAssertEqual(runner.records["cleanup"]?.failedStep, 1)
  }

  func testARecordReadsAsTheMonitorsPageShowsIt() throws {
    let steps = Steps()
    var now: Int64 = 5_000
    let runner = runner(steps, now: { now })
    runner.start(
      "cleanup", steps: [a, b], environment: [:], timeoutSeconds: 60, cooldownSeconds: 0)
    now = 7_500
    steps.finish[0](.succeeded, "")
    steps.finish[1](.notStarted("no such file"), "")
    let json = try XCTUnwrap(runner.records["cleanup"]).jsonObject
    XCTAssertEqual(json["status"] as? String, "failed")
    XCTAssertEqual(json["steps"] as? Int, 2)
    XCTAssertEqual(json["failed_step"] as? Int, 2)
    XCTAssertEqual(json["failed_command"] as? String, "/bin/b")
    XCTAssertEqual(json["reason"] as? String, "did not start: no such file")
    XCTAssertEqual(json["started_ms"] as? Int64, 5_000)
    XCTAssertEqual(json["duration_ms"] as? Int64, 2_500)
  }

  // MARK: Executables

  private func runProcess(
    _ argv: [String], environment: [String: String] = [:], timeout: TimeInterval = 10
  ) -> (MonitorStepResult, String, TimeInterval) {
    let done = expectation(description: "step")
    var result: (MonitorStepResult, String)?
    let start = Date()
    MonitorProcess.run(argv, environment: environment, timeout: timeout) {
      result = ($0, $1)
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return (result?.0 ?? .commandFailed, result?.1 ?? "", Date().timeIntervalSince(start))
  }

  func testAnExecutableReportsItsExitStatusAndOutputTail() {
    let (result, output, _) = runProcess(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])
    XCTAssertEqual(result, .exited(3))
    XCTAssertEqual(output, "out\nerr")
    XCTAssertEqual(runProcess(["/usr/bin/true"]).0, .succeeded)
  }

  /// No terminal: tools such as `mo clean` take their non-interactive path.
  func testAnExecutableRunsInTheHomeDirectoryWithItsEnvironmentAndNoTerminal() {
    let (result, output, _) = runProcess(
      [
        "/bin/sh", "-c",
        "printf '%s|%s|' \"$FLASH_MONITOR\" \"$PWD\"; [ -t 0 ] && echo tty || echo notty",
      ],
      environment: ["FLASH_MONITOR": "cleanup", "PATH": "/usr/bin:/bin"])
    XCTAssertEqual(result, .succeeded)
    XCTAssertEqual(output, "cleanup|\(NSHomeDirectory())|notty")
  }

  func testAnExecutablePastItsTimeoutIsStopped() {
    let (result, _, elapsed) = runProcess(["/bin/sleep", "30"], timeout: 0.3)
    XCTAssertEqual(result, .timedOut)
    XCTAssertLessThan(elapsed, 8, "SIGTERM at the deadline, SIGKILL soon after")
  }

  /// The regression: at the deadline the step's group got SIGTERM, but the
  /// SIGKILL that follows went to the step's own process only, and only
  /// while it ran, so a child that ignores SIGTERM (a tool's worker, a
  /// `trap`) kept running after the run reported its timeout. The whole
  /// group goes.
  func testATimedOutStepTakesItsChildrenWithIt() throws {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("monitor-grandchild-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let (result, _, _) = runProcess(
      [
        "/bin/sh", "-c",
        "/bin/sh -c 'trap \"\" TERM; exec /bin/sleep 30' & echo $! > '\(marker.path)'; "
          + "/bin/sleep 30",
      ],
      timeout: 0.5)
    XCTAssertEqual(result, .timedOut)
    let text = try String(contentsOf: marker, encoding: .utf8)
    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertTrue(Self.isGone(child, within: 2), "the background child is gone too")
  }

  /// Quitting stops every step still running, children included.
  func testShutdownStopsRunningStepsAndTheirChildren() throws {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("monitor-shutdown-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let done = expectation(description: "step")
    var result: MonitorStepResult?
    MonitorProcess.run(
      ["/bin/sh", "-c", "/bin/sleep 30 & echo $! > '\(marker.path)'; /bin/sleep 30"],
      environment: [:], timeout: 60
    ) { outcome, _ in
      result = outcome
      done.fulfill()
    }
    var text = ""
    let deadline = Date().addingTimeInterval(5)
    while text.isEmpty, Date() < deadline {
      text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      if text.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(MonitorProcess.shutdown(graceSeconds: 0.2, deadlineSeconds: 2), [])
    wait(for: [done], timeout: 5)
    XCTAssertEqual(result, .cancelled("Flash quit"))
    XCTAssertTrue(Self.isGone(child, within: 2))
  }

  /// Whether `pid` no longer exists within `seconds`. Read with `kill(0)`:
  /// a kqueue registration on a process that is not ours can fail for
  /// reasons other than its exit.
  private static func isGone(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if kill(pid, 0) != 0, errno == ESRCH { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    return false
  }

  /// A child left in the background keeps the output pipe open; the step
  /// ends with its own process, not with the child.
  func testABackgroundChildHoldingTheOutputDoesNotHoldTheStep() {
    let (result, output, elapsed) = runProcess(["/bin/sh", "-c", "sleep 5 & echo started"])
    XCTAssertEqual(result, .succeeded)
    XCTAssertEqual(output, "started")
    XCTAssertLessThan(elapsed, 4)
  }

  func testAMissingExecutableNeverStarts() {
    let (result, _, _) = runProcess(["/nonexistent/monitor-step"])
    guard case .notStarted = result else { return XCTFail("\(result)") }
  }
}

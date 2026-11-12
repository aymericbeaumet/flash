import FlashCore
import Foundation

/// `startup run`: run `[startup] run` again, as each launch does.
enum StartupCommand: String, Hashable, CaseIterable {
  case run

  var name: CommandName { CommandName("startup", rawValue) }

  var summary: String {
    "Run the [startup] commands again, in order, and list how each ended"
  }

  var explanation: String {
    "Runs the [startup] commands again, in order, and lists how each one ended."
  }
}

/// How one `[startup] run` command ended.
struct StartupOutcome: Equatable {
  /// The command as written: `killall Dock`, `flash caffeinate on`.
  var command: String
  var result: MonitorStepResult
  /// The tail of what it wrote, stdout and stderr together.
  var output: String
  var durationMs: Int
}

/// One run of `[startup] run`, or why it did not start.
struct StartupReport: Equatable {
  var outcomes: [StartupOutcome] = []
  var timeoutSeconds: Int
  /// Why nothing ran: a run was still going.
  var refusal: String?

  /// The lines of a failed command's output the reply shows; the log keeps
  /// the whole tail.
  static let replyOutputLines = 5

  var failures: [StartupOutcome] { outcomes.filter { $0.result != .succeeded } }
  var succeeded: Bool { refusal == nil && failures.isEmpty }

  /// One line: what ran and how many failed.
  var summary: String {
    if let refusal { return refusal }
    let count = outcomes.count
    guard count > 0 else { return "[startup] run has no commands." }
    let commands = count == 1 ? "1 startup command" : "\(count) startup commands"
    let failed = failures.count
    let all = count == 1 ? "it" : "all"
    if failed == 0 { return "Ran \(commands); \(all) succeeded." }
    if failed == count { return "Ran \(commands); \(all) failed." }
    return "Ran \(commands); \(failed) failed."
  }

  /// The summary, then each command in order: `ok` or `failed` and why,
  /// with the end of a failed command's output beneath it.
  var text: String {
    var lines = [summary]
    for outcome in outcomes {
      guard let failure = outcome.result.failure(timeoutSeconds: timeoutSeconds) else {
        lines.append("ok      \(outcome.command)")
        continue
      }
      lines.append("failed  \(outcome.command) (\(failure))")
      let output = outcome.output.split(separator: "\n", omittingEmptySubsequences: false)
        .suffix(Self.replyOutputLines)
      lines += output.map { "        \($0)" }
    }
    return lines.joined(separator: "\n")
  }
}

/// Runs `[startup] run`: each command in order, once the previous one
/// ended, each bounded by `[startup] timeout`; a failed command is logged and
/// the next one runs anyway. Launch runs the list once (`runAtLaunch`); only
/// `startup run` runs it again, never a configuration reload. One run at a
/// time: a `startup run` during one is refused. Confined to its own serial
/// queue, off main, so launch and the keyboard never wait on it; `execute`
/// answers on any queue, and Flash commands hop to main there.
final class StartupRunner {
  /// Runs one command, bounded by `timeout`, and answers once, on any queue.
  typealias Executor = (
    _ command: MappingCommand, _ timeout: TimeInterval,
    _ completion: @escaping (MonitorStepResult, String) -> Void
  ) -> Void
  /// Runs `body` on `queue` once commands can start: Flash's login
  /// environment resolved, so they inherit the user's PATH.
  typealias ReadyGate = (_ queue: DispatchQueue, _ body: @escaping () -> Void) -> Void

  private let queue: DispatchQueue
  private let execute: Executor
  private let whenReady: ReadyGate
  /// A command that never answers (a Flash command that never completes)
  /// ends this long after its timeout.
  private let unansweredGraceSeconds: TimeInterval
  // Queue-confined.
  private var launched = false
  private var running = false
  /// Flash is quitting: no command starts any more.
  private var stopped = false
  /// One per command started: an answer for an earlier one is ignored.
  private var token: UInt64 = 0

  init(
    queue: DispatchQueue = DispatchQueue(label: "flash.startup", qos: .utility),
    unansweredGraceSeconds: TimeInterval = MonitorRunner.unansweredStepGraceSeconds,
    whenReady: @escaping ReadyGate, execute: @escaping Executor
  ) {
    self.queue = queue
    self.unansweredGraceSeconds = unansweredGraceSeconds
    self.whenReady = whenReady
    self.execute = execute
  }

  /// The launch's run: once per process, whatever the configuration says
  /// later. `completion` runs on the runner's queue.
  func runAtLaunch(
    _ startup: Config.Startup, completion: @escaping (StartupReport) -> Void = { _ in }
  ) {
    queue.async { [self] in
      guard !launched else {
        FlashLog.debug(
          "[startup] skipped", fields: ["trigger": "launch", "reason": "already_launched"])
        return
      }
      launched = true
      start(startup, trigger: "launch", completion: completion)
    }
  }

  /// `startup run`. `completion` runs on the runner's queue.
  func run(_ startup: Config.Startup, completion: @escaping (StartupReport) -> Void) {
    queue.async { [self] in start(startup, trigger: "command", completion: completion) }
  }

  /// Block until the queued work started. Tests.
  func drain() {
    queue.sync {}
  }

  /// Quitting, before `MonitorProcess.shutdown`: no command starts after
  /// this returns, and one whose spawn was in flight has registered with
  /// `MonitorProcess` by then, so its shutdown stops it with the rest. The
  /// commands not reached end as cancelled.
  func stop() {
    queue.sync { stopped = true }
  }

  private func start(
    _ startup: Config.Startup, trigger: String, completion: @escaping (StartupReport) -> Void
  ) {
    guard !running else {
      FlashLog.info("[startup] skipped", fields: ["trigger": trigger, "reason": "running"])
      completion(
        StartupReport(
          timeoutSeconds: startup.timeoutSeconds,
          refusal: "The startup commands are already running."))
      return
    }
    guard !startup.run.isEmpty else {
      FlashLog.debug("[startup] run", fields: ["trigger": trigger, "commands": "0"])
      completion(StartupReport(timeoutSeconds: startup.timeoutSeconds))
      return
    }
    running = true
    whenReady(queue) { [self] in
      FlashLog.info(
        "[startup] run",
        fields: [
          "trigger": trigger, "commands": String(startup.run.count),
          "timeout_s": String(startup.timeoutSeconds),
        ])
      step(
        0, startup, report: StartupReport(timeoutSeconds: startup.timeoutSeconds),
        started: ProcessInfo.processInfo.systemUptime, completion: completion)
    }
  }

  private func step(
    _ index: Int, _ startup: Config.Startup, report: StartupReport, started: TimeInterval,
    completion: @escaping (StartupReport) -> Void
  ) {
    let count = startup.run.count
    if stopped, index < count {
      var report = report
      for command in startup.run[index...] {
        report.outcomes.append(
          StartupOutcome(
            command: MonitorRunner.describe(command), result: .cancelled("Flash quit"),
            output: "", durationMs: 0))
      }
      FlashLog.info(
        "[startup] run_stopped", fields: ["step": "\(index + 1)/\(count)", "reason": "quit"])
      return step(count, startup, report: report, started: started, completion: completion)
    }
    guard index < count else {
      running = false
      let durationMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
      FlashLog.info(
        "[startup] run_done",
        fields: [
          "commands": String(count), "failed": String(report.failures.count),
          "duration_ms": String(durationMs),
        ])
      completion(report)
      return
    }
    let command = startup.run[index]
    let text = MonitorRunner.describe(command)
    let timeout = TimeInterval(startup.timeoutSeconds)
    token &+= 1
    let current = token
    let stepStarted = ProcessInfo.processInfo.systemUptime
    FlashLog.info("[startup] step", fields: ["step": "\(index + 1)/\(count)", "command": text])
    let answer: (MonitorStepResult, String) -> Void = { [weak self] result, output in
      guard let self else { return }
      self.queue.async {
        guard self.token == current else { return }
        self.token &+= 1
        let durationMs = Int((ProcessInfo.processInfo.systemUptime - stepStarted) * 1000)
        let step = "\(index + 1)/\(count)"
        if let failure = result.failure(timeoutSeconds: startup.timeoutSeconds) {
          FlashLog.warn(
            "[startup] step_failed",
            fields: [
              "step": step, "command": text, "reason": failure,
              "duration_ms": String(durationMs), "output": output,
            ])
        } else {
          FlashLog.info(
            "[startup] step_done", fields: ["step": step, "duration_ms": String(durationMs)])
        }
        var report = report
        report.outcomes.append(
          StartupOutcome(command: text, result: result, output: output, durationMs: durationMs))
        self.step(index + 1, startup, report: report, started: started, completion: completion)
      }
    }
    // A backstop bounding this one command: an executable answers at its
    // own deadline, a Flash command that never completes ends here.
    queue.asyncAfter(deadline: .now() + timeout + unansweredGraceSeconds) {
      answer(.timedOut, "")
    }
    execute(command, timeout, answer)
  }
}

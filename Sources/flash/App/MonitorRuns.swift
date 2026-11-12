import CFlashTerminal
import Darwin
import FlashTerminal
import Foundation

/// The bounds a monitor's `run` gets when its table names none.
enum MonitorRunDefaults {
  /// The whole run, every step included.
  static let timeoutSeconds = 600
  static let timeoutRange = 1...86_400
  /// Up to a week between two runs.
  static let cooldownRange = 0...604_800
}

/// How one step of a monitor's run ended.
enum MonitorStepResult: Equatable {
  case succeeded
  /// The executable exited with a non-zero status.
  case exited(Int32)
  /// The executable died of a signal it did not ask for.
  case killed(Int32)
  /// The run's timeout ran out during this step.
  case timedOut
  case notStarted(String)
  /// A Flash command that did not perform.
  case commandFailed
  /// Stopped before it ended: Flash quit, or the monitor changed.
  case cancelled(String)

  /// Why the step failed, as a run reports it; nil when it succeeded.
  func failure(timeoutSeconds: Int) -> String? {
    switch self {
    case .succeeded: return nil
    case .exited(let status): return "exited \(status)"
    case .killed(let signal): return "was killed by signal \(signal)"
    case .timedOut: return "timed out after \(timeoutSeconds) s"
    case .notStarted(let reason): return "did not start: \(reason)"
    case .commandFailed: return "failed"
    case .cancelled(let reason): return "was stopped: \(reason)"
    }
  }
}

/// Why a fire did not start a run.
enum MonitorRunSkip: Equatable {
  /// The previous run is still going: a monitor runs one at a time.
  case running
  case cooldown(remainingSeconds: Int)

  var description: String {
    switch self {
    case .running: return "running"
    case .cooldown(let seconds): return "cooldown remaining_s=\(seconds)"
    }
  }
}

enum MonitorRunDecision: Equatable {
  case start
  case skip(MonitorRunSkip)
}

/// Whether a fire starts a run: never over one in progress, and never
/// within `cooldownSeconds` of the last start, which the ledger keeps across
/// restarts.
enum MonitorRunGate {
  static func decide(
    running: Bool, lastStartMs: Int64?, cooldownSeconds: Int, nowMs: Int64
  ) -> MonitorRunDecision {
    if running { return .skip(.running) }
    if cooldownSeconds > 0, let lastStartMs {
      let remainingMs = Int64(cooldownSeconds) * 1000 - (nowMs - lastStartMs)
      if remainingMs > 0 {
        return .skip(.cooldown(remainingSeconds: Int((remainingMs + 999) / 1000)))
      }
    }
    return .start
  }
}

/// The last `limit` bytes a step wrote, stdout and stderr together, cut to
/// whole lines when it overflowed.
struct MonitorOutputTail {
  let limit: Int
  private var bytes = Data()
  private var overflowed = false

  init(limit: Int) { self.limit = limit }

  var byteCount: Int { bytes.count }

  mutating func append(_ data: Data) {
    bytes.append(data)
    guard bytes.count > limit else { return }
    bytes = bytes.suffix(limit)
    overflowed = true
  }

  /// The text, without a leading partial line once it overflowed, and
  /// without the blank edges.
  var text: String {
    var kept = bytes
    if overflowed, let newline = kept.firstIndex(of: 10) {
      kept = kept[kept.index(after: newline)...]
    }
    return String(decoding: kept, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// One run of a monitor's steps, as the monitors page shows it.
struct MonitorRunRecord: Equatable {
  enum Status: String {
    case running, succeeded, failed
  }

  var status: Status
  var startedMs: Int64
  var endedMs: Int64?
  var steps: Int
  /// The step that failed, counted from 1, and its command.
  var failedStep: Int?
  var failedCommand: String?
  var reason: String?
  /// The tail of the failing step's output, or of the last step's.
  var output = ""

  var jsonObject: [String: Any] {
    [
      "status": status.rawValue,
      "started_ms": startedMs,
      "ended_ms": endedMs as Any? ?? NSNull(),
      "duration_ms": endedMs.map { $0 - startedMs } as Any? ?? NSNull(),
      "steps": steps,
      "failed_step": failedStep as Any? ?? NSNull(),
      "failed_command": failedCommand as Any? ?? NSNull(),
      "reason": reason as Any? ?? NSNull(),
      "output": output,
    ]
  }
}

/// When each monitor's run last started, kept across restarts so a
/// cooldown outlives one.
protocol MonitorRunStoring {
  func load() -> [String: Int64]
  func save(_ starts: [String: Int64])
}

/// `monitor-runs.json` in Flash's Application Support directory: the start
/// time of each monitor's last run, nothing else. Written off main.
struct MonitorRunLedger: MonitorRunStoring {
  private static let queue = DispatchQueue(label: "flash.monitor-runs", qos: .utility)
  let url: URL

  /// The resident's ledger; the test runner keeps its own in memory.
  static func live() -> any MonitorRunStoring {
    guard NSClassFromString("XCTestCase") == nil else { return MemoryMonitorRunStore() }
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return MonitorRunLedger(
      url: support.appendingPathComponent("Flash/monitor-runs.json", isDirectory: false))
  }

  func load() -> [String: Int64] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let starts = object["last_start_ms"] as? [String: Any]
    else { return [:] }
    return starts.compactMapValues { ($0 as? NSNumber)?.int64Value }
  }

  func save(_ starts: [String: Int64]) {
    let url = url
    Self.queue.async {
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: ["last_start_ms": starts], options: [.sortedKeys])
      else { return }
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        FlashLog.warn("[monitors] could not record run starts: \(error)")
      }
    }
  }
}

final class MemoryMonitorRunStore: MonitorRunStoring {
  private var starts: [String: Int64] = [:]
  func load() -> [String: Int64] { starts }
  func save(_ starts: [String: Int64]) { self.starts = starts }
}

/// The monitors' runs. Each monitor runs one at a time: a fire during its
/// run, or within its cooldown, is skipped. Its steps run in order, each
/// once the previous succeeded; the first failure ends the run and is
/// reported once. The whole run is bounded by its timeout. Main-thread
/// confined; `execute` answers each step on main.
final class MonitorRunner {
  /// Runs one step and answers through `completion`; returns how to stop it
  /// before it answers, when it can be.
  typealias StepExecutor = (
    _ step: MappingCommand, _ environment: [String: String], _ timeout: TimeInterval,
    _ completion: @escaping (MonitorStepResult, String) -> Void
  ) -> ((String) -> Void)?

  /// The step of a run in progress, and how to stop it.
  private struct ActiveStep {
    let steps: [MappingCommand]
    let index: Int
    let generation: UInt64
    let timeoutSeconds: Int
    let cancel: ((String) -> Void)?
  }

  /// A step that never answers ends the run this long after its deadline.
  static let unansweredStepGraceSeconds: TimeInterval = 10

  private(set) var records: [String: MonitorRunRecord] = [:]
  /// How many runs each monitor started since launch.
  private(set) var counts: [String: Int] = [:]
  private var lastStartMs: [String: Int64]
  private let store: any MonitorRunStoring
  private let execute: StepExecutor
  private let wallClock: () -> Int64
  /// One generation per run: an answer from a run that ended is ignored.
  private var generations: [String: UInt64] = [:]
  private var active: [String: ActiveStep] = [:]
  var didChange: () -> Void = {}
  var didFail: (String, MonitorRunRecord) -> Void = { _, _ in }

  init(
    store: any MonitorRunStoring, execute: @escaping StepExecutor,
    wallClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
  ) {
    self.store = store
    self.execute = execute
    self.wallClock = wallClock
    lastStartMs = store.load()
  }

  func lastStart(of name: String) -> Int64? { lastStartMs[name] }

  @discardableResult
  func start(
    _ name: String, steps: [MappingCommand], environment: [String: String],
    timeoutSeconds: Int, cooldownSeconds: Int
  ) -> MonitorRunDecision {
    guard !steps.isEmpty else { return .skip(.running) }
    let now = wallClock()
    let decision = MonitorRunGate.decide(
      running: records[name]?.status == .running, lastStartMs: lastStartMs[name],
      cooldownSeconds: cooldownSeconds, nowMs: now)
    guard decision == .start else {
      if case .skip(let skip) = decision {
        FlashLog.info("[monitors] skipped name=\(name) reason=\(skip.description)")
      }
      return decision
    }
    counts[name, default: 0] += 1
    lastStartMs[name] = now
    store.save(lastStartMs)
    generations[name, default: 0] &+= 1
    records[name] = MonitorRunRecord(status: .running, startedMs: now, steps: steps.count)
    FlashLog.info("[monitors] run name=\(name) steps=\(steps.count) timeout_s=\(timeoutSeconds)")
    didChange()
    let deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(timeoutSeconds)
    runStep(
      name, steps: steps, index: 0, environment: environment, timeoutSeconds: timeoutSeconds,
      deadline: deadline, generation: generations[name] ?? 0)
    return .start
  }

  private func runStep(
    _ name: String, steps: [MappingCommand], index: Int, environment: [String: String],
    timeoutSeconds: Int, deadline: TimeInterval, generation: UInt64
  ) {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else {
      finish(
        name, generation: generation, steps: steps, failed: index, result: .timedOut,
        output: "", timeoutSeconds: timeoutSeconds)
      return
    }
    let step = steps[index]
    let command = Self.describe(step)
    FlashLog.info(
      "[monitors] step name=\(name) step=\(index + 1)/\(steps.count) command=\(command)")
    var answered = false
    let started = ProcessInfo.processInfo.systemUptime
    let answer: (MonitorStepResult, String) -> Void = { [weak self] result, output in
      guard let self, !answered, self.generations[name] == generation else { return }
      answered = true
      let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
      FlashLog.info(
        "[monitors] step_done name=\(name) step=\(index + 1)/\(steps.count) "
          + "result=\(result.failure(timeoutSeconds: timeoutSeconds) ?? "ok") duration_ms=\(elapsedMs)"
      )
      guard result == .succeeded else {
        self.finish(
          name, generation: generation, steps: steps, failed: index, result: result,
          output: output, timeoutSeconds: timeoutSeconds)
        return
      }
      guard index + 1 < steps.count else {
        self.finish(
          name, generation: generation, steps: steps, failed: nil, result: .succeeded,
          output: output, timeoutSeconds: timeoutSeconds)
        return
      }
      self.active[name] = nil
      self.runStep(
        name, steps: steps, index: index + 1, environment: environment,
        timeoutSeconds: timeoutSeconds, deadline: deadline, generation: generation)
    }
    // A backstop for a step that never answers (a Flash command that never
    // completes): the run's timeout bounds it like any other step.
    DispatchQueue.main.asyncAfter(
      deadline: .now() + remaining + Self.unansweredStepGraceSeconds
    ) {
      answer(.timedOut, "")
    }
    let cancel = execute(step, environment, remaining, answer)
    // An executor can answer synchronously, ending or advancing the run.
    if !answered, generations[name] == generation {
      active[name] = ActiveStep(
        steps: steps, index: index, generation: generation, timeoutSeconds: timeoutSeconds,
        cancel: cancel)
    }
  }

  /// A reload: a run whose monitor is gone, disabled, or runs other steps
  /// now is stopped, its step cancelled and the run failed once. `runs` maps
  /// each enabled monitor to its steps.
  func reconcile(_ runs: [String: [MappingCommand]]) {
    for (name, current) in active.sorted(by: { $0.key < $1.key })
    where runs[name] != current.steps {
      cancel(name, current, reason: "the monitor changed")
    }
  }

  /// Stop `name`'s run in progress, if any.
  func cancel(_ name: String, reason: String) {
    guard let current = active[name] else { return }
    cancel(name, current, reason: reason)
  }

  private func cancel(_ name: String, _ current: ActiveStep, reason: String) {
    guard generations[name] == current.generation else { return }
    FlashLog.info("[monitors] run_cancelled name=\(name) reason=\(reason)")
    current.cancel?(reason)
    finish(
      name, generation: current.generation, steps: current.steps, failed: current.index,
      result: .cancelled(reason), output: "", timeoutSeconds: current.timeoutSeconds)
  }

  private func finish(
    _ name: String, generation: UInt64, steps: [MappingCommand], failed: Int?,
    result: MonitorStepResult, output: String, timeoutSeconds: Int
  ) {
    guard generations[name] == generation, var record = records[name] else { return }
    generations[name, default: 0] &+= 1
    active[name] = nil
    record.endedMs = wallClock()
    record.output = output
    if let failed {
      record.status = .failed
      record.failedStep = failed + 1
      record.failedCommand = Self.describe(steps[failed])
      record.reason = result.failure(timeoutSeconds: timeoutSeconds)
    } else {
      record.status = .succeeded
    }
    records[name] = record
    let duration = (record.endedMs ?? record.startedMs) - record.startedMs
    if record.status == .failed {
      FlashLog.warn(
        "[monitors] run_failed name=\(name) step=\(record.failedStep ?? 0)/\(steps.count) "
          + "command=\(record.failedCommand ?? "") reason=\(record.reason ?? "") "
          + "duration_ms=\(duration) output=\(record.output)")
      didFail(name, record)
    } else {
      FlashLog.info("[monitors] run_done name=\(name) steps=\(steps.count) duration_ms=\(duration)")
    }
    didChange()
  }

  /// A step as written: `bonsai clean --all --force`, `flash caffeinate off`.
  static func describe(_ step: MappingCommand) -> String {
    step.argv.joined(separator: " ")
  }
}

/// One executable step of a monitor's run. It starts in its own process
/// group with `environment`, in the home directory, reading `/dev/null` (no
/// terminal, so tools take their non-interactive path), and keeps the tail
/// of what it writes, stdout and stderr together. At the deadline the whole
/// group gets SIGTERM, and SIGKILL `killGraceSeconds` later: a child the step
/// started (a script's worker, a tool's helpers) goes with it. A step that
/// ends on its own lets a child it left in the background go: that child is
/// given `drainGraceSeconds` to release the output, then let go.
enum MonitorProcess {
  static let outputLimit = 16 * 1024
  static let killGraceSeconds: TimeInterval = 5
  static let drainGraceSeconds: TimeInterval = 1
  private static let queue = DispatchQueue(label: "flash.monitor-process", qos: .utility)
  /// Steps whose process group may still run, by leader pid; queue-confined.
  private static var live: [pid_t: Step] = [:]

  /// Stops a step before it ends; idempotent.
  final class Handle: @unchecked Sendable {
    fileprivate weak var step: Step?
    fileprivate init(step: Step) { self.step = step }

    /// The whole group gets SIGTERM, SIGKILL `killGraceSeconds` later, and
    /// the step answers `.cancelled(reason)`.
    func cancel(reason: String) {
      MonitorProcess.queue.async { [step] in step?.stop(.cancelled(reason)) }
    }
  }

  /// `completion` runs once, on a background queue.
  @discardableResult
  static func run(
    _ argv: [String], environment: [String: String], timeout: TimeInterval,
    completion: @escaping (MonitorStepResult, String) -> Void
  ) -> Handle? {
    guard let plan = CommandMappingRunner.launchPlan(for: argv, environment: environment) else {
      completion(.notStarted("no executable"), "")
      return nil
    }
    let spawned: (pid: pid_t, output: Int32)
    do {
      spawned = try spawn(
        [plan.executableURL.path] + plan.arguments, environment: environment,
        directory: NSHomeDirectory())
    } catch {
      completion(.notStarted(error.localizedDescription), "")
      return nil
    }
    let step = Step(pid: spawned.pid, output: spawned.output, completion: completion)
    queue.async {
      live[spawned.pid] = step
      step.start(timeout: max(0, timeout))
    }
    return Handle(step: step)
  }

  /// Quitting: every step still running gets SIGTERM with its group, and
  /// SIGKILL after `graceSeconds`; waits on the kernel's exit events, at most
  /// `deadlineSeconds`. Each step answers `.cancelled("Flash quit")`. Returns
  /// the leaders whose group outlived the deadline.
  @discardableResult
  static func shutdown(graceSeconds: TimeInterval = 0.5, deadlineSeconds: TimeInterval = 2)
    -> [pid_t]
  {
    let steps = queue.sync { () -> [Step] in
      let steps = Array(live.values)
      for step in steps { step.detachForShutdown() }
      return steps
    }
    guard !steps.isEmpty else { return [] }
    let groups = steps.map(\.pid)
    for group in groups { kill(-group, SIGTERM) }
    let started = DispatchTime.now()
    let deadline = started + max(0, deadlineSeconds)
    var exited: Set<pid_t> = []
    _ = ProcessExit.waitForGroups(
      groups, until: min(deadline, started + max(0, graceSeconds)), exited: &exited)
    for group in groups where !ProcessExit.members(ofGroup: group).isEmpty {
      kill(-group, SIGKILL)
    }
    _ = ProcessExit.waitForGroups(groups, until: deadline, exited: &exited)
    for step in steps { step.reapAfterShutdown(exited: exited.contains(step.pid)) }
    queue.sync { for group in groups { live[group] = nil } }
    // A member whose exit was reported may still await its reaper (launchd
    // for an orphan): only one never reported exiting outlived the deadline.
    return groups.filter { group in
      ProcessExit.members(ofGroup: group).contains { !exited.contains($0) }
    }
  }

  /// `posix_spawn` into a new process group (leader = the child), stdin from
  /// `/dev/null`, stdout and stderr into one pipe whose read end is returned.
  private static func spawn(
    _ argv: [String], environment: [String: String], directory: String
  ) throws -> (pid: pid_t, output: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
      close(descriptors[1])
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
    flash_spawn_file_actions_addchdir(&actions, directory)
    var mask = sigset_t()
    var defaults = sigset_t()
    sigemptyset(&mask)
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)
    var pid: pid_t = 0
    let error = withCStringArray(argv) { arguments in
      withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) {
        environment in
        posix_spawn(&pid, argv[0], &actions, &attributes, arguments, environment)
      }
    }
    guard error == 0 else {
      close(descriptors[0])
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }
    _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
    return (pid, descriptors[0])
  }

  private static func withCStringArray<T>(
    _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
  ) -> T {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
  }

  /// One step's process group, output and deadlines. Queue-confined, except
  /// `reapAfterShutdown`, which runs once its sources are detached.
  fileprivate final class Step: @unchecked Sendable {
    let pid: pid_t
    private var output: Int32
    private var reader: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var tail = MonitorOutputTail(limit: MonitorProcess.outputLimit)
    /// The leader's status, as `waitpid` reports it.
    private var status: Int32?
    private var reachedEnd = false
    /// Why the step was stopped before it ended, if it was.
    private var stopped: MonitorStepResult?
    private var finished = false
    private var drain: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var escalation: DispatchWorkItem?
    private let completion: (MonitorStepResult, String) -> Void

    init(pid: pid_t, output: Int32, completion: @escaping (MonitorStepResult, String) -> Void) {
      self.pid = pid
      self.output = output
      self.completion = completion
    }

    func start(timeout: TimeInterval) {
      let reader = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
      reader.setEventHandler { [weak self] in self?.readAvailable() }
      self.reader = reader
      reader.resume()
      let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      exit.setEventHandler { [weak self] in self?.leaderExited() }
      exitSource = exit
      exit.resume()
      let item = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
      deadline = item
      queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// The deadline passed, Flash quit or the monitor changed: SIGTERM to
    /// the group, SIGKILL `killGraceSeconds` later while the leader runs.
    func stop(_ reason: MonitorStepResult) {
      guard !finished, status == nil, stopped == nil else { return }
      stopped = reason
      kill(-pid, SIGTERM)
      let item = DispatchWorkItem { [weak self] in
        guard let self, self.status == nil, !self.finished else { return }
        kill(-self.pid, SIGKILL)
      }
      escalation = item
      queue.asyncAfter(deadline: .now() + killGraceSeconds, execute: item)
    }

    private func leaderExited() {
      exitSource?.cancel()
      exitSource = nil
      // A stopped step takes its whole group: signal it while the zombie
      // leader still holds the group id, which a reaped one could hand to an
      // unrelated process.
      if stopped != nil { kill(-pid, SIGKILL) }
      status = Self.reap(pid)
      readAvailable()
      if reachedEnd {
        finish()
      } else {
        // A child left in the background holds the output: let it go.
        let item = DispatchWorkItem { [weak self] in self?.finish() }
        drain = item
        queue.asyncAfter(deadline: .now() + drainGraceSeconds, execute: item)
      }
    }

    private func readAvailable() {
      guard output >= 0, !reachedEnd else { return }
      var buffer = [UInt8](repeating: 0, count: 16_384)
      while true {
        let count = read(output, &buffer, buffer.count)
        if count > 0 {
          tail.append(Data(buffer.prefix(count)))
        } else if count == 0 {
          reachedEnd = true
          if status != nil { finish() }
          return
        } else if errno == EINTR {
          continue
        } else {
          return
        }
      }
    }

    private func finish() {
      guard !finished, let status else { return }
      finished = true
      closeSources()
      live[pid] = nil
      completion(stopped ?? Self.result(status), tail.text)
    }

    private func closeSources() {
      for item in [drain, deadline, escalation] { item?.cancel() }
      drain = nil
      deadline = nil
      escalation = nil
      reader?.cancel()
      reader = nil
      exitSource?.cancel()
      exitSource = nil
      if output >= 0 {
        close(output)
        output = -1
      }
    }

    /// Quitting: the caller signals and waits for the group itself.
    func detachForShutdown() {
      guard !finished else { return }
      if stopped == nil { stopped = .cancelled("Flash quit") }
      for item in [drain, deadline, escalation] { item?.cancel() }
      exitSource?.cancel()
      exitSource = nil
    }

    /// `exited`: the kernel reported the leader's exit, so the reap cannot
    /// block; one still running is not waited for.
    func reapAfterShutdown(exited: Bool) {
      queue.sync {
        guard !finished else { return }
        if status == nil { status = exited ? Self.reap(pid) ?? 0 : 0 }
        // Reaching the end of the output finishes the step itself.
        readAvailable()
        guard !finished else { return }
        finished = true
        closeSources()
        completion(stopped ?? .cancelled("Flash quit"), tail.text)
      }
    }

    /// The leader's raw status; nil when there is nothing to reap.
    private static func reap(_ pid: pid_t) -> Int32? {
      var raw: Int32 = 0
      var result: pid_t
      repeat { result = waitpid(pid, &raw, 0) } while result < 0 && errno == EINTR
      return result == pid ? raw : nil
    }

    private static func result(_ raw: Int32) -> MonitorStepResult {
      let signal = raw & 0x7f
      guard signal == 0 else { return .killed(signal) }
      let code = (raw >> 8) & 0xff
      return code == 0 ? .succeeded : .exited(code)
    }
  }
}

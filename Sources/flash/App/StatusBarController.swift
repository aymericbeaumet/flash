import AppKit
import FlashCore
import Foundation

final class FlashStatusBarController {
  private weak var overlay: OverlayPanel?
  private let queue: DispatchQueue
  private let clock: () -> TimeInterval
  private let makeJob: StatusCommandFactory
  private var template: FlashStatusBarTemplate
  private var popupTemplates: [String: FlashStatusBarTemplate]
  private var options: [String: String]
  private var sources: [String: FlashStatusBarSourceDefinition]
  private var terminalPopupNames: Set<String>
  private let pluginStatusesProvider: () -> [PluginStatusBarInfo]
  private var refreshIntervalSeconds: TimeInterval
  private var timer: DispatchSourceTimer?
  private var timerGeneration: UInt64 = 0
  private(set) var nextWakeup: TimeInterval?
  private var started = false
  private var nextJobToken: UInt64 = 0
  private var requiredSources: Set<String> = []
  private var requiredJobs: [String: StatusFormatJobRequest] = [:]

  private struct SourceRecord {
    let definition: FlashStatusBarSourceDefinition
    var schedule = StatusJobSchedule()
    var job: (any StatusCommandTask)?
    var value: String?
    var cycle: FlashStatusBarCycleState?
  }

  private struct ShellRecord {
    let command: String
    var schedule = StatusJobSchedule()
    var job: (any StatusCommandTask)?
    var value: String?
    var producedOutput = false
  }

  private var sourceRecords: [String: SourceRecord] = [:]
  private var shellRecords: [String: ShellRecord] = [:]
  private var nextClock: TimeInterval?
  private var pendingJobPublish: TimeInterval?
  private var lastJobPublish: TimeInterval = -.infinity
  private var activeAppName = ""
  private var activeBundleIdentifier = ""
  private var modeLabel = "INSERT"
  private(set) var lastPublishedModel: FlashStatusBarModel?

  init(
    overlay: OverlayPanel? = nil, template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
    options: [String: String] = [:],
    sources: [String: FlashStatusBarSourceDefinition] = [:],
    terminalPopupNames: Set<String> = [],
    refreshIntervalSeconds: TimeInterval = 5,
    pluginStatusesProvider: @escaping () -> [PluginStatusBarInfo] = { [] },
    queue: DispatchQueue = DispatchQueue(label: "flash.status_bar", qos: .utility),
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    makeJob: @escaping StatusCommandFactory = { invocation, queue, onLine, onCompletion in
      try StatusFormatCommandJob(
        queue: queue, argv: invocation.argv,
        environment: invocation.environment, workingDirectory: invocation.workingDirectory,
        timeoutSeconds: invocation.timeoutSeconds, onLine: onLine, onCompletion: onCompletion)
    }
  ) {
    self.queue = queue
    self.clock = clock
    self.makeJob = makeJob
    self.overlay = overlay
    self.template = template
    self.popupTemplates = popupTemplates
    self.options = options
    self.sources = sources
    self.terminalPopupNames = terminalPopupNames
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.pluginStatusesProvider = pluginStatusesProvider
  }

  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      self.started = true
      self.publishCurrentModel()
    }
  }

  func stop() {
    queue.sync {
      started = false
      timer?.cancel()
      timer = nil
      timerGeneration &+= 1
      nextWakeup = nil
      let jobs = sourceRecords.values.compactMap(\.job) + shellRecords.values.compactMap(\.job)
      sourceRecords.removeAll()
      shellRecords.removeAll()
      stopJobs(jobs)
      nextClock = nil
      pendingJobPublish = nil
    }
  }

  func updateModeLabel(_ label: String) {
    queue.async { [weak self] in
      self?.modeLabel = label
      self?.publishCurrentModel()
    }
  }

  func updateFocusedApplication(_ app: NSRunningApplication?) {
    let name = app?.localizedName ?? ""
    let bundle = app?.bundleIdentifier ?? ""
    queue.async { [weak self] in
      guard let self else { return }
      self.activeAppName = name
      self.activeBundleIdentifier = bundle
      self.publishCurrentModel()
    }
  }

  func updateTemplate(
    _ template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate]? = nil,
    options: [String: String]? = nil,
    sources: [String: FlashStatusBarSourceDefinition]? = nil,
    terminalPopupNames: Set<String>? = nil,
    refreshIntervalSeconds: TimeInterval? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.template = template
      if let popupTemplates { self.popupTemplates = popupTemplates }
      if let options { self.options = options }
      if let sources {
        let changed = self.sourceRecords.keys.filter {
          sources[$0] != self.sourceRecords[$0]?.definition
        }
        let jobs = changed.compactMap { self.sourceRecords.removeValue(forKey: $0)?.job }
        self.stopJobs(jobs)
        self.sources = sources
      }
      if let terminalPopupNames { self.terminalPopupNames = terminalPopupNames }
      if let refreshIntervalSeconds, refreshIntervalSeconds != self.refreshIntervalSeconds {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.nextClock = nil
        let now = self.clock()
        for key in Array(self.shellRecords.keys) {
          self.shellRecords[key]?.schedule.reschedule(
            now: now,
            interval: refreshIntervalSeconds > 0 ? max(1, refreshIntervalSeconds) : 0)
        }
      }
      self.publishCurrentModel()
    }
  }

  func refreshPluginSections() {
    queue.async { [weak self] in self?.publishCurrentModel() }
  }

  private func stopJobs(_ jobs: [any StatusCommandTask]) {
    let native = jobs.compactMap { $0 as? StatusFormatCommandJob }
    for job in jobs where !(job is StatusFormatCommandJob) { job.cancel() }
    let remaining = StatusFormatCommandJob.shutdown(native)
    if !remaining.isEmpty {
      FlashLog.warn("[statusbar] command shutdown exceeded reap deadline pids=\(remaining)")
    }
  }

  private func publishCurrentModel() {
    let now = clock()
    let context = FlashStatusBarContext(
      activeAppName: activeAppName, activeBundleIdentifier: activeBundleIdentifier,
      modeLabel: modeLabel, pluginStatuses: pluginStatusesProvider())
    var values = sourceRecords.compactMapValues(\.value)
    for (name, record) in sourceRecords {
      if let cycle = record.cycle { values[name] = "#[cyc]" + cycle.visibleLine + "#[nocyc]" }
    }
    let jobValues = shellRecords.compactMapValues(\.value)
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: template, popupTemplates: popupTemplates, context: context,
      dynamicValues: values, jobValues: jobValues, options: options,
      terminalPopupNames: terminalPopupNames)
    if result.model != lastPublishedModel {
      lastPublishedModel = result.model
      DispatchQueue.main.async { [weak overlay] in overlay?.setStatusBarModel(result.model) }
    }
    requiredSources = result.sources
    requiredJobs = [:]
    for job in result.jobs { requiredJobs[job.rawCommand] = job }
    let obsolete = shellRecords.keys.filter { requiredJobs[$0] == nil }
    var obsoleteJobs = obsolete.compactMap { shellRecords.removeValue(forKey: $0)?.job }
    for key in requiredJobs.keys.sorted() {
      guard let request = requiredJobs[key], shellRecords[key]?.command != request.command else {
        continue
      }
      let old = shellRecords.removeValue(forKey: key)
      shellRecords[key] = ShellRecord(command: request.command, value: old?.value)
      if let job = old?.job { obsoleteJobs.append(job) }
    }
    if requiredJobs.isEmpty { pendingJobPublish = nil }
    for name in Array(sourceRecords.keys) where !requiredSources.contains(name) {
      if let job = sourceRecords[name]?.job {
        sourceRecords[name]?.job = nil
        sourceRecords[name]?.schedule = StatusJobSchedule()
        obsoleteJobs.append(job)
      }
    }
    stopJobs(obsoleteJobs)
    if result.needsClock && refreshIntervalSeconds > 0 {
      if nextClock == nil { nextClock = now + max(1, refreshIntervalSeconds) }
    } else {
      nextClock = nil
    }
    guard started else { return }
    runDueJobs(now: now)
    armTimer()
  }

  private func runDueJobs(now: TimeInterval) {
    for name in requiredSources.sorted() {
      guard let definition = sources[name] else { continue }
      if sourceRecords[name] == nil { sourceRecords[name] = SourceRecord(definition: definition) }
      nextJobToken &+= 1
      let token = nextJobToken
      guard
        sourceRecords[name]?.schedule.begin(
          token: token, now: now,
          interval: definition.intervalSeconds) == true
      else { continue }
      startSource(name, definition: definition, token: token)
    }
    for key in requiredJobs.keys.sorted() {
      guard let request = requiredJobs[key] else { continue }
      nextJobToken &+= 1
      let token = nextJobToken
      guard
        shellRecords[key]?.schedule.begin(
          token: token, now: now,
          interval: refreshIntervalSeconds > 0 ? max(1, refreshIntervalSeconds) : 0) == true
      else { continue }
      shellRecords[key]?.producedOutput = false
      startShell(request, token: token)
    }
  }

  private func startSource(
    _ name: String, definition: FlashStatusBarSourceDefinition, token: UInt64
  ) {
    let launch = CommandLaunchConfiguration(
      command: definition.command,
      workingDirectory: definition.workingDirectory, overrides: definition.environment,
      environment: FlashProcessEnvironment.shared.environment)
    var argv = launch.command
    if let executable = argv.first {
      argv[0] = Self.executablePath(executable, environment: launch.environment)
    }
    do {
      sourceRecords[name]?.job = try makeJob(
        StatusCommandInvocation(
          argv: argv, environment: launch.environment, workingDirectory: launch.workingDirectory,
          timeoutSeconds: definition.timeoutSeconds), queue, { _ in },
        { [weak self] status, output in
          guard let self, self.sourceRecords[name]?.schedule.complete(token) == true else { return }
          self.sourceRecords[name]?.job = nil
          if status == 0, !output.trimmed.isEmpty {
            if let period = definition.cycleIntervalSeconds {
              let lines = output.split(separator: "\n").map { String($0).trimmed }.filter {
                !$0.isEmpty
              }
              if var cycle = self.sourceRecords[name]?.cycle {
                cycle.refresh(lines: lines, periodSeconds: period, now: self.clock())
                self.sourceRecords[name]?.cycle = cycle
              } else {
                self.sourceRecords[name]?.cycle = FlashStatusBarCycleState(
                  lines: lines, periodSeconds: period, now: self.clock())
              }
            } else {
              self.sourceRecords[name]?.value = output.trimmed
            }
          }
          self.publishCurrentModel()
        })
    } catch {
      sourceRecords[name]?.schedule.complete(token)
      FlashLog.warn("[statusbar] source failed name=\(name) error=\(error.localizedDescription)")
    }
  }

  private func startShell(_ request: StatusFormatJobRequest, token: UInt64) {
    let key = request.rawCommand
    do {
      shellRecords[key]?.job = try makeJob(
        StatusCommandInvocation(
          argv: ["/bin/sh", "-c", request.command],
          environment: FlashProcessEnvironment.shared.environment,
          workingDirectory: nil, timeoutSeconds: nil), queue,
        { [weak self] line in
          guard let self, self.shellRecords[key]?.schedule.owns(token) == true else { return }
          self.shellRecords[key]?.producedOutput = true
          if self.shellRecords[key]?.value != line {
            self.shellRecords[key]?.value = line
            self.scheduleJobPublish()
          }
        },
        { [weak self] _, _ in
          guard let self, self.shellRecords[key]?.schedule.complete(token) == true else { return }
          self.shellRecords[key]?.job = nil
          if self.shellRecords[key]?.producedOutput == false, self.shellRecords[key]?.value != "" {
            self.shellRecords[key]?.value = ""
            self.scheduleJobPublish()
          }
          self.armTimer()
        })
    } catch {
      shellRecords[key]?.schedule.complete(token)
      shellRecords[key]?.value = "<'\(key)' didn't start>"
      scheduleJobPublish()
      FlashLog.warn("[statusbar] shell job failed error=\(error.localizedDescription)")
    }
  }

  private func scheduleJobPublish() {
    let now = clock()
    let due = max(now, lastJobPublish + 1)
    if due <= now {
      lastJobPublish = now
      pendingJobPublish = nil
      publishCurrentModel()
    } else {
      pendingJobPublish = due
      armTimer()
    }
  }

  private func armTimer() {
    timer?.cancel()
    timer = nil
    timerGeneration &+= 1
    let generation = timerGeneration
    nextWakeup = nil
    guard started else { return }
    var dates = requiredSources.compactMap { sourceRecords[$0]?.schedule.dueAt }
    dates += requiredJobs.keys.compactMap { shellRecords[$0]?.schedule.dueAt }
    dates += requiredJobs.keys.compactMap { key in
      shellRecords[key]?.value == nil ? shellRecords[key]?.schedule.startedAt.map { $0 + 2 } : nil
    }
    dates += requiredSources.compactMap { sourceRecords[$0]?.cycle }
      .filter(\.needsRotationTimer).map(\.nextRotationAt)
    if let nextClock { dates.append(nextClock) }
    if let pendingJobPublish { dates.append(pendingJobPublish) }
    guard let next = dates.filter(\.isFinite).min() else { return }
    nextWakeup = next
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + max(0.001, next - clock()), leeway: .milliseconds(25))
    timer.setEventHandler { [weak self] in
      guard let self, self.timerGeneration == generation else { return }
      self.tick()
    }
    self.timer = timer
    timer.resume()
  }

  private func tick() {
    let now = clock()
    for key in requiredJobs.keys where shellRecords[key]?.value == nil {
      if let start = shellRecords[key]?.schedule.startedAt, now - start >= 2 {
        shellRecords[key]?.value = "<'\(key)' not ready>"
      }
    }
    if let nextClock, nextClock <= now { self.nextClock = nil }
    if let pendingJobPublish, pendingJobPublish <= now {
      self.pendingJobPublish = nil
      lastJobPublish = now
    }
    for name in requiredSources { _ = sourceRecords[name]?.cycle?.advanceIfDue(now: now) }
    publishCurrentModel()
  }

  private static func executablePath(_ executable: String, environment: [String: String]) -> String
  {
    guard !executable.contains("/") else { return executable }
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(
      separator: ":", omittingEmptySubsequences: false)
    {
      let path = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory))
        .appendingPathComponent(executable).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return executable
  }
}

import AppKit
import FlashCore
import Foundation

/// Evaluates every status surface — the bar and each desktop widget — over
/// one source/job registry and one `PollScheduler` deadline. Each surface is
/// memoized on the inputs it last read, so a publish re-evaluates only the
/// surfaces whose inputs changed; a skipped surface keeps contributing the
/// sources, jobs and clock its last evaluation required.
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
  private let scheduler: PollScheduler
  /// Invalidates a scheduled fire once a newer plan (or a stop) replaced it.
  /// Monotonic across lifecycles, so no fire can outlive the run that armed it.
  private var timerGeneration: UInt64 = 0

  /// Deadlines exist only while the controller runs: stopping drops them with
  /// the state, so a stopped controller can never hold a clock tick or a
  /// pending publish that a later start would fire.
  private struct Schedule {
    /// Clock-driven re-evaluation, one deadline per refresh interval in use:
    /// surfaces sharing an interval share its tick.
    var clocks: [TimeInterval: TimeInterval] = [:]
    var pendingJobPublish: TimeInterval?
    var nextWakeup: TimeInterval?
  }

  /// One surface's last evaluation: the inputs it read (an identical capture
  /// skips it) and what it required of the shared registry.
  private struct SurfaceState {
    var memo:
      (
        dependencies: StatusFormatDependencies,
        inputs: FlashStatusBarTemplateEngine.EvaluationInputs
      )?
    var jobs: [StatusFormatJobRequest] = []
    var sources: Set<String> = []
    var needsClock = false

    func isCurrent(_ native: StatusFormatContext) -> Bool {
      guard let memo else { return false }
      return FlashStatusBarTemplateEngine.EvaluationInputs.capture(
        dependencies: memo.dependencies, native: native) == memo.inputs
    }

    mutating func record(
      _ dependencies: StatusFormatDependencies, jobs: [StatusFormatJobRequest],
      native: StatusFormatContext
    ) {
      memo = (
        dependencies,
        FlashStatusBarTemplateEngine.EvaluationInputs.capture(
          dependencies: dependencies, native: native)
      )
      self.jobs = jobs
      (sources, needsClock) = FlashStatusBarTemplateEngine.requirements(of: dependencies)
    }
  }

  private struct WidgetState {
    var spec: StatusWidgetSpec
    /// False while every window of the widget is occluded: it then requires
    /// nothing, so its sources, jobs and clock stop.
    var visible = true
    var surface = SurfaceState()
  }

  private enum Lifecycle {
    case stopped
    case running(Schedule)
  }

  private var lifecycle = Lifecycle.stopped

  private var schedule: Schedule? {
    get {
      if case .running(let schedule) = lifecycle { return schedule }
      return nil
    }
    set {
      guard case .running = lifecycle, let newValue else { return }
      lifecycle = .running(newValue)
    }
  }

  var nextWakeup: TimeInterval? { schedule?.nextWakeup }
  private var nextJobToken: UInt64 = 0
  private var requiredSources: Set<String> = []
  private var requiredJobs: [String: StatusFormatJobRequest] = [:]
  /// The bar's surface; nil while `[statusbar] enabled` is off.
  private var bar: SurfaceState? = SurfaceState()
  private var widgets: [String: WidgetState] = [:]
  /// Set when a surface evaluated, appeared, disappeared or changed
  /// visibility: the registry is reconciled against the union again.
  private var requirementsChanged = true
  private let widgetSink: ((String, [StatusFormatDocument]) -> Void)?
  /// Each widget's last published lines, as handed to `widgetSink`.
  private(set) var lastPublishedWidgets: [String: [StatusFormatDocument]] = [:]
  /// How often each surface ("bar" or a widget's name) evaluated: what the
  /// tests observe to pin that unchanged surfaces are skipped.
  private(set) var surfaceEvaluations: [String: Int] = [:]

  private struct SourceRecord {
    let definition: FlashStatusBarSourceDefinition
    var schedule = StatusJobSchedule()
    var job: (any StatusCommandTask)?
    var value: String?
    var cycle: FlashStatusBarCycleState?
    /// Numeric outputs, oldest first, kept to `historyLength` — and kept
    /// while no surface reads the source, so showing it again has a past.
    var history: [String] = []
  }

  private struct ShellRecord {
    let command: String
    /// Refresh cadence: the fastest interval of the surfaces showing it.
    var interval: TimeInterval
    var schedule = StatusJobSchedule()
    var job: (any StatusCommandTask)?
    var value: String?
    var producedOutput = false
  }

  private var sourceRecords: [String: SourceRecord] = [:]
  private var shellRecords: [String: ShellRecord] = [:]
  /// Host-rotated plugin carousels keyed `<plugin>.<segment>`; a refresh with
  /// new lines keeps the visible line until its scheduled rotation.
  private var pluginCycles: [String: FlashStatusBarCycleState] = [:]
  private var lastJobPublish: TimeInterval = -.infinity
  private var activeAppName = ""
  private var activeBundleIdentifier = ""
  private var modeLabel = "INSERT"
  private var secureInput = false
  private(set) var lastPublishedModel: FlashStatusBarModel?
  private let popupCache = FlashStatusBarTemplateEngine.PopupEvaluationCache()

  init(
    overlay: OverlayPanel? = nil, template: FlashStatusBarTemplate,
    popupTemplates: [String: FlashStatusBarTemplate] = [:],
    options: [String: String] = [:],
    sources: [String: FlashStatusBarSourceDefinition] = [:],
    terminalPopupNames: Set<String> = [],
    refreshIntervalSeconds: TimeInterval = 5,
    pluginStatusesProvider: @escaping () -> [PluginStatusBarInfo] = { [] },
    scheduler: PollScheduler = .shared,
    queue: DispatchQueue = DispatchQueue(label: "flash.status_bar", qos: .userInitiated),
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    makeJob: @escaping StatusCommandFactory = { invocation, queue, onLine, onCompletion in
      try StatusFormatCommandJob(
        queue: queue, argv: invocation.argv,
        environment: invocation.environment, workingDirectory: invocation.workingDirectory,
        timeoutSeconds: invocation.timeoutSeconds, onLine: onLine, onCompletion: onCompletion)
    },
    widgetSink: ((String, [StatusFormatDocument]) -> Void)? = nil
  ) {
    self.widgetSink = widgetSink
    self.scheduler = scheduler
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
      if case .stopped = self.lifecycle {
        self.lifecycle = .running(Schedule())
        // A restart plans afresh: an evaluation cached before the stop would
        // take the unchanged-inputs shortcut and never re-run its commands.
        self.bar?.memo = nil
        for name in self.widgets.keys { self.widgets[name]?.surface.memo = nil }
      }
      self.publishCurrentModel()
    }
  }

  /// Stopping reaps command jobs, which can wait up to a second for them to
  /// exit, so it runs on `queue`; a later `start()` still follows it there.
  func stop() {
    queue.async { [weak self] in self?.stopOnQueue() }
  }

  /// Termination only: the jobs must be reaped before the process exits.
  func stopAndWait() {
    queue.sync { stopOnQueue() }
  }

  private func stopOnQueue() {
    lifecycle = .stopped
    scheduler.unregister(Self.pollClientID)
    timerGeneration &+= 1
    let jobs = sourceRecords.values.compactMap(\.job) + shellRecords.values.compactMap(\.job)
    sourceRecords.removeAll()
    shellRecords.removeAll()
    pluginCycles.removeAll()
    requirementsChanged = true
    stopJobs(jobs)
  }

  /// `[statusbar] enabled`: whether the bar is a surface. The controller keeps
  /// running for widgets while the bar is off.
  func setBar(enabled: Bool) {
    queue.async { [weak self] in
      guard let self, enabled != (self.bar != nil) else { return }
      self.bar = enabled ? SurfaceState() : nil
      self.requirementsChanged = true
      self.publishCurrentModel()
    }
  }

  /// The enabled widgets. A widget whose spec changed evaluates afresh; one
  /// that disappeared releases what only it required.
  func updateWidgets(_ specs: [String: StatusWidgetSpec]) {
    queue.async { [weak self] in
      guard let self else { return }
      var widgets: [String: WidgetState] = [:]
      for (name, spec) in specs {
        var widget = self.widgets[name] ?? WidgetState(spec: spec)
        if widget.spec != spec {
          widget.spec = spec
          widget.surface = SurfaceState()
        }
        widgets[name] = widget
      }
      for name in self.widgets.keys where specs[name] == nil {
        self.lastPublishedWidgets.removeValue(forKey: name)
        self.surfaceEvaluations.removeValue(forKey: name)
      }
      self.widgets = widgets
      self.requirementsChanged = true
      self.publishCurrentModel()
    }
  }

  /// Whether any window of the widget can be seen. An occluded widget drops
  /// out of the required sources, jobs and clock until it shows again.
  func setWidgetVisible(name: String, _ visible: Bool) {
    queue.async { [weak self] in
      guard let self, let widget = self.widgets[name], widget.visible != visible else { return }
      self.widgets[name]?.visible = visible
      self.requirementsChanged = true
      FlashLog.debug("[widgets] \(visible ? "visible" : "occluded") name=\(name)")
      self.publishCurrentModel()
    }
  }

  func updateModeLabel(_ label: String) {
    queue.async { [weak self] in
      self?.modeLabel = label
      self?.publishCurrentModel()
    }
  }

  /// `#{flash.secure_input}`: "1" while secure input is on, else "".
  func updateSecureInput(_ enabled: Bool) {
    queue.async { [weak self] in
      guard let self, self.secureInput != enabled else { return }
      self.secureInput = enabled
      self.publishCurrentModel()
    }
  }

  func updateFocusedApplication(_ app: NSRunningApplication?) {
    let name = app?.localizedName ?? ""
    let bundle = app?.bundleIdentifier ?? ""
    FlashLog.trace("[statusbar] focus bundle=\(bundle)")
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
      self.bar?.memo = nil
      self.popupCache.memos.removeAll()
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
        // A new cadence starts from now: the clocks re-arm, and the job
        // records re-plan against their new cadence when reconciled.
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.schedule?.clocks.removeAll()
        self.requirementsChanged = true
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

  /// Plugin carousels resolved to their visible line, with their rotation
  /// state refreshed (lines and period) and pruned to the segments still
  /// published.
  private func resolvedPluginStatuses(now: TimeInterval) -> [PluginStatusBarInfo] {
    var active: Set<String> = []
    let statuses = pluginStatusesProvider().map { info -> PluginStatusBarInfo in
      var info = info
      for (name, segment) in info.statusSegments {
        guard case .carousel(let prefix, let lines, let seconds) = segment else { continue }
        let key = "\(info.id).\(name)"
        active.insert(key)
        if var cycle = pluginCycles[key] {
          cycle.refresh(lines: lines, periodSeconds: seconds, now: now)
          pluginCycles[key] = cycle
        } else {
          pluginCycles[key] = FlashStatusBarCycleState(
            lines: lines, periodSeconds: seconds, now: now)
          FlashLog.trace(
            "[statusbar] carousel_start key=\(key) lines=\(lines.count) period=\(seconds)")
        }
        info.statusSegments[name] = .text(
          PluginStatusSegment.carouselLine(
            prefix: prefix, line: pluginCycles[key]?.visibleLine ?? ""))
      }
      return info
    }
    if pluginCycles.count != active.count {
      pluginCycles = pluginCycles.filter { active.contains($0.key) }
    }
    return statuses
  }

  private func publishCurrentModel() {
    let now = clock()
    let context = FlashStatusBarContext(
      activeAppName: activeAppName, activeBundleIdentifier: activeBundleIdentifier,
      modeLabel: modeLabel, secureInput: secureInput,
      pluginStatuses: resolvedPluginStatuses(now: now))
    var values = sourceRecords.compactMapValues(\.value)
    for (name, record) in sourceRecords {
      if let cycle = record.cycle { values[name] = "#[cyc]" + cycle.visibleLine + "#[nocyc]" }
      if !record.history.isEmpty {
        values["flash.history.\(name)"] = record.history.joined(separator: " ")
      }
    }
    let jobValues = shellRecords.compactMapValues(\.value)
    // The shared context is built once; each surface layers its options on it.
    let native = FlashStatusBarTemplateEngine.formatContext(
      context, dynamicValues: values, jobValues: jobValues)
    if bar != nil { publishBar(native: native, context: context) }
    for name in widgets.keys.sorted() where widgets[name]?.visible == true {
      publishWidget(name, native: native)
    }
    if requirementsChanged { reconcileRequirements(now: now) }
    guard schedule != nil else { return }
    armClocks(now: now)
    runDueJobs(now: now)
    armTimer()
  }

  private func publishBar(native shared: StatusFormatContext, context: FlashStatusBarContext) {
    var native = shared
    native.options = options.merging(template.options) { _, local in local }
    // Nothing the template or its popups read has changed since the last
    // evaluation: the bar keeps what it required.
    guard bar?.isCurrent(native) == false else { return }
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: template, popupTemplates: popupTemplates, context: context,
      options: options, terminalPopupNames: terminalPopupNames, nativeContext: native,
      popupCache: popupCache)
    bar?.record(result.dependencies, jobs: result.jobs, native: native)
    surfaceEvaluations["bar", default: 0] += 1
    requirementsChanged = true
    if result.model != lastPublishedModel {
      lastPublishedModel = result.model
      DispatchQueue.main.async { [weak overlay] in overlay?.setStatusBarModel(result.model) }
    }
  }

  private func publishWidget(_ name: String, native shared: StatusFormatContext) {
    guard let spec = widgets[name]?.spec else { return }
    var native = shared
    native.values["flash.widget.name"] = name
    native.values["flash.widget.columns"] = String(spec.columns)
    native.options = options.merging(spec.template.options) { _, local in local }
    guard widgets[name]?.surface.isCurrent(native) == false else { return }
    let result = FlashStatusBarTemplateEngine.evaluateDocument(
      spec.template, native: native, lineBreaksResetAlignment: true)
    widgets[name]?.surface.record(result.dependencies, jobs: result.jobs, native: native)
    surfaceEvaluations[name, default: 0] += 1
    requirementsChanged = true
    let lines = StatusFormatDocument(runs: result.runs).lines()
    guard lines != lastPublishedWidgets[name] else { return }
    lastPublishedWidgets[name] = lines
    if let widgetSink { DispatchQueue.main.async { widgetSink(name, lines) } }
  }

  /// The surfaces that require anything right now, with the refresh interval
  /// each one's clock and `#()` jobs run at. Occluded widgets are absent.
  private var activeSurfaces: [(surface: SurfaceState, interval: TimeInterval)] {
    var surfaces = bar.map { [($0, refreshIntervalSeconds)] } ?? []
    for name in widgets.keys.sorted() {
      guard let widget = widgets[name], widget.visible else { continue }
      surfaces.append(
        (
          widget.surface,
          widget.spec.intervalSeconds > 0 ? widget.spec.intervalSeconds : refreshIntervalSeconds
        ))
    }
    return surfaces
  }

  private static func cadence(_ interval: TimeInterval) -> TimeInterval {
    interval > 0 ? max(1, interval) : 0
  }

  /// Point the registry at the union of what the active surfaces require:
  /// reap what none requires any more, and re-plan a job whose cadence (the
  /// fastest of the surfaces showing it) changed.
  private func reconcileRequirements(now: TimeInterval) {
    requirementsChanged = false
    var sources = Set<String>()
    var jobs: [String: StatusFormatJobRequest] = [:]
    var cadences: [String: TimeInterval] = [:]
    for (surface, interval) in activeSurfaces {
      sources.formUnion(surface.sources)
      let cadence = Self.cadence(interval)
      for job in surface.jobs {
        if jobs[job.rawCommand] == nil { jobs[job.rawCommand] = job }
        let current = cadences[job.rawCommand]
        cadences[job.rawCommand] =
          current.map { $0 == 0 ? cadence : (cadence == 0 ? $0 : min($0, cadence)) } ?? cadence
      }
    }
    requiredSources = sources
    requiredJobs = jobs
    let obsolete = shellRecords.keys.filter { requiredJobs[$0] == nil }
    var obsoleteJobs = obsolete.compactMap { shellRecords.removeValue(forKey: $0)?.job }
    for key in requiredJobs.keys.sorted() {
      guard let request = requiredJobs[key] else { continue }
      let cadence = cadences[key] ?? 0
      if shellRecords[key]?.command == request.command {
        if shellRecords[key]?.interval != cadence {
          shellRecords[key]?.interval = cadence
          shellRecords[key]?.schedule.reschedule(now: now, interval: cadence)
        }
        continue
      }
      let old = shellRecords.removeValue(forKey: key)
      shellRecords[key] = ShellRecord(
        command: request.command, interval: cadence, value: old?.value)
      if let job = old?.job { obsoleteJobs.append(job) }
    }
    if requiredJobs.isEmpty { schedule?.pendingJobPublish = nil }
    for name in Array(sourceRecords.keys) where !requiredSources.contains(name) {
      if let job = sourceRecords[name]?.job {
        sourceRecords[name]?.job = nil
        sourceRecords[name]?.schedule = StatusJobSchedule()
        obsoleteJobs.append(job)
      }
    }
    stopJobs(obsoleteJobs)
  }

  /// One clock deadline per interval an active clock-driven surface uses; a
  /// fired deadline re-arms from now, an unused one is dropped.
  private func armClocks(now: TimeInterval) {
    guard var schedule else { return }
    var intervals = Set<TimeInterval>()
    for (surface, interval) in activeSurfaces where surface.needsClock && interval > 0 {
      intervals.insert(interval)
    }
    schedule.clocks = schedule.clocks.filter { intervals.contains($0.key) }
    for interval in intervals where schedule.clocks[interval] == nil {
      schedule.clocks[interval] = now + max(1, interval)
    }
    self.schedule = schedule
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
        let interval = shellRecords[key]?.interval,
        shellRecords[key]?.schedule.begin(token: token, now: now, interval: interval) == true
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
            if let limit = definition.historyLength, Double(output.trimmed)?.isFinite == true {
              var history = self.sourceRecords[name]?.history ?? []
              history.append(output.trimmed)
              self.sourceRecords[name]?.history = Array(history.suffix(limit))
            }
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
      schedule?.pendingJobPublish = nil
      publishCurrentModel()
    } else {
      schedule?.pendingJobPublish = due
      armTimer()
    }
  }

  static let pollClientID = "core:status_bar"

  /// These wake-ups are not a fixed cadence but the earliest of the user's
  /// declared per-source intervals, cycle rotations, each surface's clock and
  /// pending output — so the controller re-registers its next deadline on the
  /// shared clock each time one lands, rather than owning a timer. It is armed
  /// only while a visible surface requires something.
  private func armTimer() {
    scheduler.unregister(Self.pollClientID)
    timerGeneration &+= 1
    let generation = timerGeneration
    guard var schedule else { return }
    schedule.nextWakeup = nil
    defer { self.schedule = schedule }
    var dates = requiredSources.compactMap { sourceRecords[$0]?.schedule.dueAt }
    dates += requiredJobs.keys.compactMap { shellRecords[$0]?.schedule.dueAt }
    dates += requiredJobs.keys.compactMap { key in
      shellRecords[key]?.value == nil ? shellRecords[key]?.schedule.startedAt.map { $0 + 2 } : nil
    }
    dates += requiredSources.compactMap { sourceRecords[$0]?.cycle }
      .filter(\.needsRotationTimer).map(\.nextRotationAt)
    dates += pluginCycles.values.filter(\.needsRotationTimer).map(\.nextRotationAt)
    dates += schedule.clocks.values
    if let pendingJobPublish = schedule.pendingJobPublish { dates.append(pendingJobPublish) }
    guard let next = dates.filter(\.isFinite).min() else { return }
    schedule.nextWakeup = next
    // The bar and unoccluded widgets are surfaces the user is looking at, so
    // the slack is tight; the generation check still discards a fire that a
    // newer plan superseded.
    scheduler.scheduleOnce(
      Self.pollClientID, afterMs: Int((max(0.001, next - clock()) * 1000).rounded()),
      priority: .high, on: queue
    ) { [weak self] in
      guard let self, self.timerGeneration == generation else { return }
      self.tick()
    }
  }

  /// Internal (not private) so the controller tests can fire a due deadline
  /// deterministically instead of waiting on the dispatch timer.
  func tick() {
    let now = clock()
    for key in requiredJobs.keys where shellRecords[key]?.value == nil {
      if let start = shellRecords[key]?.schedule.startedAt, now - start >= 2 {
        shellRecords[key]?.value = "<'\(key)' not ready>"
      }
    }
    if let clocks = schedule?.clocks { schedule?.clocks = clocks.filter { $0.value > now } }
    if let pendingJobPublish = schedule?.pendingJobPublish, pendingJobPublish <= now {
      schedule?.pendingJobPublish = nil
      lastJobPublish = now
    }
    for name in requiredSources { _ = sourceRecords[name]?.cycle?.advanceIfDue(now: now) }
    for key in Array(pluginCycles.keys) {
      if pluginCycles[key]?.advanceIfDue(now: now) == true {
        FlashLog.trace("[statusbar] carousel_advance key=\(key)")
      }
    }
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

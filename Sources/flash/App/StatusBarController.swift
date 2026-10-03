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
  /// Uptime seconds: every deadline is measured on it.
  private let clock: () -> TimeInterval
  /// The wall clock the surfaces show; clock boundaries are read from it.
  private let wallClock: () -> Date
  private var clockObservers: [NSObjectProtocol] = []
  private let makeJob: StatusCommandFactory
  private var template: FlashStatusBarTemplate
  private var popupTemplates: [String: FlashStatusBarTemplate]
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
    /// The `#()` output this surface last evaluated with, by raw command: it
    /// keeps showing its own previous output while a changed expansion runs,
    /// as tmux keeps a client's job output until the new command answers.
    var jobValues: [String: String] = [:]
    var sources: Set<String> = []
    /// The plugin segments it read, keyed `<plugin>.<segment>` like
    /// `pluginCycles`: only a carousel some active surface reads rotates on a
    /// wake-up.
    var pluginSegments: Set<String> = []
    /// The finest time unit this surface shows; its clock ticks on that
    /// unit's boundaries. Nil: it shows no time.
    var clock: StatusFormatTimeResolution?

    static let pluginValuePrefix = "flash.plugin."

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
      jobValues = jobs.reduce(into: [:]) { values, job in
        if let value = native.jobs[job.rawCommand] { values[job.rawCommand] = value }
      }
      (sources, clock) = FlashStatusBarTemplateEngine.requirements(of: dependencies)
      pluginSegments = Set(
        dependencies.values.lazy.filter { $0.hasPrefix(Self.pluginValuePrefix) }
          .map { String($0.dropFirst(Self.pluginValuePrefix.count)) })
    }
  }

  /// The registry key of a `#()` job: its raw text and its expansion. Surfaces
  /// that expand the same text identically share one process; a different
  /// expansion (another widget name, local option) is its own job.
  private static func shellKey(_ job: StatusFormatJobRequest) -> String {
    job.rawCommand + "\u{0}" + job.command
  }

  /// The job output `surface` evaluates with: the current output of each job
  /// it required, over what it showed last.
  private func jobValues(for surface: SurfaceState?) -> [String: String] {
    guard let surface else { return [:] }
    var values = surface.jobValues
    for job in surface.jobs {
      if let value = shellRecords[Self.shellKey(job)]?.value { values[job.rawCommand] = value }
    }
    return values
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
  /// Plugin segments (`<plugin>.<segment>`) an active surface reads.
  private var requiredPluginSegments: Set<String> = []
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
    sources: [String: FlashStatusBarSourceDefinition] = [:],
    terminalPopupNames: Set<String> = [],
    refreshIntervalSeconds: TimeInterval = 5,
    pluginStatusesProvider: @escaping () -> [PluginStatusBarInfo] = { [] },
    scheduler: PollScheduler = .shared,
    queue: DispatchQueue = DispatchQueue(label: "flash.status_bar", qos: .userInitiated),
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    wallClock: @escaping () -> Date = Date.init,
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
    self.wallClock = wallClock
    self.makeJob = makeJob
    self.overlay = overlay
    self.template = template
    self.popupTemplates = popupTemplates
    self.sources = sources
    self.terminalPopupNames = terminalPopupNames
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.pluginStatusesProvider = pluginStatusesProvider
    observeClockChanges()
  }

  deinit {
    for observer in clockObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  /// The clock deadline is a wall-clock boundary measured in uptime, so
  /// anything that moves the wall clock against uptime — the clock being
  /// set, a time-zone change, a sleep — or a new day re-plans it at once.
  private func observeClockChanges() {
    let center = NotificationCenter.default
    let changes: [(Notification.Name, String)] = [
      (.NSSystemClockDidChange, "clock_set"),
      (.NSSystemTimeZoneDidChange, "time_zone"),
      (.NSCalendarDayChanged, "day_changed"),
    ]
    for (name, reason) in changes {
      clockObservers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          if name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
          self?.clockDidChange(reason: reason)
        })
    }
    clockObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
      ) { [weak self] _ in self?.clockDidChange(reason: "wake") })
  }

  /// Re-read the time and re-plan the next clock boundary from the wall
  /// clock as it now reads. Nothing is scheduled while stopped.
  func clockDidChange(reason: String) {
    queue.async { [weak self] in
      guard let self, self.schedule != nil else { return }
      FlashLog.debug("[statusbar] clock_changed reason=\(reason)")
      self.publishCurrentModel()
    }
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
        // The job records re-plan against their new cadence when reconciled.
        self.refreshIntervalSeconds = refreshIntervalSeconds
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
    // The shared context is built once; each surface layers its own job
    // output on it.
    let native = FlashStatusBarTemplateEngine.formatContext(context, dynamicValues: values)
    if bar != nil { publishBar(native: native, context: context) }
    for name in widgets.keys.sorted() where widgets[name]?.visible == true {
      publishWidget(name, native: native)
    }
    if requirementsChanged { reconcileRequirements(now: now) }
    guard schedule != nil else { return }
    runDueJobs(now: now)
    armTimer()
  }

  private func publishBar(native shared: StatusFormatContext, context: FlashStatusBarContext) {
    var native = shared
    native.jobs = jobValues(for: bar)
    // Nothing the template or its popups read has changed since the last
    // evaluation: the bar keeps what it required.
    guard bar?.isCurrent(native) == false else { return }
    let result = FlashStatusBarTemplateEngine.evaluate(
      template: template, popupTemplates: popupTemplates, context: context,
      terminalPopupNames: terminalPopupNames, nativeContext: native,
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
    native.jobs = jobValues(for: widgets[name]?.surface)
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
  /// each one's `#()` jobs run at. Occluded widgets are absent.
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
    var pluginSegments = Set<String>()
    var jobs: [String: StatusFormatJobRequest] = [:]
    var cadences: [String: TimeInterval] = [:]
    for (surface, interval) in activeSurfaces {
      sources.formUnion(surface.sources)
      pluginSegments.formUnion(surface.pluginSegments)
      let cadence = Self.cadence(interval)
      for job in surface.jobs {
        let key = Self.shellKey(job)
        if jobs[key] == nil { jobs[key] = job }
        let current = cadences[key]
        cadences[key] =
          current.map { $0 == 0 ? cadence : (cadence == 0 ? $0 : min($0, cadence)) } ?? cadence
      }
    }
    requiredSources = sources
    requiredPluginSegments = pluginSegments
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

  /// The next boundary of the finest time unit any active surface shows, as
  /// an uptime deadline. It is recomputed from the wall clock at every plan,
  /// so it never holds a stale boundary; nil when no active surface shows
  /// time. The refresh interval plays no part: a minute is read on the
  /// minute, not up to one interval late.
  private func clockDeadline(now: TimeInterval) -> TimeInterval? {
    guard let resolution = activeSurfaces.compactMap(\.surface.clock).max() else { return nil }
    let wall = wallClock()
    let boundary = Self.nextClockBoundary(after: wall, resolution: resolution)
    return now + max(0, boundary.timeIntervalSince(wall))
  }

  /// Seconds and minutes are whole units of Unix time in every current time
  /// zone; a day ends at the local midnight or the next daylight-saving
  /// transition, whichever comes first.
  static func nextClockBoundary(
    after date: Date, resolution: StatusFormatTimeResolution, calendar: Calendar = .current
  ) -> Date {
    let seconds = date.timeIntervalSince1970
    switch resolution {
    case .second:
      return Date(timeIntervalSince1970: seconds.rounded(.down) + 1)
    case .minute:
      return Date(timeIntervalSince1970: (seconds / 60).rounded(.down) * 60 + 60)
    case .day:
      // The calendar shows the UTC offset, so a daylight-saving transition
      // inside the day is a boundary too.
      guard let midnight = calendar.dateInterval(of: .day, for: date)?.end else {
        return nextClockBoundary(after: date, resolution: .minute)
      }
      return min(
        midnight, calendar.timeZone.nextDaylightSavingTimeTransition(after: date) ?? midnight)
    }
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
    let key = Self.shellKey(request)
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
  /// declared per-source intervals, cycle rotations, the next boundary of the
  /// finest time unit shown and pending output — so the controller re-registers its next deadline on the
  /// shared clock each time one lands, rather than owning a timer. It is armed
  /// only while a visible surface requires something.
  ///
  /// Each deadline carries the slack its kind tolerates. A clock boundary and
  /// a carousel rotation are the visible change itself — the second has to
  /// turn on the second — so they are `.high`. A job or source re-run, the
  /// placeholder for a job that has not answered and the throttled publish of
  /// output that already arrived are `.normal`: their output lands whenever
  /// the command finishes, so a tenth of a second is invisible, and the looser
  /// slack lets them coalesce with the rest of the app's wake-ups.
  private func armTimer() {
    scheduler.unregister(Self.pollClientID)
    timerGeneration &+= 1
    let generation = timerGeneration
    guard var schedule else { return }
    schedule.nextWakeup = nil
    defer { self.schedule = schedule }
    var deadlines: [Deadline] = []
    func add(_ dates: [TimeInterval], _ priority: PollScheduler.Priority) {
      deadlines += dates.map { Deadline(at: $0, priority: priority) }
    }
    add(requiredSources.compactMap { sourceRecords[$0]?.schedule.dueAt }, .normal)
    add(requiredJobs.keys.compactMap { shellRecords[$0]?.schedule.dueAt }, .normal)
    add(
      requiredJobs.keys.compactMap { key in
        shellRecords[key]?.value == nil ? shellRecords[key]?.schedule.startedAt.map { $0 + 2 } : nil
      }, .normal)
    add(
      requiredSources.compactMap { sourceRecords[$0]?.cycle }
        .filter(\.needsRotationTimer).map(\.nextRotationAt), .high)
    // A carousel no active surface reads keeps its rotation state for when
    // one shows it again, but wakes nobody meanwhile.
    add(
      pluginCycles.filter { requiredPluginSegments.contains($0.key) }.values
        .filter(\.needsRotationTimer).map(\.nextRotationAt), .high)
    if let clockDeadline = clockDeadline(now: clock()) { add([clockDeadline], .high) }
    if let pendingJobPublish = schedule.pendingJobPublish { add([pendingJobPublish], .normal) }
    guard let wakeup = Self.nextWakeup(deadlines) else { return }
    schedule.nextWakeup = wakeup.at
    // The generation check still discards a fire that a newer plan
    // superseded.
    scheduler.scheduleOnce(
      Self.pollClientID, afterMs: Int((max(0.001, wakeup.at - clock()) * 1000).rounded()),
      priority: wakeup.priority, on: queue
    ) { [weak self] in
      guard let self, self.timerGeneration == generation else { return }
      self.tick()
    }
  }

  struct Deadline: Equatable {
    var at: TimeInterval
    var priority: PollScheduler.Priority
  }

  /// The earliest deadline, at the tightest priority among the deadlines its
  /// wake-up will serve: every one due before that wake-up's slack runs out.
  /// A job re-run landing just ahead of a clock boundary therefore cannot
  /// drag the boundary late, while a lone job keeps its looser slack.
  static func nextWakeup(_ deadlines: [Deadline]) -> Deadline? {
    let finite = deadlines.filter(\.at.isFinite)
    guard let earliest = finite.min(by: { $0.at < $1.at }) else { return nil }
    var priority = earliest.priority
    while true {
      let slack = Double(priority.leewayMs) / 1000
      let tightest =
        finite.filter { $0.at <= earliest.at + slack }.map(\.priority).min() ?? priority
      guard tightest < priority else { break }
      priority = tightest
    }
    return Deadline(at: earliest.at, priority: priority)
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

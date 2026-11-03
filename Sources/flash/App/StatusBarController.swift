import AppKit
import FlashCore
import FlashTerminal
import Foundation

/// Evaluates every status surface — the bar, each desktop widget and each
/// monitor — over one source/job registry and one `PollScheduler` deadline.
/// Each surface is memoized on the inputs it last read, so a publish
/// re-evaluates only the surfaces whose inputs changed; a skipped surface
/// keeps contributing the sources, jobs and clock its last evaluation
/// required.
final class FlashStatusBarController {
  private weak var overlay: OverlayPanel?
  private let queue: DispatchQueue
  /// Uptime seconds: every deadline is measured on it.
  private let clock: () -> TimeInterval
  /// The wall clock the surfaces show; clock boundaries are read from it.
  private let wallClock: () -> Date
  /// The system time zone, read for every render: the clock, the calendar
  /// and the next meeting's times all follow it, and a time-zone change
  /// (`clockDidChange`) re-renders them.
  private let systemTimeZone: () -> TimeZone
  private var clockObservers: [NSObjectProtocol] = []
  private let makeJob: StatusCommandFactory
  /// The login environment jobs inherit; none starts before it resolves.
  private let environment: FlashProcessEnvironment
  /// Whether a publish is already owed once the environment resolves.
  private var environmentWakeArmed = false
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
    /// The process values it read: only those are sampled.
    var processValues: Set<ProcessStatusValue> = []
    /// The kernel values it read: only those are read, on its cadence.
    var hostValues: Set<HostStatusValue> = []
    /// The received-metric values it read (`#{flash.otel…}`): only their
    /// metrics wake it.
    var telemetryKeys: Set<String> = []
    /// It read a `#{flash.calendar.next…}` value: only then are events read.
    var readsCalendar = false
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
      processValues = Set(dependencies.values.compactMap(ProcessStatusValue.init(rawValue:)))
      hostValues = Set(dependencies.values.compactMap(HostStatusValue.init(rawValue:)))
      telemetryKeys = dependencies.values.filter(TelemetryQuery.isTelemetryKey)
      readsCalendar = dependencies.values.contains(where: CalendarStatusValue.isCalendarValue)
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

  /// One `[monitors.<name>]`: a surface nobody looks at, so it never ticks
  /// the clock and what only it requires runs at `.low`. It is evaluated
  /// whenever a value it read changed, alerting through its tracker.
  private struct MonitorRecord {
    var spec: StatusMonitorSpec
    var surface = SurfaceState()
    var tracker: MonitorTracker
    var snapshot: MonitorSnapshot

    init(name: String, spec: StatusMonitorSpec, sinceMs: Int64) {
      self.spec = spec
      tracker = MonitorTracker(sinceMs: sinceMs)
      snapshot = MonitorSnapshot(id: name, spec: spec, tracker: tracker)
    }
  }

  /// A surface whose requirements count: `foreground` is someone looking
  /// (the bar, a visible widget); a monitor is not, so what only monitors
  /// require wakes at `.low` and the clock ignores them.
  private struct ActiveSurface {
    var surface: SurfaceState
    var interval: TimeInterval
    var foreground: Bool
  }

  /// How a required kernel value is read: at the fastest cadence of the
  /// surfaces reading it (0: once), at `.normal` while a foreground surface
  /// shows it and `.low` for monitors alone.
  private struct HostRequirement: Equatable {
    var cadence: TimeInterval
    var priority: PollScheduler.Priority
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
  /// Process values an active surface of the running controller reads: what
  /// `processValuesObserver` was last told to sample.
  private var requiredProcessValues: Set<ProcessStatusValue> = []
  /// The sampled process values, kept only while required.
  private var processValues: [ProcessStatusValue: String] = [:]
  private let processValuesObserver: (Set<ProcessStatusValue>) -> Void
  private var requiredJobs: [String: StatusFormatJobRequest] = [:]
  /// The jobs and sources a foreground surface requires; the rest are a
  /// monitor's alone and re-run at `.low`.
  private var foregroundJobs: Set<String> = []
  private var foregroundSources: Set<String> = []
  /// Kernel values an active surface of the running controller reads.
  private var requiredHostValues: [HostStatusValue: HostRequirement] = [:]
  /// The last reading of each required kernel value and its uptime; nil text
  /// when the kernel did not answer.
  private var hostSamples: [HostStatusValue: (text: String?, at: TimeInterval)] = [:]
  private let readHostValue: (HostStatusValue) -> String?
  /// The OTLP receiver's metrics, read for `#{flash.otel…}` values.
  private let telemetry: TelemetryStore?
  /// The `#{flash.otel…}` keys an active surface of the running controller
  /// reads: what the store was last told to observe.
  private var requiredTelemetryKeys: Set<String> = []
  /// Their values as last read from the store, and the keys that reading
  /// covered (nil: none yet).
  private var telemetryValues: [String: String] = [:]
  private var telemetryReadKeys: Set<String>?
  /// A metric an active surface reads changed since the last reading.
  private var telemetryDirty = false
  /// Whether an active surface of the running controller reads a
  /// `#{flash.calendar.next…}` value, as the priority its changes wake at:
  /// `.high` while the bar or a visible widget shows one, `.low` for
  /// monitors alone. Nil: none does, and no event is read.
  private var calendarPriority: PollScheduler.Priority?
  /// The events `CalendarEvents` last published, kept only while required.
  private var calendarAgenda: CalendarAgenda?
  /// Told whether events are required, each time that changes.
  private let calendarObserver: (Bool) -> Void
  /// The bar's surface; nil while `[statusbar] enabled` is off.
  private var bar: SurfaceState? = SurfaceState()
  private var widgets: [String: WidgetState] = [:]
  private var monitors: [String: MonitorRecord] = [:]
  private let monitorSink: (([MonitorSnapshot]) -> Void)?
  private let monitorAlertSink: ((StatusAlert) -> Void)?
  /// A value monitor with a `run` fired: on a rise, or on any change of a
  /// threshold-free monitor's value.
  private let monitorFireSink: ((MonitorFire) -> Void)?
  /// A monitor with `notify = true` rose: its name and the alert it would
  /// show, for a macOS notification.
  private let monitorNotifySink: ((String, StatusAlert) -> Void)?
  /// Any value monitor rose into warning or error: its name and the level,
  /// for `core:monitor.triggered`.
  private let monitorTriggerSink: ((String, MonitorLevel) -> Void)?
  /// Every monitor's last published snapshot, sorted by name, as handed to
  /// `monitorSink`.
  private(set) var lastPublishedMonitors: [MonitorSnapshot] = []
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
  private var focusedAppName = ""
  private var focusedAppBundleID = ""
  private var modeLabel = "INSERT"
  private var secureInput = false
  private var caffeinate = false
  private var workspace = ""
  private var workspaces = ""
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
    timeZone: @escaping () -> TimeZone = { TimeZone.current },
    makeJob: @escaping StatusCommandFactory = { invocation, queue, onLine, onCompletion in
      try StatusFormatCommandJob(
        queue: queue, argv: invocation.argv,
        environment: invocation.environment, workingDirectory: invocation.workingDirectory,
        timeoutSeconds: invocation.timeoutSeconds, onLine: onLine, onCompletion: onCompletion)
    },
    environment: FlashProcessEnvironment = .shared,
    widgetSink: ((String, [StatusFormatDocument]) -> Void)? = nil,
    processValuesObserver: @escaping (Set<ProcessStatusValue>) -> Void = { _ in },
    monitorSink: (([MonitorSnapshot]) -> Void)? = nil,
    monitorAlertSink: ((StatusAlert) -> Void)? = nil,
    monitorFireSink: ((MonitorFire) -> Void)? = nil,
    monitorNotifySink: ((String, StatusAlert) -> Void)? = nil,
    monitorTriggerSink: ((String, MonitorLevel) -> Void)? = nil,
    readHostValue: @escaping (HostStatusValue) -> String? = { $0.read() },
    telemetry: TelemetryStore? = nil,
    calendarObserver: @escaping (Bool) -> Void = { _ in }
  ) {
    self.telemetry = telemetry
    self.calendarObserver = calendarObserver
    self.widgetSink = widgetSink
    self.monitorSink = monitorSink
    self.monitorAlertSink = monitorAlertSink
    self.monitorFireSink = monitorFireSink
    self.monitorNotifySink = monitorNotifySink
    self.monitorTriggerSink = monitorTriggerSink
    self.readHostValue = readHostValue
    self.processValuesObserver = processValuesObserver
    self.environment = environment
    self.scheduler = scheduler
    self.queue = queue
    self.clock = clock
    self.wallClock = wallClock
    self.systemTimeZone = timeZone
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
        for name in self.monitors.keys { self.monitors[name]?.surface.memo = nil }
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
    hostSamples.removeAll()
    processValues.removeAll()
    if !requiredTelemetryKeys.isEmpty { telemetry?.observe(keys: []) }
    requiredTelemetryKeys = []
    telemetryValues = [:]
    telemetryReadKeys = nil
    if !requiredProcessValues.isEmpty {
      requiredProcessValues = []
      processValuesObserver([])
    }
    calendarAgenda = nil
    if calendarPriority != nil {
      calendarPriority = nil
      calendarObserver(false)
    }
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

  /// Every `[monitors.<name>]`. A disabled one is listed, never evaluated. A
  /// monitor keeps its state across a change of thresholds or message; a
  /// new value expression or re-enabling starts it afresh.
  func updateMonitors(_ specs: [String: StatusMonitorSpec]) {
    queue.async { [weak self] in
      guard let self else { return }
      let sinceMs = self.wallMilliseconds()
      var monitors: [String: MonitorRecord] = [:]
      for (name, spec) in specs {
        guard var record = self.monitors[name], record.spec.value == spec.value,
          record.spec.enabled == spec.enabled
        else {
          monitors[name] = MonitorRecord(name: name, spec: spec, sinceMs: sinceMs)
          continue
        }
        if record.spec != spec {
          record.spec = spec
          record.surface.memo = nil
          record.snapshot = MonitorSnapshot(id: name, spec: spec, tracker: record.tracker)
        }
        monitors[name] = record
      }
      for name in self.monitors.keys where specs[name] == nil {
        self.surfaceEvaluations.removeValue(forKey: Self.monitorSurfaceName(name))
      }
      self.monitors = monitors
      self.requirementsChanged = true
      self.publishCurrentModel()
    }
  }

  static func monitorSurfaceName(_ name: String) -> String { "monitors.\(name)" }

  private func wallMilliseconds() -> Int64 {
    Int64((wallClock().timeIntervalSince1970 * 1000).rounded())
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
      guard let self, self.modeLabel != label else { return }
      self.modeLabel = label
      self.publishCurrentModel()
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

  /// `#{flash.workspace}` and `#{flash.workspaces}`: the tiling workspaces,
  /// empty while `[tiling]` is off.
  func updateWorkspaces(focused: String, listed: [String]) {
    let joined = listed.joined(separator: " ")
    queue.async { [weak self] in
      guard let self, self.workspace != focused || self.workspaces != joined else { return }
      self.workspace = focused
      self.workspaces = joined
      self.publishCurrentModel()
    }
  }

  /// `#{flash.caffeinate}`: "on" while `caffeinate on` holds the Mac awake.
  func updateCaffeinate(_ enabled: Bool) {
    queue.async { [weak self] in
      guard let self, self.caffeinate != enabled else { return }
      self.caffeinate = enabled
      self.publishCurrentModel()
    }
  }

  func updateFocusedApplication(_ app: NSRunningApplication?) {
    let name = app?.localizedName ?? ""
    let bundle = app?.bundleIdentifier ?? ""
    FlashLog.trace("[statusbar] focus bundle=\(bundle)")
    queue.async { [weak self] in
      guard let self else { return }
      self.focusedAppName = name
      self.focusedAppBundleID = bundle
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

  /// `status set` / `status clear`: `value` lands in the declared source
  /// `name` as a run's output would (nil clears it), and every surface showing
  /// it re-evaluates. `completion` runs on the main thread with whether the
  /// source exists.
  func push(source name: String, value: String?, completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self, let definition = self.sources[name] else {
        return DispatchQueue.main.async { completion(false) }
      }
      if self.sourceRecords[name] == nil {
        self.sourceRecords[name] = SourceRecord(definition: definition)
      }
      if let value {
        self.ingest(value, source: name, definition: definition)
      } else {
        self.sourceRecords[name]?.value = nil
        self.sourceRecords[name]?.cycle = nil
      }
      FlashLog.debug("[statusbar] push source=\(name) cleared=\(value == nil)")
      self.publishCurrentModel()
      DispatchQueue.main.async { completion(true) }
    }
  }

  /// `status refresh --name=<source>`: run a shown source now, as an
  /// i3blocks signal or a SketchyBar trigger does, instead of waiting for its
  /// interval. `completion` runs on main with why it cannot, or nil.
  func refresh(source name: String, completion: @escaping (String?) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      let refusal = StatusRefresh.refusal(
        source: name, definition: self.sources[name],
        shown: self.requiredSources.contains(name))
      if refusal == nil {
        self.sourceRecords[name]?.schedule.expedite(now: self.clock())
        FlashLog.debug("[statusbar] refresh source=\(name)")
        self.publishCurrentModel()
      }
      DispatchQueue.main.async { completion(refusal) }
    }
  }

  /// A received metric a surface or monitor reads changed, or one of its
  /// series went quiet: read the values again and re-evaluate what read them.
  func telemetryDidChange() {
    queue.async { [weak self] in
      guard let self, self.schedule != nil else { return }
      self.telemetryDirty = true
      self.publishCurrentModel()
    }
  }

  /// The events `#{flash.calendar.next…}` values are made of, as
  /// `CalendarEvents` read them; nil: none to show. Ignored while no active
  /// surface reads a calendar value.
  func updateCalendarAgenda(_ agenda: CalendarAgenda?) {
    queue.async { [weak self] in
      guard let self else { return }
      let agenda = self.calendarPriority == nil ? nil : agenda
      guard agenda != self.calendarAgenda else { return }
      self.calendarAgenda = agenda
      self.publishCurrentModel()
    }
  }

  /// Sampled process values; nil clears one. A value no active surface
  /// requires any more is dropped rather than kept stale.
  func updateProcessValues(_ values: [ProcessStatusValue: String?]) {
    queue.async { [weak self] in
      guard let self else { return }
      var changed = false
      for (value, text) in values {
        let next = text.flatMap { self.requiredProcessValues.contains(value) ? $0 : nil }
        if self.processValues[value] != next {
          self.processValues[value] = next
          changed = true
        }
      }
      if changed { self.publishCurrentModel() }
    }
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
            key: StatusCycleKey.plugin(info.id, segment: name), prefix: prefix,
            line: pluginCycles[key]?.visibleLine ?? "",
            backward: pluginCycles[key]?.arrivedBackward ?? false))
      }
      return info
    }
    if pluginCycles.count != active.count {
      pluginCycles = pluginCycles.filter { active.contains($0.key) }
    }
    return statuses
  }

  /// The calendar every time value of one render is read in.
  private var localCalendar: Calendar {
    var calendar = Calendar.current
    calendar.timeZone = systemTimeZone()
    return calendar
  }

  private func publishCurrentModel() {
    let now = clock()
    sampleHostValues(now: now)
    let calendar = localCalendar
    var context = FlashStatusBarContext(
      focusedAppName: focusedAppName, focusedAppBundleID: focusedAppBundleID,
      modeLabel: modeLabel, secureInput: secureInput, caffeinate: caffeinate,
      now: wallClock(), calendar: calendar,
      pluginStatuses: resolvedPluginStatuses(now: now))
    context.workspace = workspace
    context.workspaces = workspaces
    var values = sourceRecords.compactMapValues(\.value)
    for (value, text) in processValues { values[value.rawValue] = text }
    for (value, sample) in hostSamples {
      if let text = sample.text { values[value.rawValue] = text }
    }
    if let telemetry, telemetryDirty || telemetryReadKeys != requiredTelemetryKeys {
      telemetryValues = telemetry.values(for: requiredTelemetryKeys)
      telemetryReadKeys = requiredTelemetryKeys
      telemetryDirty = false
    }
    for (key, text) in telemetryValues { values[key] = text }
    // The next event as of now: a countdown is read at the time it shows.
    if let calendarAgenda {
      for (key, text) in CalendarNext.values(
        calendarAgenda, at: wallClock(), timeZone: calendar.timeZone)
      {
        values[key] = text
      }
    }
    for (name, record) in sourceRecords {
      if let cycle = record.cycle {
        values[name] = StatusCycleKey.wrap(
          cycle.visibleLine, key: StatusCycleKey.source(name), backward: cycle.arrivedBackward)
      }
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
    // Monitors alert, so they read only while the controller runs.
    if schedule != nil {
      for name in monitors.keys.sorted() where monitors[name]?.spec.enabled == true {
        evaluateMonitor(name, native: native, now: now)
      }
    }
    publishMonitors()
    if requirementsChanged { reconcileRequirements(now: now) }
    guard schedule != nil else { return }
    // A surface just started reading a kernel value: read it and evaluate
    // again now rather than show it unknown until the next wake-up. Every
    // required value then has a reading, so this recurses at most once per
    // newly read value.
    if requiredHostValues.keys.contains(where: { hostSamples[$0] == nil }) {
      publishCurrentModel()
      return
    }
    // Likewise for a received metric a surface just started reading.
    if telemetry != nil, telemetryReadKeys != requiredTelemetryKeys {
      publishCurrentModel()
      return
    }
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

  /// Evaluate one monitor's value, message and detail when an input it read
  /// changed, move its tracker and raise the alert a rise asks for.
  private func evaluateMonitor(
    _ name: String, native shared: StatusFormatContext, now: TimeInterval
  ) {
    guard let record = monitors[name] else { return }
    var native = shared
    native.jobs = jobValues(for: record.surface)
    guard !record.surface.isCurrent(native) else { return }
    let value = FlashStatusBarTemplateEngine.evaluateDocument(record.spec.value, native: native)
    var dependencies = value.dependencies
    var jobs = value.jobs
    let display = MonitorText.plainText(value.runs)
    let number = MonitorText.leadingNumber(display)
    let level = record.spec.level(of: number)
    func expand(_ template: FlashStatusBarTemplate?) -> String {
      guard let template else { return "" }
      let expanded = FlashStatusBarTemplateEngine.evaluateDocument(template, native: native)
      dependencies.formUnion(expanded.dependencies)
      jobs += expanded.jobs
      return MonitorText.plainText(expanded.runs)
    }
    let authored = expand(record.spec.message)
    let message =
      authored.isEmpty ? record.spec.derivedMessage(name: name, level: level) : authored
    let detail = expand(record.spec.detail)
    var tracker = record.tracker
    let previous = tracker.level
    let previousDisplay = record.snapshot.display
    let alert = tracker.observe(level, now: now, wallMs: wallMilliseconds())
    if let number { FlashTelemetry.record(.monitorValue, number, ["monitor": name]) }
    FlashTelemetry.record(.monitorLevel, Self.telemetryLevel(level), ["monitor": name])
    var snapshot = MonitorSnapshot(id: name, spec: record.spec, tracker: tracker)
    snapshot.value = number
    snapshot.display = display
    snapshot.message = message
    snapshot.detail = detail
    monitors[name]?.surface.record(dependencies, jobs: jobs, native: native)
    monitors[name]?.tracker = tracker
    monitors[name]?.snapshot = snapshot
    surfaceEvaluations[Self.monitorSurfaceName(name), default: 0] += 1
    requirementsChanged = true
    if previous != level {
      FlashLog.debug(
        "[monitors] state name=\(name) from=\(previous.rawValue) to=\(level.rawValue) "
          + "value=\(number.map { MonitorText.number($0) } ?? "none")")
    }
    // A change monitor fires from its second known value on: the first is
    // where it starts.
    if record.spec.fires == .onChange, !previousDisplay.isEmpty, previousDisplay != display,
      !display.isEmpty, let monitorFireSink
    {
      let fire = MonitorFire(monitor: name, display: display, level: level)
      FlashLog.info("[monitors] changed name=\(name) display=\(display)")
      DispatchQueue.main.async { monitorFireSink(fire) }
    }
    guard let alert else { return }
    if let monitorTriggerSink {
      DispatchQueue.main.async { monitorTriggerSink(name, alert) }
    }
    if record.spec.fires == .onRise, let monitorFireSink {
      let fire = MonitorFire(monitor: name, display: display, level: alert)
      DispatchQueue.main.async { monitorFireSink(fire) }
    }
    guard record.spec.alerts || record.spec.notifies else { return }
    // The detail rides on the alert's record, an exported log attribute;
    // the monitor gauges keep `monitor` alone, so a changing detail never
    // splits their series.
    var fields = ["monitor": name, "level": alert.rawValue]
    if !detail.isEmpty { fields["detail"] = detail }
    FlashLog.info(
      "[monitors] alert name=\(name) level=\(alert.rawValue) display=\(display) detail=\(detail)",
      fields: fields)
    let shown = snapshot.alert(at: alert)
    if record.spec.alerts, let monitorAlertSink {
      DispatchQueue.main.async { monitorAlertSink(shown) }
    }
    if record.spec.notifies, let monitorNotifySink {
      DispatchQueue.main.async { monitorNotifySink(name, shown) }
    }
  }

  /// A monitor state as `flash.monitor.level` exports it.
  static func telemetryLevel(_ level: MonitorLevel) -> Double {
    switch level {
    case .unknown: return -1
    case .ok: return 0
    case .warning: return 1
    case .error: return 2
    }
  }

  /// Hand every monitor's snapshot to the sink when any of them changed.
  private func publishMonitors() {
    let snapshots = monitors.keys.sorted().compactMap { monitors[$0]?.snapshot }
    guard snapshots != lastPublishedMonitors else { return }
    lastPublishedMonitors = snapshots
    if let monitorSink { DispatchQueue.main.async { monitorSink(snapshots) } }
  }

  /// Read each required kernel value that is due: never read, or older than
  /// its cadence. Only a running controller reads.
  private func sampleHostValues(now: TimeInterval) {
    guard schedule != nil else { return }
    for (value, requirement) in requiredHostValues {
      if let sample = hostSamples[value],
        requirement.cadence == 0 || now < sample.at + requirement.cadence
      {
        continue
      }
      hostSamples[value] = (readHostValue(value), now)
    }
  }

  /// The surfaces that require anything right now, with the refresh interval
  /// each one's `#()` jobs run at. Occluded widgets and disabled monitors
  /// are absent.
  private var activeSurfaces: [ActiveSurface] {
    var surfaces =
      bar.map { [ActiveSurface(surface: $0, interval: refreshIntervalSeconds, foreground: true)] }
      ?? []
    for name in widgets.keys.sorted() {
      guard let widget = widgets[name], widget.visible else { continue }
      surfaces.append(
        ActiveSurface(
          surface: widget.surface,
          interval: widget.spec.intervalSeconds > 0
            ? widget.spec.intervalSeconds : refreshIntervalSeconds,
          foreground: true))
    }
    for name in monitors.keys.sorted() {
      guard let monitor = monitors[name], monitor.spec.enabled else { continue }
      surfaces.append(
        ActiveSurface(
          surface: monitor.surface, interval: monitor.spec.intervalSeconds, foreground: false))
    }
    return surfaces
  }

  private static func cadence(_ interval: TimeInterval) -> TimeInterval {
    interval > 0 ? max(1, interval) : 0
  }

  /// The faster of two cadences, where 0 (run once) yields to any other.
  private static func fastest(_ current: TimeInterval?, _ cadence: TimeInterval) -> TimeInterval {
    current.map { $0 == 0 ? cadence : (cadence == 0 ? $0 : min($0, cadence)) } ?? cadence
  }

  /// Point the registry at the union of what the active surfaces require:
  /// reap what none requires any more, and re-plan a job whose cadence (the
  /// fastest of the surfaces showing it) changed.
  private func reconcileRequirements(now: TimeInterval) {
    requirementsChanged = false
    var sources = Set<String>()
    var pluginSegments = Set<String>()
    var processValues = Set<ProcessStatusValue>()
    var telemetryKeys = Set<String>()
    var calendar: PollScheduler.Priority?
    var hostValues: [HostStatusValue: HostRequirement] = [:]
    var jobs: [String: StatusFormatJobRequest] = [:]
    var cadences: [String: TimeInterval] = [:]
    var foregroundJobs = Set<String>()
    var foregroundSources = Set<String>()
    for active in activeSurfaces {
      let surface = active.surface
      sources.formUnion(surface.sources)
      pluginSegments.formUnion(surface.pluginSegments)
      processValues.formUnion(surface.processValues)
      telemetryKeys.formUnion(surface.telemetryKeys)
      if surface.readsCalendar {
        calendar = active.foreground ? .high : calendar ?? .low
      }
      let cadence = Self.cadence(active.interval)
      if active.foreground { foregroundSources.formUnion(surface.sources) }
      for value in surface.hostValues {
        let current = hostValues[value]
        hostValues[value] = HostRequirement(
          cadence: Self.fastest(current?.cadence, cadence),
          priority: active.foreground || current?.priority == .normal ? .normal : .low)
      }
      for job in surface.jobs {
        let key = Self.shellKey(job)
        if jobs[key] == nil { jobs[key] = job }
        cadences[key] = Self.fastest(cadences[key], cadence)
        if active.foreground { foregroundJobs.insert(key) }
      }
    }
    requiredSources = sources
    self.foregroundSources = foregroundSources
    self.foregroundJobs = foregroundJobs
    requiredPluginSegments = pluginSegments
    // Reading the kernel is a running controller's, like sampling.
    requiredHostValues = schedule == nil ? [:] : hostValues
    hostSamples = hostSamples.filter { requiredHostValues[$0.key] != nil }
    // The store follows the metrics a running controller's surfaces read,
    // so only those wake it.
    if schedule == nil { telemetryKeys = [] }
    if telemetryKeys != requiredTelemetryKeys {
      requiredTelemetryKeys = telemetryKeys
      telemetry?.observe(keys: telemetryKeys)
    }
    // Events are read for a running controller's surfaces only.
    if schedule == nil { calendar = nil }
    if (calendar == nil) != (calendarPriority == nil) {
      if calendar == nil { calendarAgenda = nil }
      calendarObserver(calendar != nil)
    }
    calendarPriority = calendar
    // Sampling is a running controller's: a stopped one reads nothing.
    if schedule == nil { processValues = [] }
    if processValues != requiredProcessValues {
      requiredProcessValues = processValues
      self.processValues = self.processValues.filter { processValues.contains($0.key) }
      processValuesObserver(processValues)
    }
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
    guard
      let resolution = activeSurfaces.filter(\.foreground).compactMap(\.surface.clock).max()
    else { return nil }
    let wall = wallClock()
    let boundary = Self.nextClockBoundary(
      after: wall, resolution: resolution, calendar: localCalendar)
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
    // A job inherits the environment in effect when it spawns. Until the
    // login shell has resolved the bar renders without jobs, and publishes
    // once more the moment it has, which starts every job that is due.
    guard environment.phase != .resolving else {
      if !environmentWakeArmed {
        environmentWakeArmed = true
        environment.whenResolved(on: queue) { [weak self] in
          guard let self else { return }
          self.environmentWakeArmed = false
          self.publishCurrentModel()
        }
      }
      return
    }
    for name in requiredSources.sorted() {
      guard let definition = sources[name] else { continue }
      if sourceRecords[name] == nil { sourceRecords[name] = SourceRecord(definition: definition) }
      // A pushed source has nothing to run: `status set` is its output.
      guard !definition.isPushed else { continue }
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
      environment: environment.environment)
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
          if status == 0 { self.ingest(output, source: name, definition: definition) }
          self.publishCurrentModel()
        })
    } catch {
      sourceRecords[name]?.schedule.complete(token)
      FlashLog.warn("[statusbar] source failed name=\(name) error=\(error.localizedDescription)")
    }
  }

  /// A source's new output, from its command or a push: read in the source's
  /// `output` format, kept unless empty (the last good value stays), a number
  /// joins its history, and a cycling source rotates the nonempty lines.
  private func ingest(
    _ raw: String, source name: String, definition: FlashStatusBarSourceDefinition
  ) {
    let output = definition.output.extract(raw)
    let trimmed = output.trimmed
    guard !trimmed.isEmpty else { return }
    if let limit = definition.historyLength, Double(trimmed)?.isFinite == true {
      var history = sourceRecords[name]?.history ?? []
      history.append(trimmed)
      sourceRecords[name]?.history = Array(history.suffix(limit))
    }
    guard let period = definition.cycleIntervalSeconds else {
      sourceRecords[name]?.value = trimmed
      return
    }
    let lines = output.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
    if var cycle = sourceRecords[name]?.cycle {
      cycle.refresh(lines: lines, periodSeconds: period, now: clock())
      sourceRecords[name]?.cycle = cycle
    } else {
      sourceRecords[name]?.cycle = FlashStatusBarCycleState(
        lines: lines, periodSeconds: period, now: clock())
    }
  }

  private func startShell(_ request: StatusFormatJobRequest, token: UInt64) {
    let key = Self.shellKey(request)
    do {
      shellRecords[key]?.job = try makeJob(
        StatusCommandInvocation(
          argv: ["/bin/sh", "-c", request.command],
          environment: environment.environment,
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
  /// finest time unit shown, kernel-value reads and pending output — so the
  /// controller re-registers its next deadline on the shared clock each time
  /// one lands, rather than owning a timer. It is armed only while a visible
  /// surface or an enabled monitor requires something.
  ///
  /// Each deadline carries the slack its kind tolerates. A clock boundary, a
  /// carousel rotation and the next change of a calendar value are the
  /// visible change itself — the second has to turn on the second — so they
  /// are `.high`. A job or source re-run, the
  /// placeholder for a job that has not answered and the throttled publish of
  /// output that already arrived are `.normal`: their output lands whenever
  /// the command finishes, so a tenth of a second is invisible, and the looser
  /// slack lets them coalesce with the rest of the app's wake-ups. What only
  /// monitors require — their jobs, sources, kernel reads and calendar
  /// values — is `.low`:
  /// background upkeep nobody watches.
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
    // What only monitors require re-runs at `.low`: nobody watches it land.
    for name in requiredSources {
      add(
        [sourceRecords[name]?.schedule.dueAt].compactMap { $0 },
        foregroundSources.contains(name) ? .normal : .low)
    }
    for key in requiredJobs.keys {
      let priority: PollScheduler.Priority = foregroundJobs.contains(key) ? .normal : .low
      add([shellRecords[key]?.schedule.dueAt].compactMap { $0 }, priority)
      if shellRecords[key]?.value == nil, let started = shellRecords[key]?.schedule.startedAt {
        add([started + 2], priority)
      }
    }
    // A kernel value is read again once its cadence has passed; 0 reads it
    // once.
    for (value, requirement) in requiredHostValues where requirement.cadence > 0 {
      if let sample = hostSamples[value] {
        add([sample.at + requirement.cadence], requirement.priority)
      }
    }
    add(
      requiredSources.compactMap { sourceRecords[$0]?.cycle }
        .filter(\.needsRotationTimer).map(\.nextRotationAt), .high)
    // A carousel no active surface reads keeps its rotation state for when
    // one shows it again, but wakes nobody meanwhile.
    add(
      pluginCycles.filter { requiredPluginSegments.contains($0.key) }.values
        .filter(\.needsRotationTimer).map(\.nextRotationAt), .high)
    if let clockDeadline = clockDeadline(now: clock()) { add([clockDeadline], .high) }
    // A calendar value changes at instants of its own — the countdown's
    // next minute, an event starting or ending — never on a cadence.
    if let calendarPriority, let calendarAgenda {
      let wall = wallClock()
      if let change = CalendarNext.nextChange(calendarAgenda, after: wall) {
        add([clock() + change.timeIntervalSince(wall)], calendarPriority)
      }
    }
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

  /// Step one carousel by hand: a scroll over its run on the bar, naming it
  /// with the key the run carries. The line it lands on shows at once and
  /// keeps a full period before the clock moves on, so a reader who scrolled
  /// to an article is not pushed off it a moment later. An unknown key, or a
  /// carousel with nothing to rotate, does nothing.
  func stepCycle(key: String, by delta: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      let now = self.clock()
      let stepped: Bool
      if let segment = StatusCycleKey.pluginSegment(key) {
        stepped = self.pluginCycles[segment]?.step(by: delta, now: now) ?? false
      } else if let name = StatusCycleKey.sourceName(key) {
        stepped = self.sourceRecords[name]?.cycle?.step(by: delta, now: now) ?? false
      } else {
        stepped = false
      }
      guard stepped else { return }
      FlashLog.trace("[statusbar] carousel_step key=\(key) delta=\(delta)")
      // Publishing re-arms the clock, so the restarted dwell is the next one.
      self.publishCurrentModel()
    }
  }

  /// A status command's executable as a terminal popup's is found
  /// (`TerminalExecutable.resolve`): a path as written, else the first
  /// regular executable file on `PATH`, never a directory nor a name
  /// resolved against Flash's own working directory. Unfound, it is kept as
  /// written and the spawn reports it.
  static func executablePath(_ executable: String, environment: [String: String]) -> String {
    TerminalExecutable.resolve(executable, path: environment["PATH"]) ?? executable
  }
}

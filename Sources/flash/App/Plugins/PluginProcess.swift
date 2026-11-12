import AppKit
import Darwin
import FlashCore
import FlashTerminal
import Foundation

/// One managed plugin child process speaking the NDJSON wire protocol
/// (protocol v1 — see Plugins/_flash_plugin_rust/protocol.json).
///
/// `PluginLifecycle` owns desired state, attempt generations, and retries;
/// this object interprets effects and owns each child transport, with
/// `failed` the parked terminal state (no auto-restart; file watchers stay
/// armed so a rebuilt binary recovers). Resident plugins spawn at startup;
/// on-demand plugins spawn on their first `perform`, or once startup has
/// settled when a configured mapping keeps them warm (`prewarm`);
/// manifest-only plugins never spawn.
final class PluginProcess {
  typealias RequestCompletion = ([String: Any]?) -> Void
  private let stderrLock = NSLock()
  private var stderrLines = PluginStderrLines()
  struct PendingRequest {
    let completion: RequestCompletion
    let settleOnStop: Bool
    let method: String
    let startedAt: DispatchTime
    let deadline: DispatchTime?
    /// The interaction the request serves (`Trace`), for its log lines.
    let trace: String?

    init(
      completion: @escaping RequestCompletion,
      settleOnStop: Bool,
      method: String = "test",
      startedAt: DispatchTime = .now(),
      deadline: DispatchTime? = nil,
      trace: String? = nil
    ) {
      self.completion = completion
      self.settleOnStop = settleOnStop
      self.method = method
      self.startedAt = startedAt
      self.deadline = deadline
      self.trace = trace
    }
  }

  /// A `perform` accepted while the child is still spawning/initializing.
  /// Dispatched when the plugin reaches `running`; settled `.unhandled` if
  /// that never happens before its deadline — nothing was dispatched, so
  /// fallback is safe.
  private struct DeferredPerform {
    let id: Int
    let kind: String
    let params: [String: Any]
    let timeoutMs: Int
    let startedAt: DispatchTime
    let trace: Trace.ID?
    let completion: (PluginPerformOutcome) -> Void
  }

  let root: URL
  let manifest: PluginManifest
  let origin: PluginOrigin
  private let listenPatterns: [PluginPattern]
  /// The manifest's status segment names, as a set built once: every
  /// `status` notification is filtered against it.
  private let declaredStatusSegments: Set<String>

  /// Lifecycle, replies and requests: `.userInitiated`, because a keypress
  /// (`hints`, `evaluate` under its 50 ms deadline, `perform`) or the
  /// liveness `ping` waits on what crosses these three queues, and a
  /// utility-class thread is what the kernel starves first under load.
  private let queue: DispatchQueue
  private let readQueue: DispatchQueue
  private let writeQueue: DispatchQueue
  /// Catalog decode alone, `.utility`: nobody waits on a publish, and a
  /// 700 KB catalog decoding here never holds a reply frame behind it on
  /// the reader. Serial, so one plugin's publishes keep their order; a
  /// publish and a later reply are not ordered host-side. Internal so a
  /// test can hold it and prove a reply completes while a publish is still
  /// undecoded.
  let catalogQueue: DispatchQueue
  private let dataDir: URL
  private let sandboxExecPath: String
  private let installLogDirectory: URL
  private var process: Process?
  private var stdinPipe: Pipe?
  private var frameCollector = NDJSONFrameCollector(maxLineBytes: PluginProtocol.maxFrameBytes)
  private let transportLock = NSLock()
  private var transportBudget = PluginTransportBudget()
  /// Frames admitted by `transportBudget` and not yet written, drained in
  /// order on `writeQueue`. Guarded by `transportLock`.
  private var outbound = PluginOutboundQueue()
  /// Whether a `writeQueue` drain owns `outbound`. Guarded by `transportLock`.
  private var outboundDraining = false
  private let lock = NSLock()
  private var state: PluginRuntimeState = .stopped
  /// Runtime status-bar segments, merged under `lock` on every `status`
  /// notification so concurrent updates can never lose each other.
  private var statusSegments: [String: PluginStatusSegment] = [:]
  /// Cadences and deadlines this plugin asked the core to drive, keyed by the
  /// plugin's own name. The plugin never arms a timer itself; `PollScheduler`
  /// ticks it, so one shared wake-up serves every poller in the app. Guarded
  /// by `lock`, as are the two fields below.
  private var pollRegistrations: [String: PollRegistration] = [:]
  /// Deadlines that fired and are still listed: repeating one unchanged in a
  /// later set must not fire it again.
  private var firedPollDeadlines: Set<String> = []
  /// The arming each live registration's tick must carry, so a fire already
  /// queued when its entry was replaced or dropped is discarded.
  private var pollArmings: [String: UInt64] = [:]
  private var pollArmingSerial: UInt64 = 0
  private var staleStatusSegments: Set<String> = []
  /// The grace a planned reload gives stale status segments, on the shared
  /// clock. `.low`: nobody watches the instant a stale label blanks. Armed
  /// afresh on every keep-status teardown, so the newest replacement gets
  /// the whole grace. Queue-confined.
  /// The clock behind this plugin's deadlines and `poll` registrations: the
  /// shared one, except in tests.
  private let scheduler: PollScheduler
  private lazy var statusGraceDeadline = PollDeadline(
    "core:plugin_status_grace:\(manifest.id):\(instanceTag)", priority: .low, on: queue,
    scheduler: scheduler)
  private var startDate: Date?
  /// Mirrors of queue-confined runtime fields, guarded by `lock`, so status
  /// reads from main never wait on `queue` (a stop sleeps there for up to
  /// 1.5 s). Republished by `publishRuntimeStatus` whenever they change.
  private var publishedPID: pid_t?
  private var publishedStartDate: Date?
  private var publishedRestartCount = 0
  /// The latest spawn's duration, read as `flash.plugin.spawn_ms`. Guarded
  /// by `lock`; set where the spawn returns.
  private var publishedSpawn: PluginSpawnTiming?
  /// Whether a status surface (the enabled bar, its popups, a desktop widget)
  /// shows this plugin's segments; decides a status-bound plugin's
  /// activation. Guarded by `lock`.
  private var statusObserved: Bool
  /// Whether a perform spawned the current run, which then outlives its status
  /// observers like any on-demand plugin. Queue-confined.
  private var performActivated = false
  /// Whether a configured mapping can run one of this plugin's commands
  /// (`PluginWarmPolicy`): an on-demand child is then spawned once startup
  /// has settled and outlives its status observers. Guarded by `lock`.
  private var warm = false
  /// The manifest `status` names a live status surface shows, sorted — the
  /// `core:status.observed` payload. Guarded by `lock`.
  private var observedStatusSegments: [String]
  /// The set the current child last received; queue-confined and cleared on
  /// each initialize, so a restarted child starts from the truth and no child
  /// ever receives an unchanged set twice.
  private var deliveredStatusSegments: [String]?
  private var lifecycle = PluginLifecycle()
  /// The crash-restart backoff (1–30 s) on the shared clock. `.low`: a
  /// restart is background upkeep — catalogs survive it in the host store —
  /// and a second of slack on a multi-second backoff changes nothing.
  /// Queue-confined.
  private lazy var restartDeadline = PollDeadline(
    "core:plugin_restart:\(manifest.id):\(instanceTag)", priority: .low, on: queue,
    scheduler: scheduler)
  /// Tells this instance's deadlines from a replacement's for the same id.
  private var instanceTag: String { String(UInt(bitPattern: ObjectIdentifier(self).hashValue)) }
  /// Set by a user-initiated reload so the lifecycle teardown keeps the
  /// published status segments (see `stopOnQueue(preserveStatus:)`).
  private var preserveStatusOnTeardown = false
  private var installer: PluginInstallJob?
  /// Guards `notifyStatus` so a burst of status changes collapses to one
  /// main-thread callback per runloop turn instead of one hop per change.
  private var statusNotificationPending = false
  private let statusNotifyLock = NSLock()
  /// Bounded restart loop: if
  /// `restartWindowAttempts` restarts happen within `restartWindowSeconds`,
  /// the plugin is parked in `.failed` and stops auto-restarting. The user
  /// can recover with `:plugins reload`.
  // Testability seams: production values, overridden (and restored) by the
  // lifecycle tests so restart parking and idle-ping teardown run in
  // milliseconds instead of minutes, and a wire check on `evaluate` is not
  // held to the per-keystroke deadline. `var` + internal on purpose.
  // `@Synchronized`: a test overrides them while an earlier test's plugin
  // queue may still read them.
  @Synchronized static var restartWindowAttempts = 5
  @Synchronized static var statusReloadGraceSeconds: TimeInterval = 10
  @Synchronized static var restartWindowSeconds: TimeInterval = 300
  @Synchronized static var idleBeforePingMs = PluginProtocol.idleBeforePingMs
  @Synchronized static var pingTimeoutMs = PluginProtocol.pingDeadlineMs
  @Synchronized static var queryDeadlineMs = PluginProtocol.queryDeadlineMs
  @Synchronized static var restartDelaySeconds: (Int) -> Int = { min(30, max(1, $0 + 1)) }
  /// Request deadlines settle callers that are waiting: a late timeout is a
  /// late failure on the key path, so this is not a utility queue either.
  private static let deadlineQueue = DispatchQueue(
    label: "flash.plugin.deadlines", qos: .userInitiated)
  private var requestID: Int = 0
  private var pending: [Int: PendingRequest] = [:]
  private var hostRequestToken: UInt64 = 0
  private var pendingHostRequests: Set<UInt64> = []
  private var deferredPerforms: [DeferredPerform] = []
  private var deferredPerformID = 0
  /// Uptime of the most recent inbound frame — any frame resets the idle
  /// clock, so a plugin that publishes or logs is never pinged.
  private var lastInboundFrameAt = DispatchTime.now()
  private var fileWatchers: [DispatchSourceFileSystemObject] = []
  /// Trailing debounce for plugin file changes. `.normal`: someone just
  /// rebuilt the plugin and is waiting for it to come back. Queue-confined.
  private lazy var fileReloadDeadline = PollDeadline(
    "core:plugin_reload:\(manifest.id):\(instanceTag)", priority: .normal, on: queue,
    scheduler: scheduler)
  /// Trailing debounce for a change to a file the manifest's
  /// `watch_settings` name: the user just saved it and may open the
  /// flashlight next, so `.normal`. Queue-confined.
  private lazy var watchedFileDeadline = PollDeadline(
    "core:plugin_watched_file:\(manifest.id):\(instanceTag)", priority: .normal, on: queue,
    scheduler: scheduler)
  /// A `publish_then_exit` run ends when both its child's clean exit and
  /// its stdout EOF were seen, so every byte it wrote is decoded first. The
  /// generation each was seen for; queue-confined.
  private var cleanExitGeneration: UInt64?
  private var stdoutEOFGeneration: UInt64?
  /// Bounds the wait for that EOF: a descendant holding the pipe open past
  /// the shutdown grace ends the run with whatever landed. `.low`: nothing
  /// waits on a plugin whose child has already exited. Queue-confined.
  private lazy var completionDeadline = PollDeadline(
    "core:plugin_complete:\(manifest.id):\(instanceTag)", priority: .low, on: queue,
    scheduler: scheduler)
  private var lastError: String?
  private var lastLog: String?
  /// Mirrors `Config.Plugins.watchingEnabled`. When false, plugin file
  /// watchers are not installed and the plugin only restarts when
  /// content changes propagate via an explicit `:plugins reload`.
  private var watchFiles: Bool
  /// User settings from `[plugins.<id>]`, delivered to the plugin process
  /// as JSON via `FLASH_PLUGIN_CONFIG`. Retained so a config reload can
  /// tell whether this plugin's settings changed.
  let settings: [String: PluginConfigValue]
  var onStatusChanged: (() -> Void)?
  var onFilesChanged: (() -> Void)?
  var watchesFiles: Bool { watchFiles }
  /// Host-owned catalog store validated `publish` notifications land in.
  /// Set by PluginManager; entries are dropped on `failed` park and unload,
  /// never on plain restarts.
  var catalogStore: PluginCatalogStore?
  /// Supplies the host's current running-applications snapshot for the one
  /// `core:apps.changed` event delivered right after initialize (the
  /// snapshot no longer rides initialize itself).
  var runningApplicationsProvider: (() -> [[String: Any]])?
  /// Handles a plugin→host RPC request (`call_host` on the plugin side):
  /// `(method, params, pluginID, scope, reply)`. Queued host actions validate
  /// the scope before execution. The host RPC router (PluginManager)
  /// installs this; `reply` is invoked with the JSON result, possibly async
  /// (e.g. AX work hops to the main thread first).
  var onHostRequest:
    (
      (String, [String: Any], String, PluginHostRequestScope, @escaping ([String: Any]) -> Void) ->
        Void
    )?

  init(
    root: URL,
    manifest: PluginManifest,
    origin: PluginOrigin,
    baseDataDir: URL,
    watchFiles: Bool = true,
    settings: [String: PluginConfigValue] = [:],
    statusObserved: Bool = true,
    observedStatusSegments: Set<String> = [],
    environment: FlashProcessEnvironment = .shared,
    sandboxExecPath: String = PluginSandbox.sandboxExecPath,
    installLogDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Flash/plugin-install"),
    scheduler: PollScheduler = .shared
  ) {
    self.scheduler = scheduler
    self.root = root
    self.environment = environment
    self.manifest = manifest
    self.origin = origin
    self.listenPatterns = manifest.listen.map(PluginPattern.init)
    self.declaredStatusSegments = Set(manifest.statusSegments)
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.sandboxExecPath = sandboxExecPath
    self.installLogDirectory = installLogDirectory
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .userInitiated)
    self.readQueue = DispatchQueue(
      label: "flash.plugin.\(manifest.id).read", qos: .userInitiated)
    self.writeQueue = DispatchQueue(
      label: "flash.plugin.\(manifest.id).write", qos: .userInitiated)
    self.catalogQueue = DispatchQueue(label: "flash.plugin.\(manifest.id).catalog", qos: .utility)
    self.watchFiles = watchFiles
    self.settings = settings
    self.statusObserved = statusObserved
    self.observedStatusSegments = Self.statusObservedSegments(
      observedStatusSegments, declared: manifest.status)
  }

  /// The login environment the child inherits; a spawn waits for it.
  private let environment: FlashProcessEnvironment

  var identifier: String { manifest.id }

  /// The manifest's activation, on demand while a status-bound plugin is
  /// unobserved.
  var activation: PluginActivation {
    lock.lock()
    defer { lock.unlock() }
    return manifest.activation(statusObserved: statusObserved)
  }

  /// The status surfaces started or stopped showing this plugin's segments. A
  /// status-bound plugin that becomes observed spawns if it has not yet. One
  /// that stops being observed returns to on-demand: its process stops unless
  /// a perform started it or a mapping keeps it warm, since on-demand plugins
  /// remain running once a command needs them.
  func setStatusObserved(_ observed: Bool) {
    lock.lock()
    let changed = statusObserved != observed
    statusObserved = observed
    lock.unlock()
    guard changed, manifest.isStatusBound else { return }
    queue.async {
      FlashLog.info(
        "[plugin] status \(observed ? "observed" : "unobserved")",
        fields: ["id": self.manifest.id])
      if observed {
        self.applyLifecycle(.activate)
      } else {
        self.deactivateIfUnneeded()
      }
    }
  }

  /// Whether a configured mapping can run one of this plugin's commands
  /// (`PluginWarmPolicy`). A plugin that becomes warm spawns at the next
  /// prewarm; a status-bound one that stops being warm while nothing shows
  /// its segments stops as any unobserved one does.
  func setWarm(_ warm: Bool) {
    lock.lock()
    let changed = self.warm != warm
    self.warm = warm
    lock.unlock()
    guard changed, !warm, manifest.isStatusBound else { return }
    queue.async { self.deactivateIfUnneeded() }
  }

  private var isWarm: Bool {
    lock.lock()
    defer { lock.unlock() }
    return warm
  }

  /// Runs on `queue`: a status-bound child that no surface shows, no perform
  /// started and no mapping keeps warm stops and returns to on-demand.
  private func deactivateIfUnneeded() {
    lock.lock()
    let observed = statusObserved
    lock.unlock()
    guard !observed,
      PluginWarmPolicy.stopsWhenUnobserved(
        manifest, state: lifecycle.state, performActivated: performActivated, warm: isWarm)
    else { return }
    applyLifecycle(.deactivate)
  }

  /// Spawn a warm on-demand child ahead of its first perform, unless
  /// something already started it. The manager asks once startup has
  /// settled; a perform that comes first spawns the child itself, as before.
  func prewarm() {
    queue.async {
      guard
        PluginWarmPolicy.prewarms(
          activation: self.activation, state: self.lifecycle.state, warm: self.isWarm)
      else { return }
      FlashLog.info("[plugin] prewarm", fields: ["id": self.manifest.id])
      self.applyLifecycle(.activate)
    }
  }

  /// The complete observed set a plugin receives: only names its manifest
  /// declares, each nonempty and listed once, sorted.
  static func statusObservedSegments(_ observed: Set<String>, declared: [String]) -> [String] {
    observed.intersection(declared).filter { !$0.isEmpty }.sorted()
  }

  /// The surfaces started or stopped showing some of this plugin's segments.
  /// A running child hears the new set at once; a starting one hears it right
  /// after initialize.
  func setObservedStatusSegments(_ observed: Set<String>) {
    let segments = Self.statusObservedSegments(observed, declared: manifest.status)
    lock.lock()
    let changed = observedStatusSegments != segments
    observedStatusSegments = segments
    lock.unlock()
    guard changed else { return }
    queue.async { [weak self] in
      guard let self, self.runtimeStateSnapshot() == .running else { return }
      self.deliverObservedStatusSegments()
    }
  }

  /// `core:status.observed` to a listening child, unless it already has
  /// this exact set. Runs on `queue`.
  private func deliverObservedStatusSegments() {
    guard listenPatterns.contains(where: { $0.matches(HostEvent.statusObserved.rawValue) }) else {
      return
    }
    lock.lock()
    let segments = observedStatusSegments
    lock.unlock()
    guard segments != deliveredStatusSegments else { return }
    deliveredStatusSegments = segments
    deliverEventOnQueue(
      PluginEvent(.statusObserved, payload: ["segments": segments], bundleID: nil))
  }

  func reportDefinitionError(_ error: String) {
    queue.async { [weak self] in
      self?.recordError("[plugin] invalid replacement definition: \(error)")
    }
  }

  // MARK: - Lifecycle

  func start() {
    queue.async {
      let activation = self.activation
      self.applyLifecycle(.start(resident: activation.spawnsAtStart))
      // Performs that arrived before the start — a replacement published
      // while its predecessor was still stopping — asked for the child.
      if activation == .onDemand, !self.deferredPerforms.isEmpty {
        self.performActivated = true
        self.applyLifecycle(.activate)
      }
      self.installFileWatchers()
    }
  }

  func stopAndWait(reason: String = "stop") {
    queue.sync {
      self.settleDeferredPerforms(as: .unhandled)
      self.applyLifecycle(.stop)
    }
  }

  /// Returns once every block already on the lifecycle queue has run — each
  /// `sendEvent` hop among them, so its frame is queued or written.
  func drainLifecycleQueue() { queue.sync {} }

  func reload(reason: String) {
    queue.async {
      let resident = self.activation.spawnsAtStart
      self.preserveStatusOnTeardown = resident
      self.applyLifecycle(.reload(resident: resident))
      self.installFileWatchers()
    }
  }

  private func applyLifecycle(_ event: PluginLifecycle.Event) {
    switch event {
    case .reload, .stop: performActivated = false
    default: break
    }
    let effects = lifecycle.transition(
      event, now: ProcessInfo.processInfo.systemUptime,
      restartLimit: Self.restartWindowAttempts, restartWindow: Self.restartWindowSeconds,
      restartDelay: Self.restartDelaySeconds)
    for effect in effects {
      switch effect {
      case .teardown:
        stopOnQueue(reason: "lifecycle", preserveStatus: preserveStatusOnTeardown)
        preserveStatusOnTeardown = false
      case .start(let generation):
        startOnQueue(generation: generation)
      case .retry(let generation, let delay):
        FlashTelemetry.record(.pluginRestarts, 1, ["plugin": manifest.id])
        restartDeadline.arm(afterMs: delay * 1000) { [weak self] in
          self?.applyLifecycle(.retry(generation))
        }
      case .park:
        settleDeferredPerforms(as: .unhandled)
        if lifecycle.failures.count > Self.restartWindowAttempts {
          recordError(
            "[plugin] restart loop exhausted: \(lifecycle.failures.count) failures within \(Int(Self.restartWindowSeconds))s",
            level: .error)
        }
        catalogStore?.drop(pluginID: manifest.id)
        installFileWatchers()
      case .rest:
        // The catalog stays in the store; the watchers the teardown removed
        // come back, since a file change is what runs the plugin again.
        settleDeferredPerforms(as: .unhandled)
        installFileWatchers()
        FlashLog.plugin(
          .info, pluginID: manifest.id,
          message: "[plugin] published and exited; runs again on a reload or a watched change",
          fields: ["rows": String(catalogStore?.rows(for: manifest.id).count ?? 0)])
      }
    }
    // Terminal status is observable only after teardown and catalog removal.
    // Nested startup transitions may advance the reducer while interpreting
    // effects, so publish its current projection rather than a captured state.
    publishRuntimeStatus()
    setState(lifecycle.runtimeState)
  }

  private func startOnQueue(generation: UInt64) {
    guard manifest.exec != nil else { return }
    // The child inherits the environment in effect when it spawns, for its
    // whole life: wait for the login environment, so a plugin started at
    // launch does not keep launchd's bare `PATH` until its next restart.
    environment.whenResolved(on: queue) { [weak self] in
      guard let self, self.lifecycle.generation == generation, self.lifecycle.state == .installing
      else { return }
      self.installAndLaunch(generation: generation)
    }
  }

  private func installAndLaunch(generation: UInt64) {
    let startedAt = DispatchTime.now()
    do {
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      try installIfNeeded(generation: generation) { [weak self] result in
        guard let self, self.lifecycle.generation == generation, self.lifecycle.state == .installing
        else { return }
        self.installer = nil
        switch result {
        case .success:
          self.applyLifecycle(.installed(generation))
          do {
            try self.launch(
              startupStartedAt: startedAt, installMs: Self.elapsedMilliseconds(since: startedAt))
            self.installFileWatchers()
          } catch {
            self.recordError("[plugin] launch failed: \(error)")
            self.applyLifecycle(.interrupted(generation))
          }
        case .failure(let error):
          self.recordError("[plugin] install failed: \(error)")
          self.applyLifecycle(.interrupted(generation))
        }
      }
    } catch {
      recordError("[plugin] start failed: \(error)")
      applyLifecycle(.interrupted(generation))
    }
  }

  /// Shutdown contract: there is no shutdown method. Closing stdin IS the
  /// signal — the plugin runs cleanup and exits 0. `shutdown_grace` later
  /// comes SIGTERM, and +0.5 s after that SIGKILL.
  private func stopOnQueue(reason: String, preserveStatus: Bool = false) {
    // Remove every callback before invoking any of them. A completion can
    // enqueue another plugin request, so iterating the live dictionary would
    // be reentrant and could strand or double-complete work.
    let abandonedCallbacks = Self.takePendingCallbacks(&pending)
    pendingHostRequests.removeAll()
    restartDeadline.cancel()
    fileReloadDeadline.cancel()
    watchedFileDeadline.cancel()
    completionDeadline.cancel()
    cleanExitGeneration = nil
    stdoutEOFGeneration = nil
    installer?.cancel()
    installer = nil
    PluginLivenessSweep.shared.leave(self)
    removeFileWatchers()
    invalidateTransport()
    if let process, process.isRunning {
      // Each stage ends on the child's exit event; the deadlines only bound
      // a child that ignores stdin EOF and then SIGTERM.
      let pid = process.processIdentifier
      stdinPipe?.fileHandleForWriting.closeFile()
      if !ProcessExit.waitForExit(
        pid, until: .now() + .milliseconds(PluginProtocol.shutdownGraceMs))
      {
        process.terminate()
        if !ProcessExit.waitForExit(pid, until: .now() + .milliseconds(500)), process.isRunning {
          kill(pid, SIGKILL)
        }
      }
    }
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    process = nil
    stdinPipe = nil
    startDate = nil
    publishRuntimeStatus()
    cancelPollRegistrations()
    lock.lock()
    if preserveStatus {
      staleStatusSegments.formUnion(statusSegments.keys)
    } else {
      statusSegments.removeAll()
      staleStatusSegments.removeAll()
    }
    let needsStatusExpiry = !staleStatusSegments.isEmpty
    lock.unlock()
    if !preserveStatus {
      statusGraceDeadline.cancel()
    } else if needsStatusExpiry {
      // A planned reload keeps the previous labels until each segment is
      // refreshed. One bounded grace window also handles a replacement that
      // initializes successfully but never republishes its status; a second
      // reload inside the window arms it again, so the grace a label gets
      // is always measured from the newest replacement.
      statusGraceDeadline.arm(after: Self.statusReloadGraceSeconds) { [weak self] in
        guard let self else { return }
        self.lock.lock()
        for name in self.staleStatusSegments { self.statusSegments.removeValue(forKey: name) }
        self.staleStatusSegments.removeAll()
        self.lock.unlock()
        self.notifyStatus()
      }
    }

    for callback in abandonedCallbacks {
      callback(nil)
    }
  }

  static func takePendingCallbacks(
    _ pending: inout [Int: PendingRequest]
  ) -> [RequestCompletion] {
    let callbacks = pending.keys.sorted().compactMap { id -> RequestCompletion? in
      guard let request = pending[id], request.settleOnStop else { return nil }
      return request.completion
    }
    pending.removeAll(keepingCapacity: true)
    return callbacks
  }

  private func launch(startupStartedAt: DispatchTime, installMs: String) throws {
    // Unreachable for manifest-only plugins — startOnQueue returns before
    // install/launch when the manifest has no exec argv.
    guard let execArgv = manifest.exec, let executable = execArgv.first else {
      throw PluginError.failure("plugin \(manifest.id) has no exec argv to launch")
    }
    // Direct exec, no shell wrap: a `/bin/sh -lc` here used to source the
    // user's login rc files inside the child, silently re-widening the
    // scrubbed 11-key env allowlist. Resolution of argv[0]: absolute paths
    // pass through, "./"-style paths resolve against the plugin root
    // (official plugins use "./flash-plugin-<id>"), and bare names resolve
    // through mise/the login-shell PATH for third-party executables.
    let resolutionStartedAt = DispatchTime.now()
    let executablePath: String
    if executable.hasPrefix("/") {
      executablePath = executable
    } else if executable.contains("/") {
      executablePath = root.appendingPathComponent(executable).standardizedFileURL.path
    } else if let resolved = PluginSandbox.resolveExecutable(named: executable, from: root) {
      executablePath = resolved
      FlashLog.plugin(
        .info, pluginID: manifest.id,
        message: "[plugin] runtime \(executable) -> \(resolved)")
    } else {
      throw PluginError.failure(
        "plugin \(manifest.id) exec runtime not found via mise or the login PATH: \(executable)")
    }
    let resolutionMs = Self.elapsedMilliseconds(since: resolutionStartedAt)
    let execTail = Array(execArgv.dropFirst())
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    // Protect this transport independently of main.swift's process-wide
    // SIGPIPE policy, including when embedded in the XCTest host.
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw PluginError.failure("could not suppress SIGPIPE on plugin stdin")
    }
    // Run the plugin under its resolved seatbelt profile. sandbox-exec execs
    // in place, so the pid we track and the child flash-plugin binary are
    // unchanged.
    let sandboxStartedAt = DispatchTime.now()
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest, settings: settings, root: root, dataDir: dataDir,
      executablePath: executablePath)
    let sandboxMs = Self.elapsedMilliseconds(since: sandboxStartedAt)
    let sandboxed = resolved.profile != nil
    if sandboxed { try requireSandboxExecutable() }
    if sandboxed, let profile = resolved.profile {
      process.executableURL = URL(fileURLWithPath: sandboxExecPath)
      process.arguments = ["-p", profile, executablePath] + execTail
    } else {
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = execTail
    }
    if resolved.mode == "disabled_by_config" {
      FlashLog.warn(
        "[plugin] \(manifest.id) sandbox DISABLED by [plugins.\(manifest.id)] sandbox = false",
        fields: ["plugin": manifest.id, "sandbox_mode": resolved.mode])
    }
    FlashLog.info(
      "[plugin] \(manifest.id) launch sandbox=\(resolved.mode)",
      fields: ["plugin": manifest.id, "sandbox_mode": resolved.mode])
    process.currentDirectoryURL = root
    process.environment = pluginEnvironment()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let transportGeneration = beginTransport()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        // EOF: every writer of the pipe is gone. Once is enough.
        handle.readabilityHandler = nil
        self?.handleStdoutEOF(generation: transportGeneration)
        return
      }
      self?.handleStdout(data, generation: transportGeneration)
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleStderr(handle.availableData, generation: transportGeneration)
    }
    process.terminationHandler = { [weak self] p in
      self?.queue.async {
        guard let self, self.process === p else { return }
        if self.manifest.lifecycle == .publishThenExit, p.terminationReason == .exit,
          p.terminationStatus == 0, self.lifecycle.state == .running
        {
          // The run it declared: its catalog is read to the end first.
          self.observeCleanExit(generation: self.lifecycle.generation)
          return
        }
        // A signal (a crash, a kill) and an exit status are different stories.
        let reason = p.terminationReason == .uncaughtSignal ? "signal" : "exit"
        self.recordError("[plugin] exited reason=\(reason) status=\(p.terminationStatus)")
        self.applyLifecycle(.interrupted(self.lifecycle.generation))
      }
    }
    let spawnStartedAt = DispatchTime.now()
    do {
      try process.run()
    } catch {
      invalidateTransport()
      throw PluginError.failure("\(error)")
    }
    let spawnMsValue = Self.elapsedMillisecondsValue(since: spawnStartedAt)
    let spawnMs = String(format: "%.2f", spawnMsValue)
    lock.lock()
    publishedSpawn = PluginSpawnTiming(
      milliseconds: spawnMsValue, at: DispatchTime.now().uptimeNanoseconds)
    lock.unlock()
    FlashTelemetry.record(.pluginSpawnDuration, spawnMsValue, ["plugin": manifest.id])
    self.process = process
    self.stdinPipe = stdin
    self.startDate = Date()
    publishRuntimeStatus()
    self.lastInboundFrameAt = .now()
    let initializationStartedAt = DispatchTime.now()
    // initialize carries the protocol version and nothing else; the reply
    // must be immediate (no warm-catalog wait — on_start hooks run after it
    // and publish when ready).
    sendRequest(
      method: "initialize",
      params: ["protocol_version": PluginProtocol.version],
      timeout: Self.startupTimeout,
      settleOnStop: false
    ) { [weak self, weak process] response in
      guard let self, let process, self.process === process else { return }
      let initializationMs = Int(
        (DispatchTime.now().uptimeNanoseconds
          &- initializationStartedAt.uptimeNanoseconds) / 1_000_000)
      let startupTotalMs = Self.elapsedMillisecondsValue(since: startupStartedAt)
      guard let response else {
        // No reply within the startup deadline: teardown + backoff restart —
        // unlike a version NAK, a hung binary may recover on relaunch.
        self.recordError(
          "[plugin] initialize timed out after \(Self.startupTimeoutSeconds)s")
        self.applyLifecycle(.interrupted(self.lifecycle.generation))
        return
      }
      guard PluginWireCodec.acceptsProtocolVersion(response) else {
        let reported = PluginWireCodec.protocolVersionValue(response).map(String.init) ?? "missing"
        self.parkFailed(
          "[plugin] protocol_version \(reported) != host v\(PluginProtocol.version)")
        return
      }
      guard PluginJSON.boolean(response["ok"]) == true else {
        let error = response["error"] as? String ?? "plugin rejected initialize"
        self.parkFailed("[plugin] initialize failed: \(error)")
        return
      }
      guard Set(response.keys) == ["ok", "protocol_version"] else {
        self.parkFailed("[plugin] malformed initialize reply")
        return
      }
      FlashLog.plugin(
        startupTotalMs > 1_000 ? .warn : .info,
        pluginID: self.manifest.id,
        message: "[plugin] initialized elapsed_ms=\(initializationMs)",
        fields: [
          "elapsed_ms": String(initializationMs),
          "startup_total_ms": String(format: "%.2f", startupTotalMs),
          "install_ms": installMs,
          "resolution_ms": resolutionMs,
          "sandbox_ms": sandboxMs,
          "spawn_ms": spawnMs,
        ])
      self.completeStartup()
    }
  }

  private func completeStartup() {
    clearError()
    applyLifecycle(.initialized(lifecycle.generation))
    // The running-applications snapshot no longer rides initialize: every
    // plugin, whatever its `listen`, gets exactly one core:apps.changed with
    // the full snapshot (it seeds the SDK's running-apps list), then only
    // subscribers get live updates through the normal event stream. A
    // `publish_then_exit` child reads no events and may already be gone.
    if manifest.lifecycle != .publishThenExit, let snapshot = runningApplicationsProvider?() {
      deliverEventOnQueue(.appsChanged(snapshot))
    }
    // Every child, including a restarted one, starts from the current set —
    // sent even when it is empty.
    deliveredStatusSegments = nil
    deliverObservedStatusSegments()
    PluginLivenessSweep.shared.join(self)
    let deferred = deferredPerforms
    deferredPerforms.removeAll()
    for item in deferred {
      let elapsedMs = Int(Self.elapsedMillisecondsValue(since: item.startedAt))
      guard elapsedMs < item.timeoutMs else {
        item.completion(.unhandled)
        continue
      }
      dispatchPerform(
        kind: item.kind,
        params: item.params,
        timeoutMs: max(1, item.timeoutMs - elapsedMs),
        trace: item.trace,
        completion: item.completion)
    }
  }

  /// Terminal park: no auto-restart. Used for initialize NAKs and protocol
  /// mismatches — relaunching the same binary cannot recover. File watchers
  /// re-arm so a REBUILT binary (the dev hot loop) recovers without
  /// `:plugins reload`; the published catalog is dropped (a failed plugin
  /// could never serve its rows' effects).
  private func parkFailed(_ message: String) {
    recordError(message, level: .error)
    applyLifecycle(.reject(lifecycle.generation))
  }

  // MARK: - Publish then exit

  /// The child of a `publish_then_exit` plugin exited 0 while running. Its
  /// last frames may still be in the pipe or on the catalog queue: the run
  /// completes once stdout reached EOF and everything read was decoded, or
  /// fails at the shutdown grace if a descendant keeps the pipe open. Runs on
  /// `queue`.
  private func observeCleanExit(generation: UInt64) {
    cleanExitGeneration = generation
    completionDeadline.arm(afterMs: PluginProtocol.shutdownGraceMs) { [weak self] in
      guard let self, self.lifecycle.generation == generation, self.lifecycle.state == .running
      else { return }
      FlashLog.plugin(
        .warn, pluginID: self.manifest.id,
        message: "[plugin] stdout stayed open after the exit; rejecting incomplete output")
      self.applyLifecycle(.interrupted(generation))
    }
    completeRunIfSettled(generation: generation)
  }

  /// The pipe callback saw EOF. Ordered behind every chunk already read
  /// (the read queue), then behind every publish those chunks started (the
  /// catalog queue), then onto the lifecycle queue: the run completes only
  /// after the last decoded publish reached the store.
  private func handleStdoutEOF(generation: UInt64) {
    readQueue.async { [weak self] in
      guard let self, self.isTransportActive(generation) else { return }
      self.catalogQueue.async { [weak self] in
        guard let self else { return }
        self.queue.async { [weak self] in
          guard let self, self.isTransportActive(generation) else { return }
          self.stdoutEOFGeneration = self.lifecycle.generation
          self.completeRunIfSettled(generation: self.lifecycle.generation)
        }
      }
    }
  }

  private func completeRunIfSettled(generation: UInt64) {
    guard cleanExitGeneration == generation, stdoutEOFGeneration == generation else { return }
    completeRun(generation: generation)
  }

  private func completeRun(generation: UInt64) {
    completionDeadline.cancel()
    applyLifecycle(.completed(generation))
  }

  // MARK: - Idle ping

  /// The one residual liveness probe: after `idleBeforePingMs` of inbound
  /// silence with nothing in flight, send `ping`; one missed reply tears
  /// down and restarts. Any inbound frame (the reply included) resets the
  /// silence, and pending requests suppress it — a blocking single-threaded
  /// plugin is fully conformant. `PluginLivenessSweep` asks; nothing here
  /// arms a timer.
  func checkIdleLiveness() {
    queue.async { [weak self] in self?.pingIfIdle() }
  }

  private func pingIfIdle() {
    guard runtimeStateSnapshot() == .running, process?.isRunning == true, pending.isEmpty,
      Int(Self.elapsedMillisecondsValue(since: lastInboundFrameAt)) >= Self.idleBeforePingMs
    else { return }
    sendRequest(
      method: "ping",
      params: [:],
      timeout: .milliseconds(Self.pingTimeoutMs),
      settleOnStop: false
    ) { [weak self] response in
      guard let self, self.runtimeStateSnapshot() == .running else { return }
      guard PluginWireCodec.okPayload(response) != nil else {
        self.recordError("[plugin] ping missed — restarting")
        self.applyLifecycle(.interrupted(self.lifecycle.generation))
        return
      }
    }
  }

  // MARK: - Events

  /// Whether the manifest's `listen` globs admit `name`.
  func listens(to name: String) -> Bool {
    listenPatterns.contains(where: { $0.matches(name) })
  }

  func sendEvent(_ event: PluginEvent) {
    guard listens(to: event.name) else { return }
    queue.async { [weak self] in
      guard let self, self.runtimeStateSnapshot() == .running else { return }
      self.deliverEventOnQueue(event)
    }
  }

  /// The `event` frame every listener receives for `event`; nil when the
  /// payload is not JSON-encodable (the per-plugin path then logs the drop).
  static func encodedEventFrame(_ event: PluginEvent) -> Data? {
    try? PluginWireCodec.encodeFrame(eventFrameObject(event))
  }

  private static func eventFrameObject(_ event: PluginEvent) -> [String: Any] {
    [
      "method": "event",
      "params": [
        "name": event.name,
        "payload": event.wirePayload,
      ],
    ]
  }

  /// The queue slot `event` replaces, from the payload every listener sees.
  static func coalescingKey(_ event: PluginEvent) -> String? {
    PluginProtocol.coalescingKey(eventName: event.name, payload: event.wirePayload)
  }

  private func deliverEventOnQueue(_ event: PluginEvent) {
    let coalescingKey = event.coalescingKey ?? Self.coalescingKey(event)
    if let frame = event.encodedFrame, frame.count - 1 <= PluginProtocol.maxFrameBytes {
      enqueueWrite(frame, label: "event", coalescingKey: coalescingKey)
      return
    }
    writeFrame(Self.eventFrameObject(event), coalescingKey: coalescingKey)
  }

  // MARK: - Host → plugin requests

  /// Live hint pull (`hints`). Always a fresh request — there is no cached
  /// discovery. Blocks the caller up to `timeout` and returns `[]` for a
  /// missing/rejected/mismatched reply.
  func discoverTargets(
    context: AppContext, timeout: TimeInterval, resolveAtCommit: Bool = true
  ) -> [JumpTarget] {
    guard runtimeStateSnapshot() == .running else { return [] }
    let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    let window =
      resolveAtCommit
      ? HintWindowSnapshot.current(pid: context.processID, primaryHeight: primaryHeight) : nil
    let startedAt = DispatchTime.now()
    let semaphore = DispatchSemaphore(value: 0)
    var targets: [JumpTarget] = []
    let resultLock = NSLock()
    let params = PluginWireCodec.spatialContextJSON(context)
    sendRequest(
      method: "hints",
      params: params,
      timeout: .milliseconds(Int((timeout * 1_000).rounded()))
    ) { [weak self] response in
      defer { semaphore.signal() }
      guard let self, let payload = PluginWireCodec.okPayload(response) else { return }
      guard
        let wire = PluginWireCodec.hintTargets(
          from: payload, sourceID: "plugin:\(self.manifest.id)", contextPID: context.processID)
      else { return }
      let decoded = wire.map {
        self.hostJumpTarget(
          from: $0, context: context, window: window, primaryHeight: primaryHeight,
          timeout: timeout, resolveAtCommit: resolveAtCommit)
      }
      resultLock.lock()
      targets = decoded
      resultLock.unlock()
    }
    let waitResult = semaphore.wait(timeout: .now() + timeout)
    resultLock.lock()
    let completedTargets = waitResult == .success ? targets : []
    resultLock.unlock()
    if FlashLog.wouldEmit(.debug) {
      FlashLog.debug(
        "[plugin] hints",
        fields: [
          "plugin": manifest.id,
          "pid": "\(context.processID)",
          "bundle": context.bundleIdentifier,
          "targets": "\(completedTargets.count)",
          "timed_out": "\(waitResult == .timedOut)",
          "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
        ],
        source: "plugin:\(manifest.id)")
    }
    return completedTargets
  }

  /// Materialise a wire-format target as host-owned geometry and semantics.
  /// Hint activation is never delegated back to the plugin: the host posts a
  /// real mouse event to the owning app for every committed target.
  private func hostJumpTarget(
    from wire: PluginWireTarget, context: AppContext, window: HintWindowSnapshot?,
    primaryHeight: CGFloat, timeout: TimeInterval, resolveAtCommit: Bool
  ) -> JumpTarget {
    let captured = wire.capturedTarget(contextPID: context.processID)
    guard resolveAtCommit else { return captured }
    return JumpTarget(
      id: captured.id, frame: captured.frame, role: captured.role,
      accessibilityLabel: captured.accessibilityLabel, url: captured.url,
      contextID: captured.contextID, pid: captured.pid,
      resolveClickPoint: { [weak self] preferred in
        guard let self, let window, window.frame == context.frontWindowFrame,
          let current = HintWindowSnapshot.current(
            pid: context.processID, primaryHeight: primaryHeight),
          current.number == window.number, current.layer == window.layer
        else { return nil }
        let currentContext = AppContext(
          bundleIdentifier: context.bundleIdentifier, processID: context.processID,
          runningApp: context.runningApp, frontWindowFrame: current.frame,
          allScreensFrame: context.allScreensFrame, displays: context.displays)
        let live = self.discoverTargets(
          context: currentContext, timeout: timeout, resolveAtCommit: false)
        guard
          HintWindowSnapshot.current(
            pid: context.processID, primaryHeight: primaryHeight) == current
        else { return nil }
        return captured.matchingClickPoint(preferred: preferred, among: live)
      },
      isTextInput: captured.isTextInput, priority: captured.priority,
      providerID: captured.providerID)
  }

  /// Live text-grid pull (`text_grid`) for a letter search. Never waits:
  /// `completion` runs once, on the plugin queue with the validated grid or
  /// nil for a timeout or a rejected reply, or at once with nil when the
  /// plugin is not running.
  func textGrid(context: AppContext, completion: @escaping (PluginTextGrid?) -> Void) {
    guard runtimeStateSnapshot() == .running else {
      completion(nil)
      return
    }
    let startedAt = DispatchTime.now()
    sendRequest(
      method: "text_grid",
      params: PluginWireCodec.spatialContextJSON(context),
      timeout: .milliseconds(PluginProtocol.textGridDeadlineMs)
    ) { [weak self] response in
      let payload = PluginWireCodec.okPayload(response)
      let grid = payload.flatMap(PluginWireCodec.textGrid(from:))
      if let self {
        if payload != nil, grid == nil {
          FlashLog.plugin(
            .warn, pluginID: self.manifest.id, message: "[plugin] malformed text_grid reply",
            fields: ["method": "text_grid"])
        }
        if FlashLog.wouldEmit(.debug) {
          FlashLog.debug(
            "[plugin] text_grid",
            fields: [
              "plugin": self.manifest.id,
              "pid": "\(context.processID)",
              "lines": "\(grid?.lines.count ?? 0)",
              "replied": "\(response != nil)",
              "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
            ],
            source: "plugin:\(self.manifest.id)")
        }
      }
      completion(grid)
    }
  }

  func evaluate(
    _ request: QueryEvaluationRequest,
    completion: @escaping ([Candidate]) -> Void
  ) {
    // Query evaluation is an O(memory), CPU-only hot path. App/external state
    // reaches plugins through events and must already be warm.
    guard runtimeStateSnapshot() == .running else {
      DispatchQueue.main.async { completion([]) }
      return
    }
    let params: [String: Any] = ["query": request.text]
    sendRequest(
      method: "evaluate",
      params: params,
      timeout: .milliseconds(Self.queryDeadlineMs)
    ) { [weak self] response in
      guard let self, let payload = PluginWireCodec.okPayload(response),
        Set(payload.keys) == ["ok", "answers"],
        let raw = payload["answers"] as? [[String: Any]]
      else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      let sourceID = "plugin:\(self.manifest.id)"
      guard
        let items = PluginWireCodec.queryAnswers(
          from: raw,
          sourceID: sourceID,
          source: self.manifest.id)
      else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] rejected malformed or oversized answers",
          fields: [
            "received": String(raw.count),
            "answer_limit": String(PluginProtocol.maxAnswers),
          ])
        DispatchQueue.main.async { completion([]) }
        return
      }
      DispatchQueue.main.async { completion(items) }
    }
  }

  // MARK: - Perform (the single effect method)

  /// Dispatch one `perform`. `kind` is one of resolve/command/navigate;
  /// the completion delivers the universal trichotomy on the main
  /// queue. Never dispatched to a failed or unspawnable plugin — that
  /// settles `.unhandled` immediately without burning the deadline (nothing
  /// could have started). On-demand plugins lazily spawn here; the perform
  /// deadline absorbs the startup budget.
  func perform(
    kind: String,
    params: [String: Any],
    timeoutMs: Int? = nil,
    completion: @escaping (PluginPerformOutcome) -> Void
  ) {
    // The interaction that asked travels on the request and comes back with
    // the outcome, which completes inside it.
    let trace = Trace.current
    let mainCompletion: (PluginPerformOutcome) -> Void = { outcome in
      DispatchQueue.main.async { Trace.run(in: trace) { completion(outcome) } }
    }
    guard manifest.exec != nil else {
      mainCompletion(.unhandled)
      return
    }
    queue.async { [weak self] in
      guard let self else {
        mainCompletion(.unhandled)
        return
      }
      let timeoutMs = timeoutMs ?? PluginProtocol.performDeadlineMs
      let route = PluginLifecycle.performRoute(
        state: self.lifecycle.state, onDemand: self.activation == .onDemand)
      switch route {
      case .unhandled:
        mainCompletion(.unhandled)
      case .dispatch:
        self.dispatchPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, trace: trace,
          completion: mainCompletion)
      case .wait:
        // Not yet started, still starting, or between restarts: dispatch
        // once running; the deferral deadline settles `.unhandled` if that
        // never happens.
        self.enqueueDeferredPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, trace: trace,
          completion: mainCompletion)
      case .waitAndActivate:
        self.enqueueDeferredPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, trace: trace,
          completion: mainCompletion)
        self.performActivated = true
        self.applyLifecycle(.activate)
      }
    }
  }

  private func dispatchPerform(
    kind: String,
    params: [String: Any],
    timeoutMs: Int,
    trace: Trace.ID?,
    completion: @escaping (PluginPerformOutcome) -> Void
  ) {
    var wireParams = params
    wireParams["kind"] = kind
    sendRequest(
      method: "perform",
      params: wireParams,
      timeout: .milliseconds(max(1, timeoutMs)),
      trace: trace
    ) { response in
      completion(PluginWireCodec.performOutcome(from: response))
    }
  }

  private func enqueueDeferredPerform(
    kind: String,
    params: [String: Any],
    timeoutMs: Int,
    trace: Trace.ID?,
    completion: @escaping (PluginPerformOutcome) -> Void
  ) {
    guard deferredPerforms.count < PluginProtocol.maxPendingRequests else {
      completion(.unhandled)
      return
    }
    deferredPerformID += 1
    let id = deferredPerformID
    deferredPerforms.append(
      DeferredPerform(
        id: id,
        kind: kind,
        params: params,
        timeoutMs: timeoutMs,
        startedAt: .now(),
        trace: trace,
        completion: completion))
    Self.deadlineQueue.asyncAfter(deadline: .now() + .milliseconds(max(1, timeoutMs))) {
      [weak self] in
      self?.queue.async { [weak self] in
        guard let self,
          let index = self.deferredPerforms.firstIndex(where: { $0.id == id })
        else { return }
        // Still deferred at the deadline: nothing was ever dispatched, so
        // fallback is safe.
        let item = self.deferredPerforms.remove(at: index)
        item.completion(.unhandled)
      }
    }
  }

  /// Runs on `queue`. Settles every not-yet-dispatched perform (park,
  /// unload) — never called on plain restarts, whose deferrals stay queued
  /// for the relaunch.
  private func settleDeferredPerforms(as outcome: PluginPerformOutcome) {
    let deferred = deferredPerforms
    deferredPerforms.removeAll()
    for item in deferred {
      item.completion(outcome)
    }
  }

  // MARK: - Status reads

  /// On `queue`: mirror the queue-confined runtime fields for lock-only reads.
  private func publishRuntimeStatus() {
    let pid = process?.processIdentifier
    let started = startDate
    let restarts = lifecycle.failures.count
    lock.lock()
    publishedPID = pid
    publishedStartDate = started
    publishedRestartCount = restarts
    lock.unlock()
  }

  func statusSnapshot() -> PluginStatus {
    lock.lock()
    let pid = publishedPID
    let startDate = publishedStartDate
    let restartCount = publishedRestartCount
    let segments = statusSegments
    let state = self.state
    let lastError = self.lastError
    let lastLog = self.lastLog
    let activation = manifest.activation(statusObserved: statusObserved)
    lock.unlock()
    let usage = pid.flatMap(Self.resourceUsage)
    return PluginStatus(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      description: manifest.description,
      origin: origin.label,
      root: root.path,
      state: Self.stateLabel(state: state, activation: activation),
      activation: activation.rawValue,
      pid: pid.map(Int.init),
      startedAtUnixMs: startDate.map { Int64($0.timeIntervalSince1970 * 1000) },
      sourceCount: manifest.sources.count,
      commandCount: manifest.pluginCommands.count,
      restartCount: restartCount,
      lastError: lastError,
      lastLog: lastLog,
      cpuTimeMs: usage?.cpuTimeMs,
      memoryBytes: usage?.memoryBytes,
      onlyBundleIDs: manifest.onlyBundleIDs,
      priority: manifest.priority,
      commands: manifest.pluginCommands,
      statusSegments: segments.mapValues(\.debugText))
  }

  /// The status bar's per-publish read: no rusage syscall, no commands copy.
  func statusBarInfo() -> PluginStatusBarInfo {
    lock.lock()
    let segments = statusSegments
    let state = self.state
    let hasError = !(lastError ?? "").isEmpty
    let spawn = publishedSpawn
    lock.unlock()
    return PluginStatusBarInfo(
      id: manifest.id,
      state: Self.stateLabel(state: state, activation: manifest.activation),
      hasError: hasError,
      statusSegments: segments,
      lastSpawn: spawn)
  }

  /// A manifest-only plugin never enters the process state machine; it
  /// reports its activation as a static state instead of a misleading
  /// "stopped".
  private static func stateLabel(
    state: PluginRuntimeState, activation: PluginActivation
  ) -> String {
    activation == .manifestOnly ? PluginActivation.manifestOnly.rawValue : state.rawValue
  }

  /// Cheap lifecycle read for hot-path adapters. Unlike `statusSnapshot`, this
  /// does not sample process CPU/memory or allocate the full diagnostics model.
  func runtimeStateSnapshot() -> PluginRuntimeState {
    lock.lock()
    let state = self.state
    lock.unlock()
    return state
  }

  /// Read the plugin subprocess's resident memory and cumulative CPU time
  /// via `proc_pid_rusage`; nil when the process is gone. macOS-only by
  /// design (the whole plugin runtime is).
  private static func resourceUsage(pid: pid_t) -> (cpuTimeMs: Int, memoryBytes: Int)? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    guard rc == 0 else { return nil }
    let cpuNs = MachTime.nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time)
    return (Int(cpuNs / 1_000_000), Int(info.ri_resident_size))
  }

  // MARK: - Install

  private func requireSandboxExecutable() throws {
    guard FileManager.default.isExecutableFile(atPath: sandboxExecPath) else {
      throw PluginError.failure(
        "required sandbox executable is missing or not executable: \(sandboxExecPath)")
    }
  }

  private func installIfNeeded(
    generation: UInt64, completion: @escaping (Result<Void, Error>) -> Void
  ) throws {
    guard let install = manifest.install else {
      completion(.success(()))
      return
    }
    let stampURL = dataDir.appendingPathComponent(".install-stamp")
    // Data survives checkout replacement, but an install's outputs may live
    // in that checkout. A different pinned root must never borrow its
    // predecessor's success just because its manifest version stayed equal.
    let stamp = try JSONSerialization.data(
      withJSONObject: [
        "root": root.resolvingSymlinksInPath().standardizedFileURL.path,
        "origin": origin.label,
        "version": manifest.version,
        "install": install,
      ], options: [.sortedKeys])
    if let existing = try? Data(contentsOf: stampURL), existing == stamp {
      completion(.success(()))
      return
    }
    try requireSandboxExecutable()
    let argv = [
      sandboxExecPath, "-p",
      PluginSandbox.installSandboxProfile(root: root, dataDir: dataDir), "/bin/sh", "-c", install,
    ]
    installer = try PluginInstallJob(
      argv: argv, environment: pluginEnvironment(), workingDirectory: root.path,
      timeoutSeconds: Double(FlashTunables.pluginInstallTimeoutSeconds), completionQueue: queue
    ) { [weak self] output in
      guard let self, self.lifecycle.generation == generation, self.lifecycle.state == .installing
      else { return }
      self.writePluginInstallLog(
        stdout: output.stdout, stderr: output.stderr, status: output.status)
      guard !output.cancelled, !output.timedOut, output.status == 0 else {
        completion(
          .failure(
            PluginError.failure(
              "install failed status=\(output.status) timed_out=\(output.timedOut)")))
        return
      }
      do {
        try stamp.write(to: stampURL, options: .atomic)
        completion(.success(()))
      } catch { completion(.failure(error)) }
    }
  }

  private func writePluginInstallLog(
    stdout: Data,
    stderr: Data,
    status: Int32
  ) {
    let fm = FileManager.default
    let logsDir = installLogDirectory
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let path = logsDir.appendingPathComponent("\(manifest.id)-\(timestamp).log")
    var body = "# plugin=\(manifest.id) version=\(manifest.version) status=\(status)\n"
    body += "# install=\(manifest.install ?? "<none>")\n"
    body += "# root=\(root.path)\n\n"
    body += "## stdout\n"
    body += (String(data: stdout, encoding: .utf8) ?? "<non-utf8>") + "\n"
    body += "## stderr\n"
    body += (String(data: stderr, encoding: .utf8) ?? "<non-utf8>") + "\n"
    try? body.write(to: path, atomically: true, encoding: .utf8)
  }

  // MARK: - Environment

  /// `settings` serialized to a JSON object string for the plugin's
  /// `FLASH_PLUGIN_CONFIG`. `{}` when there are no settings.
  private var settingsJSON: String {
    let object = settings.mapValues(\.jsonValue)
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  private func pluginEnvironment() -> [String: String] {
    var overrides: [String: String] = [:]
    overrides["FLASH_PLUGIN_ID"] = manifest.id
    overrides["FLASH_PLUGIN_VERSION"] = manifest.version
    overrides["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    overrides["FLASH_PLUGIN_CONFIG"] = settingsJSON
    return Self.sanitizedPluginEnvironment(base: environment.environment, overrides: overrides)
  }

  static func sanitizedPluginEnvironment(
    base: [String: String],
    overrides: [String: String]
  ) -> [String: String] {
    // Runtime plugins get process basics, never the complete login-shell
    // environment (cloud tokens, agent sockets, unrelated app secrets, …).
    // Plugin credentials belong in that plugin's own config table.
    let allowed = [
      "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL",
      "TERM", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING",
    ]
    var environment: [String: String] = [:]
    for key in allowed {
      if let value = base[key] {
        environment[key] = value
      }
    }
    if environment["PATH", default: ""].isEmpty {
      environment["PATH"] = FlashProcessEnvironment.fallbackPath
    }
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }

  static var startupTimeoutSeconds: Int { FlashTunables.pluginStartupTimeoutSeconds }
  // Computed, not a cached `let`: a `static let` snapshots the tunable at
  // first access, so tests (and config reloads) shrinking the timeout after
  // that read would silently see the stale value.
  private static var startupTimeout: DispatchTimeInterval { .seconds(startupTimeoutSeconds) }

  // MARK: - Wire plumbing

  private func sendRequest(
    method: String,
    params: [String: Any],
    timeout: DispatchTimeInterval,
    settleOnStop: Bool = true,
    trace: Trace.ID? = nil,
    completion: (([String: Any]?) -> Void)? = nil
  ) {
    let traceText = trace?.text
    let startedAt = DispatchTime.now()
    let deadline = startedAt + timeout
    transportLock.lock()
    let generation = transportBudget.generation
    transportLock.unlock()
    queue.async { [weak self] in
      guard let self, generation != 0, self.isTransportActive(generation),
        DispatchTime.now() < deadline
      else {
        completion?(nil)
        return
      }
      guard self.pending.count < PluginProtocol.maxPendingRequests else {
        FlashLog.plugin(
          .warn, pluginID: self.manifest.id, message: "[plugin] host request capacity exceeded")
        completion?(nil)
        return
      }
      self.requestID += 1
      let id = self.requestID
      if let completion {
        self.pending[id] = PendingRequest(
          completion: completion,
          settleOnStop: settleOnStop,
          method: method,
          startedAt: startedAt, deadline: deadline, trace: traceText)
        Self.deadlineQueue.asyncAfter(deadline: deadline) { [weak self] in
          self?.queue.async { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
            Self.recordRequest(
              pluginID: self.manifest.id, method: method,
              elapsedMs: Self.elapsedMillisecondsValue(since: startedAt), outcome: "timeout",
              trace: traceText)
            FlashLog.plugin(
              .warn,
              pluginID: self.manifest.id,
              message: "[plugin] request timed out",
              fields: [
                "id": "\(id)",
                "method": method,
                "elapsed_ms": elapsedMs,
              ],
              trace: traceText)
            request.completion(nil)
          }
        }
      }
      var frame: [String: Any] = ["id": id, "method": method, "params": params]
      if let traceText { frame["trace"] = traceText }
      // What is left of the wait, so the plugin can stop a handler whose
      // answer would arrive after it (the SDK's read-only handlers do).
      frame["deadline_ms"] = Self.remainingMilliseconds(until: deadline)
      self.writeFrame(frame)
    }
  }

  /// Whole milliseconds left before `deadline`, at least 1.
  static func remainingMilliseconds(
    until deadline: DispatchTime, now: DispatchTime = .now()
  ) -> Int {
    guard deadline.uptimeNanoseconds > now.uptimeNanoseconds else { return 1 }
    return max(1, Int((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000))
  }

  private func routeHostRequest(id: Int, method: String, params: [String: Any], generation: UInt64)
  {
    guard pendingHostRequests.count < PluginProtocol.maxHostRPCs else {
      sendResponse(
        id: id, result: ["ok": false, "error": PluginProtocol.hostCallCapacityError],
        generation: generation)
      return
    }
    guard let onHostRequest else {
      sendResponse(
        id: id, result: ["ok": false, "error": PluginProtocol.unknownMethodError(method)],
        generation: generation)
      return
    }
    hostRequestToken &+= 1
    let token = hostRequestToken
    pendingHostRequests.insert(token)
    let scope = PluginHostRequestScope { [weak self] in
      self?.isTransportActive(generation) == true
    }
    onHostRequest(method, params, manifest.id, scope) { [weak self] result in
      self?.sendResponse(id: id, result: result, generation: generation, token: token)
    }
  }

  private func sendResponse(
    id: Int, result: [String: Any], generation: UInt64, token: UInt64? = nil
  ) {
    queue.async { [weak self] in
      guard let self, self.isTransportActive(generation) else { return }
      if let token, self.pendingHostRequests.remove(token) == nil { return }
      self.writeFrame(["id": id, "result": result])
    }
  }

  /// Start one transport generation. Reader/writer work from an older child
  /// is ignored after restart, and the collector is reset before the new
  /// process can emit bytes.
  private func beginTransport() -> UInt64 {
    let generation = lifecycle.generation
    transportLock.lock()
    transportBudget.begin(generation)
    outbound = PluginOutboundQueue()
    transportLock.unlock()
    readQueue.sync {
      frameCollector = NDJSONFrameCollector(maxLineBytes: PluginProtocol.maxFrameBytes)
    }
    return generation
  }

  private func invalidateTransport() {
    transportLock.lock()
    transportBudget.begin(0)
    outbound = PluginOutboundQueue()
    transportLock.unlock()
  }

  private func isTransportActive(_ generation: UInt64) -> Bool {
    transportLock.lock()
    defer { transportLock.unlock() }
    return generation != 0 && transportBudget.generation == generation
  }

  private func reserveTransport(_ lane: PluginTransportBudget.Lane, bytes: Int, generation: UInt64)
    -> PluginTransportBudget.Reservation?
  {
    transportLock.lock()
    defer { transportLock.unlock() }
    guard transportBudget.generation == generation else { return nil }
    return transportBudget.reserve(lane, bytes: bytes)
  }

  private func releaseTransport(_ reservation: PluginTransportBudget.Reservation) {
    transportLock.lock()
    transportBudget.release(reservation)
    transportLock.unlock()
  }

  /// Queue one encoded frame without ever blocking the lifecycle queue on a
  /// child that stopped reading stdin. The timeout still includes time spent
  /// in this bounded FIFO. A frame with a `coalescingKey` first retires the
  /// unsent frame it supersedes (see `PluginOutboundQueue`), so a burst of
  /// state signals to a stalled child never exhausts the budget.
  private func enqueueWrite(_ frame: Data, label: String, coalescingKey: String? = nil) {
    guard let handle = stdinPipe?.fileHandleForWriting else {
      transportLock.lock()
      let generation = transportBudget.generation
      transportLock.unlock()
      handleTransportFailureOnQueue(
        generation: generation,
        message: "[plugin] missing IPC stdin (method=\(label))")
      return
    }

    transportLock.lock()
    let generation = transportBudget.generation
    if let coalescingKey, let superseded = outbound.removeSuperseded(by: coalescingKey) {
      transportBudget.release(superseded.reservation)
    }
    guard let reservation = transportBudget.reserve(.writeFrames, bytes: frame.count) else {
      transportLock.unlock()
      handleTransportFailureOnQueue(
        generation: generation, message: "[plugin] IPC write queue overflow (method=\(label))")
      return
    }
    let pendingFrame: PluginOutboundQueue.Frame
    do {
      pendingFrame = try PluginOutboundQueue.Frame(
        data: frame, label: label, coalescingKey: coalescingKey, handle: handle,
        reservation: reservation)
    } catch {
      transportBudget.release(reservation)
      transportLock.unlock()
      handleTransportFailureOnQueue(
        generation: generation,
        message: "[plugin] IPC writer allocation failed (method=\(label))")
      return
    }
    outbound.append(pendingFrame)
    let startDrain = !outboundDraining
    outboundDraining = true
    transportLock.unlock()
    if startDrain {
      writeQueue.async { [weak self] in self?.drainOutbound() }
    }
  }

  /// Write queued frames in order until none is left. Runs on `writeQueue`;
  /// a write blocks only while the child's stdin pipe is full, and frames
  /// queued meanwhile stay replaceable until this loop takes them.
  private func drainOutbound() {
    while true {
      transportLock.lock()
      guard let frame = outbound.popFirst() else {
        outboundDraining = false
        transportLock.unlock()
        return
      }
      transportLock.unlock()
      let generation = frame.reservation.generation
      if isTransportActive(generation) {
        do { try frame.handle.write(contentsOf: frame.data) } catch {
          queue.async { [weak self] in
            self?.handleTransportFailureOnQueue(
              generation: generation, message: "[plugin] IPC write failed (method=\(frame.label))",
              onWrite: true)
          }
        }
      }
      releaseTransport(frame.reservation)
    }
  }

  private func scheduleTransportFailure(generation: UInt64, message: String) {
    transportLock.lock()
    let shouldSchedule = transportBudget.fail(generation: generation)
    transportLock.unlock()
    guard shouldSchedule else { return }
    queue.async { [weak self] in
      self?.handleTransportFailureOnQueue(generation: generation, message: message)
    }
  }

  /// Runs on the lifecycle queue. A broken or saturated stdin makes every
  /// subsequent request unreachable, so recover through the existing bounded
  /// restart state machine instead of dropping individual frames.
  private func handleTransportFailureOnQueue(
    generation: UInt64, message: String, onWrite: Bool = false
  ) {
    guard generation != 0, isTransportActive(generation), process?.isRunning == true else {
      return
    }
    if onWrite, manifest.lifecycle == .publishThenExit {
      // The child ends its run on its own and may be closing stdin as this
      // frame reaches it; its exit status is the verdict, not the write.
      FlashLog.plugin(.debug, pluginID: manifest.id, message: message)
      return
    }
    recordError(message)
    applyLifecycle(.interrupted(lifecycle.generation))
  }

  private func writeFrame(_ object: [String: Any], coalescingKey: String? = nil) {
    let label = object["method"] as? String ?? "response"
    let frame: Data
    do {
      frame = try PluginWireCodec.encodeFrame(object)
    } catch {
      // A non-encodable message is a runtime bug that would otherwise vanish
      // silently and only show up as a timed-out RPC; surface it.
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] dropped non-encodable IPC message (method=\(label)): \(error)")
      return
    }
    guard frame.count - 1 <= PluginProtocol.maxFrameBytes else {
      // An outbound response above the frame cap is replaced by the
      // canonical overflow error under the same id, so the plugin's own
      // pending call settles instead of timing out.
      if let id = object["id"], object["result"] != nil {
        writeFrame([
          "id": id,
          "result": ["ok": false, "error": PluginProtocol.frameOverflowError],
        ])
      } else {
        FlashLog.plugin(
          .warn, pluginID: manifest.id,
          message: "[plugin] dropped oversized IPC message (method=\(label), "
            + "bytes=\(frame.count), max=\(PluginProtocol.maxFrameBytes))")
      }
      return
    }
    enqueueWrite(frame, label: label, coalescingKey: coalescingKey)
  }

  private func handleStdout(_ data: Data, generation: UInt64) {
    guard !data.isEmpty, isTransportActive(generation) else { return }
    guard let reservation = reserveTransport(.readChunks, bytes: data.count, generation: generation)
    else {
      scheduleTransportFailure(generation: generation, message: "[plugin] IPC read queue overflow")
      return
    }
    readQueue.async { [weak self] in
      guard let self else { return }
      defer { self.releaseTransport(reservation) }
      guard self.isTransportActive(generation) else { return }
      for output in self.frameCollector.append(data) {
        switch output {
        case .frame(let line): self.handleFrame(line, generation: generation)
        case .oversized(let bytes):
          FlashLog.plugin(
            .warn, pluginID: self.manifest.id,
            message: "[plugin] dropped oversized IPC line (bytes=\(bytes))")
        }
      }
    }
  }

  private func handleFrame(_ line: Data, generation: UInt64) {
    let object: [String: Any]
    do {
      object = try PluginWireCodec.decodeFrame(line)
    } catch {
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] undecodable IPC frame: \(error)")
      // A malformed reply to a pending request settles that request now
      // instead of leaving its caller to wait out the deadline.
      if let id = PluginWireCodec.responseID(inMalformedFrame: line) {
        queue.async { [weak self] in
          guard let self, self.isTransportActive(generation),
            let request = self.pending.removeValue(forKey: id)
          else { return }
          FlashLog.plugin(
            .warn, pluginID: self.manifest.id,
            message: "[plugin] malformed reply failed its request",
            fields: ["id": "\(id)", "method": request.method])
          request.completion(nil)
        }
      }
      return
    }
    guard let reservation = reserveTransport(.readFrames, bytes: line.count, generation: generation)
    else {
      scheduleTransportFailure(generation: generation, message: "[plugin] IPC frame queue overflow")
      return
    }
    if object["method"] as? String == "publish", object["id"] == nil {
      // Validation and decode leave the reader at once: a reply frame behind
      // this publish must not wait for its rows. The frame's bytes travel
      // along so the byte quota is read off them, never re-encoded.
      let startedAt = DispatchTime.now()
      let sourceID = "plugin:\(manifest.id)"
      let allowedSources = Set(manifest.candidateSources)
      catalogQueue.async { [weak self] in
        guard let self else { return }
        guard self.isTransportActive(generation) else {
          self.releaseTransport(reservation)
          return
        }
        let decoded = PluginWireCodec.publish(
          frame: line, object: object, sourceID: sourceID, allowedSources: allowedSources)
        self.queue.async { [weak self] in
          guard let self else { return }
          defer { self.releaseTransport(reservation) }
          guard self.isTransportActive(generation), self.lifecycle.state == .running else {
            return
          }
          self.lastInboundFrameAt = .now()
          self.applyPublish(decoded, startedAt: startedAt)
        }
      }
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      defer { self.releaseTransport(reservation) }
      guard self.isTransportActive(generation) else { return }
      self.lastInboundFrameAt = .now()
      self.handleProtocolMessage(object, generation: generation)
    }
  }

  private func handleStderr(_ data: Data, generation: UInt64) {
    guard isTransportActive(generation), !data.isEmpty else { return }
    // Drain diagnostics on the pipe callback. Enqueuing them on the lifecycle
    // queue lets a stderr flood retain unbounded data and delay shutdown.
    // Whole lines, each capped, at a bounded rate: a chatty or crashing
    // child can't flood the log.
    let pluginID = manifest.id
    stderrLock.lock()
    let output = stderrLines.append(data, now: DispatchTime.now().uptimeNanoseconds)
    stderrLock.unlock()
    if output.suppressed > 0 {
      FlashLog.plugin(
        .warn, pluginID: pluginID, message: "[plugin] stderr suppressed",
        fields: ["lines": "\(output.suppressed)"])
    }
    for line in output.lines {
      FlashLog.plugin(.warn, pluginID: pluginID, message: "[plugin] stderr: \(line)")
    }
  }

  private func handleProtocolMessage(_ object: [String: Any], generation: UInt64) {
    // An inbound id-without-method frame is always a response to one of our
    // requests; an id+method frame is a plugin→host request; a bare method
    // is a notification.
    if let responseID = PluginJSON.integer(object["id"]), responseID > 0,
      object["method"] == nil
    {
      let result = object["result"] as? [String: Any]
      guard let request = pending.removeValue(forKey: responseID) else {
        // Its deadline already settled the caller (logged as a timeout).
        FlashLog.plugin(
          .debug, pluginID: manifest.id, message: "[plugin] late reply dropped",
          fields: ["id": "\(responseID)"])
        return
      }
      let elapsedMsValue = Self.elapsedMillisecondsValue(since: request.startedAt)
      // Formatted inside the field autoclosures: nothing is built at `info`.
      let elapsedMs = { Self.elapsedMilliseconds(since: request.startedAt) }
      if let deadline = request.deadline, DispatchTime.now() >= deadline {
        FlashLog.plugin(
          .debug, pluginID: manifest.id, message: "[plugin] reply after its deadline",
          fields: ["id": "\(responseID)", "method": request.method, "elapsed_ms": elapsedMs()],
          trace: request.trace)
        Self.recordRequest(
          pluginID: manifest.id, method: request.method, elapsedMs: elapsedMsValue,
          outcome: "late", trace: request.trace)
        request.completion(nil)
        return
      }
      Self.recordRequest(
        pluginID: manifest.id, method: request.method, elapsedMs: elapsedMsValue,
        outcome: result == nil ? "error" : "ok", trace: request.trace)
      // Startup is timed by the launch phases; every other request that
      // takes over a second is worth a line, `perform` included.
      let level: FlashLog.Level =
        elapsedMsValue > 1_000 && request.method != "initialize" ? .warn : .trace
      FlashLog.plugin(
        level, pluginID: manifest.id,
        message: level == .warn ? "[plugin] slow request" : "[plugin] request done",
        fields: [
          "id": "\(responseID)",
          "method": request.method,
          "elapsed_ms": elapsedMs(),
          "ok": result == nil ? "false" : "true",
        ],
        trace: request.trace)
      request.completion(result)
      return
    }
    guard let method = object["method"] as? String else { return }
    let params = object["params"] as? [String: Any] ?? [:]
    if let requestID = PluginJSON.integer(object["id"]), requestID > 0 {
      routeHostRequest(id: requestID, method: method, params: params, generation: generation)
      return
    }
    switch method {
    case "status":
      applyStatusSegments(params)
    case "poll":
      applyPollRegistrations(params)
    case "log":
      let level = FlashLog.Level.parse(params["level"] as? String ?? "info") ?? .info
      let message = params["message"] as? String ?? ""
      let fields = params["fields"] as? [String: String] ?? [:]
      // A line logged while serving a request names that request's
      // interaction; a malformed id is dropped rather than trusted.
      let trace = (params["trace"] as? String).flatMap { Trace.isValid($0) ? $0 : nil }
      lock.lock()
      lastLog = message
      lock.unlock()
      FlashLog.plugin(level, pluginID: manifest.id, message: message, fields: fields, trace: trace)
      // Debug telemetry belongs in the log file, but it must not continually
      // invalidate the status bar and HTTP inspector state.
      if level >= .info {
        notifyStatus()
      }
    default:
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] unknown notification method=\(method)",
        fields: ["method": method])
    }
  }

  /// One `publish` notification, decoded on the catalog queue, handed to the
  /// host store: the whole catalog, or the one source it names. A malformed
  /// or over-quota payload is rejected whole — content-free log — and the
  /// store keeps the previous catalog by construction; so is a source
  /// publish whose merge would exceed the catalog quotas.
  private func applyPublish(_ decoded: PluginWireCodec.DecodedPublish?, startedAt: DispatchTime) {
    guard let decoded else {
      FlashLog.plugin(
        .warn, pluginID: manifest.id, message: "[plugin] rejected malformed or oversized publish")
      return
    }
    let outcome = catalogStore?.publish(pluginID: manifest.id, decoded) ?? .unchanged
    if outcome == .overQuota {
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] rejected publish: merged catalog over quota",
        fields: [
          "source": decoded.source ?? "*", "rows": String(decoded.rows.count),
          "encoded_bytes": String(decoded.encodedBytes),
        ])
      return
    }
    let elapsedMs = Self.elapsedMillisecondsValue(since: startedAt)
    if elapsedMs >= 50 {
      FlashLog.plugin(
        .warn,
        pluginID: manifest.id,
        message: "[plugin] slow catalog publish",
        fields: [
          "elapsed_ms": String(format: "%.2f", elapsedMs),
          "source": decoded.source ?? "*",
          "rows": String(decoded.rows.count),
          "encoded_bytes": String(decoded.encodedBytes),
        ])
    }
  }

  /// One `status` notification. The read-modify-write runs entirely under
  /// `lock`, so two concurrent segment updates can never lose each other.
  /// Internal (not private) so the lost-update regression test can drive it
  /// without a live child process.
  func applyStatusSegments(_ params: [String: Any]) {
    guard let raw = params["segments"] as? [String: Any] else { return }
    let declared = declaredStatusSegments
    guard !declared.isEmpty else { return }
    var decoded: [(key: String, segment: PluginStatusSegment?)] = []
    for (name, value) in raw {
      let key = name.trimmed
      guard declared.contains(key) else { continue }
      switch Self.decodeStatusSegment(value) {
      case .clear: decoded.append((key, nil))
      case .value(let segment): decoded.append((key, segment))
      case .malformed:
        FlashLog.plugin(
          .warn, pluginID: manifest.id,
          message: "[plugin] status segment rejected: expected markup or a carousel object",
          fields: ["segment": key])
      }
    }
    // A notification that restates every segment unchanged wakes nobody:
    // the bar's re-evaluation and host-source reconcile run only for a
    // value, or a stale mark, that actually moved.
    var changed = false
    lock.lock()
    for (key, segment) in decoded {
      if staleStatusSegments.remove(key) != nil { changed = true }
      if let segment {
        if statusSegments[key] != segment {
          statusSegments[key] = segment
          changed = true
        }
      } else if statusSegments.removeValue(forKey: key) != nil {
        changed = true
      }
    }
    lock.unlock()
    if changed { notifyStatus() }
  }

  /// One registration of a `poll` set: a cadence (`every`) or a one-shot
  /// deadline (`after`, from receipt), at the plugin-chosen priority.
  struct PollRegistration: Equatable {
    enum Kind: String {
      case every
      case after
    }
    var kind: Kind
    var ms: Int
    var priority: PollScheduler.Priority
  }

  /// What one new set changes: registrations to (re)arm, names to release,
  /// and the fired deadlines it still lists unchanged.
  struct PollPlan: Equatable {
    var arm: [String: PollRegistration] = [:]
    var release: [String] = []
    var fired: Set<String> = []
  }

  /// A set is the plugin's whole answer. An entry identical to the current
  /// one keeps running — a cadence stays on its grid, a pending deadline
  /// stays pending, and a fired one is not fired again — while a new or
  /// changed entry arms afresh and a dropped one is released.
  static func pollPlan(
    current: [String: PollRegistration], fired: Set<String>, next: [String: PollRegistration]
  ) -> PollPlan {
    var plan = PollPlan()
    plan.release = current.keys.filter { next[$0] == nil }.sorted()
    for (name, registration) in next {
      if current[name] == registration {
        if fired.contains(name) { plan.fired.insert(name) }
      } else {
        plan.arm[name] = registration
      }
    }
    return plan
  }

  /// One `poll` notification: the plugin's complete set of cadences and
  /// deadlines. An empty set cancels its polling entirely; a malformed or
  /// over-bound frame is rejected whole so a typo cannot silently leave a
  /// collector running at the wrong rate.
  func applyPollRegistrations(_ params: [String: Any]) {
    guard let decoded = Self.decodePollRegistrations(params) else {
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] poll registration rejected: expected at most "
          + "\(PluginProtocol.pollMaxRegistrations) {every|after: seconds, priority: "
          + "\(PluginProtocol.pollPriorities.map(\.name).joined(separator: "|"))}")
      return
    }
    lock.lock()
    let plan = Self.pollPlan(
      current: pollRegistrations, fired: firedPollDeadlines, next: decoded)
    pollRegistrations = decoded
    firedPollDeadlines = plan.fired
    for name in plan.release { pollArmings.removeValue(forKey: name) }
    var armed: [(name: String, registration: PollRegistration, arming: UInt64)] = []
    for (name, registration) in plan.arm {
      pollArmingSerial &+= 1
      pollArmings[name] = pollArmingSerial
      armed.append((name, registration, pollArmingSerial))
    }
    lock.unlock()
    for name in plan.release {
      scheduler.unregister(Self.pollClientID(pluginID: manifest.id, name: name))
    }
    for (name, registration, arming) in armed {
      let id = Self.pollClientID(pluginID: manifest.id, name: name)
      let tick: () -> Void = { [weak self] in
        self?.deliverPollTickOnQueue(name: name, arming: arming)
      }
      switch registration.kind {
      case .every:
        scheduler.register(
          id, everyMs: registration.ms, priority: registration.priority, on: queue, handler: tick)
      case .after:
        scheduler.scheduleOnce(
          id, afterMs: registration.ms, priority: registration.priority, on: queue, handler: tick)
      }
    }
    guard !plan.arm.isEmpty || !plan.release.isEmpty else { return }
    FlashLog.plugin(
      .trace, pluginID: manifest.id,
      message: "[plugin] poll registered",
      fields: [
        "registrations": "\(decoded.count)", "armed": "\(plan.arm.count)",
        "released": "\(plan.release.count)",
      ])
  }

  /// Registration names ride inside the event name, so keep them to
  /// characters that cannot be confused with the `core:poll:` prefix.
  static let pollNameAllowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

  static func pollClientID(pluginID: String, name: String) -> String {
    "plugin:\(pluginID):\(name)"
  }

  /// A registration is the subscription, so a tick bypasses `listen` matching
  /// — the plugin asked for exactly this by name. A tick from an arming that
  /// a newer set replaced or dropped is discarded; a deadline's tick marks it
  /// fired, so repeating it unchanged never fires it twice.
  private func deliverPollTickOnQueue(name: String, arming: UInt64) {
    lock.lock()
    let current = pollArmings[name] == arming
    if current, pollRegistrations[name]?.kind == .after { firedPollDeadlines.insert(name) }
    lock.unlock()
    guard current, runtimeStateSnapshot() == .running else { return }
    // The registration name rides in the event name, so a tick needs no
    // payload shape of its own and stays greppable in the logs.
    deliverEventOnQueue(PluginEvent(name: "core:poll:\(name)", payload: [:], bundleID: nil))
  }

  private func cancelPollRegistrations() {
    lock.lock()
    let names = Array(pollRegistrations.keys)
    pollRegistrations.removeAll()
    firedPollDeadlines.removeAll()
    pollArmings.removeAll()
    lock.unlock()
    for name in names {
      scheduler.unregister(Self.pollClientID(pluginID: manifest.id, name: name))
    }
  }

  /// `nil` rejects the frame; an empty dictionary clears every registration.
  static func decodePollRegistrations(_ params: [String: Any]) -> [String: PollRegistration]? {
    guard Set(params.keys) == ["registrations"],
      let raw = params["registrations"] as? [String: Any],
      raw.count <= PluginProtocol.pollMaxRegistrations
    else { return nil }
    var decoded: [String: PollRegistration] = [:]
    for (name, value) in raw {
      guard !name.isEmpty, name.utf8.count <= PluginProtocol.pollMaxNameBytes,
        name.unicodeScalars.allSatisfy({ Self.pollNameAllowed.contains($0) }),
        let entry = value as? [String: Any],
        let priorityName = entry["priority"] as? String,
        let priority = PluginProtocol.pollPriorities.first(where: { $0.name == priorityName })?
          .scheduler
      else { return nil }
      let kinds = entry.keys.filter { $0 != "priority" }
      guard kinds.count == 1, let kind = PollRegistration.Kind(rawValue: kinds[0]),
        let seconds = PluginJSON.number(entry[kind.rawValue]),
        seconds >= 0, seconds <= Double(PluginProtocol.pollMaxSeconds)
      else { return nil }
      let ms = Int((seconds * 1000).rounded())
      // Below the floor a cadence is a busy loop; a deadline may be due now.
      guard kind == .after || ms >= PollScheduler.minimumIntervalMs else { return nil }
      decoded[name] = PollRegistration(kind: kind, ms: ms, priority: priority)
    }
    return decoded
  }

  enum DecodedStatusSegment: Equatable {
    case clear
    case value(PluginStatusSegment)
    case malformed
  }

  /// A segment value is markup (`""` clears) or a carousel object
  /// `{"prefix"?: markup, "lines": [markup], "cycle_seconds": ≥ 1}`; blank
  /// lines are dropped and no lines clears. Anything else is rejected whole.
  static func decodeStatusSegment(_ value: Any) -> DecodedStatusSegment {
    if let text = value as? String {
      let trimmed = text.trimmed
      return trimmed.isEmpty ? .clear : .value(.text(trimmed))
    }
    guard let object = value as? [String: Any],
      let rawLines = object["lines"] as? [Any],
      let seconds = PluginJSON.number(object["cycle_seconds"]), seconds >= 1
    else { return .malformed }
    let prefix: String
    switch object["prefix"] {
    case nil: prefix = ""
    case let text as String: prefix = text
    default: return .malformed
    }
    var lines: [String] = []
    for line in rawLines {
      guard let text = line as? String else { return .malformed }
      let trimmed = text.trimmed
      if !trimmed.isEmpty { lines.append(trimmed) }
    }
    guard !lines.isEmpty else { return .clear }
    return .value(.carousel(prefix: prefix, lines: lines, cycleSeconds: seconds))
  }

  private func setState(_ state: PluginRuntimeState) {
    lock.lock()
    guard self.state != state else {
      lock.unlock()
      return
    }
    self.state = state
    lock.unlock()
    notifyStatus()
  }

  /// Lifecycle failures only (launch, abnormal exit, ping teardown,
  /// initialize failures, write errors, park). Per-request anomalies are
  /// warn-logs, never lastError — a single slow reply must not paint the
  /// plugin red in `:plugins show`.
  /// `.warn` for a failure the lifecycle restarts from; `.error` for one
  /// that parks the plugin until someone acts.
  private func recordError(_ message: String, level: FlashLog.Level = .warn) {
    // Also log: a throwing launch() (e.g. an unresolvable interpreter)
    // otherwise parks the plugin with zero log evidence.
    FlashLog.plugin(level, pluginID: manifest.id, message: message)
    FlashTelemetry.record(.pluginErrors, 1, ["plugin": manifest.id])
    lock.lock()
    lastError = message
    lock.unlock()
    notifyStatus()
  }

  private func clearError() {
    lock.lock()
    lastError = nil
    lock.unlock()
    notifyStatus()
  }

  private func notifyStatus() {
    // Coalesce: a chatty plugin spamming `log` / `status` would otherwise
    // schedule an unbounded number of main-thread callbacks (the
    // tap-starvation class). Collapse bursts to one main hop per runloop
    // turn; `onStatusChanged` re-reads the latest state, so nothing is lost.
    // A dedicated lock (not the state `lock`) so this can never deadlock
    // with a caller that holds `lock` while changing state and then
    // notifies.
    statusNotifyLock.lock()
    if statusNotificationPending {
      statusNotifyLock.unlock()
      return
    }
    statusNotificationPending = true
    statusNotifyLock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.statusNotifyLock.lock()
      self.statusNotificationPending = false
      self.statusNotifyLock.unlock()
      self.onStatusChanged?()
    }
  }

  // MARK: - File watchers

  /// The plugin's own files when `watchFiles`, and always the files its
  /// `watch_settings` name.
  private struct WatchedFileStamp: Equatable {
    var inode: UInt64?
    var size: UInt64?
    var modified: Date?

    init(_ path: URL) {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
      inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
      size = (attributes?[.size] as? NSNumber)?.uint64Value
      modified = attributes?[.modificationDate] as? Date
    }
  }
  private var watchedFileStamps: [URL: WatchedFileStamp] = [:]

  private func watchedSettingChanged() {
    let current = Dictionary(
      uniqueKeysWithValues: watchedFileStamps.keys.map { ($0, WatchedFileStamp($0)) })
    guard current != watchedFileStamps else { return }
    watchedFileStamps = current
    scheduleWatchedFileReload()
  }

  private func installFileWatchers() {
    removeFileWatchers()
    // Root only: `manifest.json` and the `flash-plugin-<id>` binary both live
    // there, and `build-plugins.sh` lands a rebuilt binary as a rename in the
    // root, which a vnode watcher on the directory sees. Watching the whole
    // tree opened one descriptor per directory (hundreds with a stray
    // `target/`) and fired on source edits that change nothing the host loads.
    if watchFiles { watchPath(root) { [weak self] in self?.scheduleFileReload() } }
    // A watched setting's file, and its directory: an editor's atomic save
    // renames a new file into place, and a file that does not exist yet
    // appears there. The reload installs the watchers afresh on the new
    // vnode.
    var directories = Set<String>()
    let watched = Self.watchedSettingPaths(
      names: manifest.watchSettings, settings: settings, root: root,
      home: FileManager.default.homeDirectoryForCurrentUser.path)
    watchedFileStamps = Dictionary(
      uniqueKeysWithValues: Set(watched).map { ($0, WatchedFileStamp($0)) })
    for file in watched {
      watchPath(file) { [weak self] in self?.watchedSettingChanged() }
      let directory = file.deletingLastPathComponent()
      guard directories.insert(directory.path).inserted else { continue }
      watchPath(directory) { [weak self] in self?.watchedSettingChanged() }
    }
  }

  /// The files a plugin's `watch_settings` name: the string settings among
  /// `names`, `~` expanded against `home` and a relative path resolved under
  /// `root`, the child's working directory. Empty and non-string values
  /// name nothing.
  static func watchedSettingPaths(
    names: [String], settings: [String: PluginConfigValue], root: URL, home: String
  ) -> [URL] {
    names.compactMap { name in
      guard case .string(let raw)? = settings[name] else { return nil }
      let path = raw.trimmed
      guard !path.isEmpty else { return nil }
      if path == "~" { return URL(fileURLWithPath: home) }
      if path.hasPrefix("~/") { return URL(fileURLWithPath: home + path.dropFirst(1)) }
      if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
      return root.appendingPathComponent(path)
    }
  }

  private func watchPath(_ url: URL, onEvent: @escaping () -> Void) {
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete, .rename, .extend, .attrib],
      queue: queue)
    source.setEventHandler(handler: onEvent)
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    fileWatchers.append(source)
  }

  /// A file a `watch_settings` setting names changed: the plugin's data can
  /// have changed, so it runs again once the burst settles.
  private func scheduleWatchedFileReload() {
    watchedFileDeadline.arm(afterMs: 300) { [weak self] in
      guard let self, self.lifecycle.state != .stopped else { return }
      self.reload(reason: "watched_file_changed")
    }
  }

  private func removeFileWatchers() {
    for watcher in fileWatchers {
      watcher.cancel()
    }
    fileWatchers.removeAll()
  }

  private func scheduleFileReload() {
    fileReloadDeadline.arm(afterMs: 300) { [weak self] in
      guard let self, self.lifecycle.state != .stopped else { return }
      if let onFilesChanged = self.onFilesChanged {
        onFilesChanged()
      } else {
        self.reload(reason: "plugin_files_changed")
      }
    }
  }

  private static func elapsedMilliseconds(since start: DispatchTime) -> String {
    String(format: "%.2f", elapsedMillisecondsValue(since: start))
  }

  /// A finished request as telemetry: its round trip, and a span inside
  /// the interaction it served. Content-free: plugin id, method, outcome.
  private static func recordRequest(
    pluginID: String, method: String, elapsedMs: Double, outcome: String, trace: String?
  ) {
    guard FlashTelemetry.current != nil else { return }
    let attributes = ["plugin": pluginID, "method": method, "outcome": outcome]
    FlashTelemetry.record(.pluginRequestDuration, elapsedMs, attributes)
    let end = ProcessInfo.processInfo.systemUptime
    FlashTelemetry.span(
      "plugin \(method)", trace: trace, startUptime: end - elapsedMs / 1000, endUptime: end,
      attributes: attributes, failed: outcome != "ok")
  }

  private static func elapsedMillisecondsValue(since start: DispatchTime) -> Double {
    let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Double(nanos) / 1_000_000
  }
}

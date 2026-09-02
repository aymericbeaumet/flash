import AppKit
import Darwin
import FlashCore
import Foundation

/// One managed plugin child process speaking the NDJSON wire protocol
/// (protocol v1 — see Plugins/_flash_plugin_specs/protocol.json).
///
/// Lifecycle: stopped → installing → launching → running → stopped, with
/// `failed` the parked terminal state (no auto-restart; file watchers stay
/// armed so a rebuilt binary recovers). Resident plugins spawn at startup;
/// on-demand plugins spawn on their first `perform`; manifest-only plugins
/// never spawn.
final class PluginProcess {
  typealias RequestCompletion = ([String: Any]?) -> Void
  struct PendingRequest {
    let completion: RequestCompletion
    let settleOnStop: Bool
    let method: String
    let startedAt: DispatchTime

    init(
      completion: @escaping RequestCompletion,
      settleOnStop: Bool,
      method: String = "test",
      startedAt: DispatchTime = .now()
    ) {
      self.completion = completion
      self.settleOnStop = settleOnStop
      self.method = method
      self.startedAt = startedAt
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
    let completion: (PluginPerformOutcome) -> Void
  }

  let root: URL
  let manifest: PluginManifest
  let origin: PluginOrigin
  private let listenPatterns: [PluginPattern]

  private let queue: DispatchQueue
  private let readQueue: DispatchQueue
  private let writeQueue: DispatchQueue
  private let dataDir: URL
  private var process: Process?
  private var stdinPipe: Pipe?
  private var frameCollector = NDJSONFrameCollector(maxLineBytes: PluginProtocol.maxFrameBytes)
  private let transportLock = NSLock()
  private var nextTransportGeneration: UInt64 = 0
  private var activeTransportGeneration: UInt64 = 0
  private var bufferedWriteFrames = 0
  private var bufferedWriteBytes = 0
  private let lock = NSLock()
  private var state: PluginRuntimeState = .stopped
  /// Runtime status-bar segments, merged under `lock` on every `status`
  /// notification so concurrent updates can never lose each other.
  private var statusSegments: [String: String] = [:]
  private var startDate: Date?
  private var restartCount = 0
  /// Guards `notifyStatus` so a burst of status changes collapses to one
  /// main-thread callback per runloop turn instead of one hop per change.
  private var statusNotificationPending = false
  private let statusNotifyLock = NSLock()
  /// Timestamps of recent restart attempts. Bounded restart loop: if
  /// `restartWindowAttempts` restarts happen within `restartWindowSeconds`,
  /// the plugin is parked in `.failed` and stops auto-restarting. The user
  /// can recover with `:plugins reload`.
  private var restartTimestamps: [Date] = []
  // Testability seams: production values, overridden (and restored) by the
  // lifecycle tests so restart parking and idle-ping teardown run in
  // milliseconds instead of minutes. `var` + internal on purpose.
  static var restartWindowAttempts = 5
  static var restartWindowSeconds: TimeInterval = 300
  static var idleBeforePingMs = PluginProtocol.idleBeforePingMs
  static var pingTimeoutMs = PluginProtocol.pingDeadlineMs
  static var restartDelaySeconds: (Int) -> Int = { min(30, max(1, $0 + 1)) }
  private static let deadlineQueue = DispatchQueue(
    label: "flash.plugin.deadlines", qos: .utility)
  private static let maxBufferedWriteFrames = 256
  private static let maxBufferedWriteBytes = PluginProtocol.maxFrameBytes * 2
  private var requestID: Int = 0
  private var pending: [Int: PendingRequest] = [:]
  private var deferredPerforms: [DeferredPerform] = []
  private var deferredPerformID = 0
  /// Uptime of the most recent inbound frame — any frame resets the idle
  /// clock, so a plugin that publishes or logs is never pinged.
  private var lastInboundFrameAt = DispatchTime.now()
  private var idlePingWork: DispatchWorkItem?
  private var fileWatchers: [DispatchSourceFileSystemObject] = []
  private var reloadWork: DispatchWorkItem?
  private var lastError: String?
  private var lastLog: String?
  /// Previous CPU sample (cumulative user+system nanoseconds and the wall
  /// clock at which it was read) so `statusSnapshot` can derive an
  /// instantaneous CPU percentage from the delta between two reads.
  private var lastCPUSample: (totalNs: UInt64, at: Date)?
  /// Mirrors `Config.Plugins.watchingEnabled`. When false, plugin file
  /// watchers are not installed and the plugin only restarts when
  /// content changes propagate via an explicit `:plugins reload`.
  private var watchFiles: Bool
  /// User settings from `[plugin.<id>]`, delivered to the plugin process
  /// as JSON via `FLASH_PLUGIN_CONFIG`. Retained so a config reload can
  /// tell whether this plugin's settings changed.
  let settings: [String: PluginConfigValue]
  var onStatusChanged: (() -> Void)?
  /// Host-owned catalog store validated `publish` notifications land in.
  /// Set by PluginManager; entries are dropped on `failed` park and unload,
  /// never on plain restarts.
  var catalogStore: PluginCatalogStore?
  /// Supplies the host's current running-applications snapshot for the one
  /// `core:apps.changed` event delivered right after initialize (the
  /// snapshot no longer rides initialize itself).
  var runningApplicationsProvider: (() -> [[String: Any]])?
  /// Handles a plugin→host RPC request (`call_host` on the plugin side):
  /// `(method, params, pluginID, reply)`. The host RPC router (PluginManager)
  /// installs this; `reply` is invoked with the JSON result, possibly async
  /// (e.g. AX work hops to the main thread first).
  var onHostRequest: ((String, [String: Any], String, @escaping ([String: Any]) -> Void) -> Void)?

  init(
    root: URL,
    manifest: PluginManifest,
    origin: PluginOrigin,
    baseDataDir: URL,
    watchFiles: Bool = true,
    settings: [String: PluginConfigValue] = [:]
  ) {
    self.root = root
    self.manifest = manifest
    self.origin = origin
    self.listenPatterns = manifest.listen.map(PluginPattern.init)
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.readQueue = DispatchQueue(label: "flash.plugin.\(manifest.id).read", qos: .utility)
    self.writeQueue = DispatchQueue(label: "flash.plugin.\(manifest.id).write", qos: .utility)
    self.watchFiles = watchFiles
    self.settings = settings
  }

  var identifier: String { manifest.id }

  // MARK: - Lifecycle

  func start() {
    queue.async {
      switch self.manifest.activation {
      case .resident:
        self.startOnQueue(reason: "start")
      case .onDemand, .manifestOnly:
        // No child yet: on-demand plugins spawn on their first perform;
        // manifest-only plugins never spawn. File watchers still arm so
        // manifest/binary edits hot-reload.
        if self.watchFiles {
          self.installFileWatchers()
        }
        FlashLog.plugin(
          .info, pluginID: self.manifest.id,
          message: "[plugin] \(self.manifest.activation.rawValue) registered")
      }
    }
  }

  func stopAndWait(reason: String = "stop") {
    queue.sync {
      self.settleDeferredPerforms(as: .unhandled)
      self.stopOnQueue(reason: reason)
    }
  }

  func reload(reason: String) {
    queue.async {
      // User-initiated reload re-arms the bounded restart loop so a previously
      // parked plugin can recover without restarting the resident process.
      self.restartTimestamps.removeAll()
      self.restartCount = 0
      self.stopOnQueue(reason: reason)
      switch self.manifest.activation {
      case .resident:
        self.startOnQueue(reason: reason)
      case .onDemand, .manifestOnly:
        if self.watchFiles {
          self.installFileWatchers()
        }
      }
    }
  }

  private func startOnQueue(reason: String) {
    stopOnQueue(reason: "pre_start")
    guard manifest.exec != nil else { return }
    let startupStartedAt = DispatchTime.now()
    setState(.installing)
    do {
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      try installIfNeeded()
      let installMs = Self.elapsedMilliseconds(since: startupStartedAt)
      setState(.launching)
      try launch(startupStartedAt: startupStartedAt, installMs: installMs)
      if watchFiles {
        installFileWatchers()
      }
      FlashLog.plugin(.info, pluginID: manifest.id, message: "[plugin] started reason=\(reason)")
    } catch {
      recordError("[plugin] start failed: \(error)")
      setState(.stopped)
      scheduleRestart()
    }
  }

  /// Shutdown contract: there is no shutdown method. Closing stdin IS the
  /// signal — the plugin runs cleanup and exits 0. `shutdown_grace` later
  /// comes SIGTERM, and +0.5 s after that SIGKILL.
  private func stopOnQueue(reason: String) {
    // Remove every callback before invoking any of them. A completion can
    // enqueue another plugin request, so iterating the live dictionary would
    // be reentrant and could strand or double-complete work.
    let abandonedCallbacks = Self.takePendingCallbacks(&pending)
    idlePingWork?.cancel()
    idlePingWork = nil
    removeFileWatchers()
    invalidateTransport()
    if let process, process.isRunning {
      stdinPipe?.fileHandleForWriting.closeFile()
      waitForExit(process, timeout: Double(PluginProtocol.shutdownGraceMs) / 1_000)
      if process.isRunning {
        process.terminate()
        waitForExit(process, timeout: 0.5)
      }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    process = nil
    stdinPipe = nil
    startDate = nil
    // Segments are live state (unlike catalogs): cleared on any teardown.
    lock.lock()
    statusSegments.removeAll()
    lock.unlock()
    setState(.stopped)
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
    // Run the plugin under its resolved seatbelt profile. sandbox-exec execs
    // in place, so the pid we track and the child flash-plugin binary are
    // unchanged.
    let sandboxStartedAt = DispatchTime.now()
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest, settings: settings, root: root, dataDir: dataDir,
      executablePath: executablePath)
    let sandboxMs = Self.elapsedMilliseconds(since: sandboxStartedAt)
    let sandboxed =
      resolved.profile != nil
      && FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath)
    if sandboxed, let profile = resolved.profile {
      process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
      process.arguments = ["-p", profile, executablePath] + execTail
    } else {
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = execTail
    }
    if resolved.mode == "disabled_by_config" {
      FlashLog.warn(
        "[plugin] \(manifest.id) sandbox DISABLED by [plugin.\(manifest.id)] sandbox = false",
        fields: ["plugin": manifest.id, "sandbox_mode": resolved.mode])
    }
    FlashLog.info(
      "[plugin] \(manifest.id) launch sandbox=\(sandboxed ? resolved.mode : "unsandboxed")",
      fields: ["plugin": manifest.id, "sandbox_mode": sandboxed ? resolved.mode : "unsandboxed"])
    process.currentDirectoryURL = root
    process.environment = pluginEnvironment()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let transportGeneration = beginTransport()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleStdout(handle.availableData, generation: transportGeneration)
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleStderr(handle.availableData)
    }
    process.terminationHandler = { [weak self] p in
      self?.queue.async {
        guard let self, self.process === p else { return }
        self.recordError("[plugin] exited status=\(p.terminationStatus)")
        self.stopOnQueue(reason: "exit")
        self.scheduleRestart()
      }
    }
    let spawnStartedAt = DispatchTime.now()
    do {
      try process.run()
    } catch {
      invalidateTransport()
      throw PluginError.failure("\(error)")
    }
    let spawnMs = Self.elapsedMilliseconds(since: spawnStartedAt)
    self.process = process
    self.stdinPipe = stdin
    self.startDate = Date()
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
        self.stopOnQueue(reason: "startup_timeout")
        self.scheduleRestart()
        return
      }
      guard PluginWireCodec.acceptsProtocolVersion(response) else {
        let reported = PluginWireCodec.protocolVersionValue(response).map(String.init) ?? "missing"
        self.parkFailed(
          "[plugin] protocol_version \(reported) != host v\(PluginProtocol.version)")
        return
      }
      guard response["ok"] as? Bool == true else {
        let error = response["error"] as? String ?? "plugin rejected initialize"
        self.parkFailed("[plugin] initialize failed: \(error)")
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
    setState(.running)
    // Successful startup resets the backoff counter so a transient crash
    // doesn't accumulate across hours of healthy operation.
    restartCount = 0
    restartTimestamps.removeAll()
    // The running-applications snapshot no longer rides initialize: plugins
    // whose `listen` matches get exactly one core:apps.changed with the full
    // snapshot, then live updates through the normal event stream.
    if let snapshot = runningApplicationsProvider?() {
      deliverEventOnQueue(
        PluginEvent(
          name: "core:apps.changed",
          payload: [
            "reason": "initialize",
            "running_applications": snapshot,
          ],
          bundleID: nil))
    }
    armIdlePing()
    let deferred = deferredPerforms
    deferredPerforms.removeAll()
    for item in deferred {
      let elapsedMs = Int(Self.elapsedMillisecondsValue(since: item.startedAt))
      dispatchPerform(
        kind: item.kind,
        params: item.params,
        timeoutMs: max(1, item.timeoutMs - elapsedMs),
        completion: item.completion)
    }
  }

  /// Terminal park: no auto-restart. Used for initialize NAKs and protocol
  /// mismatches — relaunching the same binary cannot recover. File watchers
  /// re-arm so a REBUILT binary (the dev hot loop) recovers without
  /// `:plugins reload`; the published catalog is dropped (a failed plugin
  /// could never serve its rows' effects).
  private func parkFailed(_ message: String) {
    recordError(message)
    FlashLog.plugin(.error, pluginID: manifest.id, message: message)
    settleDeferredPerforms(as: .unhandled)
    stopOnQueue(reason: "park")
    setState(.failed)
    catalogStore?.drop(pluginID: manifest.id)
    if watchFiles {
      installFileWatchers()
    }
  }

  private func scheduleRestart() {
    let now = Date()
    let windowStart = now.addingTimeInterval(-Self.restartWindowSeconds)
    restartTimestamps.removeAll(where: { $0 < windowStart })
    restartTimestamps.append(now)
    if restartTimestamps.count > Self.restartWindowAttempts {
      parkFailed(
        "[plugin] restart loop exhausted: \(restartTimestamps.count) restarts "
          + "within \(Int(Self.restartWindowSeconds))s — parking in .failed. "
          + "Run :plugins reload (or change a plugin file) to retry.")
      return
    }
    let delay = Self.restartDelaySeconds(restartCount)
    restartCount += 1
    queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
      guard let self, self.runtimeStateSnapshot() != .failed else { return }
      self.startOnQueue(reason: "restart")
    }
  }

  // MARK: - Idle ping

  /// The one residual liveness probe: after `idleBeforePingMs` of inbound
  /// silence with nothing in flight, send `ping`; one missed reply tears
  /// down and restarts. Any inbound frame resets the clock, and pending
  /// requests suppress it — a blocking single-threaded plugin is fully
  /// conformant.
  private func armIdlePing(afterMs: Int? = nil) {
    idlePingWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.idlePingTick()
    }
    idlePingWork = work
    queue.asyncAfter(
      deadline: .now() + .milliseconds(afterMs ?? Self.idleBeforePingMs), execute: work)
  }

  private func idlePingTick() {
    guard runtimeStateSnapshot() == .running, process?.isRunning == true else { return }
    let idleMs = Int(Self.elapsedMillisecondsValue(since: lastInboundFrameAt))
    guard pending.isEmpty, idleMs >= Self.idleBeforePingMs else {
      armIdlePing(afterMs: max(1, Self.idleBeforePingMs - idleMs))
      return
    }
    sendRequest(
      method: "ping",
      params: [:],
      timeout: .milliseconds(Self.pingTimeoutMs),
      settleOnStop: false
    ) { [weak self] response in
      guard let self, self.runtimeStateSnapshot() == .running else { return }
      guard PluginWireCodec.okPayload(response) != nil else {
        self.recordError("[plugin] ping missed — restarting")
        self.stopOnQueue(reason: "ping")
        self.scheduleRestart()
        return
      }
      self.armIdlePing()
    }
  }

  // MARK: - Events

  func sendEvent(_ event: PluginEvent) {
    guard listenPatterns.contains(where: { $0.matches(event.name) }) else { return }
    // Default-deny capability gate. Events that carry sensitive data
    // (clipboard text, etc.) reach a plugin only when its manifest
    // explicitly opts in via `capabilities`.
    if let required = PluginCapability.required(for: event.name),
      !manifest.capabilities.contains(required)
    {
      return
    }
    queue.async { [weak self] in
      guard let self, self.runtimeStateSnapshot() == .running else { return }
      self.deliverEventOnQueue(event)
    }
  }

  private func deliverEventOnQueue(_ event: PluginEvent) {
    var payload = event.payload
    if let bundleID = event.bundleID, payload["bundle_id"] == nil {
      payload["bundle_id"] = bundleID
    }
    if let pid = event.pid, payload["pid"] == nil {
      payload["pid"] = Int(pid)
    }
    if let frame = event.frontWindowFrame, !frame.isNull,
      payload["front_window_frame"] == nil
    {
      payload["front_window_frame"] = [
        "x": frame.minX,
        "y": frame.minY,
        "width": frame.width,
        "height": frame.height,
      ]
    }
    writeFrame([
      "method": "event",
      "params": [
        "name": event.name,
        "payload": payload,
      ],
    ])
  }

  // MARK: - Host → plugin requests

  /// Live hint pull (`hints`). Always a fresh request — there is no cached
  /// discovery. Blocks the caller up to `timeout` and returns `[]` for a
  /// missing/rejected/mismatched reply.
  func discoverTargets(context: AppContext, timeout: TimeInterval) -> [JumpTarget] {
    guard runtimeStateSnapshot() == .running else { return [] }
    let startedAt = DispatchTime.now()
    let semaphore = DispatchSemaphore(value: 0)
    var targets: [JumpTarget] = []
    let params: [String: Any] = [
      "bundle_id": context.bundleIdentifier,
      "pid": Int(context.processID),
      "front_window_frame": [
        "x": context.frontWindowFrame.minX,
        "y": context.frontWindowFrame.minY,
        "width": context.frontWindowFrame.width,
        "height": context.frontWindowFrame.height,
      ],
    ]
    sendRequest(
      method: "hints",
      params: params,
      timeout: .milliseconds(Int((timeout * 1_000).rounded()))
    ) { [weak self] response in
      defer { semaphore.signal() }
      guard let self, let payload = PluginWireCodec.okPayload(response) else { return }
      let contextPID = (payload["context_pid"] as? Int).map(pid_t.init) ?? context.processID
      guard contextPID == context.processID else { return }
      let sourceID = "plugin:\(self.manifest.id)"
      targets = (payload["targets"] as? [[String: Any]] ?? [])
        .compactMap { PluginWireCodec.target(from: $0, sourceID: sourceID) }
        .map { self.hostJumpTarget(from: $0, contextPID: context.processID) }
    }
    let waitResult = semaphore.wait(timeout: .now() + timeout)
    if FlashLog.wouldEmit(.debug) {
      FlashLog.debug(
        "[plugin] hints",
        fields: [
          "plugin": manifest.id,
          "pid": "\(context.processID)",
          "bundle": context.bundleIdentifier,
          "targets": "\(targets.count)",
          "timed_out": "\(waitResult == .timedOut)",
          "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
        ],
        source: "plugin:\(manifest.id)")
    }
    return targets
  }

  /// Materialise a wire-format target as host-owned geometry and semantics.
  /// Hint activation is never delegated back to the plugin: the host posts a
  /// real mouse event to the owning app for every committed target.
  private func hostJumpTarget(
    from wire: PluginWireTarget, contextPID: pid_t
  ) -> JumpTarget {
    return JumpTarget(
      id: wire.id,
      frame: wire.frame,
      role: wire.role,
      accessibilityLabel: wire.label,
      url: wire.url,
      pid: wire.pid ?? contextPID,
      entersInsertMode: wire.entersInsertMode,
      priority: wire.priority,
      providerID: wire.sourceID)
  }

  /// `search`: fetch live rows for one explicitly scoped query. Unlike
  /// `evaluate` (50 ms, CPU-only), a live source may do real work (mdfind,
  /// window enumeration); the caller's aggregator drops late replies. Rows
  /// decode through the same catalog codec as `publish`.
  func search(
    matching text: String,
    scope: CandidateScope,
    timeoutMs: Int,
    completion: @escaping ([Candidate]?) -> Void
  ) {
    guard runtimeStateSnapshot() == .running else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    sendRequest(
      method: "search",
      params: ["query": text, "scope": Self.scopeName(scope)],
      timeout: .milliseconds(timeoutMs)
    ) { [weak self] response in
      guard let self, let payload = PluginWireCodec.okPayload(response) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      guard let raw = payload["rows"] as? [[String: Any]] else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] malformed search reply",
          fields: ["method": "search"])
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let rows = PluginWireCodec.catalogRows(
        from: raw,
        sourceID: "plugin:\(self.manifest.id)",
        allowedSources: Set(self.manifest.candidateSources))?.rows
      if rows == nil {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] rejected malformed or oversized search rows",
          fields: ["received": String(raw.count)])
      }
      DispatchQueue.main.async { completion(rows) }
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
    let params: [String: Any] = [
      "query": request.text,
      "scope": Self.scopeName(request.scope),
      "surface": request.surface.rawValue,
    ]
    sendRequest(
      method: "evaluate",
      params: params,
      timeout: .milliseconds(PluginProtocol.queryDeadlineMs)
    ) { [weak self] response in
      guard let self, let payload = PluginWireCodec.okPayload(response),
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

  /// Dispatch one `perform`. `kind` is one of resolve/command/action/
  /// navigate; the completion delivers the universal trichotomy on the main
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
    let mainCompletion: (PluginPerformOutcome) -> Void = { outcome in
      DispatchQueue.main.async { completion(outcome) }
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
      switch self.runtimeStateSnapshot() {
      case .failed:
        mainCompletion(.unhandled)
      case .running:
        self.dispatchPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, completion: mainCompletion)
      case .stopped where self.manifest.activation == .onDemand && self.process == nil:
        self.enqueueDeferredPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, completion: mainCompletion)
        self.startOnQueue(reason: "on_demand")
      case .stopped, .installing, .launching:
        // A resident plugin still starting (or between restarts): dispatch
        // once running; the deferral deadline settles `.unhandled` if that
        // never happens.
        self.enqueueDeferredPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, completion: mainCompletion)
      }
    }
  }

  private func dispatchPerform(
    kind: String,
    params: [String: Any],
    timeoutMs: Int,
    completion: @escaping (PluginPerformOutcome) -> Void
  ) {
    var wireParams = params
    wireParams["kind"] = kind
    sendRequest(
      method: "perform",
      params: wireParams,
      timeout: .milliseconds(max(1, timeoutMs))
    ) { response in
      completion(PluginWireCodec.performOutcome(from: response))
    }
  }

  private func enqueueDeferredPerform(
    kind: String,
    params: [String: Any],
    timeoutMs: Int,
    completion: @escaping (PluginPerformOutcome) -> Void
  ) {
    deferredPerformID += 1
    let id = deferredPerformID
    deferredPerforms.append(
      DeferredPerform(
        id: id,
        kind: kind,
        params: params,
        timeoutMs: timeoutMs,
        startedAt: .now(),
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

  private static func scopeName(_ scope: CandidateScope) -> String {
    switch scope {
    case .running: return "running"
    case .all: return "all"
    }
  }

  // MARK: - Status reads

  func statusSnapshot() -> PluginStatus {
    // `process`/`startDate`/`restartCount` are queue-confined; hop onto the
    // queue (the same manager→process direction stopAndWait uses) instead of
    // racing them under `lock`, which guards state/segments/lastError/lastLog.
    let (pid, startDate, restartCount) = queue.sync {
      (process?.processIdentifier, self.startDate, self.restartCount)
    }
    lock.lock()
    let segments = statusSegments
    let state = self.state
    let lastError = self.lastError
    let lastLog = self.lastLog
    let now = Date()
    let usage = pid.map { sampleResourceUsageLocked(pid: $0, now: now) }
    lock.unlock()
    let activation = manifest.activation
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
      uptimeMs: startDate.map { Int(now.timeIntervalSince($0) * 1000) },
      sourceCount: manifest.sources.count,
      commandCount: manifest.commands.count,
      restartCount: restartCount,
      lastError: lastError,
      lastLog: lastLog,
      cpuPercent: usage?.cpuPercent ?? nil,
      memoryBytes: usage?.memoryBytes ?? nil,
      onlyBundleIDs: manifest.onlyBundleIDs,
      priority: manifest.priority,
      commands: manifest.commands,
      statusSegments: segments)
  }

  /// The status bar's per-publish read: no rusage syscall, no commands copy.
  func statusBarInfo() -> PluginStatusBarInfo {
    lock.lock()
    let segments = statusSegments
    let state = self.state
    let hasError = !(lastError ?? "").isEmpty
    lock.unlock()
    return PluginStatusBarInfo(
      id: manifest.id,
      state: Self.stateLabel(state: state, activation: manifest.activation),
      hasError: hasError,
      statusSegments: segments)
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

  /// Read the plugin subprocess's resident memory and CPU time via
  /// `proc_pid_rusage`, deriving an instantaneous CPU percentage from the
  /// delta against the previous sample. Mutates `lastCPUSample`, so the
  /// caller must already hold `lock`. macOS-only by design (the whole
  /// plugin runtime is).
  private func sampleResourceUsageLocked(
    pid: pid_t, now: Date
  ) -> (cpuPercent: Double?, memoryBytes: Int?) {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    guard rc == 0 else {
      lastCPUSample = nil
      return (nil, nil)
    }
    let memoryBytes = Int(info.ri_resident_size)
    let totalNs = info.ri_user_time &+ info.ri_system_time
    var cpuPercent: Double?
    if let previous = lastCPUSample {
      let elapsed = now.timeIntervalSince(previous.at)
      if elapsed > 0, totalNs >= previous.totalNs {
        let busyNs = Double(totalNs - previous.totalNs)
        cpuPercent = (busyNs / (elapsed * 1_000_000_000)) * 100
      }
    }
    lastCPUSample = (totalNs, now)
    return (cpuPercent, memoryBytes)
  }

  // MARK: - Install

  private func installIfNeeded() throws {
    // Official plugins ship prebuilt and declare no install step; only
    // third-party manifests may, and theirs runs sandboxed.
    guard let install = manifest.install else { return }
    let stampURL = dataDir.appendingPathComponent(".install-stamp")
    let stamp = "\(manifest.version)\n\(install)\n"
    if let existing = try? String(contentsOf: stampURL), existing == stamp {
      return
    }
    let process = Process()
    let sandboxed = FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath)
    if sandboxed {
      process.executableURL = URL(fileURLWithPath: PluginSandbox.sandboxExecPath)
      process.arguments = [
        "-p", PluginSandbox.installSandboxProfile(root: root, dataDir: dataDir), "/bin/sh", "-lc",
        install,
      ]
    } else {
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-lc", install]
    }
    FlashLog.info(
      "[plugin] \(manifest.id) install sandbox=\(sandboxed)",
      fields: ["plugin": manifest.id, "install_sandboxed": "\(sandboxed)"])
    process.currentDirectoryURL = root
    process.environment = pluginEnvironment()
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Bound a hung install script (network stall, interactive `read`, a wedged
    // build) so it can't pin this plugin's serial queue forever — stop runs on
    // that queue. Mirrors PluginManager.runGit's kill pattern.
    let killer = DispatchQueue.global(qos: .utility)
    let killWork = DispatchWorkItem {
      if process.isRunning { process.terminate() }
    }
    killer.asyncAfter(
      deadline: .now() + .seconds(FlashTunables.pluginInstallTimeoutSeconds),
      execute: killWork)
    process.waitUntilExit()
    killWork.cancel()
    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
    // Persist the install script's output even on success. Third-party
    // plugin `install` strings run as `/bin/sh -lc <attacker-controllable>`
    // — when an incident comes to light later, the diagnostics need to be
    // on disk to figure out what the script actually did. Best-effort:
    // failures here don't block the install path.
    writePluginInstallLog(
      stdout: stdoutData,
      stderr: stderrData,
      status: process.terminationStatus)
    if process.terminationStatus != 0 {
      let message = String(data: stderrData, encoding: .utf8)?
        .trimmed
      throw PluginError.failure(
        "install failed status=\(process.terminationStatus) \(message ?? "")")
    }
    try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
  }

  private func writePluginInstallLog(
    stdout: Data,
    stderr: Data,
    status: Int32
  ) {
    let fm = FileManager.default
    let logsDir = fm.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Flash/plugin-install")
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
    overrides["FLASH_PLUGIN_PARENT_PID"] = String(getpid())
    return Self.sanitizedPluginEnvironment(
      base: FlashProcessEnvironment.shared.environment,
      overrides: overrides)
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

  private func waitForExit(_ process: Process, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
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
    completion: (([String: Any]?) -> Void)? = nil
  ) {
    let startedAt = DispatchTime.now()
    queue.async { [weak self] in
      guard let self else { return }
      self.requestID += 1
      let id = self.requestID
      if let completion {
        self.pending[id] = PendingRequest(
          completion: completion,
          settleOnStop: settleOnStop,
          method: method,
          startedAt: startedAt)
        Self.deadlineQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
          self?.queue.async { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
            FlashLog.plugin(
              .warn,
              pluginID: self.manifest.id,
              message: "[plugin] request timed out method=\(method) elapsed_ms=\(elapsedMs)",
              fields: [
                "method": method,
                "elapsed_ms": elapsedMs,
              ])
            request.completion(nil)
          }
        }
      }
      self.writeFrame([
        "id": id,
        "method": method,
        "params": params,
      ])
    }
  }

  private func routeHostRequest(id: Int, method: String, params: [String: Any]) {
    guard let onHostRequest else {
      sendResponse(
        id: id,
        result: ["ok": false, "error": PluginProtocol.unknownMethodError(method)])
      return
    }
    onHostRequest(method, params, manifest.id) { [weak self] result in
      self?.sendResponse(id: id, result: result)
    }
  }

  private func sendResponse(id: Int, result: [String: Any]) {
    queue.async { [weak self] in
      self?.writeFrame([
        "id": id,
        "result": result,
      ])
    }
  }

  /// Start one transport generation. Reader/writer work from an older child
  /// is ignored after restart, and the collector is reset before the new
  /// process can emit bytes.
  private func beginTransport() -> UInt64 {
    nextTransportGeneration &+= 1
    let generation = nextTransportGeneration
    transportLock.lock()
    activeTransportGeneration = generation
    bufferedWriteFrames = 0
    bufferedWriteBytes = 0
    transportLock.unlock()
    readQueue.sync {
      frameCollector = NDJSONFrameCollector(maxLineBytes: PluginProtocol.maxFrameBytes)
    }
    return generation
  }

  private func invalidateTransport() {
    transportLock.lock()
    activeTransportGeneration = 0
    bufferedWriteFrames = 0
    bufferedWriteBytes = 0
    transportLock.unlock()
  }

  private func isTransportActive(_ generation: UInt64) -> Bool {
    transportLock.lock()
    defer { transportLock.unlock() }
    return activeTransportGeneration == generation
  }

  /// Queue one encoded frame without ever blocking the lifecycle queue on a
  /// child that stopped reading stdin. The timeout still includes time spent
  /// in this bounded FIFO.
  private func enqueueWrite(_ frame: Data, label: String) {
    guard let handle = stdinPipe?.fileHandleForWriting else {
      transportLock.lock()
      let generation = activeTransportGeneration
      transportLock.unlock()
      handleTransportFailureOnQueue(
        generation: generation,
        message: "[plugin] missing IPC stdin (method=\(label))")
      return
    }

    transportLock.lock()
    let generation = activeTransportGeneration
    let exceedsLimit =
      generation == 0
      || bufferedWriteFrames >= Self.maxBufferedWriteFrames
      || bufferedWriteBytes > Self.maxBufferedWriteBytes - frame.count
    if !exceedsLimit {
      bufferedWriteFrames += 1
      bufferedWriteBytes += frame.count
    }
    transportLock.unlock()

    if exceedsLimit {
      handleTransportFailureOnQueue(
        generation: generation,
        message: "[plugin] IPC write queue overflow (method=\(label))")
      return
    }

    writeQueue.async { [weak self, handle] in
      var failure: String?
      do {
        try handle.write(contentsOf: frame)
      } catch {
        failure = "[plugin] failed to write IPC message (method=\(label)): \(error)"
      }
      guard let self else { return }
      self.transportLock.lock()
      if self.activeTransportGeneration == generation {
        self.bufferedWriteFrames = max(0, self.bufferedWriteFrames - 1)
        self.bufferedWriteBytes = max(0, self.bufferedWriteBytes - frame.count)
      }
      self.transportLock.unlock()
      if let failure {
        self.queue.async { [weak self] in
          self?.handleTransportFailureOnQueue(generation: generation, message: failure)
        }
      }
    }
  }

  /// Runs on the lifecycle queue. A broken or saturated stdin makes every
  /// subsequent request unreachable, so recover through the existing bounded
  /// restart state machine instead of dropping individual frames.
  private func handleTransportFailureOnQueue(generation: UInt64, message: String) {
    guard generation != 0, isTransportActive(generation), process?.isRunning == true else {
      return
    }
    recordError(message)
    stopOnQueue(reason: "write_error")
    scheduleRestart()
  }

  private func writeFrame(_ object: [String: Any]) {
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
    guard frame.count <= PluginProtocol.maxFrameBytes else {
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
    enqueueWrite(frame, label: label)
  }

  private func handleStdout(_ data: Data, generation: UInt64) {
    guard !data.isEmpty else { return }
    readQueue.async { [weak self] in
      guard let self, self.isTransportActive(generation) else { return }
      for output in self.frameCollector.append(data) {
        switch output {
        case .frame(let line):
          self.handleFrame(line, generation: generation)
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
      return
    }
    queue.async { [weak self] in
      guard let self, self.isTransportActive(generation) else { return }
      self.lastInboundFrameAt = .now()
      self.handleProtocolMessage(object, payloadBytes: line.count)
    }
  }

  private func handleStderr(_ data: Data) {
    guard !data.isEmpty,
      let message = String(data: data, encoding: .utf8)?
        .trimmed,
      !message.isEmpty
    else { return }
    queue.async { [weak self] in
      guard let self else { return }
      // Diagnostics, not failure: plugins and their subprocesses may write
      // warnings to stderr unprompted. lastError is reserved for lifecycle
      // failures.
      FlashLog.plugin(.warn, pluginID: self.manifest.id, message: message)
    }
  }

  private func handleProtocolMessage(_ object: [String: Any], payloadBytes: Int) {
    // An inbound id-without-method frame is always a response to one of our
    // requests; an id+method frame is a plugin→host request; a bare method
    // is a notification.
    if let responseID = object["id"] as? Int,
      object["method"] == nil
    {
      let result = object["result"] as? [String: Any]
      guard let request = pending.removeValue(forKey: responseID) else {
        // Responses to unknown ids are dropped silently (late replies after
        // their deadline already settled the caller).
        return
      }
      let elapsedMsValue = Self.elapsedMillisecondsValue(since: request.startedAt)
      let elapsedMs = Self.elapsedMilliseconds(since: request.startedAt)
      if let limit = PluginWireCodec.responsePayloadLimit(for: request.method),
        payloadBytes > limit
      {
        FlashLog.plugin(
          .warn,
          pluginID: manifest.id,
          message: "[plugin] rejected oversized response",
          fields: [
            "method": request.method,
            "bytes": String(payloadBytes),
            "limit": String(limit),
            "elapsed_ms": elapsedMs,
          ])
        request.completion(nil)
        return
      }
      if elapsedMsValue > 1_000, request.method != "initialize", request.method != "perform" {
        FlashLog.plugin(
          .warn,
          pluginID: manifest.id,
          message: "[plugin] slow request method=\(request.method) elapsed_ms=\(elapsedMs)",
          fields: [
            "method": request.method,
            "elapsed_ms": elapsedMs,
          ])
      }
      request.completion(result)
      return
    }
    guard let method = object["method"] as? String else { return }
    let params = object["params"] as? [String: Any] ?? [:]
    if let requestID = object["id"] as? Int {
      routeHostRequest(id: requestID, method: method, params: params)
      return
    }
    switch method {
    case "publish":
      applyPublish(params)
    case "status":
      applyStatusSegments(params)
    case "log":
      let level = FlashLog.Level.parse(params["level"] as? String ?? "info") ?? .info
      let message = params["message"] as? String ?? ""
      let fields = params["fields"] as? [String: String] ?? [:]
      lock.lock()
      lastLog = message
      lock.unlock()
      FlashLog.plugin(level, pluginID: manifest.id, message: message, fields: fields)
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

  /// One `publish` notification: validate at receipt (on this plugin's own
  /// reader queue) and hand the full-replacement catalog to the host store.
  /// A malformed or over-quota payload is rejected whole — content-free log
  /// — and the store keeps the previous catalog by construction.
  private func applyPublish(_ params: [String: Any]) {
    let startedAt = DispatchTime.now()
    guard let raw = params["rows"] as? [[String: Any]] else {
      FlashLog.plugin(
        .warn, pluginID: manifest.id,
        message: "[plugin] malformed publish payload (rows missing)")
      return
    }
    guard
      let decoded = PluginWireCodec.catalogRows(
        from: raw,
        sourceID: "plugin:\(manifest.id)",
        allowedSources: Set(manifest.candidateSources))
    else {
      FlashLog.plugin(
        .warn,
        pluginID: manifest.id,
        message: "[plugin] rejected malformed or oversized publish",
        fields: [
          "received": String(raw.count),
          "row_limit": String(PluginProtocol.maxCatalogRows),
          "byte_limit": String(PluginProtocol.maxCatalogBytes),
        ])
      return
    }
    catalogStore?.publish(
      pluginID: manifest.id, rows: decoded.rows, encodedBytes: decoded.encodedBytes)
    let elapsedMs = Self.elapsedMillisecondsValue(since: startedAt)
    if elapsedMs >= 50 {
      FlashLog.plugin(
        .warn,
        pluginID: manifest.id,
        message: "[plugin] slow catalog publish",
        fields: [
          "elapsed_ms": String(format: "%.2f", elapsedMs),
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
    let declared = Set(manifest.statusSegments)
    guard !declared.isEmpty else { return }
    lock.lock()
    for (name, value) in raw {
      let key = name.trimmed
      guard declared.contains(key) else { continue }
      guard let text = value as? String else { continue }
      let trimmed = text.trimmed
      if trimmed.isEmpty {
        statusSegments.removeValue(forKey: key)
      } else {
        statusSegments[key] = trimmed
      }
    }
    lock.unlock()
    notifyStatus()
  }

  private func setState(_ state: PluginRuntimeState) {
    lock.lock()
    self.state = state
    lock.unlock()
    notifyStatus()
  }

  /// Lifecycle failures only (launch, abnormal exit, ping teardown,
  /// initialize failures, write errors, park). Per-request anomalies are
  /// warn-logs, never lastError — a single slow reply must not paint the
  /// plugin red in `:plugins`.
  private func recordError(_ message: String) {
    // Also log: a throwing launch() (e.g. an unresolvable interpreter)
    // otherwise parks the plugin with zero log evidence.
    FlashLog.plugin(.warn, pluginID: manifest.id, message: message)
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

  private func installFileWatchers() {
    removeFileWatchers()
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    // Watch directories only. The previous code opened one fd per file
    // in the plugin tree, so a plugin with `node_modules` (typically
    // 30k+ files) blew past the default `ulimit -n` (256–2560). DirOnly
    // still triggers reload on any file write inside a watched dir, so
    // semantics are equivalent for the dev-iteration use case.
    watchPath(root)
    for case let url as URL in enumerator {
      let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
      if resourceValues?.isDirectory == true {
        watchPath(url)
      }
    }
  }

  private func watchPath(_ url: URL) {
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete, .rename, .extend, .attrib],
      queue: queue)
    source.setEventHandler { [weak self] in
      self?.scheduleFileReload()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    fileWatchers.append(source)
  }

  private func removeFileWatchers() {
    for watcher in fileWatchers {
      watcher.cancel()
    }
    fileWatchers.removeAll()
  }

  private func scheduleFileReload() {
    reloadWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.reload(reason: "plugin_files_changed")
    }
    reloadWork = work
    queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
  }

  private static func elapsedMilliseconds(since start: DispatchTime) -> String {
    String(format: "%.2f", elapsedMillisecondsValue(since: start))
  }

  private static func elapsedMillisecondsValue(since start: DispatchTime) -> Double {
    let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Double(nanos) / 1_000_000
  }
}

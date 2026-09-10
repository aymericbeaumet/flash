import AppKit
import Darwin
import FlashCore
import Foundation

/// One managed plugin child process speaking the NDJSON wire protocol
/// (protocol v1 — see Plugins/_flash_plugin_specs/protocol.json).
///
/// `PluginLifecycle` owns desired state, attempt generations, and retries;
/// this object interprets effects and owns each child transport, with
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
    let deadline: DispatchTime?

    init(
      completion: @escaping RequestCompletion,
      settleOnStop: Bool,
      method: String = "test",
      startedAt: DispatchTime = .now(),
      deadline: DispatchTime? = nil
    ) {
      self.completion = completion
      self.settleOnStop = settleOnStop
      self.method = method
      self.startedAt = startedAt
      self.deadline = deadline
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
  private var transportBudget = PluginTransportBudget()
  private let lock = NSLock()
  private var state: PluginRuntimeState = .stopped
  /// Runtime status-bar segments, merged under `lock` on every `status`
  /// notification so concurrent updates can never lose each other.
  private var statusSegments: [String: String] = [:]
  private var staleStatusSegments: Set<String> = []
  private var statusExpiryWork: DispatchWorkItem?
  private var startDate: Date?
  private var lifecycle = PluginLifecycle()
  private var restartWork: DispatchWorkItem?
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
  // milliseconds instead of minutes. `var` + internal on purpose.
  static var restartWindowAttempts = 5
  static var statusReloadGraceSeconds: TimeInterval = 10
  static var restartWindowSeconds: TimeInterval = 300
  static var idleBeforePingMs = PluginProtocol.idleBeforePingMs
  static var pingTimeoutMs = PluginProtocol.pingDeadlineMs
  static var restartDelaySeconds: (Int) -> Int = { min(30, max(1, $0 + 1)) }
  private static let deadlineQueue = DispatchQueue(
    label: "flash.plugin.deadlines", qos: .utility)
  private var requestID: Int = 0
  private var pending: [Int: PendingRequest] = [:]
  private var hostRequestToken: UInt64 = 0
  private var pendingHostRequests: Set<UInt64> = []
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

  func reportDefinitionError(_ error: String) {
    queue.async { [weak self] in
      self?.recordError("[plugin] invalid replacement definition: \(error)")
    }
  }

  // MARK: - Lifecycle

  func start() {
    queue.async {
      self.applyLifecycle(.start(resident: self.manifest.activation == .resident))
      if self.watchFiles { self.installFileWatchers() }
    }
  }

  func stopAndWait(reason: String = "stop") {
    queue.sync {
      self.settleDeferredPerforms(as: .unhandled)
      self.applyLifecycle(.stop)
    }
  }

  func reload(reason: String) {
    queue.async {
      self.preserveStatusOnTeardown = self.manifest.activation == .resident
      self.applyLifecycle(.reload(resident: self.manifest.activation == .resident))
      if self.watchFiles { self.installFileWatchers() }
    }
  }

  private func applyLifecycle(_ event: PluginLifecycle.Event) {
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
        let work = DispatchWorkItem { [weak self] in self?.applyLifecycle(.retry(generation)) }
        restartWork = work
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
      case .park:
        settleDeferredPerforms(as: .unhandled)
        if lifecycle.failures.count > Self.restartWindowAttempts {
          recordError(
            "[plugin] restart loop exhausted: \(lifecycle.failures.count) failures within \(Int(Self.restartWindowSeconds))s"
          )
        }
        catalogStore?.drop(pluginID: manifest.id)
        if watchFiles { installFileWatchers() }
      }
    }
    // Terminal status is observable only after teardown and catalog removal.
    // Nested startup transitions may advance the reducer while interpreting
    // effects, so publish its current projection rather than a captured state.
    setState(lifecycle.runtimeState)
  }

  private func startOnQueue(generation: UInt64) {
    guard manifest.exec != nil else { return }
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
            if self.watchFiles { self.installFileWatchers() }
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
    restartWork?.cancel()
    restartWork = nil
    reloadWork?.cancel()
    reloadWork = nil
    installer?.cancel()
    installer = nil
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
      statusExpiryWork?.cancel()
      statusExpiryWork = nil
    } else if needsStatusExpiry, statusExpiryWork == nil {
      // A planned reload keeps the previous labels until each segment is
      // refreshed. One bounded grace window also handles a replacement that
      // initializes successfully but never republishes its status.
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.lock.lock()
        for name in self.staleStatusSegments { self.statusSegments.removeValue(forKey: name) }
        self.staleStatusSegments.removeAll()
        self.lock.unlock()
        self.statusExpiryWork = nil
        self.notifyStatus()
      }
      statusExpiryWork = work
      queue.asyncAfter(deadline: .now() + Self.statusReloadGraceSeconds, execute: work)
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
      self?.handleStderr(handle.availableData, generation: transportGeneration)
    }
    process.terminationHandler = { [weak self] p in
      self?.queue.async {
        guard let self, self.process === p else { return }
        self.recordError("[plugin] exited status=\(p.terminationStatus)")
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
      guard elapsedMs < item.timeoutMs else {
        item.completion(.unhandled)
        continue
      }
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
    applyLifecycle(.reject(lifecycle.generation))
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
      armIdlePing(
        afterMs: pending.isEmpty ? max(1, Self.idleBeforePingMs - idleMs) : Self.idleBeforePingMs)
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
        self.applyLifecycle(.interrupted(self.lifecycle.generation))
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

  /// The `event` frame every listener receives for `event`; nil when the
  /// payload is not JSON-encodable (the per-plugin path then logs the drop).
  static func encodedEventFrame(_ event: PluginEvent) -> Data? {
    try? PluginWireCodec.encodeFrame(eventFrameObject(event))
  }

  private static func eventFrameObject(_ event: PluginEvent) -> [String: Any] {
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
    return [
      "method": "event",
      "params": [
        "name": event.name,
        "payload": payload,
      ],
    ]
  }

  private func deliverEventOnQueue(_ event: PluginEvent) {
    if let frame = event.encodedFrame, frame.count - 1 <= PluginProtocol.maxFrameBytes {
      enqueueWrite(frame, label: "event")
      return
    }
    writeFrame(Self.eventFrameObject(event))
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
    let resultLock = NSLock()
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
      guard
        let wire = PluginWireCodec.hintTargets(
          from: payload, sourceID: "plugin:\(self.manifest.id)", contextPID: context.processID)
      else { return }
      let decoded = wire.map { self.hostJumpTarget(from: $0, contextPID: context.processID) }
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
      guard Set(payload.keys) == ["ok", "rows"], let raw = payload["rows"] as? [[String: Any]]
      else {
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
      case .stopped where self.lifecycle.state == .stopped:
        mainCompletion(.unhandled)
      case .stopped
      where self.manifest.activation == .onDemand
        && (self.lifecycle.state == .idle || self.lifecycle.state == .initial):
        self.enqueueDeferredPerform(
          kind: kind, params: params, timeoutMs: timeoutMs, completion: mainCompletion)
        self.applyLifecycle(.activate)
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
      (process?.processIdentifier, self.startDate, self.lifecycle.failures.count)
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

  private func installIfNeeded(
    generation: UInt64, completion: @escaping (Result<Void, Error>) -> Void
  ) throws {
    guard let install = manifest.install else {
      completion(.success(()))
      return
    }
    let stampURL = dataDir.appendingPathComponent(".install-stamp")
    let stamp = "\(manifest.version)\n\(install)\n"
    if let existing = try? String(contentsOf: stampURL), existing == stamp {
      completion(.success(()))
      return
    }
    let sandboxed = FileManager.default.isExecutableFile(atPath: PluginSandbox.sandboxExecPath)
    let argv =
      sandboxed
      ? [
        PluginSandbox.sandboxExecPath, "-p",
        PluginSandbox.installSandboxProfile(root: root, dataDir: dataDir), "/bin/sh", "-c", install,
      ]
      : ["/bin/sh", "-c", install]
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
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
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
          startedAt: startedAt, deadline: deadline)
        Self.deadlineQueue.asyncAfter(deadline: deadline) { [weak self] in
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
    onHostRequest(method, params, manifest.id) { [weak self] result in
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
    transportLock.unlock()
    readQueue.sync {
      frameCollector = NDJSONFrameCollector(maxLineBytes: PluginProtocol.maxFrameBytes)
    }
    return generation
  }

  private func invalidateTransport() {
    transportLock.lock()
    transportBudget.begin(0)
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
  /// in this bounded FIFO.
  private func enqueueWrite(_ frame: Data, label: String) {
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
    let reservation = transportBudget.reserve(.writeFrames, bytes: frame.count)
    transportLock.unlock()
    guard let reservation else {
      handleTransportFailureOnQueue(
        generation: generation, message: "[plugin] IPC write queue overflow (method=\(label))")
      return
    }
    writeQueue.async { [weak self, handle] in
      guard let self else { return }
      defer { self.releaseTransport(reservation) }
      guard self.isTransportActive(generation) else { return }
      do { try handle.write(contentsOf: frame) } catch {
        self.queue.async { [weak self] in
          self?.handleTransportFailureOnQueue(
            generation: generation, message: "[plugin] IPC write failed (method=\(label))")
        }
      }
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
  private func handleTransportFailureOnQueue(generation: UInt64, message: String) {
    guard generation != 0, isTransportActive(generation), process?.isRunning == true else {
      return
    }
    recordError(message)
    applyLifecycle(.interrupted(lifecycle.generation))
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
    enqueueWrite(frame, label: label)
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
      return
    }
    guard let reservation = reserveTransport(.readFrames, bytes: line.count, generation: generation)
    else {
      scheduleTransportFailure(generation: generation, message: "[plugin] IPC frame queue overflow")
      return
    }
    if object["method"] as? String == "publish", object["id"] == nil {
      let startedAt = DispatchTime.now()
      let params = object["params"] as? [String: Any] ?? [:]
      let decoded = (params["rows"] as? [[String: Any]]).flatMap {
        Set(params.keys) == ["rows"]
          ? PluginWireCodec.catalogRows(
            from: $0, sourceID: "plugin:\(manifest.id)",
            allowedSources: Set(manifest.candidateSources)) : nil
      }
      queue.async { [weak self] in
        guard let self else { return }
        defer { self.releaseTransport(reservation) }
        guard self.isTransportActive(generation), self.lifecycle.state == .running else { return }
        self.lastInboundFrameAt = .now()
        self.applyPublish(decoded, startedAt: startedAt)
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
    guard isTransportActive(generation), !data.isEmpty,
      let message = String(data: data, encoding: .utf8)?.trimmed,
      !message.isEmpty
    else { return }
    // Drain diagnostics on the pipe callback. Enqueuing them on the lifecycle
    // queue lets a stderr flood retain unbounded data and delay shutdown.
    FlashLog.plugin(.warn, pluginID: manifest.id, message: message)
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
        // Responses to unknown ids are dropped silently (late replies after
        // their deadline already settled the caller).
        return
      }
      if let deadline = request.deadline, DispatchTime.now() >= deadline {
        request.completion(nil)
        return
      }
      let elapsedMsValue = Self.elapsedMillisecondsValue(since: request.startedAt)
      let elapsedMs = Self.elapsedMilliseconds(since: request.startedAt)
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
    if let requestID = PluginJSON.integer(object["id"]), requestID > 0 {
      routeHostRequest(id: requestID, method: method, params: params, generation: generation)
      return
    }
    switch method {
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
  private func applyPublish(
    _ decoded: (rows: [Candidate], encodedBytes: Int)?, startedAt: DispatchTime
  ) {
    guard let decoded else {
      FlashLog.plugin(
        .warn, pluginID: manifest.id, message: "[plugin] rejected malformed or oversized publish")
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
      staleStatusSegments.remove(key)
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
    // Root only: `manifest.json` and the `flash-plugin-<id>` binary both live
    // there, and `build-plugins.sh` lands a rebuilt binary as a rename in the
    // root, which a vnode watcher on the directory sees. Watching the whole
    // tree opened one descriptor per directory (hundreds with a stray
    // `target/`) and fired on source edits that change nothing the host loads.
    watchPath(root)
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
      guard let self, self.lifecycle.state != .stopped else { return }
      if let onFilesChanged = self.onFilesChanged {
        onFilesChanged()
      } else {
        self.reload(reason: "plugin_files_changed")
      }
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

import AppKit
import Darwin
import FlashCore
import Foundation

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

  let root: URL
  let manifest: PluginManifest
  let origin: PluginOrigin
  private let listenPatterns: [PluginPattern]

  private let queue: DispatchQueue
  private let dataDir: URL
  /// Latest host-owned app snapshot. Each child launch receives the value once
  /// in `initialize`, including automatic restarts of this PluginProcess.
  private var initialRunningApplications: [[String: Any]]
  private var process: Process?
  private var stdinPipe: Pipe?
  private var frameCollector = MessagePackFrameCollector(maxFrameBytes: PluginProcess.maxFrameBytes)
  private let lock = NSLock()
  private var discovery = PluginDiscovery()
  private var state: PluginRuntimeState = .unloaded
  private var startDate: Date?
  private var lastHeartbeatAt: Date?
  private var awaitingHeartbeat = false
  private var heartbeatMisses = 0
  private var heartbeatTimer: DispatchSourceTimer?
  /// Queue-confined proof that the current child generation completed the
  /// protocol-v2 initialize/on_start publication boundary. Runtime state alone
  /// is insufficient: heartbeat degradation must never make a starting child
  /// eligible for warm reads.
  private var initializationCompleted = false
  private var restartCount = 0
  /// Set only while `stopOnQueue` is sending its `shutdown` frame, so the
  /// write-error recovery in `writeFrame` doesn't recurse back into stop.
  private var isStopping = false
  /// Guards `notifyStatus` so a burst of status changes collapses to one
  /// main-thread callback per runloop turn instead of one hop per change.
  private var statusNotificationPending = false
  private let statusNotifyLock = NSLock()
  /// Timestamps of recent restart attempts. Bounded restart loop: if
  /// `restartWindowAttempts` restarts happen within `restartWindowSeconds`,
  /// the plugin is parked in `.crashed` and stops auto-restarting. The user
  /// can recover with `:plugins reload`.
  private var restartTimestamps: [Date] = []
  private static let restartWindowAttempts = 5
  private static let restartWindowSeconds: TimeInterval = 300
  private var restartLoopExhausted = false
  private var requestID: Int = 0
  private var pending: [Int: PendingRequest] = [:]
  private var fileWatchers: [DispatchSourceFileSystemObject] = []
  private var fileWatcherFDs: [Int32] = []
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
    settings: [String: PluginConfigValue] = [:],
    initialRunningApplications: [[String: Any]] = []
  ) {
    self.root = root
    self.manifest = manifest
    self.origin = origin
    self.listenPatterns = manifest.listen.map(PluginPattern.init)
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.watchFiles = watchFiles
    self.settings = settings
    self.initialRunningApplications = initialRunningApplications
  }

  var identifier: String { manifest.id }

  var commands: [PluginCommandRegistration] {
    manifest.commands
  }

  var mappings: [PluginMappingRegistration] {
    manifest.mappings
  }

  /// Flashlight bang registrations. Static from the manifest (no runtime
  /// update RPC), so this reads straight through rather than caching a
  /// `dynamic` copy the way commands/mappings do.
  var shebangs: [PluginShebangRegistration] { manifest.shebangs }

  func start() {
    queue.async {
      self.startOnQueue(reason: "start")
    }
  }

  func updateRunningApplicationsSnapshot(_ applications: [[String: Any]]) {
    queue.async {
      self.initialRunningApplications = applications
    }
  }

  func stopAndWait(reason: String = "stop") {
    queue.sync {
      self.stopOnQueue(reason: reason)
    }
  }

  func reload(reason: String) {
    queue.async {
      // User-initiated reload re-arms the bounded restart loop so a previously
      // exhausted plugin can recover without restarting the resident process.
      self.restartLoopExhausted = false
      self.restartTimestamps.removeAll()
      self.restartCount = 0
      self.stopOnQueue(reason: reason)
      self.startOnQueue(reason: reason)
    }
  }

  func sendEvent(_ event: PluginEvent) {
    guard listenPatterns.contains(where: { $0.matches(event.name) }) else { return }
    // Default-deny capability gate. Events that carry sensitive data
    // (clipboard text, etc.) reach a plugin only when its manifest
    // explicitly opts in via `capabilities`. A plugin that drops or
    // logs this event would otherwise have unsupervised access to the
    // contents.
    if let required = PluginCapability.required(for: event.name),
      !manifest.capabilities.contains(required)
    {
      return
    }
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
    sendNotification(
      method: "event",
      params: [
        "name": event.name,
        "payload": payload,
      ])
  }

  /// Synchronous-style discover for volatile plugins. Sends a
  /// `hints.discover` RPC and waits up to `timeout` for the plugin to
  /// return a fresh set of jump targets for the given context. Used on
  /// each activation when the manifest declares `volatile: true`.
  func discoverTargets(context: AppContext, timeout: TimeInterval) -> [JumpTarget] {
    let startedAt = DispatchTime.now()
    let semaphore = DispatchSemaphore(value: 0)
    var discovery: PluginDiscovery?
    let frame: [String: Any] = [
      "x": context.frontWindowFrame.minX,
      "y": context.frontWindowFrame.minY,
      "width": context.frontWindowFrame.width,
      "height": context.frontWindowFrame.height,
    ]
    let params: [String: Any] = [
      "bundle_id": context.bundleIdentifier,
      "pid": Int(context.processID),
      "front_window_frame": frame,
    ]
    sendRequest(method: "hints.discover", params: params) { [weak self] response in
      guard let self else {
        semaphore.signal()
        return
      }
      if let response {
        discovery = self.applyDiscoveryResponse(response, defaultPID: context.processID)
      }
      semaphore.signal()
    }
    let waitResult = semaphore.wait(timeout: .now() + timeout)
    let snap =
      discovery
      ?? {
        lock.lock()
        let s = self.discovery
        lock.unlock()
        return s
      }()
    let contextMismatch = snap.contextPID.map { $0 != context.processID } ?? false
    if FlashLog.wouldEmit(.debug) {
      var fields: [String: String] = [
        "plugin": manifest.id,
        "pid": "\(context.processID)",
        "bundle": context.bundleIdentifier,
        "discovery_targets": "\(snap.targets.count)",
        "targets": "\(contextMismatch ? 0 : snap.targets.count)",
        "timed_out": "\(waitResult == .timedOut)",
        "discovery_fallback": "\(discovery == nil)",
        "context_mismatch": "\(contextMismatch)",
        "timeout_ms": "\(Int((timeout * 1000).rounded()))",
        "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
      ]
      if let contextPID = snap.contextPID {
        fields["discovery_pid"] = "\(contextPID)"
      }
      FlashLog.debug(
        "[plugin] discover_targets",
        fields: fields,
        source: "plugin:\(manifest.id)")
    }
    if let contextPID = snap.contextPID, contextPID != context.processID {
      return []
    }
    return snap.targets.map { wire in
      hostJumpTarget(from: wire, contextPID: context.processID)
    }
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

  private func applyDiscoveryResponse(_ params: [String: Any], defaultPID: pid_t) -> PluginDiscovery
  {
    let sourceID = "plugin:\(manifest.id)"
    let contextPID = (params["context_pid"] as? Int).map(pid_t.init) ?? defaultPID
    let targetItems = (params["targets"] as? [[String: Any]] ?? [])
      .compactMap { PluginWireCodec.target(from: $0, sourceID: sourceID) }
    let previousStatusSegments: [String: String]
    lock.lock()
    previousStatusSegments = discovery.statusSegments
    lock.unlock()
    let snap = PluginDiscovery(
      targets: targetItems,
      statusSegments: previousStatusSegments,
      contextPID: contextPID,
      updatedAt: Date())
    lock.lock()
    discovery = snap
    lock.unlock()
    notifyStatus()
    return snap
  }

  func snapshotCandidates(completion: @escaping ([Candidate]) -> Void) {
    // Catalog snapshots are complete warm-store reads. Filtering is host-owned,
    // and running-app state is seeded by initialize then refreshed by
    // `core:apps.changed`, so this wire request intentionally carries no data.
    sendRequest(
      method: "sources.snapshot",
      params: [:],
      timeout: .milliseconds(150),
      requiresWarmProcess: true
    ) { [weak self] response in
      guard let self else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      guard let response else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      guard let raw = response["candidates"] as? [[String: Any]] else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] malformed sources.snapshot envelope",
          fields: ["method": "sources.snapshot"])
        DispatchQueue.main.async { completion([]) }
        return
      }
      let sourceID = "plugin:\(self.manifest.id)"
      let allowedSources = Set(self.manifest.candidateSources)
      guard
        let items = PluginWireCodec.catalogCandidates(
          from: raw,
          sourceID: sourceID,
          allowedSources: allowedSources)
      else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] rejected malformed or oversized catalog snapshot",
          fields: [
            "received": String(raw.count),
            "candidate_limit": String(PluginWireCodec.maxCatalogCandidates),
            "string_bytes_limit": String(PluginWireCodec.maxCatalogEncodedBytes),
          ])
        DispatchQueue.main.async { completion([]) }
        return
      }
      DispatchQueue.main.async {
        completion(items)
      }
    }
  }

  func evaluateQuery(
    _ request: QueryEvaluationRequest,
    environment: FlashSourceEnvironment,
    completion: @escaping ([Candidate]) -> Void
  ) {
    // Query evaluation is an O(memory), CPU-only hot path. App/external state
    // reaches plugins through initialize + events and must already be warm.
    _ = environment
    let scopeName: String
    switch request.scope {
    case .running: scopeName = "running"
    case .all: scopeName = "all"
    }
    let params: [String: Any] = [
      "surface": request.surface.rawValue,
      "scope": scopeName,
      "query": request.text,
    ]
    sendRequest(
      method: "query.evaluate",
      params: params,
      timeout: .milliseconds(50),
      requiresWarmProcess: true
    ) { [weak self] response in
      guard let self else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      guard let response else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      guard let raw = response["answers"] as? [[String: Any]] else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] malformed query.evaluate envelope",
          fields: ["method": "query.evaluate"])
        DispatchQueue.main.async { completion([]) }
        return
      }
      let sourceID = "plugin:\(self.manifest.id)"
      let declaredSource = self.manifest.queriesProvider?.source?.trimmed ?? ""
      let querySource = declaredSource.isEmpty ? self.manifest.id : declaredSource
      guard
        let items = PluginWireCodec.queryAnswers(
          from: raw,
          sourceID: sourceID,
          source: querySource)
      else {
        FlashLog.plugin(
          .warn,
          pluginID: self.manifest.id,
          message: "[plugin] rejected malformed or oversized query answers",
          fields: [
            "received": String(raw.count),
            "answer_limit": String(PluginWireCodec.maxQueryAnswersPerEvaluator),
            "string_bytes_limit": String(PluginWireCodec.maxQueryEncodedBytes),
          ])
        DispatchQueue.main.async { completion([]) }
        return
      }
      DispatchQueue.main.async {
        completion(items)
      }
    }
  }

  func targets(for context: AppContext) -> [JumpTarget] {
    lock.lock()
    let snap = discovery
    lock.unlock()
    if let contextPID = snap.contextPID, contextPID != context.processID {
      return []
    }
    return snap.targets.map { wire in
      hostJumpTarget(from: wire, contextPID: context.processID)
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    let params: [String: Any] = [
      "candidate": PluginWireCodec.candidateJSON(candidate)
    ]
    sendRequest(method: "candidate.resolve", params: params) { response in
      let didResolve = response?["did_resolve"] as? Bool ?? false
      let pid = response?["target_pid"] as? Int
      let navigationURL = (response?["navigation_url"] as? String).flatMap(URL.init(string:))
      DispatchQueue.main.async {
        completion(
          didResolve
            ? .resolved(pid: pid.map(pid_t.init), navigationURL: navigationURL)
            : .unresolved)
      }
    }
  }

  func invokeCommand(
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    meta: [String: String] = [:],
    completion: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) {
    var params: [String: Any] = [
      "args": args,
      "command": command,
      "subcommand": subcommand,
      "raw": raw,
    ]
    // Forward the matched manifest entry's `_`-prefixed metadata verbatim so
    // the plugin can read e.g. `_url` without re-deriving it.
    for (key, value) in meta {
      params[key] = value
    }
    sendRequest(
      method: "command.invoke",
      params: params
    ) { response in
      let ok = response?["ok"] as? Bool ?? false
      // A command may name an app (by pid) for Flash to raise once it
      // succeeds — e.g. the tmux plugin returns the terminal hosting the
      // session it just switched to, so a `:tmux window …` mapping brings
      // that window forward. Optional; most commands omit it.
      let pid = response?["target_pid"] as? Int
      let navigationURL = (response?["navigation_url"] as? String).flatMap(URL.init(string:))
      // A command may also return `stdout` for Flash to surface as a toast
      // (e.g. the calculator returns "2 + 2 = 4"). Optional.
      let stdout = (response?["stdout"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      DispatchQueue.main.async {
        completion?(ok, pid.map(pid_t.init), stdout, navigationURL)
      }
    }
  }

  func invokeSourceAction(
    name: String,
    context: AppContext,
    extra: [String: Any],
    completion: @escaping (SourceActionResult) -> Void
  ) {
    var params = extra
    params["name"] = name
    params["context"] = PluginWireCodec.contextJSON(context)
    sendRequest(method: "source.action", params: params) { [weak self] response in
      let result: SourceActionResult
      if let response {
        let didPerform = response["did_perform"] as? Bool ?? false
        let handled = response["handled"] as? Bool ?? false
        let pid = (response["target_pid"] as? Int).map(pid_t.init)
        let navigationURL = (response["navigation_url"] as? String).flatMap(URL.init(string:))
        if didPerform {
          result = .performed(pid: pid, navigationURL: navigationURL)
        } else if handled {
          result = SourceActionResult(
            targetPID: pid,
            disposition: .failed,
            navigationURL: navigationURL)
        } else {
          result = .unhandled
        }
      } else {
        // No reply (RPC timeout, plugin crash mid-call): the plugin was
        // consulted because it claims this context, and the action may
        // still complete late — report failed, never unhandled, so the
        // host can't double-fire a keystroke fallback.
        result = .failed
      }
      FlashLog.trace(
        "[plugin] source_action plugin=\(self?.manifest.id ?? "?") name=\(name) "
          + "disposition=\(result.disposition) "
          + "target_pid=\(result.targetPID.map(String.init) ?? "nil")",
        source: "plugin:\(self?.manifest.id ?? "?")")
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  func restoreNavigation(
    to url: URL,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    sendRequest(method: "navigation.restore", params: ["url": url.absoluteString]) {
      [weak self] response in
      let result: SourceActionResult
      if let response {
        let didPerform = response["did_perform"] as? Bool ?? false
        let handled = response["handled"] as? Bool ?? false
        let pid = (response["target_pid"] as? Int).map(pid_t.init)
        let navigationURL = (response["navigation_url"] as? String).flatMap(URL.init(string:))
        if didPerform {
          result = .performed(pid: pid, navigationURL: navigationURL)
        } else if handled {
          result = SourceActionResult(
            targetPID: pid,
            disposition: .failed,
            navigationURL: navigationURL)
        } else {
          result = .unhandled
        }
      } else {
        result = .failed
      }
      FlashLog.trace(
        "[plugin] navigation_restore plugin=\(self?.manifest.id ?? "?") "
          + "scheme=\(url.scheme ?? "nil") "
          + "disposition=\(result.disposition) "
          + "target_pid=\(result.targetPID.map(String.init) ?? "nil")",
        source: "plugin:\(self?.manifest.id ?? "?")")
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  func statusSnapshot() -> PluginStatus {
    lock.lock()
    let snap = discovery
    let state = self.state
    let pid = process?.processIdentifier
    let startDate = self.startDate
    let lastHeartbeatAt = self.lastHeartbeatAt
    let restartCount = self.restartCount
    let lastError = self.lastError
    let lastLog = self.lastLog
    let commands = manifest.commands
    let now = Date()
    let usage = pid.map { sampleResourceUsageLocked(pid: $0, now: now) }
    lock.unlock()
    return PluginStatus(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      description: manifest.description,
      origin: origin.label,
      root: root.path,
      state: state.rawValue,
      pid: pid.map(Int.init),
      uptimeMs: startDate.map { Int(now.timeIntervalSince($0) * 1000) },
      heartbeatAgeMs: lastHeartbeatAt.map { Int(now.timeIntervalSince($0) * 1000) },
      sourceCount: snap.targets.isEmpty ? 0 : 1,
      commandCount: commands.count,
      targetCount: snap.targets.count,
      discoveryAgeMs: snap.updatedAt.map { Int(now.timeIntervalSince($0) * 1000) },
      restartCount: restartCount,
      lastError: lastError,
      lastLog: lastLog,
      cpuPercent: usage?.cpuPercent ?? nil,
      memoryBytes: usage?.memoryBytes ?? nil,
      onlyBundleIDs: manifest.onlyBundleIDs,
      onlyURLs: manifest.onlyURLs,
      volatile: manifest.volatile,
      priority: manifest.priority,
      commands: commands,
      statusSegments: snap.statusSegments)
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

  private func startOnQueue(reason: String) {
    stopOnQueue(reason: "pre_start")
    initializationCompleted = false
    // Manifest-only plugin (no `exec`): no child process exists — nothing to
    // install, launch, or heartbeat. The host compiles its inline surfaces
    // (inline-keystroke verbs, mappings, help) straight from the manifest.
    // File watchers stay armed so manifest edits still hot-reload.
    guard manifest.exec != nil else {
      setState(.ready)
      if watchFiles {
        installFileWatchers()
      }
      FlashLog.plugin(
        .info, pluginID: manifest.id, message: "[plugin] manifest-only ready reason=\(reason)")
      return
    }
    setState(.installing)
    do {
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      try installIfNeeded()
      setState(.starting)
      try launch()
      if watchFiles {
        installFileWatchers()
      }
      startHeartbeat()
      FlashLog.plugin(.info, pluginID: manifest.id, message: "[plugin] started reason=\(reason)")
    } catch {
      recordError("[plugin] start failed: \(error)")
      setState(.crashed)
      scheduleRestart()
    }
  }

  private func stopOnQueue(reason: String) {
    // Remove every callback before invoking any of them. A completion can
    // enqueue another plugin request, so iterating the live dictionary would
    // be reentrant and could strand or double-complete work.
    let abandonedCallbacks = Self.takePendingCallbacks(&pending)
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    removeFileWatchers()
    if let process, process.isRunning {
      isStopping = true
      writeFrame([
        "jsonrpc": "2.0",
        "method": "shutdown",
        "params": ["reason": reason],
      ])
      isStopping = false
      stdinPipe?.fileHandleForWriting.closeFile()
      waitForExit(process, timeout: 1.0)
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
    initializationCompleted = false
    awaitingHeartbeat = false
    heartbeatMisses = 0
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

  private func launch() throws {
    // Unreachable for manifest-only plugins — startOnQueue returns before
    // install/launch when the manifest has no exec argv.
    guard let execArgv = manifest.exec, let executable = execArgv.first else {
      throw PluginError.invalidManifest("plugin \(manifest.id) has no exec argv to launch")
    }
    // Direct exec, no shell wrap: a `/bin/sh -lc` here used to source the
    // user's login rc files inside the child, silently re-widening the
    // scrubbed 11-key env allowlist. Resolution of argv[0]: absolute paths
    // pass through, "./"-style paths resolve against the plugin root
    // (compiled plugins use "./flash-plugin-<id>"), and bare names resolve
    // through the login-shell PATH — interpreted official plugins declare
    // "python3" / "bun" without hardcoding machine-specific install paths.
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
      throw PluginError.processLaunch(
        "plugin \(manifest.id) exec runtime not found via mise or the login PATH: \(executable)")
    }
    let execTail = Array(execArgv.dropFirst())
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    // Run the plugin under its resolved seatbelt profile. sandbox-exec execs
    // in place, so the pid we track and the child flash-plugin binary are
    // unchanged.
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest, settings: settings, root: root, dataDir: dataDir,
      executablePath: executablePath)
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
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleStdout(handle.availableData)
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.handleStderr(handle.availableData)
    }
    process.terminationHandler = { [weak self] p in
      self?.queue.async {
        guard let self, self.process === p else { return }
        self.recordError("[plugin] exited status=\(p.terminationStatus)")
        self.setState(.crashed)
        self.scheduleRestart()
      }
    }
    do {
      try process.run()
    } catch {
      throw PluginError.processLaunch("\(error)")
    }
    self.process = process
    self.stdinPipe = stdin
    self.startDate = Date()
    self.lastHeartbeatAt = Date()
    let initializationStartedAt = DispatchTime.now()
    sendRequest(
      method: "initialize",
      params: [
        "plugin_id": manifest.id,
        "version": manifest.version,
        "protocol_version": PluginWireCodec.protocolVersion,
        "running_applications": initialRunningApplications,
      ],
      timeout: Self.startupTimeout,
      settleOnStop: false
    ) { [weak self, weak process] response in
      guard let self, let process, self.process === process else { return }
      let elapsedMs = Int(
        (DispatchTime.now().uptimeNanoseconds
          &- initializationStartedAt.uptimeNanoseconds) / 1_000_000)
      if response != nil {
        FlashLog.plugin(
          elapsedMs > 1_000 ? .warn : .info,
          pluginID: self.manifest.id,
          message: "[plugin] initialization settled elapsed_ms=\(elapsedMs)",
          fields: ["elapsed_ms": String(elapsedMs)])
      }
      guard let response else {
        self.failStartup(
          "[plugin] initialization timed out after \(Self.startupTimeoutSeconds)s",
          fatal: false)
        return
      }
      guard PluginWireCodec.acceptsProtocolVersion(response) else {
        let reported = PluginWireCodec.protocolVersionValue(response).map(String.init) ?? "missing"
        self.failStartup(
          "[plugin] protocol_version \(reported) != host v\(PluginWireCodec.protocolVersion)",
          fatal: true)
        return
      }
      guard response["ok"] as? Bool == true else {
        let error = response["error"] as? String ?? "plugin rejected initialization"
        self.failStartup("[plugin] initialization failed: \(error)", fatal: true)
        return
      }
      if !self.manifest.sources.isEmpty,
        !PluginWireCodec.hasCanonicalInitialPublication(response, pluginID: self.manifest.id)
      {
        self.failStartup(
          "[plugin] initialization failed: candidate source did not publish exactly "
            + "\"plugin:\(self.manifest.id)\"",
          fatal: true)
        return
      }
      self.clearError()
      self.initializationCompleted = true
      self.setState(.ready)
      // Successful startup resets the backoff counter so a transient crash
      // doesn't accumulate across hours of healthy operation.
      self.restartCount = 0
      self.restartTimestamps.removeAll()
    }
  }

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
        "-p", PluginSandbox.installSandboxProfile(root: root, dataDir: dataDir), "/bin/sh", "-lc", install,
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
    // build) so it can't pin this plugin's serial queue forever — heartbeat and
    // stop both run on that queue. Mirrors PluginManager.runGit's kill pattern.
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
      throw PluginError.processLaunch(
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
    Self.sanitizedPluginEnvironment(
      base: FlashProcessEnvironment.shared.environment,
      overrides: [
        "FLASH_PLUGIN_ID": manifest.id,
        "FLASH_PLUGIN_VERSION": manifest.version,
        "FLASH_PLUGIN_DATA_DIR": dataDir.path,
        "FLASH_PLUGIN_CONFIG": settingsJSON,
        "FLASH_PLUGIN_PARENT_PID": String(getpid()),
        "PYTHONDONTWRITEBYTECODE": "1",
      ])
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
  private static let startupTimeout = DispatchTimeInterval.seconds(startupTimeoutSeconds)

  private func failStartup(_ message: String, fatal: Bool) {
    recordError(message)
    FlashLog.plugin(.error, pluginID: manifest.id, message: message)
    if fatal {
      // A wire mismatch or a source that violates the initial-publication
      // contract will not recover by immediately launching the same binary.
      // Explicit reload/file change resets this latch.
      restartLoopExhausted = true
    }
    stopOnQueue(reason: fatal ? "startup_rejected" : "startup_timeout")
    setState(.crashed)
    if !fatal {
      scheduleRestart()
    }
  }

  private func sendRequest(
    method: String,
    params: [String: Any],
    timeout: DispatchTimeInterval? = nil,
    settleOnStop: Bool = true,
    requiresWarmProcess: Bool = false,
    completion: (([String: Any]?) -> Void)? = nil
  ) {
    let startedAt = DispatchTime.now()
    queue.async { [weak self] in
      guard let self else { return }
      if requiresWarmProcess,
        !Self.warmRequestIsDispatchable(
          state: self.runtimeStateSnapshot(),
          initializationCompleted: self.initializationCompleted,
          processRunning: self.process?.isRunning == true)
      {
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
          startedAt: startedAt)
        self.queue.asyncAfter(deadline: .now() + (timeout ?? self.requestTimeout)) { [weak self] in
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
      self.writeFrame([
        "id": id,
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
      ])
    }
  }

  private func sendNotification(method: String, params: [String: Any]) {
    queue.async { [weak self] in
      self?.writeFrame([
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
      ])
    }
  }

  private func routeHostRequest(id: Int, method: String, params: [String: Any]) {
    guard let onHostRequest else {
      sendResponse(id: id, result: ["ok": false, "error": "host requests unsupported"])
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
        "jsonrpc": "2.0",
        "result": result,
      ])
    }
  }

  private func writeFrame(_ object: [String: Any]) {
    let label = object["method"] as? String ?? "response"
    let payload: Data
    do {
      payload = try MessagePack.encode(object)
    } catch {
      // A non-encodable message is a runtime bug that would otherwise vanish
      // silently and only show up as a timed-out RPC; surface it.
      recordError("[plugin] dropped non-encodable IPC message (method=\(label)): \(error)")
      return
    }
    guard payload.count <= Self.maxFrameBytes else {
      recordError(
        "[plugin] dropped oversized IPC message (method=\(label), bytes=\(payload.count), "
          + "max=\(Self.maxFrameBytes))")
      return
    }
    // Length-prefixed MessagePack: a 4-byte big-endian payload length, then
    // the payload itself. The plugin reads the prefix, then exactly that many
    // bytes — no delimiter scanning and binary-safe.
    let count = UInt32(payload.count)
    var frame = Data(capacity: 4 + payload.count)
    frame.append(UInt8(truncatingIfNeeded: count >> 24))
    frame.append(UInt8(truncatingIfNeeded: count >> 16))
    frame.append(UInt8(truncatingIfNeeded: count >> 8))
    frame.append(UInt8(truncatingIfNeeded: count))
    frame.append(payload)
    do {
      try stdinPipe?.fileHandleForWriting.write(contentsOf: frame)
    } catch {
      // A broken pipe during teardown is expected, so only act while the
      // subprocess is supposed to be alive (and not while we're already sending
      // the shutdown frame from `stopOnQueue`).
      if process?.isRunning == true, !isStopping {
        recordError("[plugin] failed to write IPC message (method=\(label)): \(error)")
        // The stdin pipe is broken: every subsequent RPC will fail too, so the
        // plugin is effectively unreachable even though it still "runs". Don't
        // wait ~10s for the heartbeat to notice — tear down and restart now
        // (mirrors the heartbeat-miss recovery).
        restartCount += 1
        stopOnQueue(reason: "write_error")
        scheduleRestart()
      }
    }
  }

  /// Sanity ceiling on a single frame's payload. Real frames are a few KB at
  /// most; anything larger means the stream desynced and the "length" is
  /// really payload bytes misread as a prefix.
  // Real payloads (candidate snapshots, query answers, command responses) sit well under
  // 1 MiB. The previous 64 MiB ceiling let a misbehaving plugin starve the
  // host on every frame; 10 MiB still covers any sensible payload while
  // bounding the worst-case allocation.
  private static let maxFrameBytes = 10 * 1024 * 1024

  private func handleStdout(_ data: Data) {
    guard !data.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      for output in self.frameCollector.append(data) {
        switch output {
        case .frame(let payload):
          self.handleFrame(payload)
        case .desynced(let length):
          self.recordError("[plugin] invalid frame length \(length); resetting stream")
        }
      }
    }
  }

  private func handleFrame(_ payload: Data) {
    let object: [String: Any]
    do {
      guard let decoded = try MessagePack.decode(payload) as? [String: Any] else {
        recordError("[plugin] non-object IPC frame")
        return
      }
      object = decoded
    } catch {
      recordError("[plugin] undecodable IPC frame: \(error)")
      return
    }
    handleProtocolMessage(object, payloadBytes: payload.count)
  }

  private func handleStderr(_ data: Data) {
    guard !data.isEmpty,
      let message = String(data: data, encoding: .utf8)?
        .trimmed,
      !message.isEmpty
    else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.recordError(message)
      FlashLog.plugin(.error, pluginID: self.manifest.id, message: message)
    }
  }

  private func handleProtocolMessage(_ object: [String: Any], payloadBytes: Int) {
    if let responseID = object["id"] as? Int,
      object["method"] == nil
    {
      if let error = object["error"] {
        recordError("[plugin] response error id=\(responseID) \(error)")
      }
      let result = object["result"] as? [String: Any]
      if responseID == -1 {
        lastHeartbeatAt = Date()
        awaitingHeartbeat = false
        heartbeatMisses = 0
        if initializationCompleted, runtimeStateSnapshot() == .degraded {
          setState(.ready)
        }
      }
      if let request = pending.removeValue(forKey: responseID) {
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
        if elapsedMsValue > 1_000, request.method != "initialize" {
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
      }
      return
    }
    guard let method = object["method"] as? String else { return }
    let params = object["params"] as? [String: Any] ?? [:]
    // A frame carrying both an id and a method is a plugin→host request:
    // route it to the host RPC router and reply with a response frame. (Host
    // responses carry an id but no method and were handled above; plugin
    // notifications carry a method but no id and fall through to the switch.)
    if let requestID = object["id"] as? Int {
      routeHostRequest(id: requestID, method: method, params: params)
      return
    }
    switch method {
    case "flash.log":
      let level = FlashLog.Level.parse(params["level"] as? String ?? "info") ?? .info
      let message = params["message"] as? String ?? ""
      let fields = params["fields"] as? [String: String] ?? [:]
      lastLog = message
      FlashLog.plugin(level, pluginID: manifest.id, message: message, fields: fields)
      notifyStatus()
    case "discovery.invalidated":
      lock.lock()
      discovery = PluginDiscovery()
      lock.unlock()
      notifyStatus()
    case "status.updated":
      applyStatusSegments(params)
    default:
      break
    }
  }

  private func applyStatusSegments(_ params: [String: Any]) {
    guard let raw = params["segments"] as? [String: Any] else { return }
    let declared = Set(manifest.statusSegments)
    guard !declared.isEmpty else { return }
    lock.lock()
    let previous = discovery
    var next = previous.statusSegments
    lock.unlock()
    for (name, value) in raw {
      let key = name.trimmed
      guard declared.contains(key) else { continue }
      guard let text = value as? String else { continue }
      let trimmed = text.trimmed
      if trimmed.isEmpty {
        next.removeValue(forKey: key)
      } else {
        next[key] = trimmed
      }
    }
    lock.lock()
    discovery = PluginDiscovery(
      targets: previous.targets,
      statusSegments: next,
      contextPID: previous.contextPID,
      updatedAt: previous.updatedAt)
    lock.unlock()
    notifyStatus()
  }

  private func startHeartbeat() {
    heartbeatTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
    timer.setEventHandler { [weak self] in
      self?.heartbeat()
    }
    timer.resume()
    heartbeatTimer = timer
  }

  private func heartbeat() {
    guard initializationCompleted, process?.isRunning == true else { return }
    if awaitingHeartbeat {
      heartbeatMisses += 1
      if runtimeStateSnapshot() == .ready {
        setState(.degraded)
      }
      if heartbeatMisses >= 2 {
        recordError("[plugin] heartbeat missed")
        restartCount += 1
        stopOnQueue(reason: "heartbeat")
        scheduleRestart()
        return
      }
    }
    awaitingHeartbeat = true
    writeFrame([
      "id": -1,
      "jsonrpc": "2.0",
      "method": "heartbeat",
      "params": ["time_unix_ms": Int64((Date().timeIntervalSince1970 * 1000).rounded())],
    ])
  }

  static func warmRequestIsDispatchable(
    state: PluginRuntimeState,
    initializationCompleted: Bool,
    processRunning: Bool
  ) -> Bool {
    initializationCompleted
      && processRunning
      && (state == .ready || state == .degraded)
  }

  private func scheduleRestart() {
    let now = Date()
    let windowStart = now.addingTimeInterval(-Self.restartWindowSeconds)
    restartTimestamps.removeAll(where: { $0 < windowStart })
    restartTimestamps.append(now)
    if restartTimestamps.count > Self.restartWindowAttempts {
      restartLoopExhausted = true
      recordError(
        "[plugin] restart loop exhausted: \(restartTimestamps.count) restarts "
          + "within \(Int(Self.restartWindowSeconds))s — parking in .crashed. "
          + "Run :plugins reload to retry.")
      setState(.crashed)
      return
    }
    let delay = min(30, max(1, restartCount + 1))
    restartCount += 1
    queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
      self?.startOnQueue(reason: "restart")
    }
  }

  private func setState(_ state: PluginRuntimeState) {
    lock.lock()
    self.state = state
    lock.unlock()
    notifyStatus()
  }

  /// Per-request RPC deadline. Defaults to 2s; a plugin can raise it via
  /// `request_timeout_ms` in its manifest for slow, network-backed work.
  private var requestTimeout: DispatchTimeInterval {
    .milliseconds(max(1, manifest.requestTimeoutMs ?? 2000))
  }

  private func recordError(_ message: String) {
    // Also log: a throwing launch() (e.g. an unresolvable interpreter)
    // otherwise parks the plugin in .crashed with zero log evidence.
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
    // Coalesce: a chatty plugin spamming `flash.log` / `status.updated` would
    // otherwise schedule an unbounded number of main-thread callbacks (the
    // tap-starvation class). Collapse bursts to one main hop per runloop turn;
    // `onStatusChanged` re-reads the latest state, so nothing is lost.
    // A dedicated lock (not the state `lock`) so this can never deadlock with a
    // caller that holds `lock` while changing state and then notifies.
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
    fileWatcherFDs.append(fd)
  }

  private func removeFileWatchers() {
    for watcher in fileWatchers {
      watcher.cancel()
    }
    fileWatchers.removeAll()
    fileWatcherFDs.removeAll()
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

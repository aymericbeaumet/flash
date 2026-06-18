import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginProcess {
  let root: URL
  let manifest: PluginManifest
  let origin: PluginOrigin
  private let listenPatterns: [PluginPattern]

  private let queue: DispatchQueue
  private let dataDir: URL
  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutBuffer = Data()
  private let lock = NSLock()
  private var snapshot = PluginSnapshot()
  private var state: PluginRuntimeState = .unloaded
  private var startDate: Date?
  private var lastHeartbeatAt: Date?
  private var awaitingHeartbeat = false
  private var heartbeatMisses = 0
  private var heartbeatTimer: DispatchSourceTimer?
  private var restartCount = 0
  /// Timestamps of recent restart attempts. Bounded restart loop: if
  /// `restartWindowAttempts` restarts happen within `restartWindowSeconds`,
  /// the plugin is parked in `.crashed` and stops auto-restarting. The user
  /// can recover with `:plugins reload`.
  private var restartTimestamps: [Date] = []
  private static let restartWindowAttempts = 5
  private static let restartWindowSeconds: TimeInterval = 300
  private var restartLoopExhausted = false
  private var requestID: Int = 0
  private var pending: [Int: ([String: Any]?) -> Void] = [:]
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
    settings: [String: PluginConfigValue] = [:]
  ) {
    self.root = root
    self.manifest = manifest
    self.origin = origin
    self.listenPatterns = manifest.listen.map(PluginPattern.init)
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.watchFiles = watchFiles
    self.settings = settings
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
    queue.async { [weak self] in
      self?.startOnQueue(reason: "start")
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue(reason: "stop")
    }
  }

  func reload(reason: String) {
    queue.async { [weak self] in
      guard let self else { return }
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
  /// `discoverTargets` RPC and waits up to `timeout` for the plugin to
  /// return a snapshot of jump targets for the given context. Used on
  /// each activation when the manifest declares `volatile: true`.
  func discoverTargets(context: AppContext, timeout: TimeInterval) -> [JumpTarget] {
    let startedAt = DispatchTime.now()
    let semaphore = DispatchSemaphore(value: 0)
    var snapshot: PluginSnapshot?
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
    sendRequest(method: "discoverTargets", params: params) { [weak self] response in
      guard let self else {
        semaphore.signal()
        return
      }
      if let response {
        snapshot = self.applyDiscoveryResponse(response, defaultPID: context.processID)
      }
      semaphore.signal()
    }
    let waitResult = semaphore.wait(timeout: .now() + timeout)
    let snap =
      snapshot
      ?? {
        lock.lock()
        let s = self.snapshot
        lock.unlock()
        return s
      }()
    let contextMismatch = snap.contextPID.map { $0 != context.processID } ?? false
    if FlashLog.wouldEmit(.debug) {
      var fields: [String: String] = [
        "plugin": manifest.id,
        "pid": "\(context.processID)",
        "bundle": context.bundleIdentifier,
        "snapshot_targets": "\(snap.targets.count)",
        "targets": "\(contextMismatch ? 0 : snap.targets.count)",
        "timed_out": "\(waitResult == .timedOut)",
        "snapshot_fallback": "\(snapshot == nil)",
        "context_mismatch": "\(contextMismatch)",
        "timeout_ms": "\(Int((timeout * 1000).rounded()))",
        "elapsed_ms": Self.elapsedMilliseconds(since: startedAt),
      ]
      if let contextPID = snap.contextPID {
        fields["snapshot_pid"] = "\(contextPID)"
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

  /// Materialise a wire-format target as a host `JumpTarget`. When the
  /// plugin opts into `prefer_host_click`, the `activate` closure is
  /// dropped AND the host-click flag is propagated so
  /// `ActionDispatcher.perform` skips its AX hit-test fallback (which
  /// for terminal surfaces silently "succeeds" via a useless AXPress on
  /// the enclosing window without ever delivering the click) and goes
  /// straight to the real synthesized click.
  private func hostJumpTarget(
    from wire: PluginWireTarget, contextPID: pid_t
  ) -> JumpTarget {
    let activate: ((JumpAction) -> Bool)?
    if wire.preferHostClick {
      activate = nil
    } else {
      activate = { [weak self] action in
        self?.activateTarget(wire.id, action: action)
        return true
      }
    }
    return JumpTarget(
      id: wire.id,
      frame: wire.frame,
      role: wire.role,
      accessibilityLabel: wire.label,
      url: wire.url,
      pid: wire.pid ?? contextPID,
      activate: activate,
      entersInsertMode: wire.entersInsertMode,
      preferHostClick: wire.preferHostClick,
      important: wire.important,
      providerID: wire.sourceID)
  }

  private func applyDiscoveryResponse(_ params: [String: Any], defaultPID: pid_t) -> PluginSnapshot
  {
    let sourceID = params["source_id"] as? String ?? "plugin:\(manifest.id)"
    let contextPID = (params["context_pid"] as? Int).map(pid_t.init) ?? defaultPID
    let targetItems = (params["targets"] as? [[String: Any]] ?? [])
      .compactMap { Self.target(from: $0, sourceID: sourceID) }
    // `discoverTargets` callers (e.g. the tmux plugin) only return
    // targets — the response carries no `candidates` field. Preserving
    // the existing candidates is what lets `:flashlight` keep showing
    // tmux windows between activations; previously every `f` press in
    // alacritty wiped the candidate list to 0 until the next
    // `snapshot.updated` notification re-filled it on the focus tick.
    let previousCandidates: [Candidate]
    let previousStatusSegments: [String: String]
    lock.lock()
    previousCandidates = snapshot.candidates
    previousStatusSegments = snapshot.statusSegments
    lock.unlock()
    let candidateItems: [Candidate]
    if let raw = params["candidates"] as? [[String: Any]] {
      candidateItems = raw.compactMap {
        Self.candidate(
          from: $0,
          pluginID: manifest.id,
          pluginName: manifest.name,
          sourceID: sourceID)
      }
    } else {
      candidateItems = previousCandidates
    }
    let snap = PluginSnapshot(
      targets: targetItems,
      candidates: candidateItems,
      statusSegments: previousStatusSegments,
      contextPID: contextPID,
      updatedAt: Date())
    lock.lock()
    snapshot = snap
    lock.unlock()
    notifyStatus()
    return snap
  }

  func candidates(scope: CandidateScope) -> [Candidate] {
    lock.lock()
    let items = snapshot.candidates
    lock.unlock()
    return items
  }

  func queryCandidates(
    scope: CandidateScope,
    query: String,
    environment: FlashSourceEnvironment,
    completion: @escaping ([Candidate]) -> Void
  ) {
    let applications = environment.runningApplications.compactMap { app -> [String: Any]? in
      guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
      return [
        "bundle_id": bundleID,
        "pid": Int(app.processIdentifier),
        "localized_name": app.localizedName ?? "",
      ]
    }
    let scopeName: String
    switch scope {
    case .running:
      scopeName = "running"
    case .all:
      scopeName = "all"
    }
    let params: [String: Any] = [
      "scope": scopeName,
      "query": query,
      "running_applications": applications,
    ]
    sendRequest(method: "candidateQuery", params: params) { [weak self] response in
      guard let self else {
        DispatchQueue.main.async { completion([]) }
        return
      }
      guard let raw = response?["candidates"] as? [[String: Any]] else {
        let fallback = self.candidates(scope: scope)
        DispatchQueue.main.async { completion(fallback) }
        return
      }
      let sourceID = response?["source_id"] as? String ?? "plugin:\(self.manifest.id)"
      let items = raw.compactMap {
        Self.candidate(
          from: $0,
          pluginID: self.manifest.id,
          pluginName: self.manifest.name,
          sourceID: sourceID)
      }
      self.lock.lock()
      let previous = self.snapshot
      self.snapshot = PluginSnapshot(
        targets: previous.targets,
        candidates: items,
        statusSegments: previous.statusSegments,
        contextPID: previous.contextPID,
        updatedAt: Date())
      self.lock.unlock()
      self.notifyStatus()
      DispatchQueue.main.async {
        completion(items)
      }
    }
  }

  func targets(for context: AppContext) -> [JumpTarget] {
    lock.lock()
    let snap = snapshot
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
      "candidate": candidateJSON(candidate)
    ]
    sendRequest(method: "resolveCandidate", params: params) { response in
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
    params["context"] = contextJSON(context)
    sendRequest(method: "sourceAction", params: params) { [weak self] response in
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
        "[plugin] navigation_restore plugin=\(self?.manifest.id ?? "?") url=\(url.absoluteString) "
          + "disposition=\(result.disposition) "
          + "target_pid=\(result.targetPID.map(String.init) ?? "nil")",
        source: "plugin:\(self?.manifest.id ?? "?")")
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  func statusSnapshot() -> PluginStatusSnapshot {
    lock.lock()
    let snap = snapshot
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
    return PluginStatusSnapshot(
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
      sourceCount: snap.targets.isEmpty && snap.candidates.isEmpty ? 0 : 1,
      commandCount: commands.count,
      targetCount: snap.targets.count,
      candidateCount: snap.candidates.count,
      snapshotAgeMs: snap.updatedAt.map { Int(now.timeIntervalSince($0) * 1000) },
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
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    removeFileWatchers()
    if let process, process.isRunning {
      sendNotification(method: "shutdown", params: ["reason": reason])
      process.terminate()
    }
    process = nil
    stdinPipe = nil
    pending.removeAll()
    awaitingHeartbeat = false
    heartbeatMisses = 0
    setState(.stopped)
  }

  private func launch() throws {
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", manifest.start]
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
    sendRequest(
      method: "initialize",
      params: [
        "plugin_id": manifest.id,
        "version": manifest.version,
      ]
    ) { [weak self] _ in
      self?.clearError()
      self?.setState(.ready)
      // Successful startup resets the backoff counter so a transient crash
      // doesn't accumulate across hours of healthy operation.
      self?.restartCount = 0
      self?.restartTimestamps.removeAll()
    }
  }

  private func installIfNeeded() throws {
    let stampURL = dataDir.appendingPathComponent(".install-stamp")
    let stamp = "\(manifest.version)\n\(manifest.install)\n"
    if let existing = try? String(contentsOf: stampURL), existing == stamp {
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", manifest.install]
    process.currentDirectoryURL = root
    process.environment = pluginEnvironment()
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
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
    body += "# install=\(manifest.install)\n"
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
    // Plugin-specific vars are overrides on the shared login-shell cache so
    // they never leak into the global environment used by other child
    // processes (status bar, command mappings, …).
    FlashProcessEnvironment.shared.environment(withOverrides: [
      "FLASH_PLUGIN_ID": manifest.id,
      "FLASH_PLUGIN_VERSION": manifest.version,
      "FLASH_PLUGIN_DATA_DIR": dataDir.path,
      "FLASH_PLUGIN_CONFIG": settingsJSON,
      "PYTHONDONTWRITEBYTECODE": "1",
    ])
  }

  private func sendRequest(
    method: String,
    params: [String: Any],
    completion: (([String: Any]?) -> Void)? = nil
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.requestID += 1
      let id = self.requestID
      if let completion {
        self.pending[id] = completion
        self.queue.asyncAfter(deadline: .now() + self.requestTimeout) { [weak self] in
          guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
          callback(nil)
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
      // A broken pipe during teardown is expected, so only surface a write
      // failure while the subprocess is supposed to be alive.
      if process?.isRunning == true {
        recordError("[plugin] failed to write IPC message (method=\(label)): \(error)")
      }
    }
  }

  /// Sanity ceiling on a single frame's payload. Real frames are a few KB at
  /// most; anything larger means the stream desynced and the "length" is
  /// really payload bytes misread as a prefix.
  // Real payloads (candidate snapshots, command responses) sit well under
  // 1 MiB. The previous 64 MiB ceiling let a misbehaving plugin starve the
  // host on every frame; 10 MiB still covers any sensible payload while
  // bounding the worst-case allocation.
  private static let maxFrameBytes = 10 * 1024 * 1024

  private func handleStdout(_ data: Data) {
    guard !data.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.stdoutBuffer.append(data)
      self.drainFrames()
    }
  }

  /// Pull every complete length-prefixed MessagePack frame out of
  /// `stdoutBuffer`, leaving any partial tail for the next stdout chunk. The
  /// wire is a 4-byte big-endian payload length followed by that many bytes.
  private func drainFrames() {
    while stdoutBuffer.count >= 4 {
      let base = stdoutBuffer.startIndex
      let length =
        (Int(stdoutBuffer[base]) << 24)
        | (Int(stdoutBuffer[base + 1]) << 16)
        | (Int(stdoutBuffer[base + 2]) << 8)
        | Int(stdoutBuffer[base + 3])
      // A length past the ceiling means the stream desynced (a stray write to
      // the plugin's stdout, say). We can't realign mid-stream, so drop the
      // buffer and surface it rather than try to allocate gigabytes.
      guard length >= 0, length <= Self.maxFrameBytes else {
        recordError("[plugin] invalid frame length \(length); resetting stream")
        stdoutBuffer.removeAll(keepingCapacity: false)
        return
      }
      guard stdoutBuffer.count >= 4 + length else { return }
      let payloadStart = base + 4
      let payloadEnd = payloadStart + length
      let payload = stdoutBuffer.subdata(in: payloadStart..<payloadEnd)
      stdoutBuffer.removeSubrange(base..<payloadEnd)
      handleFrame(payload)
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
    handleProtocolMessage(object)
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

  private func handleProtocolMessage(_ object: [String: Any]) {
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
      }
      if let callback = pending.removeValue(forKey: responseID) {
        callback(result)
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
    case "snapshot.updated":
      applySnapshot(params)
    case "snapshot.invalidated":
      lock.lock()
      snapshot = PluginSnapshot()
      lock.unlock()
      notifyStatus()
    case "status.updated":
      applyStatusSegments(params)
    default:
      break
    }
  }

  private func applySnapshot(_ params: [String: Any]) {
    let sourceID = params["source_id"] as? String ?? "plugin:\(manifest.id)"
    let contextPID = (params["context_pid"] as? Int).map(pid_t.init)
    // Carry previous state forward when a particular slot is missing
    // from the incoming wire frame. Plugins that refresh only one slot
    // (tmux refreshes `candidates` on focus events, omits `targets`)
    // should leave the other unchanged rather than nuke it to empty.
    let previous: PluginSnapshot
    lock.lock()
    previous = snapshot
    lock.unlock()
    let targetItems: [PluginWireTarget]
    if let raw = params["targets"] as? [[String: Any]] {
      targetItems = raw.compactMap { Self.target(from: $0, sourceID: sourceID) }
    } else {
      targetItems = previous.targets
    }
    let candidateItems: [Candidate]
    if let raw = params["candidates"] as? [[String: Any]] {
      candidateItems = raw.compactMap {
        Self.candidate(
          from: $0,
          pluginID: manifest.id,
          pluginName: manifest.name,
          sourceID: sourceID)
      }
    } else {
      candidateItems = previous.candidates
    }
    lock.lock()
    snapshot = PluginSnapshot(
      targets: targetItems,
      candidates: candidateItems,
      statusSegments: previous.statusSegments,
      contextPID: contextPID,
      updatedAt: Date())
    lock.unlock()
    notifyStatus()
  }

  private func applyStatusSegments(_ params: [String: Any]) {
    guard let raw = params["segments"] as? [String: Any] else { return }
    let declared = Set(manifest.statusSegments)
    guard !declared.isEmpty else { return }
    lock.lock()
    let previous = snapshot
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
    snapshot = PluginSnapshot(
      targets: previous.targets,
      candidates: previous.candidates,
      statusSegments: next,
      contextPID: previous.contextPID,
      updatedAt: previous.updatedAt)
    lock.unlock()
    notifyStatus()
  }

  private static func target(from raw: [String: Any], sourceID: String) -> PluginWireTarget? {
    guard let id = raw["id"] as? String else { return nil }
    let frameRaw = raw["frame"] as? [String: Any] ?? raw
    guard
      let x = number(frameRaw["x"]),
      let y = number(frameRaw["y"]),
      let width = number(frameRaw["width"]),
      let height = number(frameRaw["height"]),
      width > 0, height > 0
    else { return nil }
    let role = raw["role"] as? String
    // A plugin can state explicitly whether committing this target should
    // enter insert mode. When it doesn't, fall back to the same AX-role
    // heuristic the core walk uses so text-field hints still type.
    let entersInsertMode =
      raw["enters_insert_mode"] as? Bool
      ?? JumpTarget.textInputRoles.contains(role ?? "")
    return PluginWireTarget(
      id: id,
      frame: CGRect(x: x, y: y, width: width, height: height),
      role: role,
      label: raw["label"] as? String,
      url: raw["url"] as? String,
      pid: (raw["pid"] as? Int).map(pid_t.init),
      entersInsertMode: entersInsertMode,
      sourceID: raw["source_id"] as? String ?? sourceID,
      preferHostClick: raw["prefer_host_click"] as? Bool ?? false,
      important: raw["important"] as? Bool ?? false)
  }

  private static func candidate(
    from raw: [String: Any],
    pluginID: String,
    pluginName: String,
    sourceID: String
  ) -> Candidate? {
    guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
    let url = (raw["url"] as? String).flatMap(URL.init(string:))
    var metadata: [String: String] = [:]
    if let dict = raw["metadata"] as? [String: Any] {
      for (key, value) in dict {
        guard let stringValue = Self.metadataString(value) else { continue }
        metadata[key] = stringValue
      }
    }
    // Fill the host-side routing defaults the plugin may have omitted. These are
    // host conventions, not part of FlashCore's schema — sources are free to
    // override or skip them when they have no meaningful value.
    if metadata[CandidateMetadataKey.source] == nil {
      metadata[CandidateMetadataKey.source] = pluginName
    }
    if metadata[CandidateMetadataKey.sourceID] == nil {
      metadata[CandidateMetadataKey.sourceID] = sourceID
    }
    if metadata[CandidateMetadataKey.kind] == nil {
      metadata[CandidateMetadataKey.kind] = "plugin"
    }
    return Candidate(title: title, url: url, metadata: metadata)
  }

  private static func metadataString(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let bool = value as? Bool { return bool ? "1" : "0" }
    if let int = value as? Int { return String(int) }
    if let int64 = value as? Int64 { return String(int64) }
    if let double = value as? Double { return String(double) }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }

  private func candidateJSON(_ candidate: Candidate) -> [String: Any] {
    var dict: [String: Any] = [
      "title": candidate.title,
      "metadata": candidate.metadata,
    ]
    if let url = candidate.url {
      dict["url"] = url.absoluteString
    }
    return dict
  }

  private func contextJSON(_ context: AppContext) -> [String: Any] {
    [
      "bundle_id": context.bundleIdentifier,
      "front_window_frame": [
        "height": context.frontWindowFrame.height,
        "width": context.frontWindowFrame.width,
        "x": context.frontWindowFrame.minX,
        "y": context.frontWindowFrame.minY,
      ],
      "pid": Int(context.processID),
    ]
  }

  private func activateTarget(_ targetID: String, action: JumpAction) {
    sendNotification(
      method: "activateTarget",
      params: [
        "action": actionName(action),
        "target_id": targetID,
      ])
  }

  private func actionName(_ action: JumpAction) -> String {
    switch action {
    case .leftClick: return "left_click"
    case .rightClick: return "right_click"
    case .doubleClick: return "double_click"
    }
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
    guard process?.isRunning == true else { return }
    if awaitingHeartbeat {
      heartbeatMisses += 1
      setState(.degraded)
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
    DispatchQueue.main.async { [weak self] in
      self?.onStatusChanged?()
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
    let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return String(format: "%.2f", Double(nanos) / 1_000_000)
  }
}

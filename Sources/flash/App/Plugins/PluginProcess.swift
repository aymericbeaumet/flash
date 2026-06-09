import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginProcess {
  let root: URL
  let manifest: PluginManifest
  let origin: PluginOrigin

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
  private var requestID: Int = 0
  private var pending: [Int: ([String: Any]?) -> Void] = [:]
  private var fileWatchers: [DispatchSourceFileSystemObject] = []
  private var fileWatcherFDs: [Int32] = []
  private var reloadWork: DispatchWorkItem?
  private var dynamicCommands: [PluginCommandRegistration] = []
  private var dynamicMappings: [PluginMappingRegistration] = []
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
  /// Fired when the plugin's mappings change at runtime (`mappings.updated`).
  /// Distinct from `onStatusChanged` so the host only rebuilds its mapping
  /// index on real mapping edits, not on every log line / heartbeat.
  var onMappingsChanged: (() -> Void)?
  /// Handles a plugin→host RPC request (`call_host` on the plugin side):
  /// `(method, params, pluginID, reply)`. The host RPC router (PluginManager)
  /// installs this; `reply` is invoked with the JSON result, possibly async
  /// (e.g. AX work hops to the main thread first).
  var onHostRequest:
    ((String, [String: Any], String, @escaping ([String: Any]) -> Void) -> Void)?

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
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.dynamicCommands = manifest.commands
    self.dynamicMappings = manifest.mappings
    self.watchFiles = watchFiles
    self.settings = settings
  }

  var identifier: String { manifest.id }

  var commands: [PluginCommandRegistration] {
    lock.lock()
    defer { lock.unlock() }
    return dynamicCommands
  }

  var mappings: [PluginMappingRegistration] {
    lock.lock()
    defer { lock.unlock() }
    return dynamicMappings
  }

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
      self.stopOnQueue(reason: reason)
      self.startOnQueue(reason: reason)
    }
  }

  func sendEvent(_ event: PluginEvent) {
    guard manifest.events.contains(where: { $0.matches(event) }) else { return }
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
    sendNotification(method: "event", params: [
      "name": event.name,
      "payload": payload,
    ])
  }

  /// Synchronous-style discover for volatile plugins. Sends a
  /// `discoverTargets` RPC and waits up to `timeout` for the plugin to
  /// return a snapshot of jump targets for the given context. Used on
  /// each activation when the manifest declares `volatile: true`.
  func discoverTargets(context: AppContext, timeout: TimeInterval) -> [JumpTarget] {
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
    _ = semaphore.wait(timeout: .now() + timeout)
    let snap = snapshot ?? {
      lock.lock()
      let s = self.snapshot
      lock.unlock()
      return s
    }()
    if let contextPID = snap.contextPID, contextPID != context.processID {
      return []
    }
    return snap.targets.map { wire in
      JumpTarget(
        id: wire.id,
        frame: wire.frame,
        role: wire.role,
        accessibilityLabel: wire.label,
        url: wire.url,
        pid: wire.pid ?? context.processID,
        activate: { [weak self] action in
          self?.activateTarget(wire.id, action: action)
          return true
        },
        providerID: wire.sourceID)
    }
  }

  private func applyDiscoveryResponse(_ params: [String: Any], defaultPID: pid_t) -> PluginSnapshot {
    let sourceID = params["source_id"] as? String ?? "plugin.\(manifest.id)"
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
    lock.lock()
    previousCandidates = snapshot.candidates
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

  func targets(for context: AppContext) -> [JumpTarget] {
    lock.lock()
    let snap = snapshot
    lock.unlock()
    if let contextPID = snap.contextPID, contextPID != context.processID {
      return []
    }
    return snap.targets.map { wire in
      JumpTarget(
        id: wire.id,
        frame: wire.frame,
        role: wire.role,
        accessibilityLabel: wire.label,
        url: wire.url,
        pid: wire.pid ?? context.processID,
        activate: { [weak self] action in
          self?.activateTarget(wire.id, action: action)
          return true
        },
        providerID: wire.sourceID)
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
      DispatchQueue.main.async {
        completion(didResolve ? .resolved(pid: pid.map(pid_t.init)) : .unresolved)
      }
    }
  }

  func invokeCommand(
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    meta: [String: String] = [:],
    completion: ((Bool, pid_t?, String?) -> Void)? = nil
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
      // A command may also return `stdout` for Flash to surface as a toast
      // (e.g. the calculator returns "2 + 2 = 4"). Optional.
      let stdout = (response?["stdout"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      DispatchQueue.main.async {
        completion?(ok, pid.map(pid_t.init), stdout)
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
      let didPerform = response?["did_perform"] as? Bool ?? false
      let pid = response?["target_pid"] as? Int
      FlashLog.trace(
        "[plugin] source_action plugin=\(self?.manifest.id ?? "?") name=\(name) "
          + "did_perform=\(didPerform) target_pid=\(pid.map(String.init) ?? "nil")",
        source: "plugin:\(self?.manifest.id ?? "?")")
      DispatchQueue.main.async {
        completion(didPerform ? .performed(pid: pid.map(pid_t.init)) : .unhandled)
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
    let commands = dynamicCommands
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
      bundleIDs: manifest.bundleIDs,
      volatile: manifest.volatile,
      priority: manifest.priority,
      commands: commands)
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
    sendRequest(method: "initialize", params: [
      "plugin_id": manifest.id,
      "version": manifest.version,
    ]) { [weak self] _ in
      self?.clearError()
      self?.setState(.ready)
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
    process.standardOutput = FileHandle.nullDevice
    let err = Pipe()
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let data = err.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw PluginError.processLaunch("install failed status=\(process.terminationStatus) \(message ?? "")")
    }
    try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
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
    var env = ProcessInfo.processInfo.environment
    if env["PATH", default: ""].isEmpty {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    env["FLASH_PLUGIN_ID"] = manifest.id
    env["FLASH_PLUGIN_VERSION"] = manifest.version
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
    env["FLASH_PLUGIN_CONFIG"] = settingsJSON
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env
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
    // `cli.run` is served here, by the very process that owns this plugin's
    // sandbox — the core executes the subprocess so the plugin never touches
    // the process API. Everything else routes up to the host RPC router
    // (AX broker, app activation, …) installed by PluginManager.
    if method == "cli.run" {
      runHostCLI(params) { [weak self] result in
        self?.sendResponse(id: id, result: result)
      }
      return
    }
    guard let onHostRequest else {
      sendResponse(id: id, result: ["ok": false, "error": "host requests unsupported"])
      return
    }
    onHostRequest(method, params, manifest.id) { [weak self] result in
      self?.sendResponse(id: id, result: result)
    }
  }

  /// Executes `cli.run`: spawns `argv` inside this plugin's sandbox (HOME and
  /// the XDG base dirs redirected under `dataDir`, `dataDir/bin` prepended to
  /// PATH), bounded by `timeout_ms`. Mirrors the old in-plugin runner so the
  /// `Context::run_cli` contract is unchanged for plugins. Runs off the plugin
  /// IPC queue so a slow command never stalls protocol I/O; `reply` lands on a
  /// background queue and `sendResponse` re-hops to `queue` to write.
  private func runHostCLI(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    let argv = params["argv"] as? [String] ?? []
    guard let program = argv.first, !program.isEmpty else {
      reply(["ok": false, "stdout": "", "stderr": "missing command", "status": -1])
      return
    }
    let timeoutMs = (params["timeout_ms"] as? Int) ?? 5000
    let quiet = params["quiet"] as? Bool ?? false
    let dataDir = self.dataDir
    let pluginID = manifest.id
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let started = Date()
      let result = Self.runSandboxedCLI(
        argv: argv, dataDir: dataDir, timeoutMs: timeoutMs)
      if !quiet {
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let programName = (program as NSString).lastPathComponent
        let ok = result["ok"] as? Bool ?? false
        let status = result["status"] as? Int ?? -1
        let fields: [String: String] = [
          "program": programName,
          "command": Self.shorten(argv.joined(separator: " ")),
          "argc": String(argv.count - 1),
          "status": String(status),
          "duration_ms": String(durationMs),
          "ok": String(ok),
          "stdout": (result["stdout"] as? String) ?? "",
          "stderr": (result["stderr"] as? String) ?? "",
        ]
        let outcome = ok ? "ok" : "failed (status \(status))"
        FlashLog.plugin(
          ok ? .debug : .warn,
          pluginID: pluginID,
          message: "ran \(programName): \(outcome) in \(durationMs)ms",
          fields: fields)
        self?.lock.lock()
        self?.lastLog = "ran \(programName): \(outcome)"
        self?.lock.unlock()
        self?.notifyStatus()
      }
      reply(result)
    }
  }

  /// Runs `argv` with the plugin sandbox env and a hard timeout, returning the
  /// `{ok, stdout, stderr, status}` wire shape. `124` on timeout, `127` when
  /// the program is not found — matching the prior in-plugin semantics.
  private static func runSandboxedCLI(
    argv: [String], dataDir: URL, timeoutMs: Int
  ) -> [String: Any] {
    let process = Process()
    // Run through `env` so a bare program name resolves against the sandbox
    // PATH (and absolute paths still work), matching the old runner.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    process.currentDirectoryURL = dataDir
    var env = ProcessInfo.processInfo.environment
    if (env["PATH"] ?? "").isEmpty {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    let bin = dataDir.appendingPathComponent("bin").path
    env["PATH"] = bin + ":" + (env["PATH"] ?? "")
    env["HOME"] = dataDir.appendingPathComponent("home").path
    env["XDG_CONFIG_HOME"] = dataDir.appendingPathComponent("config").path
    env["XDG_CACHE_HOME"] = dataDir.appendingPathComponent("cache").path
    env["XDG_DATA_HOME"] = dataDir.appendingPathComponent("share").path
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch let error as NSError where error.code == NSFileNoSuchFileError {
      return ["ok": false, "stdout": "", "stderr": "command not found: \(argv[0])", "status": 127]
    } catch {
      return ["ok": false, "stdout": "", "stderr": "\(error)", "status": -1]
    }
    let timeout = DispatchTime.now() + .milliseconds(max(1, timeoutMs))
    let killer = DispatchWorkItem {
      if process.isRunning { process.terminate() }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: timeout, execute: killer)
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let timedOut = killer.isCancelled == false && process.terminationReason == .uncaughtSignal
    killer.cancel()
    let stdout = Self.shorten(String(data: outData, encoding: .utf8) ?? "")
    let stderr = Self.shorten(String(data: errData, encoding: .utf8) ?? "")
    if timedOut {
      return [
        "ok": false, "stdout": stdout,
        "stderr": "command timed out after \(timeoutMs)ms", "status": 124,
      ]
    }
    let status = Int(process.terminationStatus)
    return ["ok": status == 0, "stdout": stdout, "stderr": stderr, "status": status]
  }

  /// Truncate to a fixed character budget so a chatty command can't push a
  /// giant frame back over IPC. Mirrors the SDK's `shorten`.
  private static func shorten(_ value: String) -> String {
    let limit = 2000
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit - 3)) + "..."
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
  private static let maxFrameBytes = 64 * 1024 * 1024

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
        .trimmingCharacters(in: .whitespacesAndNewlines),
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
    case "plugin.status":
      if let message = params["message"] as? String {
        lastLog = message
      }
      notifyStatus()
    case "commands.updated":
      if let raw = params["commands"] as? [[String: Any]] {
        let commands = raw.compactMap(Self.command(from:))
        lock.lock()
        dynamicCommands = commands
        lock.unlock()
        notifyStatus()
      }
    case "mappings.updated":
      if let raw = params["mappings"] as? [[String: Any]] {
        let mappings = raw.compactMap(Self.mapping(from:))
        lock.lock()
        dynamicMappings = mappings
        lock.unlock()
        onMappingsChanged?()
        notifyStatus()
      }
    default:
      break
    }
  }

  private func applySnapshot(_ params: [String: Any]) {
    let sourceID = params["source_id"] as? String ?? "plugin.\(manifest.id)"
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
      contextPID: contextPID,
      updatedAt: Date())
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
    return PluginWireTarget(
      id: id,
      frame: CGRect(x: x, y: y, width: width, height: height),
      role: raw["role"] as? String,
      label: raw["label"] as? String,
      url: raw["url"] as? String,
      pid: (raw["pid"] as? Int).map(pid_t.init),
      sourceID: raw["source_id"] as? String ?? sourceID)
  }

  private static func candidate(
    from raw: [String: Any],
    pluginID: String,
    pluginName: String,
    sourceID: String
  ) -> Candidate? {
    guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
    let source = raw["source"] as? String ?? pluginName
    let kind = candidateKind(raw["kind"] as? String)
    let url = (raw["url"] as? String).flatMap(URL.init(string:))
    return Candidate(
      kind: kind,
      sourceID: raw["source_id"] as? String ?? sourceID,
      source: source,
      pid: (raw["pid"] as? Int).map(pid_t.init),
      name: name,
      subtitle: raw["subtitle"] as? String ?? "",
      bundleIdentifier: raw["bundle_id"] as? String ?? "",
      url: url,
      sourcePayload: raw["payload"].flatMap(Self.payloadString))
  }

  private static func command(from raw: [String: Any]) -> PluginCommandRegistration? {
    guard let command = raw["command"] as? String,
      let subcommand = raw["subcommand"] as? String
    else { return nil }
    return PluginCommandRegistration(
      command: command,
      subcommand: subcommand,
      description: raw["description"] as? String ?? "")
  }

  private static func mapping(from raw: [String: Any]) -> PluginMappingRegistration? {
    guard let key = raw["key"] as? String, !key.isEmpty,
      let command = raw["command"] as? String, !command.isEmpty
    else { return nil }
    return PluginMappingRegistration(
      key: key,
      mode: raw["mode"] as? String ?? "normal",
      command: command,
      bundleIDs: raw["bundle_ids"] as? [String] ?? [],
      priority: raw["priority"] as? Int)
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }

  private static func payloadString(_ value: Any) -> String? {
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func candidateKind(_ raw: String?) -> CandidateKind {
    switch raw {
    case "app":
      return .app
    case let value?:
      return .plugin(value)
    case nil:
      return .plugin("plugin")
    }
  }

  private func candidateJSON(_ candidate: Candidate) -> [String: Any] {
    [
      "bundle_id": candidate.bundleIdentifier,
      "kind": "\(candidate.kind)",
      "name": candidate.name,
      "payload": candidate.sourcePayload ?? NSNull(),
      "pid": candidate.pid.map { Int($0) } ?? NSNull(),
      "source": candidate.source,
      "source_id": candidate.sourceID,
      "subtitle": candidate.subtitle,
      "url": candidate.url?.absoluteString ?? NSNull(),
    ]
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
    sendNotification(method: "activateTarget", params: [
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
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return }
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
}

import AppKit
import Darwin
import FlashCore
import Foundation

struct PluginEventSubscription: Codable, Equatable {
  var match: String
  var bundleIDs: [String]
  var paths: [String]
  var focusedOnly: Bool
  var debounceMs: Int?

  init(
    match: String,
    bundleIDs: [String] = [],
    paths: [String] = [],
    focusedOnly: Bool = false,
    debounceMs: Int? = nil
  ) {
    self.match = match
    self.bundleIDs = bundleIDs
    self.paths = paths
    self.focusedOnly = focusedOnly
    self.debounceMs = debounceMs
  }

  init(from decoder: Decoder) throws {
    if let raw = try? decoder.singleValueContainer().decode(String.self) {
      self.init(match: raw)
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let match = try c.decode(String.self, forKey: .match)
    let bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    let paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    let focusedOnly = try c.decodeIfPresent(Bool.self, forKey: .focusedOnly) ?? false
    let debounceMs = try c.decodeIfPresent(Int.self, forKey: .debounceMs)
    self.init(
      match: match,
      bundleIDs: bundleIDs,
      paths: paths,
      focusedOnly: focusedOnly,
      debounceMs: debounceMs)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(match, forKey: .match)
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
    if !paths.isEmpty { try c.encode(paths, forKey: .paths) }
    if focusedOnly { try c.encode(focusedOnly, forKey: .focusedOnly) }
    if let debounceMs { try c.encode(debounceMs, forKey: .debounceMs) }
  }

  enum CodingKeys: String, CodingKey {
    case match
    case bundleIDs = "bundle_ids"
    case paths
    case focusedOnly = "focused_only"
    case debounceMs = "debounce_ms"
  }

  func matches(_ event: PluginEvent) -> Bool {
    guard Self.pattern(match, matches: event.name) else { return false }
    if !bundleIDs.isEmpty {
      guard let bundleID = event.bundleID, bundleIDs.contains(bundleID) else { return false }
    }
    if !paths.isEmpty {
      guard let path = event.configPath else { return false }
      guard paths.contains(where: { Self.pattern($0, matches: path) }) else { return false }
    }
    if focusedOnly, event.focused != true { return false }
    return true
  }

  private static func pattern(_ pattern: String, matches value: String) -> Bool {
    if pattern == "*" { return true }
    if pattern.hasSuffix(".*") {
      return value.hasPrefix(String(pattern.dropLast(1)))
    }
    return pattern == value
  }
}

struct PluginActionRegistration: Codable, Hashable {
  var command: String
  var name: String
  var description: String
}

struct PluginManifest: Codable, Equatable {
  var id: String
  var name: String
  var version: String
  var description: String
  var install: String
  var start: String
  var events: [PluginEventSubscription]
  var actions: [PluginActionRegistration]
  var priority: Int
  var volatile: Bool
  /// Bundle identifiers the source applies to. When non-empty, restricts
  /// `supports()` and jump-target discovery to these apps. Mirrors the
  /// `bundle_ids` filter used on event subscriptions but applies even when
  /// the manifest doesn't subscribe to `focus.changed`.
  var bundleIDs: [String]

  enum CodingKeys: String, CodingKey {
    case id, name, version, description, install, start, events, actions, priority
    case volatile
    case bundleIDs = "bundle_ids"
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String, start: String,
    events: [PluginEventSubscription] = [],
    actions: [PluginActionRegistration] = [],
    priority: Int = 25,
    volatile: Bool = false,
    bundleIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.install = install
    self.start = start
    self.events = events
    self.actions = actions
    self.priority = priority
    self.volatile = volatile
    self.bundleIDs = bundleIDs
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.version = try c.decode(String.self, forKey: .version)
    self.description = try c.decode(String.self, forKey: .description)
    self.install = try c.decode(String.self, forKey: .install)
    self.start = try c.decode(String.self, forKey: .start)
    self.events = try c.decodeIfPresent([PluginEventSubscription].self, forKey: .events) ?? []
    self.actions = try c.decodeIfPresent([PluginActionRegistration].self, forKey: .actions) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.volatile = try c.decodeIfPresent(Bool.self, forKey: .volatile) ?? false
    self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(version, forKey: .version)
    try c.encode(description, forKey: .description)
    try c.encode(install, forKey: .install)
    try c.encode(start, forKey: .start)
    if !events.isEmpty { try c.encode(events, forKey: .events) }
    if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
    try c.encode(priority, forKey: .priority)
    if volatile { try c.encode(volatile, forKey: .volatile) }
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
  }

  static func load(from root: URL) throws -> PluginManifest {
    let url = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()
    return manifest
  }

  func validate() throws {
    let required = [
      ("id", id),
      ("name", name),
      ("version", version),
      ("description", description),
      ("install", install),
      ("start", start),
    ]
    for (field, value) in required {
      if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw PluginError.invalidManifest("manifest.json field \(field) must not be empty")
      }
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard id.lowercased() == id,
      id.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw PluginError.invalidManifest("manifest.json id must be lowercase [a-z0-9._-]")
    }
    for action in actions {
      if action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw PluginError.invalidManifest("plugin action command and name must not be empty")
      }
    }
  }
}

enum PluginError: Error, CustomStringConvertible {
  case invalidManifest(String)
  case invalidReference(String)
  case processLaunch(String)

  var description: String {
    switch self {
    case .invalidManifest(let message), .invalidReference(let message), .processLaunch(let message):
      return message
    }
  }
}

enum PluginOrigin: Equatable {
  case official
  case github(String)
  case file(String)

  var label: String {
    switch self {
    case .official:
      return "official"
    case .github(let ref), .file(let ref):
      return ref
    }
  }
}

enum PluginRuntimeState: String {
  case unloaded
  case installing
  case starting
  case ready
  case degraded
  case crashed
  case stopped
}

struct PluginEvent {
  var name: String
  var payload: [String: Any]
  var bundleID: String?
  var configPath: String?
  var focused: Bool?
  /// Front window frame (screen coordinates). Optional — only meaningful
  /// for app-scoped events like `focus.changed`, `ax.changed`. Passed
  /// through to plugins as `payload.front_window_frame`.
  var frontWindowFrame: CGRect?
  /// Process id of the focused app for the event. Some events embed this
  /// in `payload.pid` already; setting this here also lets PluginProcess
  /// scope its snapshot to the right context.
  var pid: pid_t?
}

struct PluginStatusSnapshot {
  var id: String
  var name: String
  var version: String
  var origin: String
  var state: String
  var pid: Int?
  var uptimeMs: Int?
  var heartbeatAgeMs: Int?
  var sourceCount: Int
  var actionCount: Int
  var targetCount: Int
  var candidateCount: Int
  var snapshotAgeMs: Int?
  var restartCount: Int
  var lastError: String?
  var lastLog: String?

  var jsonObject: [String: Any] {
    [
      "action_count": actionCount,
      "candidate_count": candidateCount,
      "heartbeat_age_ms": heartbeatAgeMs ?? NSNull(),
      "id": id,
      "last_error": lastError ?? NSNull(),
      "last_log": lastLog ?? NSNull(),
      "name": name,
      "origin": origin,
      "pid": pid ?? NSNull(),
      "restart_count": restartCount,
      "snapshot_age_ms": snapshotAgeMs ?? NSNull(),
      "source_count": sourceCount,
      "state": state,
      "target_count": targetCount,
      "uptime_ms": uptimeMs ?? NSNull(),
      "version": version,
    ]
  }
}

private struct PluginSnapshot {
  var targets: [PluginWireTarget] = []
  var candidates: [Candidate] = []
  var contextPID: pid_t?
  var updatedAt: Date?
}

private struct PluginWireTarget {
  var id: String
  var frame: CGRect
  var role: String?
  var label: String?
  var url: String?
  var pid: pid_t?
  var sourceID: String
}

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
  private var dynamicActions: [PluginActionRegistration] = []
  private var lastError: String?
  private var lastLog: String?
  private var watchFilesEnabled: Bool
  var onStatusChanged: (() -> Void)?

  init(
    root: URL,
    manifest: PluginManifest,
    origin: PluginOrigin,
    baseDataDir: URL,
    watchFiles: Bool = false
  ) {
    self.root = root
    self.manifest = manifest
    self.origin = origin
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.dynamicActions = manifest.actions
    self.watchFilesEnabled = watchFiles
  }

  var identifier: String { manifest.id }

  var actions: [PluginActionRegistration] {
    lock.lock()
    defer { lock.unlock() }
    return dynamicActions
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

  /// Toggle the per-plugin file watcher at runtime. Called when the
  /// debug.watch_plugins config flips. Off → stop watching but keep
  /// the process running; on → install watchers if the process is up.
  func setWatchFiles(_ enabled: Bool) {
    queue.async { [weak self] in
      guard let self, self.watchFilesEnabled != enabled else { return }
      self.watchFilesEnabled = enabled
      if enabled, self.process?.isRunning == true {
        self.installFileWatchers()
      } else if !enabled {
        self.removeFileWatchers()
      }
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
    let candidateItems = (params["candidates"] as? [[String: Any]] ?? [])
      .compactMap {
        Self.candidate(
          from: $0,
          pluginID: manifest.id,
          pluginName: manifest.name,
          sourceID: sourceID)
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

  func invokeAction(
    command: String,
    name: String,
    args: [String],
    raw: String,
    completion: ((Bool) -> Void)? = nil
  ) {
    sendRequest(
      method: "action.invoke",
      params: [
        "args": args,
        "command": command,
        "name": name,
        "raw": raw,
      ]
    ) { response in
      let ok = response?["ok"] as? Bool ?? false
      DispatchQueue.main.async {
        completion?(ok)
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
    sendRequest(method: "sourceAction", params: params) { response in
      let didPerform = response?["did_perform"] as? Bool ?? false
      let pid = response?["target_pid"] as? Int
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
    let actions = dynamicActions
    lock.unlock()
    let now = Date()
    return PluginStatusSnapshot(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      origin: origin.label,
      state: state.rawValue,
      pid: pid.map(Int.init),
      uptimeMs: startDate.map { Int(now.timeIntervalSince($0) * 1000) },
      heartbeatAgeMs: lastHeartbeatAt.map { Int(now.timeIntervalSince($0) * 1000) },
      sourceCount: snap.targets.isEmpty && snap.candidates.isEmpty ? 0 : 1,
      actionCount: actions.count,
      targetCount: snap.targets.count,
      candidateCount: snap.candidates.count,
      snapshotAgeMs: snap.updatedAt.map { Int(now.timeIntervalSince($0) * 1000) },
      restartCount: restartCount,
      lastError: lastError,
      lastLog: lastLog)
  }

  private func startOnQueue(reason: String) {
    stopOnQueue(reason: "pre_start")
    setState(.installing)
    do {
      try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
      try installIfNeeded()
      setState(.starting)
      try launch()
      if watchFilesEnabled {
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

  private func pluginEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if env["PATH", default: ""].isEmpty {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    env["FLASH_PLUGIN_ID"] = manifest.id
    env["FLASH_PLUGIN_VERSION"] = manifest.version
    env["FLASH_PLUGIN_DATA_DIR"] = dataDir.path
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
        self.queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
          guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
          callback(nil)
        }
      }
      self.writeJSON([
        "id": id,
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
      ])
    }
  }

  private func sendNotification(method: String, params: [String: Any]) {
    queue.async { [weak self] in
      self?.writeJSON([
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
      ])
    }
  }

  private func writeJSON(_ object: [String: Any]) {
    // Drop `.sortedKeys` on the hot path: per-message stable ordering
    // costs CPU we don't need for runtime IPC, and Foundation's default
    // (insertion-order-ish) order is fine for plugin protocols.
    guard JSONSerialization.isValidJSONObject(object),
      var data = try? JSONSerialization.data(withJSONObject: object)
    else { return }
    data.append(10)  // newline
    try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
  }

  private func handleStdout(_ data: Data) {
    guard !data.isEmpty else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.stdoutBuffer.append(data)
      // Linear scan with a moving cursor avoids the previous O(n²)
      // behaviour: `firstIndex(of:)` scanned from index 0 each
      // iteration and `removeSubrange(...newline)` memmove'd the
      // remaining buffer left on every line. For a bulk push of 1000
      // lines that turned into ~500k byte moves. Now we scan once
      // and drop the consumed prefix at the end.
      var cursor = self.stdoutBuffer.startIndex
      let end = self.stdoutBuffer.endIndex
      var lastConsumed = self.stdoutBuffer.startIndex
      while cursor < end {
        if self.stdoutBuffer[cursor] == 10 {
          let lineRange = lastConsumed..<cursor
          if !lineRange.isEmpty,
            let line = String(data: self.stdoutBuffer[lineRange], encoding: .utf8),
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            self.handleProtocolLine(line)
          }
          lastConsumed = self.stdoutBuffer.index(after: cursor)
        }
        cursor = self.stdoutBuffer.index(after: cursor)
      }
      if lastConsumed > self.stdoutBuffer.startIndex {
        self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex..<lastConsumed)
      }
    }
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

  private func handleProtocolLine(_ line: String) {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      recordError("[plugin] invalid JSOND line")
      return
    }
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
    case "actions.updated":
      if let raw = params["actions"] as? [[String: Any]] {
        let actions = raw.compactMap(Self.action(from:))
        lock.lock()
        dynamicActions = actions
        lock.unlock()
        notifyStatus()
      }
    default:
      break
    }
  }

  private func applySnapshot(_ params: [String: Any]) {
    let sourceID = params["source_id"] as? String ?? "plugin.\(manifest.id)"
    let contextPID = (params["context_pid"] as? Int).map(pid_t.init)
    let targetItems = (params["targets"] as? [[String: Any]] ?? [])
      .compactMap { Self.target(from: $0, sourceID: sourceID) }
    let candidateItems = (params["candidates"] as? [[String: Any]] ?? [])
      .compactMap {
        Self.candidate(
          from: $0,
          pluginID: manifest.id,
          pluginName: manifest.name,
          sourceID: sourceID)
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
      tmuxClientTTY: nil,
      tmuxTarget: nil,
      targetElement: nil,
      sourcePayload: raw["payload"].flatMap(Self.payloadString))
  }

  private static func action(from raw: [String: Any]) -> PluginActionRegistration? {
    guard let command = raw["command"] as? String,
      let name = raw["name"] as? String
    else { return nil }
    return PluginActionRegistration(
      command: command,
      name: name,
      description: raw["description"] as? String ?? "")
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
    case "tmux_window":
      return .tmuxWindow
    case "browser_tab":
      return .browserTab
    case "slack_channel":
      return .slackChannel
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
    writeJSON([
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

final class PluginFlashSource: FlashSource {
  private let plugin: PluginProcess

  init(plugin: PluginProcess) {
    self.plugin = plugin
  }

  var identifier: String { "plugin.\(plugin.identifier)" }
  var displayName: String { plugin.manifest.name }
  var priority: Int { plugin.manifest.priority }
  var capabilities: FlashSourceCapabilities {
    [
      .jumpTargets, .candidates, .appActivation, .tabSelection, .tabCreation, .tabNavigation,
      .tabClosing,
    ]
  }
  var activationPolicy: FlashSourceActivationPolicy {
    let manifestBundles = Set(plugin.manifest.bundleIDs)
    return manifestBundles.isEmpty ? .always : .bundleIDs(manifestBundles)
  }
  var readinessPolicy: FlashSourceReadinessPolicy {
    plugin.manifest.volatile ? .volatile : .continuous
  }
  var resultsAreVolatile: Bool { plugin.manifest.volatile }

  func supports(_ context: AppContext) -> Bool {
    let manifestBundles = plugin.manifest.bundleIDs
    if !manifestBundles.isEmpty {
      return manifestBundles.contains(context.bundleIdentifier)
    }
    let event = PluginEvent(
      name: "focus.changed",
      payload: [:],
      bundleID: context.bundleIdentifier,
      configPath: nil,
      focused: true)
    return plugin.manifest.events.isEmpty || plugin.manifest.events.contains { $0.matches(event) }
  }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    if plugin.manifest.volatile {
      return plugin.discoverTargets(context: context, timeout: 0.5)
    }
    return plugin.targets(for: context)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    plugin.candidates(scope: scope)
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    // Activate the candidate's owning app on the main thread before
    // the plugin runs its own resolve. Without this step a tmux
    // window pick would correctly run `switch-client` but the
    // terminal app would stay in the background, so the user has
    // to manually click it to see the new window.
    if let pid = candidate.pid,
      let app = NSRunningApplication(processIdentifier: pid)
    {
      DispatchQueue.main.async {
        RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      }
    }
    plugin.resolveCandidate(candidate, completion: completion)
  }

  func candidate(matching target: String, in environment: FlashSourceEnvironment) -> Candidate? {
    candidates(in: environment, scope: .all).first {
      $0.name.localizedCaseInsensitiveContains(target)
        || $0.displayTitle.localizedCaseInsensitiveContains(target)
    }
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(
      name: "tab_select",
      context: context,
      extra: ["index": index],
      completion: completion)
  }

  func tabNext(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_next", context: context, extra: [:], completion: completion)
  }

  func tabPrev(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_prev", context: context, extra: [:], completion: completion)
  }

  func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_new", context: context, extra: [:], completion: completion)
  }

  func tabClose(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    plugin.invokeSourceAction(name: "tab_close", context: context, extra: [:], completion: completion)
  }
}

final class PluginManager {
  private struct ActionKey: Hashable {
    let command: String
    let name: String
  }

  private let queue = DispatchQueue(label: "flash.plugins", qos: .utility)
  private let baseDataDir: URL
  private var pluginsByID: [String: PluginProcess] = [:]
  private var sourceAdaptersByID: [String: PluginFlashSource] = [:]
  /// Pre-computed action lookup index: `(command, name)` →
  /// `PluginProcess`. Built from `pluginsByID` whenever the plugin set
  /// changes; per-invoke lookup is then O(1) instead of walking every
  /// plugin × every action × `localizedCaseInsensitiveCompare`.
  /// Keys are lowercased; lookups use the same normalisation.
  private var actionIndex: [ActionKey: PluginProcess] = [:]
  private var watchFiles: Bool = false
  var onStateChanged: (() -> Void)?

  init(baseDataDir: URL = PluginManager.defaultDataDir()) {
    self.baseDataDir = baseDataDir
  }

  var sources: [FlashSource] {
    queue.sync { Array(sourceAdaptersByID.values) }
  }

  func start(config: Config) {
    updateConfig(config)
  }

  func stop() {
    queue.sync {
      for plugin in pluginsByID.values {
        plugin.stop()
      }
      pluginsByID.removeAll()
      actionIndex.removeAll()
      sourceAdaptersByID.removeAll()
    }
  }

  func updateConfig(_ config: Config) {
    queue.async { [weak self] in
      self?.reloadDesiredPlugins(config: config)
    }
  }

  func emit(_ event: PluginEvent) {
    queue.async { [weak self] in
      guard let self else { return }
      for plugin in self.pluginsByID.values {
        plugin.sendEvent(event)
      }
    }
  }

  func invoke(command: String, name: String, args: [String], raw: String) -> Bool {
    let key = ActionKey(command: command.lowercased(), name: name.lowercased())
    let plugin = queue.sync { actionIndex[key] }
    guard let plugin else { return false }
    plugin.invokeAction(command: command, name: name, args: args, raw: raw) { ok in
      FlashLog.debug("[plugin_action] command=\(command) name=\(name) ok=\(ok)")
    }
    return true
  }

  func actionRegistrations() -> [PluginActionRegistration] {
    queue.sync {
      pluginsByID.values.flatMap { $0.actions }
    }
  }

  func hasAction(command: String, name: String) -> Bool {
    let key = ActionKey(command: command.lowercased(), name: name.lowercased())
    return queue.sync { actionIndex[key] != nil }
  }

  /// Rebuild the action lookup index. Must be called from `queue` after
  /// `pluginsByID` changes.
  private func rebuildActionIndex() {
    var next: [ActionKey: PluginProcess] = [:]
    for plugin in pluginsByID.values {
      for registration in plugin.actions {
        let key = ActionKey(
          command: registration.command.lowercased(),
          name: registration.name.lowercased())
        // First plugin to register an action wins on collision, matching
        // the previous walk's first-match semantics.
        if next[key] == nil { next[key] = plugin }
      }
    }
    actionIndex = next
  }

  func statusText() -> String {
    let snapshots = statusSnapshots()
    guard !snapshots.isEmpty else {
      return "PLUGINS\n\nNo plugins loaded."
    }
    let headers = ["ID", "STATE", "PID", "HEARTBEAT", "SNAPSHOT", "ACTIONS", "ORIGIN"]
    let rows = snapshots.map { snapshot in
      [
        "\(snapshot.id) \(snapshot.version)",
        snapshot.state,
        snapshot.pid.map(String.init) ?? "-",
        snapshot.heartbeatAgeMs.map { "\($0)ms" } ?? "-",
        "\(snapshot.targetCount)t/\(snapshot.candidateCount)c",
        "\(snapshot.actionCount)",
        snapshot.origin,
      ]
    }
    let widths = headers.indices.map { idx in
      max(headers[idx].count, rows.map { $0[idx].count }.max() ?? 0)
    }
    func padded(_ value: String, _ idx: Int) -> String {
      value + String(repeating: " ", count: max(0, widths[idx] - value.count))
    }
    var lines = ["PLUGINS", ""]
    lines.append(headers.indices.map { padded(headers[$0], $0) }.joined(separator: "  "))
    for row in rows {
      lines.append(row.indices.map { padded(row[$0], $0) }.joined(separator: "  "))
    }
    let errors = snapshots.compactMap { snapshot -> String? in
      guard let error = snapshot.lastError, !error.isEmpty else { return nil }
      return "\(snapshot.id): \(error)"
    }
    if !errors.isEmpty {
      lines.append("")
      lines.append("LAST ERRORS")
      lines.append(contentsOf: errors)
    }
    return lines.joined(separator: "\n")
  }

  func statusSnapshots() -> [PluginStatusSnapshot] {
    queue.sync {
      pluginsByID.values.map { $0.statusSnapshot() }.sorted { $0.id < $1.id }
    }
  }

  func stateJSON() -> [[String: Any]] {
    statusSnapshots().map(\.jsonObject)
  }

  private func reloadDesiredPlugins(config: Config) {
    watchFiles = config.debug.watchPlugins
    var desired: [(root: URL, origin: PluginOrigin)] = officialPluginRoots().map {
      ($0, .official)
    }
    for ref in config.plugins.thirdParty {
      if let materialized = materialize(ref) {
        desired.append(materialized)
      }
    }

    var nextIDs = Set<String>()
    for item in desired {
      do {
        let manifest = try PluginManifest.load(from: item.root)
        if nextIDs.contains(manifest.id) {
          FlashLog.warn("[plugins] duplicate plugin id \(manifest.id) ignored")
          continue
        }
        nextIDs.insert(manifest.id)
        let existing = pluginsByID[manifest.id]
        if existing?.root == item.root, existing?.manifest == manifest {
          existing?.setWatchFiles(watchFiles)
          continue
        }
        existing?.stop()
        let plugin = PluginProcess(
          root: item.root,
          manifest: manifest,
          origin: item.origin,
          baseDataDir: baseDataDir,
          watchFiles: watchFiles)
        plugin.onStatusChanged = { [weak self] in self?.notifyStateChanged() }
        pluginsByID[manifest.id] = plugin
        sourceAdaptersByID[manifest.id] = PluginFlashSource(plugin: plugin)
        plugin.start()
      } catch {
        FlashLog.warn("[plugins] failed to load \(item.root.path): \(error)")
      }
    }

    for id in Array(pluginsByID.keys) where !nextIDs.contains(id) {
      pluginsByID[id]?.stop()
      pluginsByID.removeValue(forKey: id)
      sourceAdaptersByID.removeValue(forKey: id)
    }
    rebuildActionIndex()
    notifyStateChanged()
  }

  /// Stop every loaded plugin and restart it. Triggered by
  /// `:plugins reload`. Returns the IDs that were restarted so
  /// callers can include them in a confirmation alert.
  @discardableResult
  func reloadAll() -> [String] {
    let ids: [String] = queue.sync {
      let snapshot = Array(pluginsByID.keys).sorted()
      for id in snapshot {
        pluginsByID[id]?.reload(reason: "plugins_reload")
      }
      return snapshot
    }
    notifyStateChanged()
    return ids
  }

  private func materialize(_ ref: PluginReference) -> (root: URL, origin: PluginOrigin)? {
    switch ref.kind {
    case .file(let path):
      return (URL(fileURLWithPath: path), .file(ref.raw))
    case .github(let owner, let repository):
      let root = baseDataDir.appendingPathComponent("github/\(owner)-\(repository)")
      let url = "https://github.com/\(owner)/\(repository).git"
      do {
        try FileManager.default.createDirectory(
          at: root.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: root.path) {
          _ = runShell("git -C \(shellQuote(root.path)) pull --ff-only")
        } else {
          _ = runShell("git clone \(shellQuote(url)) \(shellQuote(root.path))")
        }
        return (root, .github(ref.raw))
      } catch {
        FlashLog.warn("[plugins] failed to materialize \(ref.raw): \(error)")
        return nil
      }
    }
  }

  /// Runs `command` via `/bin/sh -lc`, bounded by a 60s timeout. The
  /// timeout protects config reload from a network-stalled `git pull`
  /// or `git clone` — without it, a stuck shell hangs the whole plugin
  /// reload until the OS eventually kills the orphan process. On
  /// timeout the child is terminated and `false` is returned.
  private func runShell(_ command: String, timeoutSeconds: TimeInterval = 60) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    let timeout = DispatchTime.now() + .nanoseconds(Int(timeoutSeconds * 1_000_000_000))
    let killer = DispatchQueue.global(qos: .utility)
    let workItem = DispatchWorkItem {
      if process.isRunning {
        process.terminate()
      }
    }
    killer.asyncAfter(deadline: timeout, execute: workItem)
    process.waitUntilExit()
    workItem.cancel()
    return process.terminationStatus == 0
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func manifestRoots(in candidates: [URL], fileManager fm: FileManager = .default) -> [URL] {
    var roots: [URL] = []
    var seenBases = Set<String>()
    var seenRoots = Set<String>()
    for candidate in candidates {
      let bases = [candidate, candidate.resolvingSymlinksInPath()]
      for base in bases where seenBases.insert(base.path).inserted {
        guard let children = try? fm.contentsOfDirectory(
          at: base,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])
        else { continue }
        for child in children {
          let root = child.resolvingSymlinksInPath()
          guard fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            continue
          }
          guard seenRoots.insert(root.path).inserted else { continue }
          roots.append(root)
        }
      }
    }
    return roots
  }

  private func officialPluginRoots() -> [URL] {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Plugins"),
    ].compactMap { $0 }
    return Self.manifestRoots(in: candidates)
  }

  private func notifyStateChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.onStateChanged?()
    }
  }

  static func defaultDataDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Flash/Plugins")
  }
}

extension PluginManager {
  static let helpTopic = HelpTopic(
    name: "plugins",
    title: "Plugins",
    summary: "Managed stdio plugins, manifests, events, and actions.",
    body: """
      # Plugins

      Plugins are managed child processes owned by Flash. Each plugin has a
      required `manifest.json` with `id`, `name`, `version`, `description`,
      `install`, and `start` strings. `install` and `start` are shell command
      strings, similar to npm scripts.

      Official bundled plugins are always enabled. Third-party plugins are
      listed in `[plugins] third_party` as `github:user/project` or
      `file:<path>`.

      Flash starts plugins with:

      - `FLASH_PLUGIN_ID`
      - `FLASH_PLUGIN_VERSION`
      - `FLASH_PLUGIN_DATA_DIR`

      Protocol input is JSOND on stdin. Successful and failed protocol results
      are JSOND on stdout. Unexpected plugin errors go to stderr. Plugins can
      log through the protocol and Flash records those messages with
      `source = "plugin:<id>"`.

      Plugins can subscribe to events such as `apps.*`, `config.*`, and
      focused AX changes. They can also register command actions. For example,
      a Spotify plugin can register the `spotify` command and a `pause` action,
      which users run as `:spotify pause`.

      Official bundled plugins are installed under `FLASH_PLUGIN_DATA_DIR`;
      they do not write CLI binaries into global shell paths. Bundled commands
      include `:spotify`, `:github`, `:linear`, `:slack`, and `:notion`.
      Authentication is explicit through actions such as `:github login`;
      install and start do not run login flows.

      `flash://plugins` or `:plugins` opens the plugin status modal. When
      `[debug] http_host = localhost:4242` is set, the debug page shows live
      logs, resolved config, and plugin state.
      """)
}

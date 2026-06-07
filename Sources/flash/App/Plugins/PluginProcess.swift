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
  private var dynamicActions: [PluginActionRegistration] = []
  private var lastError: String?
  private var lastLog: String?
  var onStatusChanged: (() -> Void)?

  init(
    root: URL,
    manifest: PluginManifest,
    origin: PluginOrigin,
    baseDataDir: URL
  ) {
    self.root = root
    self.manifest = manifest
    self.origin = origin
    self.dataDir = baseDataDir.appendingPathComponent(manifest.id)
    self.queue = DispatchQueue(label: "flash.plugin.\(manifest.id)", qos: .utility)
    self.dynamicActions = manifest.actions
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
      installFileWatchers()
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

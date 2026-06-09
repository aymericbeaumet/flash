import AppKit
import Darwin
import FlashCore
import Foundation

final class PluginManager {
  private struct CommandKey: Hashable {
    let command: String
    let subcommand: String
  }

  /// A resolved command target: the owning plugin plus the matched manifest
  /// entry's `_`-prefixed metadata, forwarded to the plugin on invoke.
  /// `bundleIDs` carries the command's app gate (empty ⇒ every app), applied at
  /// lookup against the focused app — the same predicate `ResolvedPluginMapping`
  /// uses.
  private struct CommandTarget {
    let plugin: PluginProcess
    let bundleIDs: [String]
    let meta: [String: String]

    /// Whether this command is available while `bundleID` is the focused app.
    /// An app-scoped command (non-empty `bundleIDs`) needs a known focused app
    /// that matches; an unconditional command is always available.
    func matches(bundleID: String?) -> Bool {
      if bundleIDs.isEmpty { return true }
      guard let bundleID else { return false }
      return bundleIDs.contains(bundleID)
    }
  }

  /// A plugin mapping with its `key`/`command` already canonicalized and
  /// parsed (the work done once at index-rebuild time, not per focus-change).
  /// `bundleIDs` empty ⇒ applies to every app the plugin is otherwise scoped
  /// to; non-empty ⇒ only those apps.
  private struct ResolvedPluginMapping {
    let bundleIDs: [String]
    let priority: Int
    let scope: ModeScope
    let mapping: ModeMapping
  }

  private let queue = DispatchQueue(label: "flash.plugins", qos: .utility)
  private let baseDataDir: URL
  private var pluginsByID: [String: PluginProcess] = [:]
  private var sourceAdaptersByID: [String: PluginFlashSource] = [:]
  /// Pre-computed command lookup index: `(command, subcommand)` →
  /// `PluginProcess`. Built from `pluginsByID` whenever the plugin set
  /// changes; per-invoke lookup is then O(1) instead of walking every
  /// plugin × every command × `localizedCaseInsensitiveCompare`.
  /// Keys are lowercased; lookups use the same normalisation.
  private var commandIndex: [CommandKey: CommandTarget] = [:]
  /// Commands that register the wildcard subcommand `"*"`: the verb takes
  /// no fixed subcommand and consumes the whole remainder as args (e.g.
  /// `:calc 2 + 2`). Keyed by lowercased command; consulted only when the
  /// exact `(command, subcommand)` lookup misses.
  private var wildcardCommandIndex: [String: CommandTarget] = [:]
  /// Resolved plugin mappings across all loaded plugins, rebuilt whenever the
  /// plugin set or any plugin's mappings change. `mappings(forBundleID:)`
  /// filters this for the focused app.
  private var mappingIndex: [ResolvedPluginMapping] = []
  /// Owns the single AX (Accessibility) grant and the handle registry that
  /// backs the `ax.*` host RPCs. Plugins never touch AX directly; they reach
  /// it through this broker via `handleHostRequest`.
  private let axBroker = AXBroker()
  var onStateChanged: (() -> Void)?
  /// Fired on the main thread after the mapping index is rebuilt because a
  /// plugin emitted `mappings.updated`. The app recomputes its effective
  /// per-app mapping tables in response.
  var onMappingsChanged: (() -> Void)?

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
      commandIndex.removeAll()
      wildcardCommandIndex.removeAll()
      mappingIndex.removeAll()
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

  /// Returns true when a plugin owns `(command, subcommand)` and the
  /// invocation was dispatched (synchronous ownership check). The plugin
  /// runs asynchronously; `onResult` delivers its `(ok, targetPID, stdout)`
  /// once it replies. `targetPID`, when present, is an app the command asked
  /// Flash to raise; `stdout`, when present, is text to surface as a toast
  /// (see `PluginProcess.invokeCommand`).
  @discardableResult
  func invoke(
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    forBundleID bundleID: String? = nil,
    onResult: ((Bool, pid_t?, String?) -> Void)? = nil
  ) -> Bool {
    let lcCommand = command.lowercased()
    let key = CommandKey(command: lcCommand, subcommand: subcommand.lowercased())
    // Exact `(command, subcommand)` first; on a miss, fall back to a wildcard
    // command that consumes the whole remainder (the parsed subcommand token
    // is really the first arg, e.g. `:calc 2 + 2`). An app-scoped command is
    // only owned here when its gate matches the focused app.
    let resolved: (target: CommandTarget, subcommand: String, args: [String])? = queue.sync {
      if let target = commandIndex[key], target.matches(bundleID: bundleID) {
        return (target, subcommand, args)
      }
      if let target = wildcardCommandIndex[lcCommand], target.matches(bundleID: bundleID) {
        return (target, "", [subcommand] + args)
      }
      return nil
    }
    guard let resolved else { return false }
    resolved.target.plugin.invokeCommand(
      command: command, subcommand: resolved.subcommand, args: resolved.args, raw: raw,
      meta: resolved.target.meta
    ) {
      ok, pid, stdout in
      FlashLog.debug(
        "[plugin_command] command=\(command) subcommand=\(resolved.subcommand) ok=\(ok) "
          + "target_pid=\(pid.map(String.init) ?? "nil")")
      onResult?(ok, pid, stdout)
    }
    return true
  }

  /// Routes a plugin→host RPC request to the matching core capability and
  /// delivers the JSON result via `reply`. This is the single entry point
  /// through which plugins reach native APIs the core owns (the AX broker,
  /// app activation, …) — plugins never touch those APIs directly. `reply`
  /// may be called asynchronously; AX methods hop to the main thread first.
  func handleHostRequest(
    method: String,
    params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch method {
    case "host.ping":
      // Round-trip validation of the bidirectional channel.
      reply(["ok": true, "echo": params])
    case let method where method.hasPrefix("ax."):
      axBroker.handle(method: method, params: params, reply: reply)
    default:
      FlashLog.warn(
        "[plugin] unknown host method \(method) from \(pluginID)",
        fields: ["method": method, "plugin": pluginID])
      reply(["ok": false, "error": "unknown host method: \(method)"])
    }
  }

  /// Command registrations available for completion while `bundleID` is the
  /// focused app. `nil` keeps only unconditional commands (no app context to
  /// satisfy an app gate). App-scoped commands appear only for their apps.
  func commandRegistrations(forBundleID bundleID: String? = nil)
    -> [PluginCommandRegistration]
  {
    queue.sync {
      pluginsByID.values.flatMap { $0.commands }.filter { registration in
        if registration.bundleIDs.isEmpty { return true }
        guard let bundleID else { return false }
        return registration.bundleIDs.contains(bundleID)
      }
    }
  }

  func hasCommand(command: String, subcommand: String, forBundleID bundleID: String? = nil) -> Bool
  {
    let lcCommand = command.lowercased()
    let key = CommandKey(command: lcCommand, subcommand: subcommand.lowercased())
    return queue.sync {
      if let target = commandIndex[key], target.matches(bundleID: bundleID) { return true }
      if let target = wildcardCommandIndex[lcCommand], target.matches(bundleID: bundleID) {
        return true
      }
      return false
    }
  }

  /// Rebuild the command lookup index. Must be called from `queue` after
  /// `pluginsByID` changes.
  private func rebuildCommandIndex() {
    var next: [CommandKey: CommandTarget] = [:]
    var wildcard: [String: CommandTarget] = [:]
    for plugin in pluginsByID.values {
      for registration in plugin.commands {
        let command = registration.command.lowercased()
        let subcommand = registration.subcommand.lowercased()
        let target = CommandTarget(
          plugin: plugin, bundleIDs: registration.bundleIDs, meta: registration.meta)
        if subcommand == "*" {
          if wildcard[command] == nil { wildcard[command] = target }
          continue
        }
        let key = CommandKey(command: command, subcommand: subcommand)
        // First plugin to register a command wins on collision, matching
        // the previous walk's first-match semantics.
        if next[key] == nil { next[key] = target }
      }
    }
    commandIndex = next
    wildcardCommandIndex = wildcard
  }

  /// Rebuild the resolved-mapping index. Must be called from `queue` after
  /// `pluginsByID` or any plugin's mappings change. Canonicalizes the key and
  /// parses the `flash://` command once here so the focus-change path only
  /// filters and merges; invalid entries are dropped with a warning.
  private func rebuildMappingIndex() {
    var next: [ResolvedPluginMapping] = []
    for plugin in pluginsByID.values {
      let manifest = plugin.manifest
      for registration in plugin.mappings {
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(registration.key) else {
          FlashLog.warn(
            "[plugins] mapping key \"\(registration.key)\" from \(manifest.id) "
              + "failed canonicalization")
          continue
        }
        guard let action = parseMappingCommand(rawString: registration.command) else {
          FlashLog.warn(
            "[plugins] mapping command \"\(registration.command)\" from \(manifest.id) "
              + "is not a valid flash:// URL")
          continue
        }
        let bundleIDs = registration.bundleIDs.isEmpty ? manifest.bundleIDs : registration.bundleIDs
        next.append(
          ResolvedPluginMapping(
            bundleIDs: bundleIDs,
            priority: registration.priority ?? manifest.priority,
            scope: registration.scope,
            mapping: ModeMapping(key: canonical, action: action)))
      }
    }
    mappingIndex = next
  }

  /// Plugin mappings applicable to `bundleID`, as
  /// `(priority, scope, mapping)` tuples for `EffectiveMappings.merge`.
  /// A mapping with no bundle scope applies to every app.
  func mappings(
    forBundleID bundleID: String
  ) -> [(priority: Int, scope: ModeScope, mapping: ModeMapping)] {
    queue.sync {
      mappingIndex
        .filter { $0.bundleIDs.isEmpty || $0.bundleIDs.contains(bundleID) }
        .map { ($0.priority, $0.scope, $0.mapping) }
    }
  }

  /// A plugin's mappings changed at runtime: rebuild the index on `queue`,
  /// then notify the app to recompute effective tables on the main thread.
  private func handleMappingsChanged() {
    queue.async { [weak self] in
      guard let self else { return }
      self.rebuildMappingIndex()
      DispatchQueue.main.async { self.onMappingsChanged?() }
    }
  }

  func statusText() -> String {
    let snapshots = statusSnapshots()
    guard !snapshots.isEmpty else {
      return "PLUGINS\n\nNo plugins loaded."
    }
    let headers = ["ID", "STATE", "PID", "HEARTBEAT", "SNAPSHOT", "COMMANDS", "ORIGIN"]
    let rows = snapshots.map { snapshot in
      [
        "\(snapshot.id) \(snapshot.version)",
        snapshot.state,
        snapshot.pid.map(String.init) ?? "-",
        snapshot.heartbeatAgeMs.map { "\($0)ms" } ?? "-",
        "\(snapshot.targetCount)t/\(snapshot.candidateCount)c",
        "\(snapshot.commandCount)",
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
          FlashLog.warn(
            "[plugins] duplicate plugin id \(manifest.id) ignored",
            fields: ["id": manifest.id, "root": item.root.path])
          continue
        }
        nextIDs.insert(manifest.id)
        let settings = config.plugins.settings[manifest.id] ?? [:]
        let existing = pluginsByID[manifest.id]
        if existing?.root == item.root, existing?.manifest == manifest,
          existing?.settings == settings
        {
          continue
        }
        existing?.stop()
        let plugin = PluginProcess(
          root: item.root,
          manifest: manifest,
          origin: item.origin,
          baseDataDir: baseDataDir,
          watchFiles: config.plugins.watchingEnabled,
          settings: settings)
        plugin.onStatusChanged = { [weak self] in self?.notifyStateChanged() }
        plugin.onMappingsChanged = { [weak self] in self?.handleMappingsChanged() }
        plugin.onHostRequest = { [weak self] method, params, pluginID, reply in
          self?.handleHostRequest(
            method: method, params: params, pluginID: pluginID, reply: reply)
        }
        pluginsByID[manifest.id] = plugin
        sourceAdaptersByID[manifest.id] = PluginFlashSource(plugin: plugin)
        plugin.start()
      } catch {
        FlashLog.warn(
          "[plugins] failed to load \(item.root.path): \(error)",
          fields: [
            "root": item.root.path,
            "origin": String(describing: item.origin),
            "error": String(describing: error),
          ])
      }
    }

    for id in Array(pluginsByID.keys) where !nextIDs.contains(id) {
      pluginsByID[id]?.stop()
      pluginsByID.removeValue(forKey: id)
      sourceAdaptersByID.removeValue(forKey: id)
    }
    rebuildCommandIndex()
    rebuildMappingIndex()
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
        FlashLog.warn(
          "[plugins] failed to materialize \(ref.raw): \(error)",
          fields: ["ref": ref.raw, "root": root.path, "error": String(describing: error)])
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
    summary: "Managed stdio plugins, manifests, events, and commands.",
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

      Protocol I/O is length-prefixed MessagePack on stdin/stdout: a 4-byte
      big-endian payload length followed by a MessagePack value. Unexpected
      plugin errors go to stderr. Plugins can log through the protocol and
      Flash records those messages with `source = "plugin:<id>"`.

      Plugins can subscribe to events such as `apps.*`, `config.*`, and
      focused AX changes. They can also register commands. Each plugin
      registers one or more **commands** (the verb after `:`, e.g.
      `spotify`), and each command has one or more **subcommands** (e.g.
      `pause`), which users run as `:spotify pause`.

      Official bundled plugins are installed under `FLASH_PLUGIN_DATA_DIR`;
      they do not write CLI binaries into global shell paths. Bundled commands
      include `:spotify`, `:slack`, and `:notion`. Authentication is explicit
      through subcommands such as `:slack login`; install and start do not run
      login flows.

      `flash://plugins` or `:plugins` opens the plugin status modal. When
      `[debug] http_inspector_enabled = true` is set, the http inspector page shows live
      logs, resolved config, and plugin state.
      """)
}

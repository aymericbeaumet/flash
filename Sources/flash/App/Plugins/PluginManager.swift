import AppKit
import Darwin
import FlashCore
import Foundation

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
      `[debug] inspector_enabled = true` is set, the inspector page shows live
      logs, resolved config, and plugin state.
      """)
}

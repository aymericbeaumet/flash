import AppKit
import Carbon.HIToolbox
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

  /// A resolved plugin-verb target: the owning plugin, the command/subcommand
  /// folded from the manifest, an optional per-bundle inline-keystrokes table
  /// (which lets the host short-circuit into `input.send_key` when it matches
  /// the focused bundle, skipping the plugin RPC), and an optional bundle
  /// gate. Built by `rebuildVerbIndex` from every loaded plugin's `verbs`
  /// provider entries.
  private struct VerbTarget {
    let plugin: PluginProcess
    let command: String
    let subcommand: String
    let inlineKeystrokes: [String: String]
    let bundleIDs: [String]

    func matches(bundleID: String?) -> Bool {
      if bundleIDs.isEmpty { return true }
      guard let bundleID else { return false }
      return bundleIDs.contains(bundleID)
    }

    /// Hotkey string to synthesize for `bundleID`, or `nil` when the verb has
    /// no inline shortcut for it. The empty-key entry (`""`) acts as the
    /// catch-all default, mirroring the manifest convention.
    func inlineKeystroke(forBundleID bundleID: String?) -> String? {
      if let bundleID, let exact = inlineKeystrokes[bundleID], !exact.isEmpty {
        return exact
      }
      let fallback = inlineKeystrokes[""] ?? ""
      return fallback.isEmpty ? nil : fallback
    }
  }

  /// A resolved flashlight bang target: the owning plugin, the command its
  /// `command.invoke` carries, and the gate/metadata folded from the manifest.
  /// Dispatched with the typed bang as the subcommand — so a `shebang` provider
  /// needs no matching `commands` entry.
  private struct ShebangTarget {
    let plugin: PluginProcess
    let command: String
    let description: String
    let bundleIDs: [String]
    let meta: [String: String]
    /// Candidate source label declared on the shebang entry. When set, the
    /// flashlight pool swaps to candidates from that source while the bang is
    /// confirmed (e.g. `!kill ` → `processes.processes`).
    let candidateSource: String?

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
  /// Flashlight bang lookup: lowercased `token` → owning plugin/command.
  /// Built alongside the command index; consulted at flashlight submit when
  /// the query starts with `!<token>`.
  private var shebangIndex: [String: ShebangTarget] = [:]
  /// Catch-all bang provider (`token == "*"`): handles any `!<token>` not
  /// claimed by an exact `shebangIndex` entry, so a plugin like `searchengines`
  /// can serve the whole DuckDuckGo bang table without enumerating it.
  private var wildcardShebangTarget: ShebangTarget?
  /// Plugin-registered verbs (`flash <verb>`), keyed by lowercased verb name.
  /// First plugin to claim a verb wins on collision; the host treats the
  /// built-in `URLEventHandler.commands` table as authoritative for any name
  /// it already owns, so plugin verbs only resolve for names the host doesn't
  /// claim. Rebuilt by `rebuildVerbIndex` whenever the plugin set changes.
  private var verbIndex: [String: VerbTarget] = [:]
  /// Resolved plugin mappings across all loaded plugins, rebuilt whenever the
  /// plugin set or any plugin's mappings change. `mappings(forBundleID:)`
  /// filters this for the focused app.
  private var mappingIndex: [ResolvedPluginMapping] = []
  /// Owns the single AX (Accessibility) grant and the handle registry that
  /// backs the `ax.*` host RPCs. Plugins never touch AX directly; they reach
  /// it through this broker via `handleHostRequest`.
  private let axBroker = AXBroker()
  /// Carbon hotkey manager dedicated to plugin-owned registrations. Lives
  /// separately from `MappingsCoordinator`'s `HotKeyManager` because the
  /// mappings coordinator rebuilds its table on every mode flip, while
  /// plugin hotkeys are persistent across modes (a plugin asked for a chord
  /// and the user accepted the capability — there's no scope to flip them
  /// on).
  private let pluginHotKeys = HotKeyManager()
  /// `pluginID → (pluginHotkeyID → carbonID)` for unregistration and for
  /// looking up the owning plugin when a Carbon fire callback arrives. The
  /// plugin's `id` field is opaque to the host; reusing it on a second
  /// register call replaces the previous registration so plugins can rebind
  /// in place.
  private var pluginHotkeysByPluginID: [String: [String: UInt32]] = [:]
  /// `carbonID → (pluginID, plugin's hotkey id)` so the fire callback can
  /// route the `core:hotkey.fired` notification to the right plugin process.
  private var pluginHotkeyByCarbonID: [UInt32: (pluginID: String, hotkeyID: String)] = [:]
  var onStateChanged: (() -> Void)?
  /// Fired on the main thread after the mapping index is rebuilt because a
  /// plugin emitted `mappings.updated`. The app recomputes its effective
  /// per-app mapping tables in response.
  var onMappingsChanged: (() -> Void)?
  /// Resolver for the `host.normal_mode_target` RPC: returns the focused
  /// non-Flash app context (pid + bundle id) the host considers the
  /// normal-mode target. Plugins (notably `marks`) call this to record or
  /// reactivate the app the user was working on when they typed `m<letter>`
  /// — `core:focus.changed` alone is insufficient because Flash itself is
  /// the focused process while normal mode is active. Set by AppDelegate
  /// during plugin setup.
  var onNormalModeTargetRequested: (() -> (pid: pid_t, bundleID: String)?)?

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
      shebangIndex.removeAll()
      wildcardShebangTarget = nil
      verbIndex.removeAll()
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
  /// runs asynchronously; `onResult` delivers its `(ok, targetPID, stdout, navigationURL)`
  /// once it replies. `targetPID`, when present, is an app the command asked
  /// Flash to raise; `stdout`, when present, is text to surface as a toast
  /// and `navigationURL`, when present, is the route recorded into movement
  /// history for `ctrl-o` / `ctrl-i`
  /// (see `PluginProcess.invokeCommand`).
  @discardableResult
  func invoke(
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    forBundleID bundleID: String? = nil,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
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
      ok, pid, stdout, navigationURL in
      FlashLog.debug(
        "[plugin_command] command=\(command) subcommand=\(resolved.subcommand) ok=\(ok) "
          + "target_pid=\(pid.map(String.init) ?? "nil") "
          + "navigation_url=\(navigationURL?.absoluteString ?? "nil")")
      onResult?(ok, pid, stdout, navigationURL)
    }
    return true
  }

  /// Returns true when a plugin owns the flashlight bang `token` (an exact
  /// registration, or a `"*"` catch-all) and the bang was dispatched. `query`
  /// is the remainder after the bang; it is forwarded both as whitespace-split
  /// `args` and verbatim as `raw`, with the bang itself as the subcommand. The
  /// plugin runs asynchronously; `onResult` mirrors ``invoke(command:…)``.
  @discardableResult
  func invokeShebang(
    token: String,
    query: String,
    forBundleID bundleID: String? = nil,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcToken = token.lowercased()
    let target: ShebangTarget? = queue.sync {
      if let exact = shebangIndex[lcToken], exact.matches(bundleID: bundleID) { return exact }
      if let wildcard = wildcardShebangTarget, wildcard.matches(bundleID: bundleID) {
        return wildcard
      }
      return nil
    }
    guard let target else { return false }
    let args = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    target.plugin.invokeCommand(
      command: target.command, subcommand: token, args: args, raw: query, meta: target.meta
    ) { ok, pid, stdout, navigationURL in
      FlashLog.debug(
        "[plugin_shebang] token=\(token) command=\(target.command) ok=\(ok) "
          + "target_pid=\(pid.map(String.init) ?? "nil") "
          + "navigation_url=\(navigationURL?.absoluteString ?? "nil")")
      onResult?(ok, pid, stdout, navigationURL)
    }
    return true
  }

  /// The candidate source declared by the bang registration matching `token`.
  /// Plugins that bind a bang to a source (e.g. `!kill` → `processes.processes`)
  /// declare it on the shebang entry; the host swaps the candidate-finder pool
  /// to that source once the bang is confirmed. `nil` when no registration
  /// declared one.
  func shebangCandidateSource(token: String, forBundleID bundleID: String? = nil) -> String? {
    let lcToken = token.lowercased()
    return queue.sync {
      if let exact = shebangIndex[lcToken],
        exact.matches(bundleID: bundleID),
        let candidateSource = exact.candidateSource,
        !candidateSource.isEmpty
      {
        return candidateSource
      }
      return nil
    }
  }

  /// The display description for the bang `token` while `bundleID` is the
  /// focused app: the exact registration's if present, else the `"*"`
  /// catch-all's. `nil` when no plugin would claim the token — mirroring
  /// ``invokeShebang(token:query:forBundleID:onResult:)`` exactly, so a
  /// surfaced bang row can never fail to dispatch.
  func shebangDescription(token: String, forBundleID bundleID: String? = nil) -> String? {
    let lcToken = token.lowercased()
    return queue.sync {
      if let exact = shebangIndex[lcToken], exact.matches(bundleID: bundleID) {
        return exact.description
      }
      if let wildcard = wildcardShebangTarget, wildcard.matches(bundleID: bundleID) {
        return wildcard.description
      }
      return nil
    }
  }

  /// Synthetic flashlight rows for every exact-token bang registration
  /// (the `"*"` catch-all has no concrete token to list — typed `!<token>`
  /// queries surface it live instead). Two sources combine here:
  ///   * **Manifest shebangs** — declared statically in `manifest.json`,
  ///     gated per registration against the focused app. Used by plugins
  ///     with a small fixed set of bangs (aiproviders: chatgpt/claude/…).
  ///   * **Plugin-snapshot bangs** — kind="bang" candidates the plugin
  ///     publishes via `emit_snapshot`. Used by plugins whose bang list
  ///     is too large or too dynamic for the manifest (searchengines:
  ///     ~100 DDG bangs generated from `bangs.tsv` at build time).
  /// Plugins should not duplicate a token across both surfaces; if they
  /// do, both rows will appear.
  /// Union of every `bundle_ids` entry declared by any loaded plugin.
  /// Lets the flashlight refresh path emit synthetic
  /// `core:focus.changed` events for every running app whose AX walk
  /// a plugin owns — even when that app isn't currently focused —
  /// so the plugin can republish its candidate snapshot before the
  /// next keystroke lands.
  func claimedBundleIDs() -> Set<String> {
    queue.sync {
      var out = Set<String>()
      for plugin in pluginsByID.values {
        for bundleID in plugin.manifest.bundleIDs { out.insert(bundleID) }
      }
      return out
    }
  }

  func shebangCandidates(forBundleID bundleID: String? = nil) -> [Candidate] {
    queue.sync {
      var out: [Candidate] = []
      for plugin in pluginsByID.values {
        for registration in plugin.shebangs {
          let token = registration.token
          guard token != "*", !token.isEmpty, !registration.command.isEmpty else { continue }
          if !registration.bundleIDs.isEmpty {
            guard let bundleID, registration.bundleIDs.contains(bundleID) else { continue }
          }
          out.append(
            Candidate(
              kind: CandidateFinder.bangKind,
              sourceID: "bang:\(plugin.identifier)",
              source: "bang",
              title: "!\(token)",
              subtitle: registration.description,
              sourcePayload: token))
        }
        for snapshot in plugin.candidates(scope: .all)
        where snapshot.kind == CandidateFinder.bangKind {
          out.append(snapshot)
        }
      }
      return out
    }
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
    case "input.send_key":
      guard pluginHasCapability(pluginID, .input) else {
        reply(["ok": false, "error": "missing input capability"])
        return
      }
      sendPluginKey(params, reply: reply)
    case "tcc.request":
      guard pluginHasCapability(pluginID, .tccRequest) else {
        reply(["ok": false, "error": "missing tcc.request capability"])
        return
      }
      handleTccRequest(params, pluginID: pluginID, reply: reply)
    case "hotkey.register":
      guard pluginHasCapability(pluginID, .hotkey) else {
        reply(["ok": false, "error": "missing hotkey capability"])
        return
      }
      handleHotkeyRegister(params, pluginID: pluginID, reply: reply)
    case "hotkey.unregister":
      guard pluginHasCapability(pluginID, .hotkey) else {
        reply(["ok": false, "error": "missing hotkey capability"])
        return
      }
      handleHotkeyUnregister(params, pluginID: pluginID, reply: reply)
    case "host.normal_mode_target":
      DispatchQueue.main.async { [weak self] in
        guard let target = self?.onNormalModeTargetRequested?() else {
          reply(["ok": true, "present": false])
          return
        }
        reply([
          "ok": true,
          "present": true,
          "pid": Int(target.pid),
          "bundle_id": target.bundleID,
        ])
      }
    case let method where method.hasPrefix("ax."):
      axBroker.handle(method: method, params: params, reply: reply)
    default:
      FlashLog.warn(
        "[plugin] unknown host method \(method) from \(pluginID)",
        fields: ["method": method, "plugin": pluginID])
      reply(["ok": false, "error": "unknown host method: \(method)"])
    }
  }

  private func pluginHasCapability(_ pluginID: String, _ capability: PluginCapability) -> Bool {
    queue.sync {
      pluginsByID[pluginID]?.manifest.capabilities.contains(capability) ?? false
    }
  }

  private func sendPluginKey(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init),
      let keys = params["keys"] as? String,
      let parsed = HotkeySyntax.parse(hotkey: keys)
    else {
      reply(["ok": false, "error": "invalid input.send_key params"])
      return
    }
    let ok = NormalModeDispatcher.sendKey(
      virtualKey: CGKeyCode(parsed.virtualKey),
      flags: Self.cgEventFlags(carbon: parsed.modifiers),
      to: pid)
    reply(["ok": ok])
  }

  /// In-memory bookkeeping for TCC request rate-limiting. The TCC subsystem
  /// itself caches grants, but a malicious or buggy plugin could still spam
  /// `tcc.request` calls — when a kind+target was queried in the last 5
  /// seconds, we return the cached grant decision instead of re-issuing the
  /// underlying API call. Tracked per plugin id so one plugin's cooldown
  /// doesn't affect another's.
  private struct TccRecentRequest {
    let pluginID: String
    let key: String
    let timestamp: Date
    let result: [String: Any]
  }
  private var tccRecentRequests: [TccRecentRequest] = []
  private let tccRequestCooldown: TimeInterval = 5.0

  /// Dispatch a `tcc.request` RPC. `params` carries `kind` (currently only
  /// `applescript` is supported — it triggers the AppleEvents prompt for the
  /// `target` bundle id) and `target` (the bundle id to request access to).
  /// Replies with `{ok, granted, denied, unknown}` describing the post-request
  /// grant state; `unknown` is set when the prompt is shown for the first time
  /// and the user has not yet decided.
  private func handleTccRequest(
    _ params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let kind = params["kind"] as? String, !kind.isEmpty else {
      reply(["ok": false, "error": "tcc.request requires kind"])
      return
    }
    let target = (params["target"] as? String) ?? ""
    let key = "\(kind)|\(target)"
    let now = Date()
    queue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { reply(["ok": false, "error": "manager gone"]) }
        return
      }
      self.tccRecentRequests.removeAll { now.timeIntervalSince($0.timestamp) > self.tccRequestCooldown }
      if let cached = self.tccRecentRequests.first(where: { $0.pluginID == pluginID && $0.key == key }) {
        DispatchQueue.main.async { reply(cached.result) }
        return
      }
      let result: [String: Any]
      switch kind {
      case "applescript":
        guard !target.isEmpty else {
          let err: [String: Any] = ["ok": false, "error": "tcc.request applescript requires target"]
          DispatchQueue.main.async { reply(err) }
          return
        }
        result = Self.requestAppleEventsAccess(targetBundleID: target)
      default:
        let err: [String: Any] = ["ok": false, "error": "tcc.request unsupported kind: \(kind)"]
        DispatchQueue.main.async { reply(err) }
        return
      }
      self.tccRecentRequests.append(
        TccRecentRequest(pluginID: pluginID, key: key, timestamp: now, result: result))
      DispatchQueue.main.async { reply(result) }
    }
  }

  /// Register a Carbon hotkey on behalf of `pluginID`. Replies with `ok=true`
  /// once Carbon accepts the registration, or an error string when the spec
  /// is invalid, Carbon refuses (another app already owns the chord), or the
  /// chord clashes with one of the user's `[mode.*.mappings]` bindings.
  /// Re-registering the same plugin-side `id` replaces the previous handle.
  private func handleHotkeyRegister(
    _ params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let hotkeyID = params["id"] as? String, !hotkeyID.isEmpty,
      let spec = params["spec"] as? String, !spec.isEmpty
    else {
      reply(["ok": false, "error": "hotkey.register requires id + spec"])
      return
    }
    guard let parsed = HotkeySyntax.parse(hotkey: spec) else {
      reply(["ok": false, "error": "hotkey.register: cannot parse spec \(spec)"])
      return
    }
    queue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { reply(["ok": false, "error": "manager gone"]) }
        return
      }
      // Drop a previous registration under the same plugin+id so a plugin
      // can rebind without first unregistering.
      if let previousCarbonID = self.pluginHotkeysByPluginID[pluginID]?[hotkeyID] {
        self.pluginHotkeyByCarbonID.removeValue(forKey: previousCarbonID)
      }
      DispatchQueue.main.async {
        var assignedCarbonID: UInt32 = 0
        let status = self.pluginHotKeys.register(
          modifiers: parsed.modifiers,
          virtualKey: parsed.virtualKey
        ) { [weak self] in
          guard let self else { return }
          let target: (pluginID: String, hotkeyID: String)? = self.queue.sync {
            self.pluginHotkeyByCarbonID[assignedCarbonID]
          }
          guard let target else { return }
          self.fireHotkeyEvent(pluginID: target.pluginID, hotkeyID: target.hotkeyID)
        }
        if status != noErr {
          let err: [String: Any] = [
            "ok": false,
            "error": "RegisterEventHotKey returned \(status)",
          ]
          reply(err)
          return
        }
        assignedCarbonID = self.pluginHotKeys.lastAssignedID
        self.queue.async {
          self.pluginHotkeysByPluginID[pluginID, default: [:]][hotkeyID] = assignedCarbonID
          self.pluginHotkeyByCarbonID[assignedCarbonID] = (pluginID, hotkeyID)
          DispatchQueue.main.async { reply(["ok": true, "carbon_id": Int(assignedCarbonID)]) }
        }
      }
    }
  }

  /// Drop a hotkey registration previously installed by
  /// `handleHotkeyRegister`. No-op when the id is unknown.
  private func handleHotkeyUnregister(
    _ params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let hotkeyID = params["id"] as? String, !hotkeyID.isEmpty else {
      reply(["ok": false, "error": "hotkey.unregister requires id"])
      return
    }
    queue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { reply(["ok": false, "error": "manager gone"]) }
        return
      }
      guard let carbonID = self.pluginHotkeysByPluginID[pluginID]?.removeValue(forKey: hotkeyID)
      else {
        DispatchQueue.main.async { reply(["ok": true, "removed": false]) }
        return
      }
      self.pluginHotkeyByCarbonID.removeValue(forKey: carbonID)
      DispatchQueue.main.async {
        self.pluginHotKeys.unregister(id: carbonID)
        reply(["ok": true, "removed": true])
      }
    }
  }

  /// Deliver a `core:hotkey.fired` notification to the plugin that owns the
  /// fired registration. Routed through `PluginProcess.sendEvent`, so the
  /// plugin must declare `core:hotkey.fired` in its `subscriptions` for the
  /// event to land.
  private func fireHotkeyEvent(pluginID: String, hotkeyID: String) {
    queue.async { [weak self] in
      guard let plugin = self?.pluginsByID[pluginID] else { return }
      plugin.sendEvent(
        PluginEvent(
          name: "core:hotkey.fired",
          payload: ["hotkey_id": hotkeyID],
          bundleID: nil,
          configPath: nil,
          focused: nil))
    }
  }

  /// Native TCC bridge for AppleEvents access to `targetBundleID`. Calls the
  /// low-level `AEDeterminePermissionToAutomateTarget` so the system shows
  /// the standard "Flash wants to control <App>" prompt the first time, then
  /// caches the user's decision. Maps the OSStatus return into a `{granted,
  /// denied, unknown}` triple so plugins can branch on first-prompt UX.
  private static func requestAppleEventsAccess(targetBundleID: String) -> [String: Any] {
    let addressDesc = NSAppleEventDescriptor(
      descriptorType: typeApplicationBundleID,
      data: Data(targetBundleID.utf8))
    var status: OSStatus = -1
    if let descriptor = addressDesc, let aeDesc = descriptor.aeDesc {
      status = withUnsafePointer(to: aeDesc.pointee) { ptr in
        AEDeterminePermissionToAutomateTarget(
          ptr, typeWildCard, typeWildCard, true)
      }
    }
    switch status {
    case 0:  // noErr
      return ["ok": true, "granted": true, "denied": false, "unknown": false]
    case -1744:  // errAEEventNotPermitted
      return ["ok": true, "granted": false, "denied": true, "unknown": false]
    case -1743:  // errAEEventWouldRequireUserConsent / procNotFound — first prompt outcome unknown
      return ["ok": true, "granted": false, "denied": false, "unknown": true]
    default:
      return [
        "ok": false, "error": "AEDeterminePermissionToAutomateTarget returned \(status)",
        "granted": false, "denied": false, "unknown": true,
      ]
    }
  }

  private static func cgEventFlags(carbon: UInt32) -> CGEventFlags {
    var flags: CGEventFlags = []
    if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
    if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
    if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
    if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
    return flags
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

  /// Rebuild the flashlight bang index. Must be called from `queue` after
  /// `pluginsByID` changes. First plugin to claim a token (or the `"*"`
  /// catch-all) wins, matching the command index's collision semantics.
  private func rebuildShebangIndex() {
    var next: [String: ShebangTarget] = [:]
    var wildcard: ShebangTarget?
    for plugin in pluginsByID.values {
      for registration in plugin.shebangs {
        let token = registration.token.lowercased()
        guard !token.isEmpty, !registration.command.isEmpty else { continue }
        let target = ShebangTarget(
          plugin: plugin, command: registration.command,
          description: registration.description,
          bundleIDs: registration.bundleIDs, meta: registration.meta,
          candidateSource: registration.candidateSource)
        if token == "*" {
          if wildcard == nil { wildcard = target }
          continue
        }
        if next[token] == nil { next[token] = target }
      }
    }
    shebangIndex = next
    wildcardShebangTarget = wildcard
  }

  /// Rebuild the verb lookup index. Must be called from `queue` after
  /// `pluginsByID` changes. The first plugin to claim a verb wins on
  /// collision, matching the command/shebang index semantics. Plugin verbs
  /// only resolve names the built-in `URLEventHandler.commands` table doesn't
  /// already claim (the URL dispatch checks the built-in table first), so a
  /// collision with a built-in is silently shadowed.
  private func rebuildVerbIndex() {
    var next: [String: VerbTarget] = [:]
    for plugin in pluginsByID.values {
      for registration in plugin.manifest.verbs {
        let name = registration.name.lowercased()
        guard !name.isEmpty else { continue }
        let command = registration.command.isEmpty ? plugin.identifier : registration.command
        let subcommand = registration.subcommand.isEmpty ? name : registration.subcommand
        let target = VerbTarget(
          plugin: plugin,
          command: command,
          subcommand: subcommand,
          inlineKeystrokes: registration.inlineKeystrokes,
          bundleIDs: registration.bundleIDs)
        if next[name] == nil { next[name] = target }
      }
    }
    verbIndex = next
  }

  /// Dispatch a plugin verb. Returns true when a plugin claims the verb (and
  /// the dispatch was issued — either as a synthesized keystroke or as an
  /// asynchronous plugin command). The `inline_keystrokes` shortcut path runs
  /// synchronously and reports `(true, focusedPID, nil, nil)` via `onResult`;
  /// the RPC path follows the `command.invoke` contract, with `args` flattened
  /// into `key=value` positional tokens so plugins can parse them off
  /// `CommandRequest.args` without a special map decoder.
  @discardableResult
  func invokeVerb(
    name: String,
    args: [String: String],
    forBundleID bundleID: String? = nil,
    focusedPID: pid_t? = nil,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcName = name.lowercased()
    let target: VerbTarget? = queue.sync {
      guard let target = verbIndex[lcName], target.matches(bundleID: bundleID) else { return nil }
      return target
    }
    guard let target else { return false }
    if let keystroke = target.inlineKeystroke(forBundleID: bundleID),
      let pid = focusedPID,
      let parsed = HotkeySyntax.parse(hotkey: keystroke)
    {
      let ok = NormalModeDispatcher.sendKey(
        virtualKey: CGKeyCode(parsed.virtualKey),
        flags: Self.cgEventFlags(carbon: parsed.modifiers),
        to: pid)
      FlashLog.debug(
        "[plugin_verb] inline name=\(lcName) keys=\(keystroke) "
          + "pid=\(pid) bundle=\(bundleID ?? "nil") ok=\(ok)")
      onResult?(ok, pid, nil, nil)
      return true
    }
    let positional = args.keys.sorted().map { key in "\(key)=\(args[key] ?? "")" }
    let raw = positional.isEmpty ? name : "\(name) " + positional.joined(separator: " ")
    target.plugin.invokeCommand(
      command: target.command,
      subcommand: target.subcommand,
      args: positional,
      raw: raw,
      meta: [:]
    ) { ok, pid, stdout, navigationURL in
      FlashLog.debug(
        "[plugin_verb] command name=\(lcName) plugin=\(target.plugin.identifier) "
          + "subcommand=\(target.subcommand) ok=\(ok) "
          + "target_pid=\(pid.map(String.init) ?? "nil") "
          + "navigation_url=\(navigationURL?.absoluteString ?? "nil")")
      onResult?(ok, pid, stdout, navigationURL)
    }
    return true
  }

  /// Rebuild the resolved-mapping index. Must be called from `queue` after
  /// `pluginsByID` or any plugin's mappings change. Canonicalizes the key and
  /// parses the argv mapping command once here so the focus-change path only
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
        guard let action = parseMappingCommand(argv: registration.command) else {
          FlashLog.warn(
            "[plugins] mapping command \(registration.command) from \(manifest.id) "
              + "is not a valid argv array (`flash <verb> [k=v]...` or an external command)")
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

  /// Help topics every loaded plugin contributes via `manifest.help.topics`,
  /// flattened into the host's `HelpTopic` type so `:help` can render them
  /// alongside built-ins. Topic names collide on a first-wins basis with the
  /// host's topics (see `HelpDocs.allTopics`), so a plugin claiming `flashlight`
  /// is shadowed by the host's own topic — pick a plugin-specific name to
  /// avoid surprise.
  func pluginHelpTopics() -> [HelpTopic] {
    queue.sync {
      pluginsByID.values
        .sorted(by: { $0.identifier < $1.identifier })
        .flatMap { plugin in
          plugin.manifest.help.topics.map { topic in
            HelpTopic(
              name: topic.name,
              title: topic.title.isEmpty ? topic.name : topic.title,
              summary: topic.summary,
              body: topic.body,
              aliases: topic.aliases)
          }
        }
    }
  }

  func statusText() -> String {
    let snapshots = statusSnapshots()
    guard !snapshots.isEmpty else {
      return "# Plugins\n\nNo plugins loaded."
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
    // Wrap the column-aligned table in a fenced code block so the
    // markdown renderer keeps it in the monospace font — without the
    // fence it would render as proportional paragraphs and the
    // column alignment would collapse.
    var lines = ["# Plugins", "", "```text"]
    lines.append(headers.indices.map { padded(headers[$0], $0) }.joined(separator: "  "))
    for row in rows {
      lines.append(row.indices.map { padded(row[$0], $0) }.joined(separator: "  "))
    }
    lines.append("```")
    let errors = snapshots.compactMap { snapshot -> String? in
      guard let error = snapshot.lastError, !error.isEmpty else { return nil }
      return "- `\(snapshot.id)`: \(error)"
    }
    if !errors.isEmpty {
      lines.append("")
      lines.append("## Last errors")
      lines.append("")
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
    rebuildShebangIndex()
    rebuildMappingIndex()
    rebuildVerbIndex()
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
    case .github(let owner, let repository, let commit):
      let root = baseDataDir.appendingPathComponent("github/\(owner)-\(repository)-\(commit)")
      let url = "https://github.com/\(owner)/\(repository).git"
      do {
        try FileManager.default.createDirectory(
          at: root.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        // The directory name embeds the commit, so a populated root means we
        // already checked that exact SHA out — skip any network round trip.
        // This also means a previously vetted plugin keeps working offline.
        let head = root.appendingPathComponent(".git/HEAD")
        if FileManager.default.fileExists(atPath: head.path),
          verifyGitCommit(root: root, commit: commit)
        {
          return (root, .github(ref.raw))
        }
        // Fresh fetch: init an empty repo, fetch *exactly* the requested
        // commit, then check it out and verify HEAD matches. We never run
        // `git pull` on an existing tree — that would let a moving upstream
        // ref silently slide the worktree forward.
        if FileManager.default.fileExists(atPath: root.path) {
          try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard runGit(["init", "--quiet"], in: root),
          runGit(["remote", "add", "origin", url], in: root),
          runGit(["fetch", "--depth", "1", "origin", commit], in: root),
          runGit(["checkout", "--quiet", commit], in: root),
          verifyGitCommit(root: root, commit: commit)
        else {
          FlashLog.warn(
            "[plugins] github checkout did not match pinned commit \(commit)",
            fields: ["ref": ref.raw, "root": root.path, "commit": commit])
          return nil
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

  /// True iff `git rev-parse HEAD` inside `root` returns exactly `commit`. The
  /// equality is the defense — a checkout of the wrong object (or an opaque
  /// object database race) gets rejected loudly instead of being trusted.
  private func verifyGitCommit(root: URL, commit: String) -> Bool {
    guard let head = runGitCapture(["rev-parse", "HEAD"], in: root) else { return false }
    return head.trimmed.lowercased() == commit
  }

  /// Run a `git` subcommand using an explicit argv (no shell). Returns true on
  /// exit status 0. 60s timeout protects config reload from a network-stalled
  /// `git fetch` — without it a stuck child would hang the whole reload.
  private func runGit(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 60
  ) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
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

  /// Run a `git` subcommand and return its stdout on success. Used to read
  /// `git rev-parse HEAD` for commit-pin verification.
  private func runGitCapture(
    _ arguments: [String],
    in root: URL,
    timeoutSeconds: TimeInterval = 30
  ) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = root
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
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
    guard process.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  static func manifestRoots(in candidates: [URL], fileManager fm: FileManager = .default) -> [URL] {
    var roots: [URL] = []
    var seenBases = Set<String>()
    var seenRoots = Set<String>()
    for candidate in candidates {
      let bases = [candidate, candidate.resolvingSymlinksInPath()]
      for base in bases where seenBases.insert(base.path).inserted {
        guard
          let children = try? fm.contentsOfDirectory(
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
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Plugins"),
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

      Plugins can subscribe to events such as `core:apps.*`, `core:config.*`,
      and focused AX changes. They can also register commands and status-bar
      segments. Each plugin registers one or more **commands** (the verb after
      `:`, e.g. `spotify`), and each command has one or more **subcommands**
      (e.g. `pause`), which users run as `:spotify pause`. A `status` provider
      declares `segments` in `manifest.json`; runtime values are published with
      `status.updated` and are available to `[statusbar].template` as
      `#{plugin:<id>.<segment>}`.

      Official bundled plugins are installed under `FLASH_PLUGIN_DATA_DIR`;
      they do not write CLI binaries into global shell paths. Bundled commands
      include `:spotify` and `:slack`. Authentication is explicit through
      subcommands such as `:slack login`; install and start do not run login
      flows.

      `flash plugins` or `:plugins` opens the plugin status modal. When
      `[debug] http_inspector_enabled = true` is set, the http inspector page shows live
      logs, resolved config, and plugin state.
      """)
}

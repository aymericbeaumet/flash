import AppKit
import Carbon.HIToolbox
import Darwin
import FlashCore
import Foundation

struct PluginRegistrationInventory: Equatable {
  var plugins = 0
  var commands = 0
  var mappings = 0
  var shebangs = 0
  var verbs = 0
  var candidateSources = 0
  var sourceActions = 0
  var statusSegments = 0
  var navigationSchemes = 0
  var helpTopics = 0
  var listeners = 0
  var hintProviders = 0
  var capabilityRequests = 0

  init(manifests: [PluginManifest]) {
    plugins = manifests.count
    for manifest in manifests {
      commands += manifest.commands.count
      mappings += manifest.mappings.count
      shebangs += manifest.shebangs.count
      verbs += manifest.verbs.count
      candidateSources += manifest.candidateSourceDescriptors.count
      sourceActions += manifest.sourceActions.count
      statusSegments += manifest.statusSegments.count
      navigationSchemes += manifest.navigationSchemes.count
      helpTopics += manifest.help.topics.count
      listeners += manifest.listen.count
      if manifest.providesHints { hintProviders += 1 }
      capabilityRequests += manifest.capabilities.count
    }
  }

  var rows: [(label: String, count: Int)] {
    [
      ("plugins", plugins),
      ("commands", commands),
      ("mappings", mappings),
      ("shebangs", shebangs),
      ("verbs", verbs),
      ("candidate_sources", candidateSources),
      ("source_actions", sourceActions),
      ("status_segments", statusSegments),
      ("navigation_schemes", navigationSchemes),
      ("help_topics", helpTopics),
      ("listeners", listeners),
      ("hint_providers", hintProviders),
      ("capability_requests", capabilityRequests),
    ]
  }
}

final class PluginManager {
  private struct CommandKey: Hashable {
    let command: String
    let subcommand: String
  }

  /// A resolved command target: the owning plugin plus the matched manifest
  /// entry's `_`-prefixed metadata, forwarded to the plugin on invoke.
  /// `selector` carries the command's active-window gate, applied at lookup
  /// against the focused app/window URL — the same predicate
  /// `ResolvedPluginMapping` uses.
  private struct CommandTarget {
    let plugin: PluginProcess
    let selector: PluginSelectorStack
    let meta: [String: String]

    func specificity(in context: PluginSelectorContext) -> Int? {
      selector.specificity(in: context)
    }
  }

  /// A completion-row registration prepared at plugin reload time. Runtime
  /// completion only filters these rows by selector specificity.
  private struct CommandRegistrationTarget {
    let selector: PluginSelectorStack
    let order: Int
    let registration: PluginCommandRegistration
  }

  /// A resolved plugin-verb target: the owning plugin, the command/subcommand
  /// folded from the manifest, an optional per-bundle inline-keystrokes table
  /// (which lets the host synthesize the key directly when it matches the
  /// focused bundle, skipping the plugin RPC), and the compiled selector.
  /// Built by `rebuildVerbIndex` from every loaded plugin's `verbs` entries.
  private struct VerbTarget {
    let plugin: PluginProcess
    let command: String
    let subcommand: String
    let inlineKeystrokes: [String: String]
    let selector: PluginSelectorStack

    func specificity(in context: PluginSelectorContext) -> Int? {
      selector.specificity(in: context)
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
    let selector: PluginSelectorStack
    let meta: [String: String]
    /// Candidate source label declared on the shebang entry. When set, the
    /// flashlight pool swaps to candidates from that source while the bang is
    /// confirmed (e.g. `!kill ` → `processes.processes`).
    let candidateSource: String?

    func specificity(in context: PluginSelectorContext) -> Int? {
      selector.specificity(in: context)
    }
  }

  /// Static bang candidate prepared from manifest shebangs. Dynamic bang
  /// candidates still come from plugin snapshots.
  private struct ShebangCandidateTarget {
    let selector: PluginSelectorStack
    let candidate: Candidate
  }

  /// A plugin mapping with its `key`/`command` already canonicalized and
  /// parsed (the work done once at index-rebuild time, not per focus-change).
  /// `selector` applies the plugin root selector plus any entry-level selector.
  private struct ResolvedPluginMapping {
    let selector: PluginSelectorStack
    let priority: Int
    let scope: ModeScope
    let mapping: ModeMapping
  }

  private let queue = DispatchQueue(label: "flash.plugins", qos: .utility)
  private let baseDataDir: URL
  private var pluginsByID: [String: PluginProcess] = [:]
  private var sourceAdaptersByID: [String: PluginFlashSource] = [:]
  /// Pre-computed command lookup index: `(command, subcommand)` →
  /// candidate targets. Built from `pluginsByID` whenever the plugin set
  /// changes; per-invoke lookup is then O(1) instead of walking every
  /// plugin × every command × `localizedCaseInsensitiveCompare`.
  /// Keys are lowercased; lookups use the same normalisation.
  private var commandIndex: [CommandKey: [CommandTarget]] = [:]
  /// Flat command completion rows, pre-built with selector stacks and stable
  /// ordering so opening `:` does not walk manifests.
  private var commandRegistrationIndex: [CommandRegistrationTarget] = []
  /// Commands that register the wildcard subcommand `"*"`: the verb takes
  /// no fixed subcommand and consumes the whole remainder as args (e.g.
  /// `:calc 2 + 2`). Keyed by lowercased command; consulted only when the
  /// exact `(command, subcommand)` lookup misses.
  private var wildcardCommandIndex: [String: [CommandTarget]] = [:]
  /// Flashlight bang lookup: lowercased `token` → owning plugin/command.
  /// Built alongside the command index; consulted at flashlight submit when
  /// the query starts with `!<token>`.
  private var shebangIndex: [String: [ShebangTarget]] = [:]
  /// Static manifest bang rows for the flashlight `!` pool. Runtime filters
  /// this table by selector instead of rebuilding candidates from manifests.
  private var shebangCandidateIndex: [ShebangCandidateTarget] = []
  /// Catch-all bang provider (`token == "*"`): handles any `!<token>` not
  /// claimed by an exact `shebangIndex` entry, so a plugin like `searchengines`
  /// can serve the whole DuckDuckGo bang table without enumerating it.
  private var wildcardShebangTargets: [ShebangTarget] = []
  /// Plugin-registered verbs (`flash <verb>`), keyed by lowercased verb name.
  /// Multiple plugins may claim the same verb; dispatch chooses the matching
  /// target with highest selector specificity. The host treats the built-in
  /// `URLEventHandler.commands` table as authoritative for any name it already
  /// owns, so plugin verbs only resolve for names the host doesn't claim.
  /// Rebuilt by `rebuildVerbIndex` whenever the plugin set changes.
  private var verbIndex: [String: [VerbTarget]] = [:]
  /// Resolved plugin mappings across all loaded plugins, rebuilt whenever the
  /// plugin set or any plugin's mappings change. `mappings(in:)` filters this
  /// for the focused app/window URL.
  private var mappingIndex: [ResolvedPluginMapping] = []
  /// Root `only_bundle_ids` across loaded plugins. Used by focus/flashlight
  /// refresh paths without scanning manifests at runtime.
  private var claimedBundleIDsIndex: Set<String> = []
  /// Compiled manifest `listen` patterns across loaded plugins. Hot paths use
  /// this to skip constructing expensive events nobody can receive.
  private var eventListenPatternsIndex: [PluginPattern] = []
  /// Latest host-owned running-app snapshot. Plugins that become ready after a
  /// broadcast can replay this without forcing another LaunchServices walk.
  private var latestRunningApplicationsSnapshot: [[String: Any]] = []
  /// Process IDs that already received the post-ready running-app snapshot.
  /// Keyed by plugin id so file-watch restarts (new pid, same manifest) replay
  /// the snapshot exactly once for the new child.
  private var readyAppsSnapshotReplayPIDs: [String: Int] = [:]
  /// True when any loaded manifest or compiled registration references
  /// `only_urls`. Lets hot paths skip AX URL lookup when the loaded plugin set
  /// cannot use it.
  private var selectorContextNeedsURL = false
  /// Owns the single AX (Accessibility) grant and the handle registry that
  /// backs the `ax.*` host RPCs. Plugins never touch AX directly; they reach
  /// it through this broker via `handleHostRequest`.
  private let axBroker = AXBroker()
  var onStateChanged: (() -> Void)?
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

  private static func selectorStack(
    manifest: PluginManifest,
    entry selector: PluginSelector = PluginSelector()
  ) -> PluginSelectorStack {
    PluginSelectorStack([manifest.selector, selector])
  }

  private static func bestTarget<T>(
    _ targets: [T],
    in context: PluginSelectorContext,
    specificity: (T, PluginSelectorContext) -> Int?
  ) -> T? {
    var best: (target: T, score: Int)?
    for target in targets {
      guard let score = specificity(target, context) else { continue }
      if best == nil || score > best!.score {
        best = (target, score)
      }
    }
    return best?.target
  }

  var sources: [FlashSource] {
    queue.sync { Array(sourceAdaptersByID.values) }
  }

  func start(config: Config) {
    updateConfig(config)
  }

  func stop() {
    let plugins = queue.sync { () -> [PluginProcess] in
      let snapshot = Array(pluginsByID.values)
      for plugin in pluginsByID.values {
        plugin.onStatusChanged = nil
        plugin.onHostRequest = nil
      }
      pluginsByID.removeAll()
      commandIndex.removeAll()
      commandRegistrationIndex.removeAll()
      wildcardCommandIndex.removeAll()
      shebangIndex.removeAll()
      shebangCandidateIndex.removeAll()
      wildcardShebangTargets.removeAll()
      verbIndex.removeAll()
      mappingIndex.removeAll()
      claimedBundleIDsIndex.removeAll()
      eventListenPatternsIndex.removeAll()
      latestRunningApplicationsSnapshot.removeAll()
      readyAppsSnapshotReplayPIDs.removeAll()
      selectorContextNeedsURL = false
      sourceAdaptersByID.removeAll()
      return snapshot
    }
    for plugin in plugins {
      plugin.stopAndWait(reason: "manager_stop")
    }
  }

  func needsURLSelectorContext() -> Bool {
    queue.sync { selectorContextNeedsURL }
  }

  func hasListener(for eventName: String) -> Bool {
    queue.sync {
      eventListenPatternsIndex.contains { $0.matches(eventName) }
    }
  }

  func cacheRunningApplicationsSnapshot(_ applications: [[String: Any]]) {
    queue.async { [weak self] in
      self?.latestRunningApplicationsSnapshot = applications
    }
  }

  func emitRunningApplicationsSnapshot(reason: String, applications: [[String: Any]]) {
    queue.async { [weak self] in
      guard let self else { return }
      self.latestRunningApplicationsSnapshot = applications
      self.emitOnQueue(
        PluginEvent(
          name: "core:apps.snapshot",
          payload: [
            "reason": reason,
            "running_applications": applications,
          ],
          bundleID: nil,
          configPath: nil,
          focused: nil))
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
      self.emitOnQueue(event)
    }
  }

  private func emitOnQueue(_ event: PluginEvent) {
    for plugin in pluginsByID.values {
      plugin.sendEvent(event)
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
    in context: PluginSelectorContext = PluginSelectorContext(),
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcCommand = command.lowercased()
    let key = CommandKey(command: lcCommand, subcommand: subcommand.lowercased())
    // Exact `(command, subcommand)` first; on a miss, fall back to a wildcard
    // command that consumes the whole remainder (the parsed subcommand token
    // is really the first arg, e.g. `:calc 2 + 2`). An app-scoped command is
    // only owned here when its gate matches the focused app.
    let resolved: (target: CommandTarget, subcommand: String, args: [String])? = queue.sync {
      if let target = Self.bestTarget(
        commandIndex[key] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
      {
        return (target, subcommand, args)
      }
      if let target = Self.bestTarget(
        wildcardCommandIndex[lcCommand] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
      {
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
    in context: PluginSelectorContext = PluginSelectorContext(),
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcToken = token.lowercased()
    let target: ShebangTarget? = queue.sync {
      Self.bestTarget(
        shebangIndex[lcToken] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
        ?? Self.bestTarget(
          wildcardShebangTargets,
          in: context,
          specificity: { $0.specificity(in: $1) })
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
  func shebangCandidateSource(
    token: String,
    in context: PluginSelectorContext = PluginSelectorContext()
  ) -> String? {
    let lcToken = token.lowercased()
    return queue.sync {
      if let exact = Self.bestTarget(
        shebangIndex[lcToken] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) }),
        let candidateSource = exact.candidateSource,
        !candidateSource.isEmpty
      {
        return candidateSource
      }
      return nil
    }
  }

  /// The display description for the bang `token` in the focused window
  /// context: the exact registration's if present, else the `"*"`
  /// catch-all's. `nil` when no plugin would claim the token — mirroring
  /// ``invokeShebang(token:query:in:onResult:)`` exactly, so a
  /// surfaced bang row can never fail to dispatch.
  func shebangDescription(
    token: String,
    in context: PluginSelectorContext = PluginSelectorContext()
  ) -> String? {
    let lcToken = token.lowercased()
    return queue.sync {
      if let exact = Self.bestTarget(
        shebangIndex[lcToken] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
      {
        return exact.description
      }
      if let wildcard = Self.bestTarget(
        wildcardShebangTargets,
        in: context,
        specificity: { $0.specificity(in: $1) })
      {
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
  ///   * **Warm dynamic bangs** — kind="bang" candidates the plugin keeps
  ///     warm via `set_locations` (searchengines: ~100 DDG bangs generated
  ///     from `bangs.tsv` at build time). These are *not* returned here; they
  ///     are pulled into the flashlight session pool via `candidateQuery` and
  ///     combined with the static rows in
  ///     `NormalModeCoordinator.bangListCandidates`.
  /// Plugins should not duplicate a token across both surfaces; if they
  /// do, both rows will appear.
  /// Union of every root `only_bundle_ids` entry declared by any loaded plugin.
  /// Lets the flashlight refresh path emit synthetic
  /// `core:focus.changed` events for every running app whose AX walk
  /// a plugin owns — even when that app isn't currently focused —
  /// so the plugin can republish its candidate snapshot before the
  /// next keystroke lands.
  func claimedBundleIDs() -> Set<String> {
    queue.sync { claimedBundleIDsIndex }
  }

  func shebangCandidates(in context: PluginSelectorContext = PluginSelectorContext()) -> [Candidate]
  {
    queue.sync {
      var out: [Candidate] = []
      for item in shebangCandidateIndex where item.selector.matches(context) {
        out.append(item.candidate)
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
    case "app.activate":
      activatePluginApp(params, reply: reply)
    case let method where method.hasPrefix("ax."):
      guard pluginHasCapability(pluginID, .accessibility) else {
        reply(["ok": false, "error": "missing accessibility capability"])
        return
      }
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

  private func activatePluginApp(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init) else {
      reply(["ok": false, "error": "app.activate requires pid"])
      return
    }
    DispatchQueue.main.async {
      guard let app = NSRunningApplication(processIdentifier: pid) else {
        reply(["ok": false, "error": "no running app for pid"])
        return
      }
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      reply(["ok": true])
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

  /// Command registrations available for completion in the active-window
  /// context. More specific registrations are listed first.
  func commandRegistrations(in context: PluginSelectorContext = PluginSelectorContext())
    -> [PluginCommandRegistration]
  {
    queue.sync {
      var out: [(score: Int, order: Int, registration: PluginCommandRegistration)] = []
      for item in commandRegistrationIndex {
        guard let score = item.selector.specificity(in: context) else { continue }
        out.append((score, item.order, item.registration))
      }
      return
        out
        .sorted {
          if $0.score != $1.score { return $0.score > $1.score }
          return $0.order < $1.order
        }
        .map(\.registration)
    }
  }

  func hasCommand(
    command: String,
    subcommand: String,
    in context: PluginSelectorContext = PluginSelectorContext()
  ) -> Bool {
    let lcCommand = command.lowercased()
    let key = CommandKey(command: lcCommand, subcommand: subcommand.lowercased())
    return queue.sync {
      if Self.bestTarget(
        commandIndex[key] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) }) != nil
      {
        return true
      }
      return Self.bestTarget(
        wildcardCommandIndex[lcCommand] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) }) != nil
    }
  }

  /// Rebuild the command lookup index. Must be called from `queue` after
  /// `pluginsByID` changes.
  private func rebuildCommandIndex() {
    var next: [CommandKey: [CommandTarget]] = [:]
    var wildcard: [String: [CommandTarget]] = [:]
    var registrationRows: [CommandRegistrationTarget] = []
    var order = 0
    for plugin in pluginsByID.values.sorted(by: { $0.identifier < $1.identifier }) {
      for registration in plugin.commands {
        let command = registration.command.lowercased()
        let subcommand = registration.subcommand.lowercased()
        let selector = Self.selectorStack(manifest: plugin.manifest, entry: registration.selector)
        let target = CommandTarget(
          plugin: plugin,
          selector: selector,
          meta: registration.meta)
        registrationRows.append(
          CommandRegistrationTarget(
            selector: selector,
            order: order,
            registration: registration))
        order += 1
        if subcommand == "*" {
          wildcard[command, default: []].append(target)
          continue
        }
        let key = CommandKey(command: command, subcommand: subcommand)
        next[key, default: []].append(target)
      }
    }
    commandIndex = next
    commandRegistrationIndex = registrationRows
    wildcardCommandIndex = wildcard
  }

  /// Rebuild manifest-level indexes shared by several runtime paths.
  /// Must be called from `queue` after `pluginsByID` changes.
  private func rebuildManifestIndex() {
    var claimed = Set<String>()
    var needsURL = false
    var eventPatterns: [PluginPattern] = []
    for plugin in pluginsByID.values {
      if plugin.manifest.usesURLSelector { needsURL = true }
      eventPatterns.append(contentsOf: plugin.manifest.listen.map(PluginPattern.init))
      for bundleID in plugin.manifest.onlyBundleIDs {
        claimed.insert(bundleID)
      }
    }
    claimedBundleIDsIndex = claimed
    eventListenPatternsIndex = eventPatterns
    selectorContextNeedsURL = needsURL
  }

  /// Rebuild the flashlight bang index. Must be called from `queue` after
  /// `pluginsByID` changes. Multiple plugins may claim a token; dispatch
  /// chooses the matching target with highest selector specificity.
  private func rebuildShebangIndex() {
    var next: [String: [ShebangTarget]] = [:]
    var wildcard: [ShebangTarget] = []
    var candidates: [ShebangCandidateTarget] = []
    for plugin in pluginsByID.values.sorted(by: { $0.identifier < $1.identifier }) {
      for registration in plugin.shebangs {
        let token = registration.token.lowercased()
        guard !token.isEmpty, !registration.command.isEmpty else { continue }
        let selector = Self.selectorStack(manifest: plugin.manifest, entry: registration.selector)
        let target = ShebangTarget(
          plugin: plugin, command: registration.command,
          description: registration.description,
          selector: selector,
          meta: registration.meta,
          candidateSource: registration.candidateSource)
        if token == "*" {
          wildcard.append(target)
          continue
        }
        candidates.append(
          ShebangCandidateTarget(
            selector: selector,
            candidate: Candidate(
              kind: CandidateFinder.bangKind,
              sourceID: "bang:\(plugin.identifier)",
              source: "bang",
              title: "!\(registration.token)",
              subtitle: registration.description,
              sourcePayload: registration.token)))
        next[token, default: []].append(target)
      }
    }
    shebangIndex = next
    shebangCandidateIndex = candidates
    wildcardShebangTargets = wildcard
  }

  /// Rebuild the verb lookup index. Must be called from `queue` after
  /// `pluginsByID` changes. Plugin verbs only resolve names the built-in
  /// `URLEventHandler.commands` table doesn't already claim (the URL dispatch
  /// checks the built-in table first), so a collision with a built-in is
  /// silently shadowed.
  private func rebuildVerbIndex() {
    var next: [String: [VerbTarget]] = [:]
    for plugin in pluginsByID.values.sorted(by: { $0.identifier < $1.identifier }) {
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
          selector: Self.selectorStack(manifest: plugin.manifest, entry: registration.selector))
        next[name, default: []].append(target)
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
    in context: PluginSelectorContext = PluginSelectorContext(),
    focusedPID: pid_t? = nil,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcName = name.lowercased()
    let target: VerbTarget? = queue.sync {
      Self.bestTarget(
        verbIndex[lcName] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
    }
    guard let target else { return false }
    if let keystroke = target.inlineKeystroke(forBundleID: context.bundleID),
      let pid = focusedPID,
      let parsed = HotkeySyntax.parse(hotkey: keystroke)
    {
      let ok = NormalModeDispatcher.sendKey(
        virtualKey: CGKeyCode(parsed.virtualKey),
        flags: Self.cgEventFlags(carbon: parsed.modifiers),
        to: pid)
      FlashLog.debug(
        "[plugin_verb] inline name=\(lcName) keys=\(keystroke) "
          + "pid=\(pid) bundle=\(context.bundleID ?? "nil") ok=\(ok)")
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
        next.append(
          ResolvedPluginMapping(
            selector: Self.selectorStack(manifest: manifest, entry: registration.selector),
            priority: registration.priority ?? manifest.priority,
            scope: registration.scope,
            mapping: ModeMapping(key: canonical, action: action)))
      }
    }
    mappingIndex = next
  }

  /// Plugin mappings applicable to `context`, as
  /// `(priority, scope, mapping)` tuples for `EffectiveMappings.merge`.
  func mappings(
    in context: PluginSelectorContext
  ) -> [(priority: Int, scope: ModeScope, mapping: ModeMapping)] {
    queue.sync {
      mappingIndex
        .compactMap { item in
          guard let specificity = item.selector.specificity(in: context) else { return nil }
          return (item.priority + specificity, item.scope, item.mapping)
        }
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
    let plugins = queue.sync {
      pluginsByID.values.sorted(by: { $0.identifier < $1.identifier })
    }
    let snapshots = plugins.map { $0.statusSnapshot() }
    guard !snapshots.isEmpty else {
      return "# Plugins\n\nNo plugins loaded."
    }
    let inventory = PluginRegistrationInventory(manifests: plugins.map(\.manifest))
    let headers = ["ID", "STATE", "PID", "HEARTBEAT", "SNAPSHOT", "COMMANDS", "ORIGIN"]
    let rows = snapshots.map { snapshot in
      [
        "\(snapshot.id) \(snapshot.version)",
        snapshot.state,
        snapshot.pid.map(String.init) ?? "-",
        snapshot.heartbeatAgeMs.map { "\($0)ms" } ?? "-",
        "\(snapshot.targetCount)t",
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
    let inventoryHeaders = ["ITEM", "COUNT"]
    let inventoryRows = inventory.rows.map { [$0.label, String($0.count)] }
    let inventoryWidths = inventoryHeaders.indices.map { idx in
      max(inventoryHeaders[idx].count, inventoryRows.map { $0[idx].count }.max() ?? 0)
    }
    func inventoryPadded(_ value: String, _ idx: Int) -> String {
      value + String(repeating: " ", count: max(0, inventoryWidths[idx] - value.count))
    }
    var lines = ["# Plugins", "", "## Registered", "", "```text"]
    lines.append(
      inventoryHeaders.indices.map { inventoryPadded(inventoryHeaders[$0], $0) }
        .joined(separator: "  "))
    for row in inventoryRows {
      lines.append(row.indices.map { inventoryPadded(row[$0], $0) }.joined(separator: "  "))
    }
    lines.append("```")
    lines.append("")
    lines.append("## Runtime")
    lines.append("")
    lines.append("```text")
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
        if config.plugins.disabled.contains(manifest.id) {
          FlashLog.info(
            "[plugins] disabled plugin \(manifest.id) skipped",
            fields: ["id": manifest.id, "root": item.root.path])
          continue
        }
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
        existing?.stopAndWait(reason: "config_reload")
        let plugin = PluginProcess(
          root: item.root,
          manifest: manifest,
          origin: item.origin,
          baseDataDir: baseDataDir,
          watchFiles: config.plugins.watchingEnabled,
          settings: settings)
        plugin.onStatusChanged = { [weak self, weak plugin] in
          guard let self else { return }
          if let plugin {
            self.replayRunningApplicationsSnapshotIfReady(for: plugin)
          }
          self.notifyStateChanged()
        }
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
      pluginsByID[id]?.stopAndWait(reason: "config_removed")
      pluginsByID.removeValue(forKey: id)
      sourceAdaptersByID.removeValue(forKey: id)
      readyAppsSnapshotReplayPIDs.removeValue(forKey: id)
    }
    rebuildCommandIndex()
    rebuildShebangIndex()
    rebuildMappingIndex()
    rebuildVerbIndex()
    rebuildManifestIndex()
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
    FlashProcessEnvironment.shared.apply(to: process)
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
    FlashProcessEnvironment.shared.apply(to: process)
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

  private func replayRunningApplicationsSnapshotIfReady(for plugin: PluginProcess) {
    let snapshot = plugin.statusSnapshot()
    guard snapshot.state == PluginRuntimeState.ready.rawValue, let pid = snapshot.pid else {
      return
    }
    queue.async { [weak self, weak plugin] in
      guard let self, let plugin else { return }
      if self.readyAppsSnapshotReplayPIDs[plugin.identifier] == pid { return }
      self.readyAppsSnapshotReplayPIDs[plugin.identifier] = pid
      let applications = self.latestRunningApplicationsSnapshot
      plugin.sendEvent(
        PluginEvent(
          name: "core:apps.snapshot",
          payload: [
            "reason": "plugin_ready",
            "running_applications": applications,
          ],
          bundleID: nil,
          configPath: nil,
          focused: nil))
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

      Official bundled plugins are enabled unless their id appears in
      `[plugins] disabled`. Third-party plugins are listed in
      `[plugins] third_party` as `github:user/project@<commit-sha>` or
      `file:<path>`.

      Flash starts plugins with:

      - `FLASH_PLUGIN_ID`
      - `FLASH_PLUGIN_VERSION`
      - `FLASH_PLUGIN_DATA_DIR`

      Protocol I/O is length-prefixed MessagePack on stdin/stdout: a 4-byte
      big-endian payload length followed by a MessagePack value. Unexpected
      plugin errors go to stderr. Plugins can log through the protocol and
      Flash records those messages with `source = "plugin:<id>"`.

      Plugins declare event patterns through manifest `listen`, e.g.
      `core:apps.*`, `core:config.*`, and focused AX changes. They can also
      register commands and status-bar segments. Each plugin registers one or
      more **commands** (the verb after `:`, e.g. `spotify`), and each command
      has one or more **subcommands** (e.g. `pause`), which users run as
      `:spotify pause`. A `status` provider declares `segments` in
      `manifest.json`; runtime values are published with `status.updated` and
      are available to `[statusbar].template` as
      `#{plugin:<id>.<segment>}`.

      Official bundled plugins are installed under `FLASH_PLUGIN_DATA_DIR`;
      they do not write CLI binaries into global shell paths. Bundled commands
      include `:spotify` and `:slack`. Authentication is explicit through
      subcommands such as `:slack login`; install and start do not run login
      flows.

      `flash plugins` or `:plugins` opens the plugin modal with manifest
      registration totals and per-plugin runtime status. When `[debug]
      http_inspector_enabled = true` is set, the http inspector page shows
      live logs, resolved config, and plugin state.
      """)
}

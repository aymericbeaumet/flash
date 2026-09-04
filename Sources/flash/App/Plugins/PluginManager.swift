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

  /// A resolved command target: the owning plugin plus the matched entry's
  /// deadline override. `selector` carries the plugin root gate, applied at
  /// lookup against the focused app.
  private struct CommandTarget {
    let plugin: PluginProcess
    let selector: PluginSelectorStack
    /// The matched manifest entry's `timeout_ms`, forwarded to `perform` so
    /// interactive commands outlive the generic deadline.
    let timeoutMs: Int?

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

  /// A resolved plugin-verb target: the owning plugin, the
  /// command/subcommand folded from the manifest, and an optional
  /// per-bundle keystroke table (which lets the host synthesize the key
  /// directly when it matches the focused bundle, skipping the plugin RPC).
  private struct VerbTarget {
    let plugin: PluginProcess
    let command: String
    let subcommand: String
    let keystrokes: [String: String]
    let selector: PluginSelectorStack

    func specificity(in context: PluginSelectorContext) -> Int? {
      selector.specificity(in: context)
    }

    /// Hotkey string to synthesize for `bundleID`, or `nil` when the verb has
    /// no keystroke shortcut for it. The empty-key entry (`""`) acts as the
    /// catch-all default, mirroring the manifest convention.
    func keystroke(forBundleID bundleID: String?) -> String? {
      if let bundleID, let exact = keystrokes[bundleID], !exact.isEmpty {
        return exact
      }
      let fallback = keystrokes[""] ?? ""
      return fallback.isEmpty ? nil : fallback
    }
  }

  /// A resolved flashlight bang target: the owning plugin and the command
  /// its `perform {kind: "command"}` carries. Dispatched with the typed bang
  /// as the subcommand — so a `bangs` block needs no matching `commands`
  /// entry.
  private struct ShebangTarget {
    let plugin: PluginProcess
    let command: String
    let description: String
    let selector: PluginSelectorStack
    /// Candidate source label declared on the bang entry. When set, the
    /// flashlight pool swaps to candidates from that source while the bang
    /// is confirmed (e.g. `!kill ` → `processes.processes`).
    let candidateSource: String?

    func specificity(in context: PluginSelectorContext) -> Int? {
      selector.specificity(in: context)
    }
  }

  /// Static bang candidate prepared from manifest bangs. Dynamic bang
  /// candidates come from published catalogs.
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

  /// Everything the main thread reads on a hot path (flashlight open,
  /// focus-change mapping refresh, per-AX-notification listener checks, the
  /// status-bar publish tick, command/verb/bang dispatch, `:plugins`),
  /// captured immutably. Hot readers take this behind a plain lock instead
  /// of `queue.sync` — the manager queue runs reconciliation, which
  /// stops/starts child processes and must never gate the main thread.
  private struct HotSnapshot {
    var sourceAdapters: [PluginFlashSource] = []
    var plugins: [PluginProcess] = []
    var loadFailureStatuses: [PluginStatus] = []
    var mappingIndex: [ResolvedPluginMapping] = []
    var eventListenPatterns: [PluginPattern] = []
    var commandIndex: [CommandKey: [CommandTarget]] = [:]
    var wildcardCommandIndex: [String: [CommandTarget]] = [:]
    var commandRegistrationIndex: [CommandRegistrationTarget] = []
    var shebangIndex: [String: [ShebangTarget]] = [:]
    var shebangCandidateIndex: [ShebangCandidateTarget] = []
    var wildcardShebangTargets: [ShebangTarget] = []
    var verbIndex: [String: [VerbTarget]] = [:]
    var helpTopics: [HelpTopic] = []
  }

  private let queue = DispatchQueue(label: "flash.plugins", qos: .utility)
  /// Third-party materialization (git fetch, up to 60 s per call) runs here,
  /// never on `queue`: dispatch paths read the hot snapshot from user actions.
  private let materializeQueue = DispatchQueue(
    label: "flash.plugins.materialize", qos: .utility)
  private let hotSnapshotLock = NSLock()
  private var hotSnapshot = HotSnapshot()
  /// Monotonic config generation. A reload that finished materializing for a
  /// superseded config (or after `stop()`) must not clobber newer state.
  private let generationLock = NSLock()
  private var configGeneration = 0
  private let baseDataDir: URL
  private let repository: PluginRepository
  /// The host-owned push catalog store every plugin's validated `publish`
  /// lands in; PluginFlashSource reads it synchronously.
  let catalogStore = PluginCatalogStore()
  /// Manifest load/validate failures from the last reconcile, surfaced as
  /// `failed` rows in `:plugins`/the inspector/the status bar error count
  /// instead of the plugin silently not existing.
  private var loadFailureStatuses: [PluginStatus] = []
  private var pluginsByID: [String: PluginProcess] = [:]
  private var sourceAdaptersByID: [String: PluginFlashSource] = [:]
  /// Latest host-owned running-app snapshot, behind its own lock so each
  /// plugin's post-initialize `core:apps.changed` reads it from the plugin
  /// queue without touching the manager queue.
  private let runningApplicationsLock = NSLock()
  private var latestRunningApplicationsSnapshot: [[String: Any]] = []
  /// The plugin→host RPC router + implementations (AX broker, activation,
  /// input synthesis, fetch). The manager only wires each plugin's
  /// `onHostRequest` to it with that plugin's frozen authorization.
  private let hostRPC = PluginHostRPC()
  var onStateChanged: (() -> Void)?
  /// Coalesced (≤1/s) "catalogs changed" tick from the store — lossless,
  /// consumers re-read the store. Replaces the old per-plugin invalidation
  /// chain.
  var onCatalogsChanged: (() -> Void)? {
    get { catalogStore.onCatalogsChanged }
    set { catalogStore.onCatalogsChanged = newValue }
  }
  /// See `PluginHostRPC.onNormalModeTargetRequested`; forwarded so
  /// AppDelegate wiring stays on the manager.
  var onNormalModeTargetRequested: (() -> (pid: pid_t, bundleID: String)?)? {
    get { hostRPC.onNormalModeTargetRequested }
    set { hostRPC.onNormalModeTargetRequested = newValue }
  }

  /// See `PluginHostRPC.onNotifyRequested`; forwarded the same way.
  var onNotifyRequested: ((String, Int) -> Void)? {
    get { hostRPC.onNotifyRequested }
    set { hostRPC.onNotifyRequested = newValue }
  }

  /// See `PluginHostRPC.wifiInfoProvider`; forwarded so AppDelegate owns the
  /// system authorization provider while the manager owns RPC routing.
  var wifiInfoProvider: WiFiInfoProviding? {
    get { hostRPC.wifiInfoProvider }
    set { hostRPC.wifiInfoProvider = newValue }
  }

  /// See `PluginHostRPC.onSyntheticKeysRequested`; forwarded likewise.
  var onSyntheticKeysRequested: ((pid_t, [(key: CGKeyCode, flags: CGEventFlags)], Int) -> Void)? {
    get { hostRPC.onSyntheticKeysRequested }
    set { hostRPC.onSyntheticKeysRequested = newValue }
  }
  /// See `PluginHostRPC.onGlobalSyntheticKeyRequested`; forwarded likewise.
  var onGlobalSyntheticKeyRequested: ((CGKeyCode, CGEventFlags) -> Bool)? {
    get { hostRPC.onGlobalSyntheticKeyRequested }
    set { hostRPC.onGlobalSyntheticKeyRequested = newValue }
  }

  init(baseDataDir: URL = PluginRepository.defaultDataDir()) {
    self.baseDataDir = baseDataDir
    self.repository = PluginRepository(baseDataDir: baseDataDir)
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

  private func readHotSnapshot() -> HotSnapshot {
    hotSnapshotLock.lock()
    defer { hotSnapshotLock.unlock() }
    return hotSnapshot
  }

  /// Runs on `queue` after any mutation of the plugin set.
  private func publishHotSnapshot() {
    let plugins = pluginsByID.values.sorted { $0.identifier < $1.identifier }
    var mappingIndex: [ResolvedPluginMapping] = []
    var eventPatterns: [PluginPattern] = []
    var commandIndex: [CommandKey: [CommandTarget]] = [:]
    var wildcardCommandIndex: [String: [CommandTarget]] = [:]
    var registrationRows: [CommandRegistrationTarget] = []
    var shebangIndex: [String: [ShebangTarget]] = [:]
    var shebangCandidates: [ShebangCandidateTarget] = []
    var wildcardShebangs: [ShebangTarget] = []
    var verbIndex: [String: [VerbTarget]] = [:]
    var helpTopics: [HelpTopic] = []
    var order = 0
    for plugin in plugins {
      let manifest = plugin.manifest
      let rootSelector = PluginSelectorStack([manifest.selector])
      eventPatterns.append(contentsOf: manifest.listen.map(PluginPattern.init))

      for registration in manifest.commands {
        let command = registration.command.lowercased()
        let subcommand = registration.subcommand.lowercased()
        let target = CommandTarget(
          plugin: plugin,
          selector: rootSelector,
          timeoutMs: registration.timeoutMs)
        registrationRows.append(
          CommandRegistrationTarget(
            selector: rootSelector,
            order: order,
            registration: registration))
        order += 1
        if subcommand == "*" {
          wildcardCommandIndex[command, default: []].append(target)
          continue
        }
        commandIndex[CommandKey(command: command, subcommand: subcommand), default: []]
          .append(target)
      }

      let bangCommand = manifest.bangCommand
      for registration in manifest.bangs {
        let token = registration.token.lowercased()
        guard !token.isEmpty, !bangCommand.isEmpty else { continue }
        let target = ShebangTarget(
          plugin: plugin,
          command: bangCommand,
          description: registration.description,
          selector: rootSelector,
          candidateSource: registration.source)
        if token == "*" {
          wildcardShebangs.append(target)
          continue
        }
        shebangCandidates.append(
          ShebangCandidateTarget(
            selector: rootSelector,
            candidate: Candidate(
              kind: CandidateFinder.bangKind,
              sourceID: "bang:\(plugin.identifier)",
              source: "bang",
              title: "!\(registration.token)",
              subtitle: registration.description,
              sourcePayload: registration.token)))
        shebangIndex[token, default: []].append(target)
      }

      for registration in manifest.verbs {
        let name = registration.name.lowercased()
        guard !name.isEmpty else { continue }
        let command = registration.command.isEmpty ? plugin.identifier : registration.command
        let subcommand = registration.subcommand.isEmpty ? name : registration.subcommand
        verbIndex[name, default: []].append(
          VerbTarget(
            plugin: plugin,
            command: command,
            subcommand: subcommand,
            keystrokes: registration.keystrokes,
            selector: rootSelector))
      }

      for registration in manifest.mappings {
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
        mappingIndex.append(
          ResolvedPluginMapping(
            selector: PluginSelectorStack([manifest.selector, registration.selector]),
            priority: registration.priority ?? manifest.priority,
            scope: registration.scope,
            mapping: ModeMapping(key: canonical, action: action)))
      }

      // Topic names collide on a first-wins basis with the host's topics
      // (see `HelpDocs.allTopics`), so a plugin claiming `flashlight` is
      // shadowed by the host's own topic.
      helpTopics.append(
        contentsOf: manifest.help.topics.map { topic in
          HelpTopic(
            name: topic.name,
            title: topic.title.isEmpty ? topic.name : topic.title,
            summary: topic.summary,
            body: topic.body,
            aliases: topic.aliases)
        })
    }

    let snapshot = HotSnapshot(
      sourceAdapters: Array(sourceAdaptersByID.values),
      plugins: plugins,
      loadFailureStatuses: loadFailureStatuses,
      mappingIndex: mappingIndex,
      eventListenPatterns: eventPatterns,
      commandIndex: commandIndex,
      wildcardCommandIndex: wildcardCommandIndex,
      commandRegistrationIndex: registrationRows,
      shebangIndex: shebangIndex,
      shebangCandidateIndex: shebangCandidates,
      wildcardShebangTargets: wildcardShebangs,
      verbIndex: verbIndex,
      helpTopics: helpTopics)
    hotSnapshotLock.lock()
    hotSnapshot = snapshot
    hotSnapshotLock.unlock()
  }

  private func bumpGeneration() -> Int {
    generationLock.lock()
    defer { generationLock.unlock() }
    configGeneration += 1
    return configGeneration
  }

  private func isCurrentGeneration(_ generation: Int) -> Bool {
    generationLock.lock()
    defer { generationLock.unlock() }
    return generation == configGeneration
  }

  var sources: [FlashSource] {
    readHotSnapshot().sourceAdapters
  }

  func start(config: Config) {
    updateConfig(config)
  }

  func stop() {
    // Invalidate any in-flight materialization so a late reload can't
    // resurrect plugins after shutdown, and clear the change callback before
    // the store empties — a post-stop tick must not reach a dead consumer
    // (the old lost-callback bug).
    _ = bumpGeneration()
    catalogStore.onCatalogsChanged = nil
    let plugins = queue.sync { () -> [PluginProcess] in
      let snapshot = Array(pluginsByID.values)
      for plugin in pluginsByID.values {
        plugin.onStatusChanged = nil
        plugin.onHostRequest = nil
        plugin.runningApplicationsProvider = nil
      }
      pluginsByID.removeAll()
      sourceAdaptersByID.removeAll()
      loadFailureStatuses.removeAll()
      publishHotSnapshot()
      return snapshot
    }
    for plugin in plugins {
      plugin.stopAndWait(reason: "manager_stop")
    }
    catalogStore.removeAll()
  }

  func hasListener(for eventName: String) -> Bool {
    readHotSnapshot().eventListenPatterns.contains { $0.matches(eventName) }
  }

  private func runningApplicationsSnapshotValue() -> [[String: Any]] {
    runningApplicationsLock.lock()
    defer { runningApplicationsLock.unlock() }
    return latestRunningApplicationsSnapshot
  }

  func cacheRunningApplicationsSnapshot(_ applications: [[String: Any]]) {
    runningApplicationsLock.lock()
    latestRunningApplicationsSnapshot = applications
    runningApplicationsLock.unlock()
  }

  func emitRunningApplicationsChanged(reason: String, applications: [[String: Any]]) {
    cacheRunningApplicationsSnapshot(applications)
    emit(
      PluginEvent(
        name: "core:apps.changed",
        payload: [
          "reason": reason,
          "running_applications": applications,
        ],
        bundleID: nil))
  }

  func updateConfig(_ config: Config) {
    let generation = bumpGeneration()
    // Materialize third-party checkouts (network, a 60 s git timeout per
    // call) BEFORE entering the manager queue — the serial materialize queue
    // preserves config ordering; the generation guard drops a reload whose
    // config was superseded while it fetched.
    materializeQueue.async { [weak self] in
      guard let self, self.isCurrentGeneration(generation) else { return }
      var thirdParty: [(root: URL, origin: PluginOrigin)] = []
      for ref in config.plugins.thirdParty {
        if let materialized = self.repository.materialize(ref) {
          thirdParty.append(materialized)
        }
      }
      self.queue.async {
        guard self.isCurrentGeneration(generation) else { return }
        self.reloadDesiredPlugins(config: config, thirdParty: thirdParty)
      }
    }
  }

  func emit(_ event: PluginEvent) {
    // sendEvent filters by listen pattern off-queue and hops to each
    // plugin's own queue, so fan-out from the snapshot is safe anywhere.
    for plugin in readHotSnapshot().plugins {
      plugin.sendEvent(event)
    }
  }

  /// Returns true when a plugin owns `(command, subcommand)` and the
  /// invocation was dispatched (synchronous ownership check). The plugin
  /// runs asynchronously; `onResult` delivers `(ok, targetPID, message,
  /// navigationURL)` once its `perform` settles. `targetPID`, when present,
  /// is an app the command asked Flash to raise; `message`, when present, is
  /// text to surface as a toast; `navigationURL` is the route recorded into
  /// movement history for `ctrl-o` / `ctrl-i`.
  @discardableResult
  func invoke(
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    in context: PluginSelectorContext = PluginSelectorContext(),
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let snapshot = readHotSnapshot()
    let lcCommand = command.lowercased()
    let key = CommandKey(command: lcCommand, subcommand: subcommand.lowercased())
    // Exact `(command, subcommand)` first; on a miss, fall back to a wildcard
    // command that consumes the whole remainder (the parsed subcommand token
    // is really the first arg, e.g. `:calc 2 + 2`). An app-scoped command is
    // only owned here when its gate matches the focused app.
    let resolved: (target: CommandTarget, subcommand: String, args: [String])?
    if let target = Self.bestTarget(
      snapshot.commandIndex[key] ?? [],
      in: context,
      specificity: { $0.specificity(in: $1) })
    {
      resolved = (target, subcommand, args)
    } else if let target = Self.bestTarget(
      snapshot.wildcardCommandIndex[lcCommand] ?? [],
      in: context,
      specificity: { $0.specificity(in: $1) })
    {
      resolved = (target, "", [subcommand] + args)
    } else {
      resolved = nil
    }
    guard let resolved else { return false }
    performCommand(
      plugin: resolved.target.plugin,
      command: command,
      subcommand: resolved.subcommand,
      args: resolved.args,
      raw: raw,
      timeoutMs: resolved.target.timeoutMs,
      onResult: onResult)
    return true
  }

  /// Dispatch one `perform {kind: "command"}` and adapt the trichotomy to
  /// the `(ok, pid, message, navigationURL)` shape command callers consume.
  private func performCommand(
    plugin: PluginProcess,
    command: String,
    subcommand: String,
    args: [String],
    raw: String,
    timeoutMs: Int?,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)?
  ) {
    plugin.perform(
      kind: "command",
      params: [
        "command": command,
        "subcommand": subcommand,
        "args": args,
        "raw": raw,
      ],
      timeoutMs: timeoutMs
    ) { outcome in
      switch outcome {
      case .performed(let pid, let navigationURL, let message):
        FlashLog.debug(
          "[plugin_command] command=\(command) subcommand=\(subcommand) ok=true "
            + "target_pid=\(pid.map(String.init) ?? "nil") "
            + "navigation_scheme=\(navigationURL?.scheme ?? "nil")")
        onResult?(true, pid, message, navigationURL)
      case .unhandled:
        FlashLog.debug(
          "[plugin_command] command=\(command) subcommand=\(subcommand) unhandled")
        onResult?(false, nil, nil, nil)
      case .failed(let error):
        FlashLog.plugin(
          .warn,
          pluginID: plugin.identifier,
          message: "[plugin] command failed command=\(command) subcommand=\(subcommand)",
          fields: [
            "command": command,
            "subcommand": subcommand,
            "error": error,
          ])
        onResult?(false, nil, nil, nil)
      }
    }
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
    let snapshot = readHotSnapshot()
    let lcToken = token.lowercased()
    let target =
      Self.bestTarget(
        snapshot.shebangIndex[lcToken] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) })
      ?? Self.bestTarget(
        snapshot.wildcardShebangTargets,
        in: context,
        specificity: { $0.specificity(in: $1) })
    guard let target else { return false }
    let args = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    performCommand(
      plugin: target.plugin,
      command: target.command,
      subcommand: token,
      args: args,
      raw: query,
      timeoutMs: nil,
      onResult: onResult)
    return true
  }

  /// The candidate source declared by the bang registration matching `token`.
  /// Plugins that bind a bang to a source (e.g. `!kill` → `processes.processes`)
  /// declare it on the bang entry; the host swaps the candidate-finder pool
  /// to that source once the bang is confirmed. `nil` when no registration
  /// declared one.
  func shebangCandidateSource(
    token: String,
    in context: PluginSelectorContext = PluginSelectorContext()
  ) -> String? {
    let snapshot = readHotSnapshot()
    let lcToken = token.lowercased()
    guard
      let exact = Self.bestTarget(
        snapshot.shebangIndex[lcToken] ?? [],
        in: context,
        specificity: { $0.specificity(in: $1) }),
      let candidateSource = exact.candidateSource,
      !candidateSource.isEmpty
    else { return nil }
    return candidateSource
  }

  /// Synthetic flashlight rows for every exact-token bang registration
  /// (the `"*"` catch-all has no concrete token to list — typed `!<token>`
  /// queries surface it live instead). Two sources combine here:
  ///   * **Manifest bangs** — declared statically in `manifest.json`,
  ///     gated against the focused app. Used by plugins with a small fixed
  ///     set of bangs (aiproviders: chatgpt/claude/…).
  ///   * **Published dynamic bangs** — kind="bang" rows the plugin keeps in
  ///     its pushed catalog (searchengines: ~100 DDG bangs generated from
  ///     `bangs.tsv` at build time). Those are *not* returned here; they
  ///     reach the flashlight pool through the catalog store and are
  ///     combined with the static rows in
  ///     `NormalModeCoordinator.bangListCandidates`.
  /// Plugins should not duplicate a token across both surfaces; if they
  /// do, both rows will appear.
  func shebangCandidates(in context: PluginSelectorContext = PluginSelectorContext()) -> [Candidate]
  {
    readHotSnapshot().shebangCandidateIndex
      .filter { $0.selector.matches(context) }
      .map(\.candidate)
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
    var out: [(score: Int, order: Int, registration: PluginCommandRegistration)] = []
    for item in readHotSnapshot().commandRegistrationIndex {
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

  /// Dispatch a plugin verb. Returns true when a plugin claims the verb (and
  /// the dispatch was issued — either as a synthesized keystroke or as an
  /// asynchronous plugin command). The `keystrokes` shortcut path runs
  /// synchronously and reports `(true, focusedPID, nil, nil)` via `onResult`;
  /// the RPC path follows the command-perform contract, with `args` flattened
  /// into `key=value` positional tokens so plugins can parse them off the
  /// request args without a special map decoder.
  @discardableResult
  func invokeVerb(
    name: String,
    args: [String: String],
    in context: PluginSelectorContext = PluginSelectorContext(),
    focusedPID: pid_t? = nil,
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)? = nil
  ) -> Bool {
    let lcName = name.lowercased()
    let target = Self.bestTarget(
      readHotSnapshot().verbIndex[lcName] ?? [],
      in: context,
      specificity: { $0.specificity(in: $1) })
    guard let target else { return false }
    if let keystroke = target.keystroke(forBundleID: context.bundleID),
      let pid = focusedPID,
      let parsed = HotkeySyntax.parse(hotkey: keystroke)
    {
      let ok = NormalModeDispatcher.sendKey(
        virtualKey: CGKeyCode(parsed.virtualKey),
        flags: Self.cgEventFlags(carbon: parsed.modifiers),
        to: pid)
      FlashLog.debug(
        "[plugin_verb] keystroke name=\(lcName) keys=\(keystroke) "
          + "pid=\(pid) bundle=\(context.bundleID ?? "nil") ok=\(ok)")
      onResult?(ok, pid, nil, nil)
      return true
    }
    let positional = args.keys.sorted().map { key in "\(key)=\(args[key] ?? "")" }
    let raw = positional.isEmpty ? name : "\(name) " + positional.joined(separator: " ")
    performCommand(
      plugin: target.plugin,
      command: target.command,
      subcommand: target.subcommand,
      args: positional,
      raw: raw,
      timeoutMs: nil,
      onResult: onResult)
    return true
  }

  /// Plugin mappings applicable to `context`, as
  /// `(priority, scope, mapping)` tuples for `EffectiveMappings.merge`.
  func mappings(
    in context: PluginSelectorContext
  ) -> [(priority: Int, scope: ModeScope, mapping: ModeMapping)] {
    readHotSnapshot().mappingIndex
      .compactMap { item in
        guard let specificity = item.selector.specificity(in: context) else { return nil }
        return (item.priority + specificity, item.scope, item.mapping)
      }
  }

  /// Help topics every loaded plugin contributes via `manifest.help.topics`,
  /// flattened into the host's `HelpTopic` type at snapshot-publish time so
  /// `:help` never touches the manager queue.
  func pluginHelpTopics() -> [HelpTopic] {
    readHotSnapshot().helpTopics
  }

  func pluginStatuses() -> [PluginStatus] {
    let snapshot = readHotSnapshot()
    // statusSnapshot() hops onto each plugin's own queue — never the
    // manager queue, which may be mid-reconcile.
    return (snapshot.plugins.map { $0.statusSnapshot() } + snapshot.loadFailureStatuses)
      .sorted { $0.id < $1.id }
  }

  /// The status bar's per-publish read: id/state/error flag/segments only —
  /// no rusage syscall, no commands copy. Fires on the clock tick and every
  /// focus change, so it must stay allocation-light.
  func statusBarInfos() -> [PluginStatusBarInfo] {
    let snapshot = readHotSnapshot()
    // statusBarInfo() reads each process's own lock — no manager queue hop.
    return snapshot.plugins.map { $0.statusBarInfo() }
      + snapshot.loadFailureStatuses.map {
        PluginStatusBarInfo(id: $0.id, state: $0.state, hasError: true, statusSegments: [:])
      }
  }

  private func reloadDesiredPlugins(
    config: Config, thirdParty: [(root: URL, origin: PluginOrigin)]
  ) {
    var desired: [(root: URL, origin: PluginOrigin)] = PluginRepository.officialPluginRoots().map {
      ($0, .official)
    }
    desired.append(contentsOf: thirdParty)

    loadFailureStatuses.removeAll()
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
        plugin.catalogStore = catalogStore
        plugin.runningApplicationsProvider = { [weak self] in
          self?.runningApplicationsSnapshotValue() ?? []
        }
        plugin.onStatusChanged = { [weak self] in
          self?.notifyStateChanged()
        }
        // Capture immutable authorization with the process. A host RPC arrives
        // on PluginProcess.queue; consulting PluginManager.queue synchronously
        // from there would invert the reload path
        // (manager queue -> stopAndWait -> process queue) and can deadlock.
        let capabilities = manifest.capabilities
        let fetchURLs = manifest.fetchURLs
        let dataDir = baseDataDir.appendingPathComponent(manifest.id)
        plugin.onHostRequest = { [weak self] method, params, pluginID, reply in
          self?.hostRPC.handleHostRequest(
            method: method,
            params: params,
            pluginID: pluginID,
            capabilities: capabilities,
            fetchURLs: fetchURLs,
            dataDir: dataDir,
            reply: reply)
        }
        pluginsByID[manifest.id] = plugin
        sourceAdaptersByID[manifest.id] = PluginFlashSource(plugin: plugin, store: catalogStore)
        plugin.start()
      } catch {
        FlashLog.warn(
          "[plugins] failed to load \(item.root.path): \(error)",
          fields: [
            "root": item.root.path,
            "origin": String(describing: item.origin),
            "error": String(describing: error),
          ])
        // A manifest typo must show up in `:plugins` and the inspector as a
        // failed row — not as the plugin silently ceasing to exist.
        loadFailureStatuses.append(
          PluginStatus(
            id: item.root.lastPathComponent,
            name: item.root.lastPathComponent,
            version: "-",
            description: String(describing: error),
            origin: item.origin.label,
            root: item.root.path,
            state: PluginRuntimeState.failed.rawValue,
            activation: "",
            pid: nil,
            uptimeMs: nil,
            sourceCount: 0,
            commandCount: 0,
            restartCount: 0,
            lastError: String(describing: error),
            lastLog: nil,
            cpuPercent: nil,
            memoryBytes: nil,
            onlyBundleIDs: [],
            priority: 0,
            commands: [],
            statusSegments: [:]))
      }
    }

    for id in Array(pluginsByID.keys) where !nextIDs.contains(id) {
      pluginsByID[id]?.stopAndWait(reason: "config_removed")
      pluginsByID.removeValue(forKey: id)
      sourceAdaptersByID.removeValue(forKey: id)
      // Unload drops the published catalog — the rows' owner is gone.
      catalogStore.drop(pluginID: id)
    }
    publishHotSnapshot()
    notifyStateChanged()
  }

  /// Stop every loaded plugin and restart it. Triggered by
  /// `:plugins reload`. Returns the IDs being restarted so callers can
  /// include them in a confirmation alert; the restarts themselves run
  /// asynchronously off the snapshot — the main thread never waits on the
  /// manager queue.
  @discardableResult
  func reloadAll() -> [String] {
    let plugins = readHotSnapshot().plugins
    queue.async {
      for plugin in plugins {
        plugin.reload(reason: "plugins_reload")
      }
    }
    notifyStateChanged()
    return plugins.map(\.identifier)
  }

  private func notifyStateChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.onStateChanged?()
    }
  }
}

extension PluginManager {
  static let helpTopic = HelpTopic(
    name: "plugins",
    title: "Plugins",
    summary: "Managed stdio plugins, manifests, events, and commands.",
    body: """
      # Plugins

      Plugins are managed child processes owned by Flash, speaking NDJSON
      (one JSON object per newline-terminated line) on stdin/stdout —
      protocol v1, documented in `docs/plugin-protocol.md`. Each plugin is a
      directory with a `manifest.json` declaring what it serves: `sources`
      (push-published flashlight catalogs), `query` (inline answers),
      `hints`, `status` segments, `listen` event patterns, `commands`
      (`:verb sub`), `bangs` (`!token`), `verbs`, `mappings`, `navigation`
      schemes, `actions`, `capabilities`, an optional `sandbox` spec, and
      `help` topics. `exec` is the argv that starts the process; a manifest
      without `exec` is manifest-only (mappings, help, and keystroke verbs
      served by the host alone).

      A plugin declaring `sources`, `query`, `hints`, `status`, or `listen`
      is resident (spawned at startup); one declaring only commands, bangs,
      verbs, or navigation stays stopped until its first dispatch. Official
      bundled plugins are enabled unless their id appears in `[plugins]
      disabled`. Third-party plugins are listed in `[plugins] third_party`
      as `github:user/project@<40-char commit sha>` or `file:<path>`; only
      third-party manifests may declare an `install` shell step, which runs
      sandboxed.

      Flash starts plugin processes with a scrubbed environment plus:

      - `FLASH_PLUGIN_ID`
      - `FLASH_PLUGIN_VERSION`
      - `FLASH_PLUGIN_DATA_DIR`
      - `FLASH_PLUGIN_CONFIG` (the `[plugin.<id>]` settings as JSON)
      - `FLASH_PLUGIN_PARENT_PID` (exit when this pid dies)

      Catalogs are push-based: the plugin sends a `publish` notification
      whenever its rows change and the host serves the flashlight from its
      own store. Status segments arrive via the `status` notification and
      render as `#{plugin:<id>.<segment>}` in `[statusbar].template`.
      Structured logs go through the `log` notification and are recorded
      with `source = "plugin:<id>"`. Sensitive host surfaces (clipboard,
      accessibility, network, notifications, …) are default-deny and must be
      requested via manifest `capabilities`.

      Plugin dirs are watched (unless `[plugins] watching_enabled = false`)
      and hot-reload on change. `flash plugins` or `:plugins` opens the
      plugin dashboard with per-plugin runtime state; `:plugins reload`
      restarts everything, including plugins parked in `failed`.
      """)
}

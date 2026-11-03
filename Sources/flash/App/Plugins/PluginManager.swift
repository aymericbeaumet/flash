import AppKit
import Carbon.HIToolbox
import Darwin
import FlashCore
import Foundation
import os

final class PluginManager {
  private struct CommandKey: Hashable {
    let command: String
    let subcommand: String
  }

  /// A resolved command target: the owning plugin. `selector` carries the
  /// plugin root gate, applied at lookup against the focused app.
  private struct CommandTarget {
    let plugin: PluginProcess
    let selector: PluginSelectorStack

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

  /// A resolved flashlight bang target: the owning plugin, whose id is the
  /// command its `perform {kind: "command"}` carries. Dispatched with the
  /// typed bang as the subcommand — so `bangs` needs no matching `commands`
  /// entry. A bang is typed in the flashlight, whatever app is focused, so
  /// its selector is always the empty stack: an owner scoped to its apps
  /// (browsers' `!fh`) still resolves from Terminal.
  private struct ShebangTarget {
    let plugin: PluginProcess
    let description: String
    let selector: PluginSelectorStack
    /// Candidate source name declared on the bang entry. When set, the
    /// flashlight pool swaps to candidates from that source while the bang
    /// is confirmed (e.g. `!fh ` → `firefox.history`).
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
  /// status-bar publish tick, command/bang dispatch, command bindings,
  /// `:plugins show`), captured immutably. Hot readers take this behind a plain lock instead
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
    var commandBindings = CommandBindingIndex()
    var commandConfirmations = CommandConfirmationIndex()
    var helpTopics: [HelpTopic] = []
  }

  private let queue = DispatchQueue(label: "flash.plugins", qos: .utility)
  /// Third-party materialization (git fetch, up to 60 s per call) runs here,
  /// never on `queue`: dispatch paths read the hot snapshot from user actions.
  private let materializeQueue = DispatchQueue(
    label: "flash.plugins.materialize", qos: .utility)
  private let hotSnapshotLock = NSLock()
  private var hotSnapshot = HotSnapshot()
  /// The plugins listening to each event name seen since the snapshot was
  /// published, so a storm of one event (`core:ax.changed`) never re-walks
  /// every plugin's listen globs. Guarded by `hotSnapshotLock`.
  private var listenersByEventName: [String: [PluginProcess]] = [:]
  /// Desired configuration and pending restarts change as one locked value.
  /// A restart cannot replay a caller's older config.
  struct DesiredState {
    enum Request {
      case configure(Config)
      case restart(Set<String>)
    }

    struct Reconciliation {
      let config: Config
      let generation: Int
    }

    private(set) var config: Config?
    private var generation = 0
    private var restartIDs: Set<String> = []

    mutating func request(_ request: Request) -> Reconciliation? {
      switch request {
      case .configure(let config):
        self.config = config
      case .restart(let ids):
        guard config != nil else { return nil }
        restartIDs.formUnion(ids)
      }
      guard let config else { return nil }
      generation += 1
      return Reconciliation(config: config, generation: generation)
    }

    mutating func stop() {
      generation += 1
      config = nil
      restartIDs.removeAll()
    }

    func isCurrent(_ generation: Int) -> Bool {
      self.generation == generation && config != nil
    }

    mutating func takeRestarts(for generation: Int) -> Set<String>? {
      guard isCurrent(generation) else { return nil }
      let pending = restartIDs
      restartIDs.removeAll()
      return pending
    }
  }

  /// Monotonic config generation. A reload that finished materializing for a
  /// superseded config (or after `stop()`) must not clobber newer state.
  private let desiredState = OSAllocatedUnfairLock(initialState: DesiredState())
  private let baseDataDir: URL
  private let repository: PluginRepository
  /// The host-owned push catalog store every plugin's validated `publish`
  /// lands in; PluginFlashSource reads it synchronously.
  let catalogStore = PluginCatalogStore()
  /// Manifest load/validate failures from the last reconcile, surfaced as
  /// `failed` rows in `:plugins show`/the inspector/the status bar error count
  /// instead of the plugin silently not existing.
  private var loadFailureStatuses: [PluginStatus] = []
  private var pluginsByID: [String: PluginProcess] = [:]
  /// Desktop widgets fully covered for at least `hiddenWidgetGraceMs`: they no
  /// longer observe plugin segments. Queue-confined, as is `pendingHides`.
  private var hiddenWidgets: Set<String> = []
  /// One grace deadline per covered widget on the shared clock. `.low`:
  /// nobody can see a covered widget, and the grace only decides when its
  /// plugins stop sampling for it.
  private var pendingHides: [String: PollDeadline] = [:]
  /// How long a widget stays covered before its plugins stop sampling for it,
  /// so briefly covering the desktop does not respawn status plugins.
  static let hiddenWidgetGraceMs = 30_000
  /// Spawns the warm on-demand plugins — those a configured mapping can run
  /// (`PluginWarmPolicy`) — once startup has settled, so the first keypress
  /// that needs one does not wait on process creation. Every reconcile
  /// re-arms it, so the newest plugin set is the one warmed. `.low`: nothing
  /// waits on it, since a perform that comes first spawns its plugin itself.
  /// Queue-confined.
  private lazy var prewarmDeadline = PollDeadline(
    "core:plugin_prewarm", priority: .low, on: queue)
  /// How long after a reconcile the prewarm waits, so the resident plugins
  /// spawn before on-demand ones join them. A testability seam.
  static var prewarmDelayMs = 10_000
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

  /// `pid` quit: drop the Accessibility handles plugins hold into it.
  func appTerminated(pid: pid_t) {
    hostRPC.appTerminated(pid: pid)
  }

  var onStateChanged: (() -> Void)?
  /// Main-thread notification after a changed `own_text_editing` union is published.
  var onOwnTextEditingAppsChanged: (() -> Void)?
  /// Coalesced (≤1/s) "catalogs changed" tick from the store — lossless,
  /// consumers re-read the store. Replaces the old per-plugin invalidation
  /// chain.
  var onCatalogsChanged: (() -> Void)? {
    get { catalogStore.onCatalogsChanged }
    set { catalogStore.onCatalogsChanged = newValue }
  }
  /// See `PluginHostRPC.onNormalModeTargetRequested`; forwarded so
  /// AppDelegate wiring stays on the manager.
  var onNormalModeTargetRequested: (() -> (pid: pid_t, bundleID: String, windowID: CGWindowID?)?)?
  {
    get { hostRPC.onNormalModeTargetRequested }
    set { hostRPC.onNormalModeTargetRequested = newValue }
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

  init(baseDataDir: URL = PluginRepository.defaultDataDir()) {
    self.baseDataDir = baseDataDir
    self.repository = PluginRepository(baseDataDir: baseDataDir)
  }

  /// The selector of every flashlight bang: the flashlight is one surface
  /// in every app, so a bang never depends on the focused app.
  private static let flashlightSelector = PluginSelectorStack()

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

  /// The plugins whose manifests listen to `name`, resolved once per name
  /// per published snapshot.
  private func listeners(for name: String) -> [PluginProcess] {
    hotSnapshotLock.lock()
    defer { hotSnapshotLock.unlock() }
    if let cached = listenersByEventName[name] { return cached }
    let listeners = hotSnapshot.plugins.filter { $0.listens(to: name) }
    if listenersByEventName.count < 256 { listenersByEventName[name] = listeners }
    return listeners
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
    var commandBindings = CommandBindingIndex()
    var commandConfirmations = CommandConfirmationIndex()
    var terminalEmulators: Set<String> = []
    var onDemandHintApps: Set<String> = []
    var ownTextEditingApps: Set<String> = []
    var helpTopics: [HelpTopic] = []
    var order = 0
    for plugin in plugins {
      let manifest = plugin.manifest
      let rootSelector = PluginSelectorStack([manifest.selector])
      eventPatterns.append(contentsOf: manifest.listen.map(PluginPattern.init))

      // Only the plugin's own commands register for dispatch and completion:
      // a core command it performs is a claim on the source chain.
      for registration in manifest.pluginCommands {
        let command = registration.command.lowercased()
        let subcommand = registration.subcommand.lowercased()
        let target = CommandTarget(plugin: plugin, selector: rootSelector)
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

      for registration in manifest.bangs {
        let token = registration.token.lowercased()
        guard !token.isEmpty else { continue }
        let target = ShebangTarget(
          plugin: plugin,
          description: registration.description,
          selector: Self.flashlightSelector,
          candidateSource: registration.source)
        if token == "*" {
          wildcardShebangs.append(target)
          continue
        }
        shebangCandidates.append(
          ShebangCandidateTarget(
            selector: Self.flashlightSelector,
            candidate: Candidate(
              kind: CandidateFinder.bangKind,
              sourceID: "bang:\(plugin.identifier)",
              source: "bang",
              title: "!\(registration.token)",
              subtitle: registration.description,
              sourcePayload: registration.token)))
        shebangIndex[token, default: []].append(target)
      }

      terminalEmulators.formUnion(manifest.terminalEmulators)
      onDemandHintApps.formUnion(manifest.onDemandHints)
      ownTextEditingApps.formUnion(manifest.ownTextEditing)

      commandBindings.add(manifest)
      commandConfirmations.add(manifest)

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
              + "is not a valid argv array (`flash <topic> <action> [--k=v]...` or an external "
              + "command)")
          continue
        }
        mappingIndex.append(
          ResolvedPluginMapping(
            selector: PluginSelectorStack([manifest.selector, registration.selector]),
            priority: registration.priority ?? manifest.priority,
            scope: registration.scope,
            mapping: ModeMapping(
              key: canonical, action: action,
              repeatsOnFinalKey: registration.repeatsOnFinalKey,
              origin: ModeMapping.pluginOrigin(id: manifest.id, name: manifest.name))))
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
            body: topic.body)
        })
    }

    let snapshot = HotSnapshot(
      sourceAdapters: sourceAdaptersByID.keys.sorted().compactMap { sourceAdaptersByID[$0] },
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
      commandBindings: commandBindings,
      commandConfirmations: commandConfirmations,
      helpTopics: helpTopics)
    // Declared before the snapshot is visible, so every selector resolved
    // against it already sees these apps as terminals.
    TerminalEmulators.declared.declare(terminalEmulators)
    OnDemandHintApps.declared.declare(onDemandHintApps)
    let ownTextEditingChanged = OwnTextEditingApps.declared.all != ownTextEditingApps
    OwnTextEditingApps.declared.declare(ownTextEditingApps)
    hotSnapshotLock.lock()
    hotSnapshot = snapshot
    listenersByEventName.removeAll(keepingCapacity: true)
    hotSnapshotLock.unlock()
    if ownTextEditingChanged {
      DispatchQueue.main.async { [weak self] in self?.onOwnTextEditingAppsChanged?() }
    }
  }

  private func isCurrentGeneration(_ generation: Int) -> Bool {
    desiredState.withLock { $0.isCurrent(generation) }
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
    desiredState.withLock { $0.stop() }
    catalogStore.onCatalogsChanged = nil
    let plugins = queue.sync { () -> [PluginProcess] in
      prewarmDeadline.cancel()
      let snapshot = Array(pluginsByID.values)
      pluginsByID.removeAll()
      sourceAdaptersByID.removeAll()
      loadFailureStatuses.removeAll()
      publishHotSnapshot()
      return snapshot
    }
    // The callbacks are read on each plugin's own queue and on main; they
    // are cleared only once the child that could still invoke them is gone.
    for plugin in plugins {
      plugin.stopAndWait(reason: "manager_stop")
      plugin.onStatusChanged = nil
      plugin.onHostRequest = nil
      plugin.runningApplicationsProvider = nil
    }
    catalogStore.removeAll()
  }

  func hasListener(for eventName: String) -> Bool {
    !listeners(for: eventName).isEmpty
  }

  func hasListener(for event: HostEvent) -> Bool {
    hasListener(for: event.rawValue)
  }

  private func runningApplicationsSnapshotValue() -> [[String: Any]] {
    runningApplicationsLock.lock()
    defer { runningApplicationsLock.unlock() }
    return latestRunningApplicationsSnapshot
  }

  /// Touched only on `eventQueue`.
  private var lastEmittedRunningApplicationsSignature: [String]?

  /// What identifies a running-apps list: each app's pid and bundle id.
  static func runningApplicationsSignature(_ applications: [[String: Any]]) -> [String] {
    applications.map { "\($0["pid"] as? Int ?? 0):\($0["bundle_id"] as? String ?? "")" }.sorted()
  }

  func cacheRunningApplicationsSnapshot(_ applications: [[String: Any]]) {
    runningApplicationsLock.lock()
    latestRunningApplicationsSnapshot = applications
    runningApplicationsLock.unlock()
  }

  /// Enumerating the running apps and encoding the full list is work for
  /// `eventQueue`, not the focus change on main that triggers it. The event
  /// fires only when the set of running apps changed: a focus change asks for
  /// it too, and resending an identical list made listeners re-walk every
  /// app on each Cmd-Tab.
  func emitRunningApplicationsChanged(snapshot: @escaping () -> [[String: Any]]) {
    eventQueue.async { [weak self] in
      guard let self else { return }
      let applications = snapshot()
      self.cacheRunningApplicationsSnapshot(applications)
      let signature = Self.runningApplicationsSignature(applications)
      guard signature != self.lastEmittedRunningApplicationsSignature else { return }
      self.lastEmittedRunningApplicationsSignature = signature
      self.emitOnEventQueue(.appsChanged(applications))
    }
  }

  func updateConfig(_ config: Config) {
    reconcile(.configure(config))
  }

  /// Restart `ids` under the configuration in effect, read with the request
  /// under one lock: a reconcile taken between a caller's snapshot and its
  /// request cannot drop the request, and a stopped manager drops it on
  /// purpose, having no configuration.
  private func requestRestarts(_ ids: Set<String>) {
    reconcile(.restart(ids))
  }

  private func reconcile(_ request: DesiredState.Request) {
    guard let reconciliation = desiredState.withLock({ $0.request(request) }) else { return }
    let config = reconciliation.config
    let generation = reconciliation.generation
    // Network materialization never occupies the manager or input queues.
    // Pending restart IDs survive superseded reloads, so simultaneous binary
    // changes cannot silently lose all but the final plugin's restart.
    materializeQueue.async { [weak self] in
      guard let self, self.isCurrentGeneration(generation) else { return }
      var thirdParty: [(root: URL, origin: PluginOrigin)] = []
      for ref in config.plugins.thirdParty {
        if let materialized = self.repository.materialize(ref) { thirdParty.append(materialized) }
      }
      self.queue.async {
        guard let restartIDs = self.desiredState.withLock({ $0.takeRestarts(for: generation) })
        else { return }
        self.reloadDesiredPlugins(config: config, thirdParty: thirdParty, restartIDs: restartIDs)
      }
    }
  }

  /// A desktop widget became visible or fully covered. A covered widget stops
  /// observing its plugins' segments after `hiddenWidgetGraceMs`; one shown
  /// again observes them at once.
  func setWidgetVisible(name: String, _ visible: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      self.pendingHides.removeValue(forKey: name)?.cancel()
      guard !visible else {
        if self.hiddenWidgets.remove(name) != nil { self.applyObservedStatus() }
        return
      }
      let grace = PollDeadline(
        "core:widget_hidden:\(name)", priority: .low, on: self.queue)
      self.pendingHides[name] = grace
      grace.arm(afterMs: Self.hiddenWidgetGraceMs) { [weak self] in
        guard let self else { return }
        self.pendingHides[name] = nil
        if self.hiddenWidgets.insert(name).inserted { self.applyObservedStatus() }
      }
    }
  }

  /// Re-derive which segments the running plugins' surfaces show, without
  /// reloading any plugin.
  private func applyObservedStatus() {
    guard let config = desiredState.withLock({ $0.config }) else { return }
    let observed = config.observedStatusSegments(hiddenWidgets: hiddenWidgets)
    for (id, plugin) in pluginsByID {
      // The segments first, as on reload: a plugin that becomes observed
      // spawns now and must hear the new set after its initialize.
      plugin.setObservedStatusSegments(observed[id] ?? [])
      plugin.setStatusObserved(observed[id] != nil)
    }
  }

  private func reloadDefinition(_ plugin: PluginProcess) {
    queue.async { [weak self, weak plugin] in
      guard let self, let plugin, self.pluginsByID[plugin.identifier] === plugin else { return }
      self.requestRestarts([plugin.identifier])
    }
  }

  /// Events leave the caller at once: with no listener nothing happens, and
  /// otherwise encoding (a full running-app list, clipboard text) and fan-out
  /// run on `eventQueue`, whose serial order keeps delivery in emit order.
  func emit(_ event: PluginEvent) {
    guard hasListener(for: event.name) else { return }
    eventQueue.async { [weak self] in self?.emitOnEventQueue(event) }
  }

  /// sendEvent filters by listen pattern and hops to each plugin's own queue.
  /// The frame is identical for every listener, so it is encoded once here.
  private func emitOnEventQueue(_ event: PluginEvent) {
    let listeners = listeners(for: event.name)
    guard !listeners.isEmpty else { return }
    var event = event
    event.encodedFrame = PluginProcess.encodedEventFrame(event)
    event.coalescingKey = PluginProcess.coalescingKey(event)
    for plugin in listeners {
      plugin.sendEvent(event)
    }
  }

  private let eventQueue = DispatchQueue(label: "flash.plugins.events", qos: .userInitiated)

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
      // The registration matched case-insensitively; the plugin gets the
      // name it registered, not the typed case (`:tmux Session`).
      resolved = (target, key.subcommand, args)
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
      command: lcCommand,
      subcommand: resolved.subcommand,
      args: resolved.args,
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
    onResult: ((Bool, pid_t?, String?, URL?) -> Void)?
  ) {
    plugin.perform(
      kind: "command",
      params: [
        "command": command,
        "subcommand": subcommand,
        "args": args,
      ]
    ) { outcome in
      switch outcome {
      case .performed(let pid, let navigationURL, let message):
        FlashLog.debug(
          "[plugin] command=\(command) subcommand=\(subcommand) ok=true "
            + "target_pid=\(pid.map(String.init) ?? "nil") "
            + "navigation_scheme=\(navigationURL?.scheme ?? "nil")")
        onResult?(true, pid, message, navigationURL)
      case .unhandled:
        FlashLog.debug(
          "[plugin] command=\(command) subcommand=\(subcommand) unhandled")
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
  /// is the remainder after the bang; it is forwarded as whitespace-split
  /// `args`, with the plugin id as the command and the bang itself as the
  /// subcommand. The plugin runs asynchronously;
  /// `onResult` mirrors ``invoke(command:…)``.
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
      command: target.plugin.identifier,
      subcommand: token,
      args: args,
      onResult: onResult)
    return true
  }

  /// True when a loaded plugin declares `token` by name for this context,
  /// the `*` catch-all aside: such a bang keeps its owner over a user's.
  func declaresShebang(
    token: String, in context: PluginSelectorContext = PluginSelectorContext()
  ) -> Bool {
    Self.bestTarget(
      readHotSnapshot().shebangIndex[token.lowercased()] ?? [], in: context,
      specificity: { $0.specificity(in: $1) }) != nil
  }

  /// The candidate source declared by the bang registration matching `token`.
  /// Plugins that bind a bang to a source (e.g. `!fh` → `firefox.history`)
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
  ///     listed in every app (a bang never depends on the focused app). Used
  ///     by plugins with a small fixed set of bangs.
  ///   * **Published dynamic bangs** — kind="bang" rows the plugin keeps in
  ///     its pushed catalog (searchproviders: its DuckDuckGo and Kagi bang
  ///     rows). Those are *not* returned here; they
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

  /// What the focused app does for the command `key` names when no source
  /// performs it there (manifest `bindings`), or nil when no plugin binds it.
  func commandBinding(
    _ key: CommandBindingKey, index: Int? = nil, in context: PluginSelectorContext
  ) -> CommandBinding? {
    readHotSnapshot().commandBindings.binding(key, index: index, in: context)
  }

  /// The question an applicable plugin asks before `name` in the focused app
  /// (`confirm` on its `commands[]` entry), or nil when none gates it.
  func commandConfirmation(_ name: CommandName, in context: PluginSelectorContext) -> String? {
    readHotSnapshot().commandConfirmations.prompt(for: name, in: context)
  }

  /// Every command a plugin binds in the focused app, with its winner.
  func commandBindingResolutions(
    in context: PluginSelectorContext
  ) -> [(CommandBindingKey, CommandBindingIndex.Resolution)] {
    readHotSnapshot().commandBindings.resolutions(in: context)
  }

  /// Whether some plugin binds `chord` for the focused app itself: the app
  /// runs it as a shortcut, so synthesizing it never types text.
  func declaresBinding(
    key: CGKeyCode, flags: CGEventFlags, in context: PluginSelectorContext
  ) -> Bool {
    readHotSnapshot().commandBindings.declares(key: key, flags: flags, in: context)
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
  /// Plugin id → the status names each loaded plugin's manifest declares.
  func declaredStatusSegments() -> [String: Set<String>] {
    Dictionary(
      readHotSnapshot().plugins.map { ($0.manifest.id, Set($0.manifest.status)) },
      uniquingKeysWith: { $0.union($1) })
  }

  func statusBarInfos() -> [PluginStatusBarInfo] {
    let snapshot = readHotSnapshot()
    // statusBarInfo() reads each process's own lock — no manager queue hop.
    return snapshot.plugins.map { $0.statusBarInfo() }
      + snapshot.loadFailureStatuses.map {
        PluginStatusBarInfo(id: $0.id, state: $0.state, hasError: true, statusSegments: [:])
      }
  }

  private func reloadDesiredPlugins(
    config: Config, thirdParty: [(root: URL, origin: PluginOrigin)], restartIDs: Set<String> = []
  ) {
    var desired: [(root: URL, origin: PluginOrigin)] = PluginRepository.officialPluginRoots().map {
      ($0, .official)
    }
    desired.append(contentsOf: thirdParty)

    loadFailureStatuses.removeAll()
    var nextIDs = Set<String>()
    // Replacements are installed and published first, started and their
    // predecessors stopped second: dispatch then reaches the replacement
    // for the whole stop, which can take a child's full escalation.
    var replacements: [Replacement] = []
    // Only configured widgets can be covered; a removed one forgets it.
    let enabledWidgets = Set(config.enabledWidgets.keys)
    hiddenWidgets.formIntersection(enabledWidgets)
    for name in pendingHides.keys where !enabledWidgets.contains(name) {
      pendingHides.removeValue(forKey: name)?.cancel()
    }
    let observedStatus = config.observedStatusSegments(hiddenWidgets: hiddenWidgets)
    var claimManifests: [PluginManifest] = []
    var claimIDs = Set<String>()
    for item in desired {
      guard let manifest = try? PluginManifest.load(from: item.root),
        !config.plugins.disabled.contains(manifest.id),
        claimIDs.insert(manifest.id).inserted
      else { continue }
      claimManifests.append(manifest)
    }
    let claimFailures = PluginManifest.commandClaimFailures(claimManifests)
    let typeFailures = ResourceTypes.claimFailures(claimManifests)
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
        if let reason = claimFailures[manifest.id] {
          throw PluginError.commandConflict(reason)
        }
        if let reason = typeFailures[manifest.id] {
          throw PluginError.failure(reason)
        }
        nextIDs.insert(manifest.id)
        let settings = config.plugins.settings[manifest.id] ?? [:]
        let observedSegments = observedStatus[manifest.id]
        let statusObserved = observedSegments != nil
        let existing = pluginsByID[manifest.id]
        if existing?.root == item.root, existing?.manifest == manifest,
          existing?.settings == settings, existing?.watchesFiles == config.plugins.watchingEnabled
        {
          // The segments first: a status-bound plugin that becomes observed
          // spawns now and must hear the new set after its initialize.
          existing?.setObservedStatusSegments(observedSegments ?? [])
          existing?.setStatusObserved(statusObserved)
          if restartIDs.contains(manifest.id) { existing?.reload(reason: "definition_reload") }
          continue
        }
        let plugin = PluginProcess(
          root: item.root,
          manifest: manifest,
          origin: item.origin,
          baseDataDir: baseDataDir,
          watchFiles: config.plugins.watchingEnabled,
          settings: settings,
          statusObserved: statusObserved,
          observedStatusSegments: observedSegments ?? [])
        plugin.catalogStore = catalogStore
        plugin.runningApplicationsProvider = { [weak self] in
          self?.runningApplicationsSnapshotValue() ?? []
        }
        plugin.onStatusChanged = { [weak self] in
          self?.notifyStateChanged()
        }
        plugin.onFilesChanged = { [weak self, weak plugin] in
          guard let plugin else { return }
          self?.reloadDefinition(plugin)
        }
        // Capture immutable authorization with the process. A host RPC arrives
        // on PluginProcess.queue; consulting PluginManager.queue synchronously
        // from there would invert the reload path
        // (manager queue -> stopAndWait -> process queue) and can deadlock.
        let capabilities = manifest.capabilities
        let fetchURLs = manifest.fetchURLs
        let appleEventsTargets = manifest.appleEventsTargets
        plugin.onHostRequest = { [weak self] method, params, pluginID, scope, reply in
          self?.hostRPC.handleHostRequest(
            method: method,
            params: params,
            pluginID: pluginID,
            capabilities: capabilities,
            fetchURLs: fetchURLs,
            appleEventsTargets: appleEventsTargets,
            scope: scope,
            reply: reply)
        }
        pluginsByID[manifest.id] = plugin
        sourceAdaptersByID[manifest.id] = PluginFlashSource(plugin: plugin, store: catalogStore)
        replacements.append(
          Replacement(
            previous: existing,
            dropsCatalog: existing.map { $0.manifest != manifest || $0.root != item.root }
              ?? false,
            plugin: plugin))
      } catch {
        // A command-name conflict must take the plugin down. A malformed edit
        // of a plugin that was already valid keeps that process until fixed.
        let claimConflict = (error as? PluginError)?.isCommandConflict == true
        if !claimConflict,
          let existing = pluginsByID.values.first(where: { $0.root == item.root }),
          !config.plugins.disabled.contains(existing.identifier)
        {
          // A malformed edit is not a new definition. Keep the validated
          // process, its authorization and catalog together until corrected.
          nextIDs.insert(existing.identifier)
          existing.reportDefinitionError(String(describing: error))
          continue
        }
        FlashLog.error(
          "[plugins] failed to load \(item.root.path): \(error)",
          fields: [
            "root": item.root.path,
            "origin": String(describing: item.origin),
            "error": String(describing: error),
          ])
        // A manifest typo must show up in `:plugins show` and the inspector as a
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
            startedAtUnixMs: nil,
            sourceCount: 0,
            commandCount: 0,
            restartCount: 0,
            lastError: String(describing: error),
            lastLog: nil,
            cpuTimeMs: nil,
            memoryBytes: nil,
            onlyBundleIDs: [],
            priority: 0,
            commands: [],
            statusSegments: [:]))
      }
    }

    var removed: [PluginProcess] = []
    for id in Array(pluginsByID.keys) where !nextIDs.contains(id) {
      if let plugin = pluginsByID.removeValue(forKey: id) { removed.append(plugin) }
      sourceAdaptersByID.removeValue(forKey: id)
    }
    // From here every request resolves to the replacement, which queues it
    // until its child runs; the old child was never going to answer it.
    publishHotSnapshot()
    let warmIDs = PluginWarmPolicy.warmPluginIDs(
      references: PluginWarmPolicy.commandReferences(
        PluginWarmPolicy.configuredActions(config)
          + readHotSnapshot().mappingIndex.map(\.mapping.action)),
      commands: pluginsByID.mapValues(\.manifest.pluginCommands))
    for (id, plugin) in pluginsByID { plugin.setWarm(warmIDs.contains(id)) }
    for replacement in replacements {
      replacement.previous?.stopAndWait(reason: "config_reload")
      if replacement.dropsCatalog, let previous = replacement.previous {
        catalogStore.drop(pluginID: previous.identifier)
      }
      replacement.plugin.start()
    }
    for plugin in removed {
      plugin.stopAndWait(reason: "config_removed")
      // Unload drops the published catalog — the rows' owner is gone.
      catalogStore.drop(pluginID: plugin.identifier)
    }
    // Replacements and reloaded definitions start idle when on demand, and a
    // changed mapping may have warmed a plugin; the newest set is warmed
    // once this reconcile's spawns have settled.
    prewarmDeadline.arm(afterMs: Self.prewarmDelayMs) { [weak self] in
      guard let self else { return }
      for plugin in self.pluginsByID.values.sorted(by: { $0.identifier < $1.identifier }) {
        plugin.prewarm()
      }
    }
    notifyStateChanged()
  }

  /// A definition reconciled this pass: the process it replaces, if any,
  /// whether that one's catalog goes with it, and the one to start.
  private struct Replacement {
    let previous: PluginProcess?
    let dropsCatalog: Bool
    let plugin: PluginProcess
  }

  /// Stop every loaded plugin and restart it. Triggered by
  /// `:plugins reload`. Returns the IDs being restarted so callers can
  /// include them in a confirmation alert; the restarts themselves run
  /// asynchronously off the snapshot — the main thread never waits on the
  /// manager queue.
  @discardableResult
  func reloadAll() -> [String] {
    let ids = readHotSnapshot().plugins.map(\.identifier)
    requestRestarts(Set(ids))
    return ids
  }

  private func notifyStateChanged() {
    DispatchQueue.main.async { [weak self] in
      self?.onStateChanged?()
    }
  }
}

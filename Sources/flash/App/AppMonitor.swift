import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import os

/// Coordinates discovery + hint assignment for the focused app.
///
/// Two latency regimes coexist:
///
/// **Cold (no prepared model):** `discoverAsync` dispatches the same
/// complete walk the background model builder uses and hops the result
/// back to main. The walk is parallelised inside `AccessibilityProvider`
/// at the focused window's direct-child boundary.
///
/// **Warm (prepared model hit):** an AX-event-driven model build has
/// already completed for the focused pid and its result is still valid
/// (no observed event fired since the walk started, config revision
/// still matches, and age < `modelFreshnessMs`). Activation skips the
/// AX walk entirely and serves the prepared hints.
///
/// **Invalidation contract (the previous cache attempt got this wrong):**
///   - Every observed AX event (focus/layout/scroll/value/window) on the
///     focused app bumps `dirtyTokens[pid]`.
///   - Workspace focus change bumps the new pid's token (any prepared
///     entry from before the switch is now stale).
///   - A walk captures `startToken = dirtyTokens[pid]` before starting.
///   - On completion, the prepared model is written ONLY if
///     `dirtyTokens[pid] == startToken` (no events during the walk) AND
///     the pid is still frontmost.
///   - Model reads serve a hit ONLY if token, config revision, and
///     freshness all match.
///
/// The result is deterministic: two activations in the same UI state
/// always serve the same hint set. No partial model, no stale model.
final class AppMonitor {
  private let registry: ProviderRegistry

  private let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)

  // MARK: Config (shared between main + axQueue)
  //
  // Cheap lock — held only for the duration of a struct copy. AppDelegate
  // writes via `updateConfig` when the user edits config.toml; axQueue
  // reads via `snapshotConfig` at the start of each walk.

  private var config: Config
  private var configLock = os_unfair_lock_s()
  private var configRevision: UInt64 = 0

  private func snapshotConfig() -> Config {
    os_unfair_lock_lock(&configLock)
    defer { os_unfair_lock_unlock(&configLock) }
    return config
  }

  /// Called by the AppDelegate config file-watcher whenever
  /// ~/.config/flash/config.toml changes. Atomically swaps the shared
  /// config, then invalidates the prepared model on main so labels and
  /// provider debug settings refresh together.
  func updateConfig(_ cfg: Config) {
    os_unfair_lock_lock(&configLock)
    config = cfg
    os_unfair_lock_unlock(&configLock)

    let bump = { [weak self] in
      guard let self else { return }
      self.configRevision &+= 1
      guard let app = NSWorkspace.shared.frontmostApplication else { return }
      let pid = app.processIdentifier
      guard pid > 0 else { return }
      self.invalidatePreparedModel(for: pid)
      self.scheduleModelRefresh(for: pid, reason: "config")
    }
    if Thread.isMainThread {
      bump()
    } else {
      DispatchQueue.main.async { bump() }
    }
  }

  /// Hard ceiling on how long a prepared model is served before falling
  /// back to a fresh walk. Belt-and-suspenders against AX events the
  /// observer set missed (some apps don't fire `kAXLayoutChanged` on
  /// every UI transition).
  private static let modelFreshnessMs: Int = 1500
  private static let modelDebounceMs: Int = 80
  private static let modelMaintenanceLeadMs: Int = 250

  init(registry: ProviderRegistry, config: Config) {
    self.registry = registry
    self.config = config
  }

  // MARK: Prepared model state
  //
  // Every field below is touched only from the main thread. Walk results
  // arrive on `axQueue` and are hopped back to main before they update
  // any of these.

  private var preparedModels = PreparedModelStore()
  private var dirtyTokens: [pid_t: UInt64] = [:]
  private var observers: [pid_t: ObserverEntry] = [:]
  private var modelDebounce: [pid_t: DispatchWorkItem] = [:]
  private var maintenanceRefresh: [pid_t: DispatchWorkItem] = [:]
  private var pendingModelCompletions: [pid_t: [(PreparedModel?) -> Void]] = [:]
  private var workspaceObservers: [NSObjectProtocol] = []
  private var localObservers: [NSObjectProtocol] = []

  private struct ObserverEntry {
    let observer: AXObserver
    let appElement: AXUIElement
    let context: ObserverContext
  }

  /// The `refcon` blob passed to the C AXObserver callback. Held alive
  /// by `observers[pid]` so it stays valid for the observer's lifetime.
  private final class ObserverContext {
    weak var monitor: AppMonitor?
    let pid: pid_t
    init(monitor: AppMonitor, pid: pid_t) {
      self.monitor = monitor
      self.pid = pid
    }
  }

  private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let ctx = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    guard let monitor = ctx.monitor else { return }
    let pid = ctx.pid
    // AXObserver callbacks already run on the run loop that holds the
    // source — we add it to the main run loop below, so we're already
    // on main here. Hop anyway to make the invariant explicit and
    // bullet-proof against future relocation of the source.
    if Thread.isMainThread {
      monitor.onAXEvent(pid: pid)
    } else {
      DispatchQueue.main.async { monitor.onAXEvent(pid: pid) }
    }
  }

  /// AX notifications we subscribe to per focused app. Any one of these
  /// invalidates the prepared model (bumps `dirtyTokens[pid]`) and schedules a
  /// debounced rebuild. The set is intentionally generous — false
  /// positives only cost an 80-ms-debounced background walk, while
  /// false negatives serve stale hints.
  private static let observedNotifications: [String] = [
    kAXFocusedUIElementChangedNotification,
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXLayoutChangedNotification,
    kAXSelectedChildrenChangedNotification,
    kAXSelectedRowsChangedNotification,
    kAXValueChangedNotification,
    kAXWindowResizedNotification,
    kAXWindowMovedNotification,
    kAXTitleChangedNotification,
    kAXCreatedNotification,
    kAXUIElementDestroyedNotification,
    kAXRowExpandedNotification,
    kAXRowCollapsedNotification,
  ]

  // MARK: Lifecycle

  func start() {
    installWorkspaceObservers()
    wakeChromiumAccessibilityForAllRunningApps()
    if let app = NSWorkspace.shared.frontmostApplication {
      onFocusedAppChanged(to: app)
    }
  }

  // MARK: Chromium AX wake
  //
  // Chrome and other Chromium-based browsers ship their accessibility
  // engine OFF by default and only enable it when an assistive
  // technology asks for it (the cost is real — Chromium documents
  // a perceptible CPU/memory hit when full a11y is on). Setting
  // `AXEnhancedUserInterface = true` or `AXManualAccessibility = true`
  // on the app element is the public signal Chromium watches for.
  //
  // Waking lazily at first walk doesn't help: Chrome's a11y tree is
  // built asynchronously after the attribute is set, so the first
  // discover() sees an empty tree. Setting these attributes
  // proactively (at Flash startup for already-running Chromium apps,
  // and on `didLaunchApplicationNotification` for new ones) gives the
  // tree time to populate before the user ever triggers Flash.
  //
  // Belt-and-suspenders: `AccessibilityProvider.discover` still sets
  // the same attributes on every walk so a Chromium variant we
  // didn't recognise here still wakes the first time the user
  // triggers Flash on it.
  static let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext",
    "com.operasoftware.OperaDeveloper",
  ]

  private func wakeChromiumAccessibilityForAllRunningApps() {
    for app in NSWorkspace.shared.runningApplications {
      maybeWakeChromiumAccessibility(for: app)
    }
  }

  private func maybeWakeChromiumAccessibility(for app: NSRunningApplication) {
    guard let bid = app.bundleIdentifier, Self.chromiumBundleIDs.contains(bid) else { return }
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    // Dispatch to axQueue so the AX IPC doesn't block the main thread —
    // Chromium can take tens of ms to ack the attribute write under load.
    axQueue.async {
      let appEl = AXUIElementCreateApplication(pid)
      let trueRef = kCFBooleanTrue as CFTypeRef
      _ = AXUIElementSetAttributeValue(
        appEl, "AXEnhancedUserInterface" as CFString, trueRef)
      _ = AXUIElementSetAttributeValue(
        appEl, "AXManualAccessibility" as CFString, trueRef)
    }
  }

  func stop() {
    teardownAllObservers()
    preparedModels.removeAll()
    cancelAllRefreshWork()
    for token in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    workspaceObservers.removeAll()
    for token in localObservers {
      NotificationCenter.default.removeObserver(token)
    }
    localObservers.removeAll()
  }

  private func installWorkspaceObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    let activate = nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else { return }
      // Skip Flash itself — its overlay panel becoming key fires a
      // workspace activation we don't want to chase.
      if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
      self.onFocusedAppChanged(to: app)
    }
    let terminate = nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.onAppTerminated(pid: app.processIdentifier)
      }
    }
    let launch = nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.maybeWakeChromiumAccessibility(for: app)
      }
    }
    let activeSpace = nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.onFocusedEnvironmentChanged(reason: "space")
    }
    workspaceObservers = [activate, terminate, launch, activeSpace]

    let screen = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.onFocusedEnvironmentChanged(reason: "screen")
    }
    localObservers = [screen]
  }

  private func onFocusedAppChanged(to app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    // Bump this pid's dirty token — any prepared model from before the
    // focus came back is now suspect (the app may have repainted, the
    // window may have moved). Discarding via token bump is cheaper than
    // re-resolving the bundle frame here.
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    if observers[pid] == nil {
      installObserver(for: pid)
    }
    scheduleModelRefresh(for: pid, reason: "focus")
  }

  private func onAppTerminated(pid: pid_t) {
    teardownObserver(for: pid)
    preparedModels.remove(pid: pid)
    dirtyTokens.removeValue(forKey: pid)
    cancelRefreshWork(for: pid)
  }

  func onAXEvent(pid: pid_t) {
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    scheduleModelRefresh(for: pid, reason: "ax")
  }

  private func onFocusedEnvironmentChanged(reason: String) {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    scheduleModelRefresh(for: pid, reason: reason)
  }

  // MARK: AX observer install / teardown

  private func installObserver(for pid: pid_t) {
    // Without Accessibility permission, AXObserverAddNotification
    // silently fails — no callbacks ever fire and the model silently
    // serves stale hints because dirty tokens never bump. Skip install
    // entirely; we'll retry on the next focus change, by which time
    // the user has likely granted permission.
    if !PermissionCheck.isAccessibilityTrusted { return }
    var observer: AXObserver?
    let err = AXObserverCreate(pid, Self.observerCallback, &observer)
    guard err == .success, let observer else { return }

    let appEl = AXUIElementCreateApplication(pid)
    let ctx = ObserverContext(monitor: self, pid: pid)
    let refcon = Unmanaged.passUnretained(ctx).toOpaque()

    for n in Self.observedNotifications {
      _ = AXObserverAddNotification(observer, appEl, n as CFString, refcon)
    }

    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )

    observers[pid] = ObserverEntry(observer: observer, appElement: appEl, context: ctx)
  }

  private func teardownObserver(for pid: pid_t) {
    guard let entry = observers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(entry.observer),
      .commonModes
    )
    for n in Self.observedNotifications {
      _ = AXObserverRemoveNotification(entry.observer, entry.appElement, n as CFString)
    }
  }

  private func teardownAllObservers() {
    for pid in Array(observers.keys) {
      teardownObserver(for: pid)
    }
  }

  // MARK: Prepared model scheduling

  private func invalidatePreparedModel(for pid: pid_t) {
    preparedModels.discardModel(pid: pid)
    maintenanceRefresh[pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: pid)
  }

  private func cancelRefreshWork(for pid: pid_t) {
    modelDebounce[pid]?.cancel()
    modelDebounce.removeValue(forKey: pid)
    maintenanceRefresh[pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: pid)
    pendingModelCompletions.removeValue(forKey: pid)
  }

  private func cancelAllRefreshWork() {
    for work in modelDebounce.values { work.cancel() }
    modelDebounce.removeAll()
    for work in maintenanceRefresh.values { work.cancel() }
    maintenanceRefresh.removeAll()
    pendingModelCompletions.removeAll()
  }

  /// Debounced model refresh. Multiple events arriving within 80 ms
  /// coalesce into a single background walk. The deadline pushes back
  /// on every fresh event, so a steady stream (e.g. scrolling) stays
  /// quiet until it settles.
  private func scheduleModelRefresh(for pid: pid_t, reason: String) {
    modelDebounce[pid]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.runModelRefresh(pid: pid, reason: reason, profiler: nil, completion: nil)
    }
    modelDebounce[pid] = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.modelDebounceMs),
      execute: work)
  }

  private func scheduleMaintenanceRefresh(for model: PreparedModel) {
    maintenanceRefresh[model.pid]?.cancel()
    let delayMs = max(0, Self.modelFreshnessMs - Self.modelMaintenanceLeadMs)
    let token = model.dirtyToken
    let revision = model.configRevision
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let currentToken = self.dirtyTokens[model.pid] ?? 0
      guard currentToken == token, self.configRevision == revision else { return }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == model.pid else { return }
      self.runModelRefresh(pid: model.pid, reason: "maintenance", profiler: nil, completion: nil)
    }
    maintenanceRefresh[model.pid] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
  }

  private func runModelRefresh(
    pid: pid_t,
    reason: String,
    profiler: FlashProfiler?,
    completion: ((PreparedModel?) -> Void)?
  ) {
    modelDebounce[pid]?.cancel()
    modelDebounce.removeValue(forKey: pid)

    guard PermissionCheck.isAccessibilityTrusted else {
      completion?(nil)
      return
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
      completion?(nil)
      return
    }
    // Only prepare the front app. Background-app walks would compete
    // with the user's active app for AX IPC bandwidth and produce hints
    // that'd never be served.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      completion?(nil)
      return
    }
    let startToken = dirtyTokens[pid] ?? 0
    let revision = configRevision
    let cfg = snapshotConfig()
    guard let context = makeContext(for: app) else {
      completion?(nil)
      return
    }
    if anyVolatileProviderApplies(to: context) {
      completion?(nil)
      return
    }
    let providers = continuousProviders(for: context)
    guard !providers.isEmpty else {
      completion?(nil)
      return
    }
    guard preparedModels.beginRebuild(pid: pid) else {
      if let completion {
        pendingModelCompletions[pid, default: []].append(completion)
      }
      return
    }

    let enqueueNs = profiler?.intervalStart()
    axQueue.async { [weak self] in
      guard let self else { return }
      if let enqueueNs {
        self.finishQueueWait(profiler, since: enqueueNs)
      }
      profiler?.mark(
        "model_build_start", detail: "token=\(startToken) reason=\(reason)")
      let built = self.buildPreparedModel(
        context: context,
        providers: providers,
        cfg: cfg,
        dirtyToken: startToken,
        configRevision: revision,
        profiler: profiler)
      profiler?.mark("model_build_done", detail: "hints=\(built.hints.count)")
      DispatchQueue.main.async {
        let shouldRunQueued = self.preparedModels.finishRebuild(pid: pid)
        let waiters = self.pendingModelCompletions.removeValue(forKey: pid) ?? []
        defer {
          if shouldRunQueued {
            self.scheduleModelRefresh(for: pid, reason: "queued")
          }
        }

        let tokenStillMatches = (self.dirtyTokens[pid] ?? 0) == startToken
        let revisionStillMatches = self.configRevision == revision
        let stillFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if tokenStillMatches, revisionStillMatches, stillFocused {
          self.preparedModels.store(built)
          self.scheduleMaintenanceRefresh(for: built)
          if cfg.debug.profile {
            FlashLog.write(
              "flash: model_ready pid=\(pid) bundle=\(context.bundleIdentifier) hints=\(built.hints.count) token=\(startToken) reason=\(reason)\n"
            )
          }
        }
        let validModel = tokenStillMatches && revisionStillMatches && stillFocused ? built : nil
        completion?(validModel)
        for waiter in waiters {
          waiter(validModel)
        }
      }
    }
  }

  private func lookupPreparedModel(for pid: pid_t) -> PreparedModel? {
    preparedModels.lookup(
      pid: pid,
      dirtyToken: dirtyTokens[pid] ?? 0,
      configRevision: configRevision,
      now: DispatchTime.now(),
      freshnessMs: Self.modelFreshnessMs)
  }

  func currentContext() -> AppContext? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return makeContext(for: app)
  }

  // MARK: Discovery

  /// Activation hot path. Tries the prepared AX model first. Volatile
  /// providers (tmux) bypass the model entirely.
  func discoverAsync(
    context: AppContext,
    profiler: FlashProfiler? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let pid = context.processID
    if observers[pid] == nil {
      installObserver(for: pid)
    }

    if anyVolatileProviderApplies(to: context) {
      runActivationDiscovery(context: context, profiler: profiler, completion: completion)
      return
    }

    if let model = lookupPreparedModel(for: pid) {
      let ageMs =
        Double(DispatchTime.now().uptimeNanoseconds - model.computedAt.uptimeNanoseconds)
        / 1_000_000
      profiler?.mark(
        "model_hit",
        detail:
          "hints=\(model.hints.count) age_ms=\(String(format: "%.1f", ageMs)) token=\(model.dirtyToken)"
      )
      completion(model.hints)
      return
    }

    profiler?.mark("model_miss", detail: "pid=\(pid)")
    runModelRefresh(
      pid: pid,
      reason: "activation",
      profiler: profiler
    ) { [weak self] model in
      guard let self else { return }
      if let model {
        completion(model.hints)
      } else {
        self.runActivationDiscovery(context: context, profiler: profiler, completion: completion)
      }
    }
  }

  /// True iff any registered provider both (a) declares its results
  /// volatile and (b) supports the given context. Called on the
  /// activation hot path AND the model-builder path; keep volatile
  /// providers' `supports` cheap.
  private func anyVolatileProviderApplies(to context: AppContext) -> Bool {
    for p in registry.providers where p.readinessPolicy == .volatile || p.resultsAreVolatile {
      if p.supports(context) { return true }
    }
    return false
  }

  private func continuousProviders(for context: AppContext) -> [JumpProvider] {
    registry.chain(for: context).filter { $0.readinessPolicy == .continuous }
  }

  private func finishQueueWait(_ profiler: FlashProfiler?, since start: UInt64) {
    profiler?.finishInterval("ax_queue_wait", since: start)
  }

  private struct DiscoveryResult {
    let targets: [JumpTarget]
    let hints: [AssignedHint]
  }

  private func buildPreparedModel(
    context: AppContext,
    providers: [JumpProvider],
    cfg: Config,
    dirtyToken: UInt64,
    configRevision: UInt64,
    profiler: FlashProfiler?
  ) -> PreparedModel {
    let result = runAndAssign(
      context: context,
      cfg: cfg,
      providers: providers,
      profiler: profiler)
    return PreparedModel(
      pid: context.processID,
      bundleID: context.bundleIdentifier,
      targets: result.targets,
      hints: result.hints,
      computedAt: DispatchTime.now(),
      dirtyToken: dirtyToken,
      configRevision: configRevision)
  }

  private func runActivationDiscovery(
    context: AppContext,
    profiler: FlashProfiler?,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let cfg = snapshotConfig()
    let providers = registry.chain(for: context)
    let enqueueNs = profiler?.intervalStart()
    axQueue.async { [weak self] in
      guard let self else { return }
      if let enqueueNs {
        self.finishQueueWait(profiler, since: enqueueNs)
      }
      profiler?.mark(
        "walk_start", detail: "providers=\(providers.map(\.identifier).joined(separator: ","))")
      let result = self.runAndAssign(
        context: context,
        cfg: cfg,
        providers: providers,
        profiler: profiler)
      profiler?.mark("walk_done", detail: "hints=\(result.hints.count)")
      DispatchQueue.main.async {
        completion(result.hints)
      }
    }
  }

  private func runAndAssign(
    context: AppContext,
    cfg: Config,
    providers: [JumpProvider],
    profiler: FlashProfiler? = nil
  ) -> DiscoveryResult {
    let walkStart = profiler?.intervalStart()
    configureProviders(for: cfg, triggerMs: profiler?.triggerMs)
    let collected = collectFocusedTargets(
      context: context,
      providers: providers,
      profiler: profiler)
    let targets = finalizeTargets(collected, profiler: profiler)
    if let walkStart {
      profiler?.finishInterval("walk_all", since: walkStart, detail: "targets=\(targets.count)")
    }
    let hints = assignTargets(targets, cfg: cfg, profiler: profiler)
    return DiscoveryResult(targets: targets, hints: hints)
  }

  private func assignTargets(
    _ targets: [JumpTarget],
    cfg: Config,
    profiler: FlashProfiler?
  ) -> [AssignedHint] {
    let resolved = Alphabet.resolve(cfg.hints.keys)
    let assignStart = profiler?.intervalStart()
    let hints = HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      minLength: cfg.hints.minLength
    )
    if let assignStart {
      profiler?.finishInterval(
        "assign_hints", since: assignStart, detail: "targets=\(targets.count) hints=\(hints.count)")
    }
    return hints
  }

  // MARK: Discovery
  //
  // Firehose mode: no visibility filter, no dedup. Every JumpTarget that
  // a provider returns is forwarded. Off-screen elements (scrolled-off
  // rows, occluded controls) are still emitted as hints — they just
  // won't be visually reachable. Intended for diagnosing what AX exposes,
  // not for daily use.
  private func collectFocusedTargets(
    context focused: AppContext,
    providers: [JumpProvider],
    profiler: FlashProfiler? = nil
  ) -> [JumpTarget] {
    var collected: [JumpTarget] = []
    collected.reserveCapacity(256)
    for provider in providers {
      let providerStart = profiler?.intervalStart()
      let results =
        (try? provider.discover(in: focused, deadline: .distantFuture)) ?? []
      collected.append(contentsOf: results)
      if let providerStart {
        profiler?.finishInterval(
          "provider.\(provider.identifier)",
          since: providerStart,
          detail: "raw=\(results.count)"
        )
      }
    }
    return collected
  }

  private func finalizeTargets(
    _ collected: [JumpTarget],
    profiler: FlashProfiler? = nil
  ) -> [JumpTarget] {
    // Firehose mode: no dedup. Keep deterministic sort so hint labels are
    // stable across activations.
    var merged = collected
    let sortStart = profiler?.intervalStart()
    merged.sort { lhs, rhs in
      let lhsTop = lhs.frame.maxY
      let rhsTop = rhs.frame.maxY
      if abs(lhsTop - rhsTop) > 8 { return lhsTop > rhsTop }
      if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
      if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY > rhs.frame.minY }
      if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
      if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
      return lhs.id < rhs.id
    }
    if let sortStart {
      profiler?.finishInterval("sort_targets", since: sortStart, detail: "targets=\(merged.count)")
    }
    return merged
  }

  private func clip(_ context: AppContext, to frame: CGRect) -> AppContext {
    AppContext(
      bundleIdentifier: context.bundleIdentifier,
      processID: context.processID,
      runningApp: context.runningApp,
      frontWindowFrame: frame.isNull ? context.frontWindowFrame : frame,
      allScreensFrame: context.allScreensFrame
    )
  }

  private func union(of rects: [CGRect]) -> CGRect {
    var out: CGRect = .null
    for rect in rects { out = out.union(rect) }
    return out
  }

  private func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  /// Push the current `Config` into the provider instances each walk
  /// reads from. Called at the start of every walk so config hot-reloads
  /// take effect on the very next activation. The trigger timestamp is
  /// propagated so each dump line / log line can be correlated to the
  /// activation that produced it.
  ///   - `dump_ax`   → AX walker writes per-element trace to
  ///                   ~/Library/Logs/Flash/ax-dump.log (rewritten per walk).
  ///   - `dump_logs` → FlashLog mirrors all stderr writes to
  ///                   ~/Library/Logs/Flash/flash.log (appended).
  private func configureProviders(for cfg: Config, triggerMs: UInt64?) {
    FlashLog.setMirrorToFile(cfg.debug.dumpLogs)

    let ax = registry.providers.first { $0 is AccessibilityProvider } as? AccessibilityProvider
    if let ax {
      ax.triggerMs = triggerMs
      if cfg.debug.dumpAx {
        let home = FileManager.default.homeDirectoryForCurrentUser
        ax.dumpURL =
          home
          .appendingPathComponent("Library/Logs/Flash/ax-dump.log")
      } else {
        ax.dumpURL = nil
      }
    }
  }

  // MARK: Context

  private func makeContext(for app: NSRunningApplication) -> AppContext? {
    let pid = app.processIdentifier
    guard pid > 0 else { return nil }

    var screenFrame: CGRect = .null
    for s in NSScreen.screens { screenFrame = screenFrame.union(s.frame) }
    if screenFrame.isNull { screenFrame = .zero }

    // Deliberately no AX IPC here. `makeContext` runs on the main thread
    // every time the user activates, and a single kAXFocusedWindowAttribute
    // call on a cold AX server can add 100-300 ms of latency to the
    // overlay appearing. The AX queue builds a WindowServer visibility
    // snapshot and passes a clipped context to providers, so the
    // centre-in-visible check works without needing a precomputed AX
    // window frame from main.
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: pid,
      runningApp: app,
      frontWindowFrame: screenFrame,
      allScreensFrame: screenFrame
    )
  }
}

/// Spatial-hash dedup keyed on a 256-pixel grid. For N=1500 targets the old
/// `seen.contains(where:)` was O(N²) — 1.1M `CGRect.intersection` calls in
/// the worst case. Bucketing collapses it to ~O(N) since the average number
/// of rectangles overlapping any single bucket is small.
private struct SpatialDedup {
  private static let cellSize: CGFloat = 256
  private var buckets: [Int64: [CGRect]] = [:]

  private static func key(_ x: Int, _ y: Int) -> Int64 {
    (Int64(x) << 32) | (Int64(y) & 0xffff_ffff)
  }

  private func bucketRange(_ rect: CGRect) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int) {
    let xMin = Int((rect.minX / Self.cellSize).rounded(.down))
    let xMax = Int((rect.maxX / Self.cellSize).rounded(.down))
    let yMin = Int((rect.minY / Self.cellSize).rounded(.down))
    let yMax = Int((rect.maxY / Self.cellSize).rounded(.down))
    return (xMin, xMax, yMin, yMax)
  }

  func contains(_ rect: CGRect) -> Bool {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        guard let bucket = buckets[Self.key(x, y)] else { continue }
        for other in bucket where overlapsSubstantially(other, rect) { return true }
      }
    }
    return false
  }

  mutating func insert(_ rect: CGRect) {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        buckets[Self.key(x, y), default: []].append(rect)
      }
    }
  }

  private func overlapsSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
    let inter = a.intersection(b)
    if inter.isNull { return false }
    let interArea = inter.width * inter.height
    let smaller = min(a.width * a.height, b.width * b.height)
    return smaller > 0 && interArea / smaller > 0.7
  }
}

/// Z-order snapshot of every on-screen window, with each window's
/// genuinely-visible portion already computed. Built from a single
/// `CGWindowListCopyWindowInfo` call.
///
/// The painter's algorithm: iterate windows front → back (the order
/// CGWindowList returns them in). For each window, subtract every
/// already-seen (higher-z) window's bounds from this one's. What's left
/// is the part of the window the user can actually see. Then push this
/// window's bounds onto the occluder list so the next window down gets
/// chopped by it too.
///
/// Higher-layer windows (the Dock, the menu bar, status items, the
/// notification centre) are kept as occluders but excluded from the
/// per-pid region map — they're not user-clickable surfaces Flash should
/// hint, but they DO cover stuff behind them, so they need to chop the
/// regions of the apps they overlay.
struct WindowSnapshot {
  struct Entry {
    let pid: pid_t
    let layer: Int
    /// NSScreen-coord bounds (origin bottom-left of primary).
    let nsBounds: CGRect
  }

  /// All on-screen windows in z-order (front-most first).
  let entries: [Entry]

  /// Per-pid disjoint rectangles in NSScreen coords that represent the
  /// pid's currently-visible pixels (after subtracting every higher-z
  /// window). Empty for pids that are fully occluded.
  let visibleRegions: [pid_t: [CGRect]]

  static func build(primaryH: CGFloat, onlyComputingVisibleRegionsFor focusedPid: pid_t)
    -> WindowSnapshot
  {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
      return WindowSnapshot(entries: [], visibleRegions: [:])
    }

    var entries: [Entry] = []
    entries.reserveCapacity(info.count)
    for w in info {
      guard let wpid = w[kCGWindowOwnerPID as String] as? Int32,
        let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
        let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { continue }
      // Skip zero-area or pathological bounds — they can't occlude
      // anything and can't host hints.
      if cgBounds.width <= 0 || cgBounds.height <= 0 { continue }
      let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
      let ns = CGRect(
        x: cgBounds.minX,
        y: primaryH - cgBounds.minY - cgBounds.height,
        width: cgBounds.width,
        height: cgBounds.height
      )
      entries.append(Entry(pid: pid_t(wpid), layer: layer, nsBounds: ns))
    }

    // The "active window" is the front-most layer-0 window owned by the
    // focused pid. CGWindowList returns windows in z-order, so the
    // first hit is the right one. Every other window — including other
    // windows of the same app on another monitor — is treated purely
    // as an occluder, never as a hintable surface. This is what keeps
    // hints scoped to the single active window.
    var activeWindowIndex: Int? = nil
    for (idx, e) in entries.enumerated() where e.layer == 0 && e.pid == focusedPid {
      activeWindowIndex = idx
      break
    }

    var byPid: [pid_t: [CGRect]] = [:]
    var occluders: [CGRect] = []
    occluders.reserveCapacity(entries.count)
    for (idx, e) in entries.enumerated() {
      if idx == activeWindowIndex {
        var fragments: [CGRect] = [e.nsBounds]
        for occluder in occluders {
          if fragments.isEmpty { break }
          var next: [CGRect] = []
          next.reserveCapacity(fragments.count * 2)
          for frag in fragments {
            subtract(frag, hole: occluder, into: &next)
          }
          // Fragmentation guard. A window cross-hatched by many
          // higher-z windows can blow up the fragment count
          // quadratically; cap at 32 — we only need the
          // *approximate* visible region, not pixel-perfect.
          if next.count > 32 {
            fragments = next
            break
          }
          fragments = next
        }
        if !fragments.isEmpty {
          byPid[e.pid, default: []].append(contentsOf: fragments)
        }
      }
      occluders.append(e.nsBounds)
    }

    return WindowSnapshot(entries: entries, visibleRegions: byPid)
  }

  /// Rectangle subtraction in NSScreen-coord (Y-up) space. Returns up to
  /// four non-overlapping fragments: top strip, bottom strip, left
  /// strip (within the y-range of the hole), right strip. The math is
  /// symmetric in Y so this also works in Y-down — the strip labels
  /// are only descriptive.
  private static func subtract(_ rect: CGRect, hole: CGRect, into out: inout [CGRect]) {
    let i = rect.intersection(hole)
    if i.isNull || i.width <= 0 || i.height <= 0 {
      out.append(rect)
      return
    }
    if i.equalTo(rect) {
      // Fully consumed by the hole — nothing left to emit.
      return
    }
    // Top strip (above the hole in Y-up).
    if i.maxY < rect.maxY {
      out.append(CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY))
    }
    // Bottom strip (below the hole).
    if i.minY > rect.minY {
      out.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY))
    }
    // Left strip (only within the y-range of the hole).
    if i.minX > rect.minX {
      out.append(CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height))
    }
    // Right strip (likewise).
    if i.maxX < rect.maxX {
      out.append(CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height))
    }
  }
}

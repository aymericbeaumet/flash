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
  private let registry: SourceRegistry

  private let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
  var focusedElementDidChange: ((pid_t) -> Void)?
  var focusedWindowGeometryDidChange: ((pid_t, String) -> Void)?

  // MARK: Config (shared between main + axQueue)
  //
  // Cheap lock — held only for the duration of a struct copy. AppDelegate
  // writes via `updateConfig` when the user edits flash.toml; axQueue
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
  /// ~/.config/flash/flash.toml changes. Atomically swaps the shared
  /// config, then invalidates the prepared model on main so labels and
  /// provider debug settings refresh together.
  func updateConfig(_ cfg: Config) {
    os_unfair_lock_lock(&configLock)
    config = cfg
    os_unfair_lock_unlock(&configLock)

    MainThreadHopper.runOrAsync { [weak self] in
      guard let self else { return }
      self.configRevision &+= 1
      guard let app = NSWorkspace.shared.frontmostApplication else { return }
      let pid = app.processIdentifier
      guard pid > 0 else { return }
      self.invalidatePreparedModel(for: pid)
      self.scheduleModelRefresh(for: pid, reason: "config")
    }
  }

  /// Hard ceiling on how long a prepared model is served before falling
  /// back to a fresh walk. Belt-and-suspenders against AX events the
  /// observer set missed (some apps don't fire `kAXLayoutChanged` on
  /// every UI transition).
  private static let modelFreshnessMs: Int = 1500
  private static let modelDebounceMs: Int = 80
  private static let modelMaintenanceLeadMs: Int = 250

  init(registry: SourceRegistry, config: Config) {
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
  /// Coalesced model refresh scheduling. The previous implementation
  /// allocated a fresh `DispatchWorkItem` for every observed AX event
  /// and cancelled the previous one. Under scroll storms
  /// (`kAXValueChangedNotification` fires per frame) this churned
  /// 60+ allocations per second on main. The new approach keeps one
  /// dispatch in flight per pid; new events extend the deadline and
  /// the in-flight closure re-arms itself if the burst is still
  /// active when it wakes.
  private var modelRefreshArmed: Set<pid_t> = []
  private var modelRefreshDeadline: [pid_t: DispatchTime] = [:]
  private var modelRefreshReason: [pid_t: String] = [:]
  private var maintenanceRefresh: [pid_t: DispatchWorkItem] = [:]
  /// Only the latest activation waiter matters — earlier waiters are
  /// stale activations whose generation has already moved on. A scalar
  /// per pid replaces the previous unbounded array; if a second
  /// activation lands while a walk is in flight, it overwrites the
  /// first instead of stacking.
  private var pendingModelCompletion: [pid_t: (PreparedModel?) -> Void] = [:]
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

  private static let observerCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let ctx = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    guard let monitor = ctx.monitor else { return }
    let pid = ctx.pid
    let notificationName = notification as String
    // AXObserver callbacks already run on the run loop that holds the
    // source — we add it to the main run loop below, so we're already
    // on main here. Hop anyway to make the invariant explicit and
    // bullet-proof against future relocation of the source.
    MainThreadHopper.runOrAsync {
      monitor.onAXEvent(pid: pid, notification: notificationName)
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

  static func windowGeometryNotificationRequiresBorderSuspension(_ notification: String) -> Bool {
    notification == kAXWindowMovedNotification
      || notification == kAXWindowResizedNotification
      || notification == kAXFocusedWindowChangedNotification
      || notification == kAXMainWindowChangedNotification
  }

  // MARK: Lifecycle

  func start() {
    installWorkspaceObservers()
    wakeChromiumAccessibilityForAllRunningApps()
    if let app = NSWorkspace.shared.frontmostApplication {
      onFocusedAppChanged(to: app)
    }
  }

  private func wakeChromiumAccessibilityForAllRunningApps() {
    ChromiumAccessibilityWaker.wakeAllRunningApps(on: axQueue)
  }

  private func maybeWakeChromiumAccessibility(for app: NSRunningApplication) {
    ChromiumAccessibilityWaker.maybeWake(app: app, on: axQueue)
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

  func onAXEvent(pid: pid_t, notification: String) {
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    scheduleModelRefresh(for: pid, reason: "ax:\(notification)")
    if Self.windowGeometryNotificationRequiresBorderSuspension(notification) {
      focusedWindowGeometryDidChange?(pid, notification)
    }
    focusedElementDidChange?(pid)
  }

  func invalidateAfterUserAction(pid: pid_t, reason: String) {
    MainThreadHopper.runOrAsync { [weak self] in
      guard let self, pid > 0 else { return }
      self.dirtyTokens[pid, default: 0] &+= 1
      self.invalidatePreparedModel(for: pid)
      self.scheduleModelRefresh(for: pid, reason: reason)
      FlashLog.debug("[ax] model_invalidated pid=\(pid) reason=\(reason)")
    }
  }

  func focusedElementIsEditable(pid: pid_t, completion: @escaping (Bool) -> Void) {
    axQueue.async {
      let editable = NormalModeDispatcher.isEditableFocusedElement(pid: pid)
      DispatchQueue.main.async {
        completion(editable)
      }
    }
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
    modelRefreshArmed.remove(pid)
    modelRefreshDeadline.removeValue(forKey: pid)
    modelRefreshReason.removeValue(forKey: pid)
    maintenanceRefresh[pid]?.cancel()
    maintenanceRefresh.removeValue(forKey: pid)
    pendingModelCompletion.removeValue(forKey: pid)
  }

  private func cancelAllRefreshWork() {
    modelRefreshArmed.removeAll()
    modelRefreshDeadline.removeAll()
    modelRefreshReason.removeAll()
    for work in maintenanceRefresh.values { work.cancel() }
    maintenanceRefresh.removeAll()
    pendingModelCompletion.removeAll()
  }

  /// Debounced model refresh. Multiple events arriving within
  /// `modelDebounceMs` coalesce into a single background walk. The
  /// deadline pushes back on every fresh event so a steady stream
  /// (e.g. scrolling) stays quiet until it settles. We allocate at
  /// most one in-flight closure per pid for the whole burst.
  private func scheduleModelRefresh(for pid: pid_t, reason: String) {
    let deadline = DispatchTime.now() + .milliseconds(Self.modelDebounceMs)
    modelRefreshDeadline[pid] = deadline
    modelRefreshReason[pid] = reason
    guard modelRefreshArmed.insert(pid).inserted else { return }
    armRefreshTimer(pid: pid, deadline: deadline)
  }

  private func armRefreshTimer(pid: pid_t, deadline: DispatchTime) {
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
      guard let self else { return }
      guard let extended = self.modelRefreshDeadline[pid] else {
        self.modelRefreshArmed.remove(pid)
        self.modelRefreshReason.removeValue(forKey: pid)
        return
      }
      if DispatchTime.now() < extended {
        // A new event extended the deadline while we were waiting.
        // Re-arm rather than fire now so a burst still backs off.
        self.armRefreshTimer(pid: pid, deadline: extended)
        return
      }
      let reason = self.modelRefreshReason.removeValue(forKey: pid) ?? "debounced"
      self.modelRefreshArmed.remove(pid)
      self.modelRefreshDeadline.removeValue(forKey: pid)
      self.runModelRefresh(pid: pid, reason: reason, profiler: nil, completion: nil)
    }
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
    // Any in-flight debounce closure for this pid has already finished
    // its check (it's the one calling us, or activation jumped the
    // queue). Clear the bookkeeping defensively.
    modelRefreshArmed.remove(pid)
    modelRefreshDeadline.removeValue(forKey: pid)
    modelRefreshReason.removeValue(forKey: pid)

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
    if registry.anyVolatileSourceApplies(to: context) {
      completion?(nil)
      return
    }
    let providers = registry.continuousSources(for: context)
    guard !providers.isEmpty else {
      completion?(nil)
      return
    }
    guard preparedModels.beginRebuild(pid: pid) else {
      // Last-writer-wins: only the latest activation waiter matters,
      // earlier waiters are already-stale activations.
      if let completion {
        pendingModelCompletion[pid] = completion
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
        let waiter = self.pendingModelCompletion.removeValue(forKey: pid)
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
            FlashLog.info(
              "[ax] model_ready pid=\(pid) bundle=\(context.bundleIdentifier) "
                + "hints=\(built.hints.count) token=\(startToken) reason=\(reason)"
            )
          }
        }
        let validModel = tokenStillMatches && revisionStillMatches && stillFocused ? built : nil
        completion?(validModel)
        waiter?(validModel)
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

  func frontmostContext(excludingBundleIdentifier ignoredBundleIdentifier: String) -> AppContext? {
    if let context = currentContext(),
      context.bundleIdentifier != ignoredBundleIdentifier
    {
      return clip(context, to: topWindowFrame(for: context.processID) ?? context.frontWindowFrame)
    }
    return topVisibleWindowContext(excludingBundleIdentifier: ignoredBundleIdentifier)
  }

  func context(for pid: pid_t) -> AppContext? {
    guard pid > 0,
      let app = NSRunningApplication(processIdentifier: pid)
    else { return nil }
    guard let context = makeContext(for: app) else { return nil }
    return clip(context, to: topWindowFrame(for: pid) ?? context.frontWindowFrame)
  }

  // MARK: Discovery

  /// Activation hot path. Tries the prepared AX model first. Volatile
  /// providers (tmux) bypass the model entirely.
  func discoverAsync(
    context: AppContext,
    profiler: FlashProfiler? = nil,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let pid = context.processID
    if observers[pid] == nil {
      installObserver(for: pid)
    }

    if registry.anyVolatileSourceApplies(to: context) {
      runActivationDiscovery(
        context: context,
        profiler: profiler,
        targetFilter: targetFilter,
        completion: completion)
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
      if let targetFilter {
        let cfg = snapshotConfig()
        completion(assignTargets(model.targets.filter(targetFilter), cfg: cfg, profiler: profiler))
      } else {
        completion(model.hints)
      }
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
        if let targetFilter {
          let cfg = self.snapshotConfig()
          completion(self.assignTargets(model.targets.filter(targetFilter), cfg: cfg, profiler: profiler))
        } else {
          completion(model.hints)
        }
      } else {
        self.runActivationDiscovery(
          context: context,
          profiler: profiler,
          targetFilter: targetFilter,
          completion: completion)
      }
    }
  }

  private func finishQueueWait(_ profiler: FlashProfiler?, since start: UInt64) {
    profiler?.finishInterval("ax_queue_wait", since: start)
  }

  private struct DiscoveryResult {
    let targets: [JumpTarget]
    let hints: [AssignedHint]
  }

  private struct DiscoveryFrame {
    let providerContext: AppContext
    let visibleRegions: [CGRect]
  }

  private func buildPreparedModel(
    context: AppContext,
    providers: [FlashSource],
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
    targetFilter: ((JumpTarget) -> Bool)? = nil,
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
        targetFilter: targetFilter,
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
    providers: [FlashSource],
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    profiler: FlashProfiler? = nil
  ) -> DiscoveryResult {
    let walkStart = profiler?.intervalStart()
    configureRuntime(for: cfg)
    let frame = resolveDiscoveryFrame(for: context, profiler: profiler)
    guard !frame.visibleRegions.isEmpty else {
      if let walkStart {
        profiler?.finishInterval("walk_all", since: walkStart, detail: "targets=0")
      }
      return DiscoveryResult(targets: [], hints: [])
    }
    let collected = collectFocusedTargets(
      context: frame.providerContext,
      providers: providers,
      profiler: profiler)
    let finalizeStart = profiler?.intervalStart()
    let finalized = TargetFinalizer.finalizeWithStats(
      collected,
      visibleRegions: frame.visibleRegions)
    let targets = targetFilter.map { finalized.targets.filter($0) } ?? finalized.targets
    if let finalizeStart {
      profiler?.finishInterval(
        "finalize_targets",
        since: finalizeStart,
        detail:
          "raw=\(finalized.rawCount) visible=\(finalized.visibleCount) "
          + "deduped=\(finalized.dedupedCount)")
    }
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
    let resolved = cfg.resolvedAlphabet
    let assignStart = profiler?.intervalStart()
    let hints = HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      minLength: cfg.hints.minLength
    )
    if let assignStart {
      profiler?.finishInterval(
        "assign_hints", since: assignStart, detail: "targets=\(targets.count) hints=\(hints.count)")
    }
    return hints
  }

  private func resolveDiscoveryFrame(
    for context: AppContext,
    profiler: FlashProfiler? = nil
  ) -> DiscoveryFrame {
    let snapshotStart = profiler?.intervalStart()
    let snapshot = WindowSnapshot.build(
      primaryH: primaryScreenHeight(),
      onlyComputingVisibleRegionsFor: context.processID,
      ignoringPids: [getpid()])
    let visible: [CGRect]
    if let regions = snapshot.visibleRegions[context.processID] {
      visible = regions
    } else if snapshot.entries.isEmpty {
      // CGWindowList can fail transiently. Fall back to the activation-time
      // screen union so the user still gets hints instead of a silent empty
      // overlay; normal runs use the precise active-window visible regions.
      visible = [context.frontWindowFrame]
    } else {
      visible = []
    }
    let providerFrame = snapshot.activeWindowFrame ?? union(of: visible)
    if let snapshotStart {
      profiler?.finishInterval(
        "window_snapshot",
        since: snapshotStart,
        detail:
          "windows=\(snapshot.entries.count) visible_regions=\(visible.count)"
      )
    }
    return DiscoveryFrame(
      providerContext: clip(context, to: providerFrame),
      visibleRegions: visible)
  }

  private func collectFocusedTargets(
    context focused: AppContext,
    providers: [FlashSource],
    profiler: FlashProfiler? = nil
  ) -> [TargetCandidate] {
    var collected: [TargetCandidate] = []
    collected.reserveCapacity(256)
    for (providerOrder, provider) in providers.enumerated() {
      let providerStart = profiler?.intervalStart()
      let results =
        (try? provider.discover(in: focused)) ?? []
      collected.append(
        contentsOf: results.enumerated().map { ordinal, target in
          TargetCandidate(
            target: target,
            priority: provider.priority,
            providerOrder: providerOrder,
            ordinal: ordinal)
        })
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

  /// Push runtime config that should take effect on the next activation.
  private func configureRuntime(for cfg: Config) {
    FlashLog.setLevel(cfg.debug.logLevel)
  }

  // MARK: Context

  private func makeContext(
    for app: NSRunningApplication,
    frontWindowFrame: CGRect? = nil
  ) -> AppContext? {
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
    let windowFrame = frontWindowFrame ?? screenFrame
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: pid,
      runningApp: app,
      frontWindowFrame: windowFrame,
      allScreensFrame: screenFrame
    )
  }

  private func topWindowFrame(for pid: pid_t) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight())
      .first { $0.layer == 0 && $0.pid == pid && $0.pid != getpid() }?
      .nsBounds
  }

  private func topVisibleWindowContext(
    excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    for entry in WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight()) {
      guard entry.layer == 0, entry.pid > 0, entry.pid != getpid(),
        let app = NSRunningApplication(processIdentifier: entry.pid),
        !app.isTerminated,
        app.bundleIdentifier != ignoredBundleIdentifier
      else { continue }
      return makeContext(for: app, frontWindowFrame: entry.nsBounds)
    }
    return nil
  }
}


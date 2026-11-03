import AppKit
import ApplicationServices
import FlashCore
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
///   - Model reads serve a hit ONLY if token, config revision, freshness
///     and the window's visible region all match.
///
/// The result is deterministic: two activations in the same UI state
/// always serve the same hint set. No partial model, no stale model.
final class AppMonitor {
  let registry: SourceRegistry

  let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
  /// AX observer registration, its retry ladder, focused-window
  /// re-observation, teardown, and the launch-time Chromium wakes: each is an
  /// IPC the target app answers at its own pace, up to the 1.5 s messaging
  /// timeout, so they run here and a walk, a readiness probe or a commit on
  /// `axQueue` never waits behind them. The focus-path wake stays on
  /// `axQueue`, ahead of the probe that watches the tree it builds.
  let observerQueue = DispatchQueue(label: "flash.ax_observers", qos: .userInitiated)
  /// AX geometry reads for the active-window border that must not wait behind
  /// an AX walk on `axQueue`. Window-list reads never run here; see
  /// `WindowSnapshot.windowList`.
  let geometryQueue = DispatchQueue(label: "flash.window_geometry", qos: .userInitiated)
  /// Every observed AX notification: the app's pid, its bundle id as known
  /// at observer install, and the notification name.
  var focusedElementDidChange: ((pid_t, String?, String) -> Void)?
  /// App `pid` reported a change to what it shows: one that schedules a
  /// prepared-model refresh, outside an AX storm. A click chain waiting for
  /// its next pick walks again on it (`ClickChain.refreshes`).
  var uiDidChange: ((pid_t) -> Void)?
  /// A menu of app `pid` opened (`true`) or closed, with the element the
  /// notification named: the one handle on a menu that is not a child of
  /// its application element (Firefox's context menus).
  var menuDidChange: ((pid_t, Bool, AXUIElement) -> Void)?
  /// Focus may have moved in app `pid`: it was activated, or it reported a
  /// focus or window change (`notificationMovesFocus`).
  var focusedElementMayHaveChanged: ((pid_t) -> Void)?
  var activeWindowMayHaveChanged: ((pid_t, String, AXUIElement?) -> Void)?
  var focusedWindowDidResolve: ((pid_t, AXUIElement) -> Void)?
  /// Every application launch the workspace reports, on main.
  var applicationDidLaunch: ((NSRunningApplication) -> Void)?

  // MARK: Config (shared between main + axQueue)
  //
  // Cheap lock — held only for the duration of a struct copy. AppDelegate
  // writes via `updateConfig` when the user edits flash.toml; axQueue
  // reads via `snapshotConfig` at the start of each walk.

  private let config: OSAllocatedUnfairLock<Config>
  var configRevision: UInt64 = 0

  func snapshotConfig() -> Config {
    config.withLock { $0 }
  }

  /// Called by the AppDelegate config file-watcher whenever
  /// ~/.config/flash/flash.toml changes. Atomically swaps the shared
  /// config, then invalidates the prepared model on main so labels and
  /// provider debug settings refresh together.
  func updateConfig(_ cfg: Config) {
    config.withLock { $0 = cfg }

    MainThreadHopper.runOrAsync { [weak self] in
      guard let self else { return }
      self.configRevision &+= 1
      // A configuration change may add or drop the provider that owned a
      // gated app's hints: give every app a fresh look.
      self.backgroundWalkGate.reset()
      // Providers may have changed with it, and walk costs with them.
      self.modelIntervalsMs.removeAll()
      guard let app = NSWorkspace.shared.frontmostApplication else { return }
      let pid = app.processIdentifier
      guard pid > 0 else { return }
      self.invalidatePreparedModel(for: pid, because: .config)
      self.scheduleModelRefresh(for: pid, reason: .config)
    }
  }

  /// Hard ceiling on how long a prepared model is served before falling
  /// back to a fresh walk. Belt-and-suspenders against AX events the
  /// observer set missed (some apps don't fire `kAXLayoutChanged` on
  /// every UI transition).
  static let modelFreshnessMs: Int = 1500
  /// Ceiling for the per-model freshness backoff (see `PreparedModel.freshnessMs`).
  static let modelFreshnessMaxMs: Int = 30_000
  /// No maintenance walks while the user has produced no input for this long;
  /// the next activation performs a complete walk on demand.
  static let maintenanceIdleSuspendSeconds: Double = 60
  static let modelDebounceMs: Int = 80
  static let modelMaintenanceLeadMs: Int = 250
  static let backgroundModelMinIntervalMs: Int = 2500
  /// A walk is slow when repeating it every maintenance interval would cost
  /// more than this fraction of a core: the budget is a fraction of the
  /// model's freshness window, never an absolute number of milliseconds. The
  /// apps hints matter for (Electron, Gecko, Catalyst) walk in 50–100 ms, and
  /// a flat 50 ms budget switched the prepared model off for every one of
  /// them — 72% of hint activations walked on the key path.
  static let slowAutomaticModelRefreshFraction: Double = 0.10
  /// Below this a walk is never slow, whatever the interval.
  static let slowAutomaticModelRefreshFloorMs: Double = 50

  /// 150 ms at the 1.5 s floor, 3 s at the 30 s ceiling.
  static func slowAutomaticModelRefreshThresholdMs(intervalMs: Int) -> Double {
    max(slowAutomaticModelRefreshFloorMs, slowAutomaticModelRefreshFraction * Double(intervalMs))
  }

  static func automaticModelRefreshIsSlow(elapsedMs: Double, intervalMs: Int) -> Bool {
    elapsedMs >= slowAutomaticModelRefreshThresholdMs(intervalMs: intervalMs)
  }

  /// The app's next maintenance interval after a walk that took `elapsedMs`
  /// at the `current` one. A slow walk doubles it toward the ceiling — the
  /// backoff, instead of cancelling maintenance and letting the model expire
  /// — and so does a maintenance walk that reproduced the model `unchanged`
  /// (a static app). Otherwise the interval shrinks back toward the floor,
  /// halving as long as the walk is cheap for the halved interval, so it
  /// settles where the walk's duty cycle stays under the fraction. A
  /// `degenerate` walk is fast because there was nothing to read, so it
  /// never shrinks the interval.
  static func nextModelIntervalMs(
    current: Int, elapsedMs: Double, unchanged: Bool, degenerate: Bool
  ) -> Int {
    let current = max(current, modelFreshnessMs)
    if automaticModelRefreshIsSlow(elapsedMs: elapsedMs, intervalMs: current) || unchanged {
      return min(current * 2, modelFreshnessMaxMs)
    }
    guard !degenerate else { return current }
    var next = current
    while next > modelFreshnessMs {
      let halved = max(next / 2, modelFreshnessMs)
      guard !automaticModelRefreshIsSlow(elapsedMs: elapsedMs, intervalMs: halved) else { break }
      next = halved
    }
    return next
  }

  /// AX event storm visibility. `onAXEvent` is otherwise silent, so a
  /// notification flood from a churning app (Notes re-rendering its note
  /// list mid-iCloud-sync) was invisible in the log while it cost both the
  /// app's main thread (generation) and Flash's (delivery). Events are
  /// counted per pid and flushed as at most one line per window, only for
  /// pids whose rate is storm-like. Typing sits around 10–20 events/s and
  /// stays quiet; sustained scrolling can brush the threshold, which is
  /// itself worth seeing.
  static let axEventStormWindowMs: Int = 1000
  static let axEventStormThresholdPerSecond: Int = 120

  static func axEventRateIsStorm(count: Int, elapsedMs: Int) -> Bool {
    count * 1000 / max(elapsedMs, 1) >= axEventStormThresholdPerSecond
  }

  static var axEventStormCountThreshold: Int {
    max(1, axEventStormThresholdPerSecond * axEventStormWindowMs / 1000)
  }

  /// Some apps expose enough AX structure that background warming is more
  /// disruptive than a cold on-demand hint walk; plugins declare them
  /// (`OnDemandHintApps`). Keep activation explicit for those apps: focus
  /// changes still invalidate stale models, but Flash does not poke their AX
  /// tree just because they became frontmost.
  static func shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: String) -> Bool {
    !OnDemandHintApps.contains(bundleIdentifier)
  }

  init(registry: SourceRegistry, config: Config, pollScheduler: PollScheduler = .shared) {
    self.registry = registry
    self.config = OSAllocatedUnfairLock(initialState: config)
    self.pollScheduler = pollScheduler
  }

  /// The shared clock every prepared-model wake rides: debounce, readiness
  /// and maintenance (see `armRefreshTimer` and `armMaintenanceWake`).
  let pollScheduler: PollScheduler
  /// The pid whose maintenance wake is registered on `pollScheduler`. Main
  /// thread only.
  var maintenanceWakePID: pid_t?
  /// Debounce and readiness wakes registered on `pollScheduler`, by client
  /// id, so cancelling an app's refresh work releases them. Main thread only.
  var refreshWakeClientIDs: Set<String> = []
  /// Numbers each activation repair's wake on `pollScheduler`, so a newer
  /// activation never replaces an older one's pending step (that step still
  /// has to end its activation, if only by abandoning it). Main thread only.
  var activationRepairSerial: UInt64 = 0

  // MARK: Prepared model state
  //
  // Every field below is touched only from the main thread. Walk results
  // arrive on `axQueue` and are hopped back to main before they update
  // any of these.

  var preparedModels = PreparedModelStore()
  var dirtyTokens: [pid_t: UInt64] = [:]
  var observers: [pid_t: ObserverEntry] = [:]
  var axEventStormWindowStart = DispatchTime.now()
  var axEventStormCounts: [pid_t: [String: Int]] = [:]
  /// Pids whose current/previous observation window crossed the storm
  /// threshold. Their dirty tokens still advance on every event, but automatic
  /// background warming pauses until a quiet window proves the burst ended.
  var axEventStormingPIDs: Set<pid_t> = []
  /// Each app's maintenance interval: how long its models are served and how
  /// far apart its speculative walks run (`nextModelIntervalMs`). It outlives
  /// the models — an AX event discards a model, not the evidence that the
  /// app walks slowly — and is forgotten when the app quits or the
  /// configuration changes. Absent means the 1.5 s floor.
  var modelIntervalsMs: [pid_t: Int] = [:]
  var modelScheduler = PreparedModelScheduler(
    debounceMs: modelDebounceMs,
    minimumIntervalMs: backgroundModelMinIntervalMs,
    freshnessMs: modelFreshnessMs,
    maintenanceLeadMs: modelMaintenanceLeadMs)
  /// The activation waiting on each app's in-flight walk; a displaced or
  /// cancelled waiter is completed with nil, never dropped.
  var pendingModelWaiters = PreparedModelWaiters()
  /// The last trusted target count per app: what a later walk of the same app
  /// is judged against (`discoveryLooksDegenerate`). Written by activations
  /// and by stored background walks that do not look degenerate; forgotten
  /// when the app quits.
  var healthyTargetCounts: [pid_t: Int] = [:]
  /// Readiness re-walks left for the focused app's current focus
  /// (`backgroundReadinessRewalksPerFocus` when absent); reset on focus.
  var readinessRewalkBudget: [pid_t: Int] = [:]
  /// Apps whose automatic walks are useless: a volatile provider owns their
  /// hints and their own tree keeps walking empty.
  var backgroundWalkGate = EmptyBackgroundWalkGate()
  var workspaceObservers: [NSObjectProtocol] = []
  var localObservers: [NSObjectProtocol] = []
  /// `installObserver` runs on every focus change; this gates the
  /// missing-Accessibility-permission warning to one log line per grant
  /// state instead of one per app switch.
  var warnedMissingAXPermission = false

  final class ObserverEntry {
    let observer: AXObserver
    let appElement: AXUIElement
    let context: ObserverContext
    /// Exactly the notifications registered at install time, so teardown
    /// removes the same set (full vs light differs per bundle).
    let notifications: [String]
    /// Accessed only on `observerQueue`. Move/resize/minimize/destruction
    /// notifications are emitted by the window element, not the application
    /// element, so the focused window needs its own registrations.
    var focusedWindow: AXUIElement?
    /// Accessed only on `observerQueue`. Set by teardown so a pending registration
    /// retry stops instead of registering on an observer that is gone.
    var isTornDown = false

    init(
      observer: AXObserver,
      appElement: AXUIElement,
      context: ObserverContext,
      notifications: [String]
    ) {
      self.observer = observer
      self.appElement = appElement
      self.context = context
      self.notifications = notifications
    }
  }

  /// The `refcon` blob passed to the C AXObserver callback. Held alive
  /// by `observers[pid]` so it stays valid for the observer's lifetime.
  final class ObserverContext {
    weak var monitor: AppMonitor?
    let pid: pid_t
    /// The observed app's bundle id, looked up once at install so a storm of
    /// notifications never consults LaunchServices per event.
    let bundleIdentifier: String?
    private let focusedWindowLock = NSLock()
    private var focusedWindow: AXUIElement?
    private var active = true

    init(monitor: AppMonitor, pid: pid_t, bundleIdentifier: String?) {
      self.monitor = monitor
      self.pid = pid
      self.bundleIdentifier = bundleIdentifier
    }

    func setFocusedWindow(_ window: AXUIElement?) {
      focusedWindowLock.lock()
      if active { focusedWindow = window }
      focusedWindowLock.unlock()
    }

    /// Main revokes ownership before removing the run-loop source. A callback
    /// already in flight or queued on main must not outlive its observer.
    func invalidate() {
      focusedWindowLock.lock()
      active = false
      focusedWindow = nil
      focusedWindowLock.unlock()
    }

    var isActive: Bool {
      focusedWindowLock.lock()
      defer { focusedWindowLock.unlock() }
      return active
    }

    func isFocusedWindow(_ element: AXUIElement) -> Bool {
      focusedWindowLock.lock()
      defer { focusedWindowLock.unlock() }
      guard active, let focusedWindow else { return false }
      return CFEqual(focusedWindow, element)
    }
  }

  /// Runs on `AXObserverThread`. Touches no monitor state: it appends to the
  /// pending batch and arms at most one main-thread drain per burst.
  static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let ctx = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    guard ctx.isActive, let monitor = ctx.monitor else { return }
    let isFocusedWindow = ctx.isFocusedWindow(element)
    let name = notification as String
    let isMenu =
      name == kAXMenuOpenedNotification as String || name == kAXMenuClosedNotification as String
    monitor.enqueueAXEvent(
      PendingAXEvent(
        context: ctx,
        notification: name,
        observedElementIsFocusedWindow: isFocusedWindow,
        observedWindow: isFocusedWindow ? element : nil,
        menu: isMenu ? element : nil))
  }

  struct PendingAXEvent {
    let context: ObserverContext
    var notification: String
    var observedElementIsFocusedWindow: Bool
    var observedWindow: AXUIElement?
    /// The menu an `AXMenuOpened` / `AXMenuClosed` names.
    var menu: AXUIElement? = nil
  }

  private let pendingAXEventsLock = NSLock()
  private var pendingAXEvents: [PendingAXEvent] = []
  private var axDrainArmed = false

  func enqueueAXEvent(_ event: PendingAXEvent) {
    pendingAXEventsLock.lock()
    pendingAXEvents.append(event)
    let arm = !axDrainArmed
    if arm { axDrainArmed = true }
    pendingAXEventsLock.unlock()
    guard arm else { return }
    DispatchQueue.main.async { [weak self] in self?.drainAXEvents() }
  }

  /// Main thread. One drain handles everything that arrived since the last
  /// one, so a 1000-event storm costs one wakeup, not a thousand.
  func drainAXEvents() {
    pendingAXEventsLock.lock()
    let batch = pendingAXEvents
    pendingAXEvents.removeAll(keepingCapacity: true)
    axDrainArmed = false
    pendingAXEventsLock.unlock()
    for event in batch {
      guard event.context.isActive else { continue }
      onAXEvent(
        pid: event.context.pid,
        bundleIdentifier: event.context.bundleIdentifier,
        notification: event.notification,
        observedElementIsFocusedWindow: event.observedElementIsFocusedWindow,
        observedWindow: event.observedWindow,
        menu: event.menu)
    }
  }

  /// AX notifications we subscribe to per focused app. Any one of these
  /// invalidates the prepared model (bumps `dirtyTokens[pid]`). Only
  /// structural notifications schedule a background rebuild; value/title churn
  /// is common during media playback and should make the next activation walk
  /// fresh without spending background AX time.
  static let observedNotifications: [String] = [
    kAXFocusedUIElementChangedNotification,
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXLayoutChangedNotification,
    kAXSelectedChildrenChangedNotification,
    kAXSelectedRowsChangedNotification,
    kAXValueChangedNotification,
    kAXWindowResizedNotification,
    kAXWindowMovedNotification,
    kAXWindowCreatedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXApplicationHiddenNotification,
    kAXApplicationShownNotification,
    kAXTitleChangedNotification,
    kAXCreatedNotification,
    kAXUIElementDestroyedNotification,
    kAXRowExpandedNotification,
    kAXRowCollapsedNotification,
    // A context menu opening and closing: the evidence that decides how long
    // a native surface keeps the keyboard (`NativeSurfaceOwnership`).
    kAXMenuOpenedNotification,
    kAXMenuClosedNotification,
  ]

  /// Reduced set for apps excluded from automatic model warming
  /// (`OnDemandHintApps`). For those apps a
  /// prepared model is only built on explicit activation and served within
  /// `modelFreshnessMs`, so churn-level invalidation (value / created /
  /// destroyed / layout / rows) buys almost nothing — while forcing the app
  /// to generate a notification on its main thread for every mutation.
  /// A notes app re-rendering its list during a sync burst is exactly the
  /// moment that cost hurts. Keep only what drives mode,
  /// border, and focus behaviour.
  static let lightObservedNotifications: [String] = [
    kAXFocusedUIElementChangedNotification,
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowCreatedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXApplicationHiddenNotification,
    kAXApplicationShownNotification,
    kAXUIElementDestroyedNotification,
  ]

  static let focusedWindowObservedNotifications: [String] = [
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXUIElementDestroyedNotification,
  ]

  static func observedNotifications(forBundleIdentifier bundleIdentifier: String?) -> [String] {
    guard OnDemandHintApps.contains(bundleIdentifier) else { return observedNotifications }
    return lightObservedNotifications
  }

  static func notificationShouldSchedulePreparedModelRefresh(_ notification: String) -> Bool {
    notification != kAXValueChangedNotification as String
      && notification != kAXTitleChangedNotification as String
  }

  static func notificationMayChangeActiveWindowBorder(
    _ notification: String,
    observedElementIsFocusedWindow: Bool
  ) -> Bool {
    if notification == kAXUIElementDestroyedNotification as String {
      return observedElementIsFocusedWindow
    }
    return notification == kAXWindowMovedNotification
      || notification == kAXWindowResizedNotification
      || notification == kAXFocusedWindowChangedNotification
      || notification == kAXMainWindowChangedNotification
      || notification == kAXWindowCreatedNotification
      || notification == kAXWindowMiniaturizedNotification
      || notification == kAXWindowDeminiaturizedNotification
      || notification == kAXApplicationHiddenNotification
      || notification == kAXApplicationShownNotification
  }

  /// A move or resize names the window that changed, so the border and the
  /// layout tracker can read its frame straight from that AX element. Every
  /// other border-relevant notification still needs a WindowServer pass to
  /// work out which window is now on top.
  static func isWindowGeometryNotification(_ notification: String) -> Bool {
    notification == kAXWindowMovedNotification as String
      || notification == kAXWindowResizedNotification as String
  }

  static func notificationMayChangeObservedWindow(_ notification: String) -> Bool {
    notification == kAXFocusedWindowChangedNotification
      || notification == kAXMainWindowChangedNotification
      || notification == kAXWindowCreatedNotification
      || notification == kAXWindowMiniaturizedNotification
      || notification == kAXWindowDeminiaturizedNotification
      || notification == kAXUIElementDestroyedNotification
  }

  /// The notifications after which the focused element is re-read for its
  /// region (`FocusRegionTracker`): focus moving, never an element's
  /// destruction, which a busy web app posts by the hundred while focus
  /// stays where it is.
  static func notificationMovesFocus(_ notification: String) -> Bool {
    notification == kAXFocusedUIElementChangedNotification as String
      || notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
  }

  static func notificationMayChangeFocusedElement(_ notification: String) -> Bool {
    notification == kAXFocusedUIElementChangedNotification as String
      || notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
      || notification == kAXUIElementDestroyedNotification as String
  }

  // MARK: Lifecycle

  func start() {
    installWorkspaceObservers()
    // The tap source, AX observer sources, and all mode logic share the main
    // run loop; when it stalls, input stalls system-wide. `ConfigReload`
    // arms the recorder once the configured log level is known.
    wakeChromiumAccessibilityForAllRunningApps()
    if let app = NSWorkspace.shared.frontmostApplication {
      onFocusedAppChanged(to: app)
    }
  }

  private func wakeChromiumAccessibilityForAllRunningApps() {
    AccessibilityWaker.wakeAllRunningApps(on: observerQueue)
  }

  /// The focus-path wake, on `axQueue`: the readiness probe queued behind it
  /// watches the tree this starts building.
  func maybeWakeChromiumAccessibility(for app: NSRunningApplication) {
    AccessibilityWaker.maybeWake(app: app, on: axQueue)
  }

  /// A launch-time wake: nothing waits on it, so it stays off the walk queue.
  func wakeChromiumAccessibilityInBackground(for app: NSRunningApplication) {
    AccessibilityWaker.maybeWake(app: app, on: observerQueue)
  }

  func stop() {
    preparedModels.removeAll()
    cancelAllRefreshWork()
    teardownAllObservers()
    // Focus is no longer reported, so no Gecko mode may linger. Stop runs at
    // quit, when a deferred switch-off would never run: wait for it, bounded
    // by a walk still holding the process.
    GeckoAccessibility.releaseAll(waitingAtMost: .seconds(2))
    for token in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    workspaceObservers.removeAll()
    for token in localObservers {
      NotificationCenter.default.removeObserver(token)
    }
    localObservers.removeAll()
  }

  /// The model for `pid` if it is still current, the visible region of its
  /// window included: another app's window moving over or off it is window
  /// list state no AX event reports, so the lookup recomputes the region
  /// from `windowEntries` — the activation's own read — or one read here,
  /// on main, through the same builder the walk used. A miss says why,
  /// `suppressed` when there is no model because Flash chose not to warm the
  /// app (a storm, the empty-walk gate, an on-demand declaration).
  func resolvePreparedModel(
    for pid: pid_t, bundleIdentifier: String, windowEntries: [WindowSnapshot.Entry]? = nil
  ) -> PreparedModelStore.Resolution {
    guard let model = preparedModels.current(pid: pid) else {
      let resolution = preparedModels.resolve(
        pid: pid, dirtyToken: dirtyTokens[pid] ?? 0, configRevision: configRevision,
        now: DispatchTime.now(), occlusion: nil)
      guard case .miss(let miss) = resolution, [.absent, .focus, .invalidated].contains(miss),
        automaticWarmingIsSuppressed(pid: pid, bundleIdentifier: bundleIdentifier)
      else { return resolution }
      return .miss(.suppressed)
    }
    let entries =
      windowEntries
      ?? WindowSnapshot.windowList().map {
        WindowSnapshot.entries(from: $0, primaryH: ScreenSpace.primaryHeight)
      }
    let occlusion = entries.flatMap { entries -> WindowSnapshot.OcclusionSignature? in
      let snapshot = WindowSnapshot.build(
        entries: entries, focusedPid: pid,
        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        ignoringPids: [getpid()], walkedWindowFrame: model.occlusion?.frame)
      return WindowSnapshot.OcclusionSignature(snapshot: snapshot, pid: pid)
    }
    return preparedModels.resolve(
      pid: pid,
      dirtyToken: dirtyTokens[pid] ?? 0,
      configRevision: configRevision,
      now: DispatchTime.now(),
      occlusion: occlusion)
  }

  /// Flash is not warming `pid`: its speculative walks are held by an AX
  /// event storm, the empty-walk gate or an on-demand declaration.
  func automaticWarmingIsSuppressed(pid: pid_t, bundleIdentifier: String) -> Bool {
    backgroundWalkGate.isGated(pid) || axEventStormingPIDs.contains(pid)
      || !Self.shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: bundleIdentifier)
  }

}

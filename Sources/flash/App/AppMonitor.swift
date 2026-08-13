import AppKit
import ApplicationServices
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
  let registry: SourceRegistry

  let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
  let mainThreadWatchdog = MainThreadWatchdog()
  var focusedElementDidChange: ((pid_t, String) -> Void)?
  var focusedElementMayHaveChanged: ((pid_t) -> Void)?
  var activeWindowMayHaveChanged: ((pid_t, String, AXUIElement?) -> Void)?
  var focusedWindowDidResolve: ((pid_t, AXUIElement) -> Void)?

  // MARK: Config (shared between main + axQueue)
  //
  // Cheap lock — held only for the duration of a struct copy. AppDelegate
  // writes via `updateConfig` when the user edits flash.toml; axQueue
  // reads via `snapshotConfig` at the start of each walk.

  private var config: Config
  private var configLock = os_unfair_lock_s()
  var configRevision: UInt64 = 0

  func snapshotConfig() -> Config {
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
  static let modelFreshnessMs: Int = 1500
  static let modelDebounceMs: Int = 80
  static let modelMaintenanceLeadMs: Int = 250
  static let backgroundModelMinIntervalMs: Int = 2500
  /// Automatic warming that costs this much is no longer a background win:
  /// repeating it every freshness cycle burns a visible fraction of a core.
  /// Keep the completed model, then let focus/config reassess and activation
  /// perform a full on-demand walk when the model becomes stale.
  static let slowAutomaticModelRefreshThresholdMs: Double = 50

  static func automaticModelRefreshIsSlow(elapsedMs: Double) -> Bool {
    elapsedMs >= slowAutomaticModelRefreshThresholdMs
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

  /// Some native apps expose enough AX structure that background warming is
  /// more disruptive than a cold on-demand hint walk. Keep activation explicit
  /// for those apps: focus changes still invalidate stale models, but Flash
  /// does not poke their AX tree just because they became frontmost.
  static let automaticPreparedModelExcludedBundleIdentifiers: Set<String> = [
    "com.apple.Notes"
  ]

  static func shouldRunAutomaticPreparedModelRefresh(bundleIdentifier: String) -> Bool {
    !automaticPreparedModelExcludedBundleIdentifiers.contains(bundleIdentifier)
  }

  init(registry: SourceRegistry, config: Config) {
    self.registry = registry
    self.config = config
  }

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
  /// Pids whose last focus/config-driven automatic walk exceeded the useful
  /// background-work budget. AX/queued/maintenance warming stays paused for
  /// them until another explicit focus/config refresh measures a cheap tree.
  var slowAutomaticModelRefreshPIDs: Set<pid_t> = []
  /// Coalesced model refresh scheduling. The previous implementation
  /// allocated a fresh `DispatchWorkItem` for every observed AX event
  /// and cancelled the previous one. Under scroll storms
  /// (`kAXValueChangedNotification` fires per frame) this churned
  /// 60+ allocations per second on main. The new approach keeps one
  /// dispatch in flight per pid; new events extend the deadline and
  /// the in-flight closure re-arms itself if the burst is still
  /// active when it wakes.
  var modelRefreshArmed: Set<pid_t> = []
  var modelRefreshDeadline: [pid_t: DispatchTime] = [:]
  var modelRefreshReason: [pid_t: String] = [:]
  var maintenanceRefresh: [pid_t: DispatchWorkItem] = [:]
  var lastBackgroundModelRefreshAt: [pid_t: DispatchTime] = [:]
  /// Only the latest activation waiter matters — earlier waiters are
  /// stale activations whose generation has already moved on. A scalar
  /// per pid replaces the previous unbounded array; if a second
  /// activation lands while a walk is in flight, it overwrites the
  /// first instead of stacking.
  var pendingModelCompletion: [pid_t: (PreparedModel?) -> Void] = [:]
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
    /// Accessed only on `axQueue`. Move/resize/minimize/destruction
    /// notifications are emitted by the window element, not the application
    /// element, so the focused window needs its own registrations.
    var focusedWindow: AXUIElement?

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
    private let focusedWindowLock = NSLock()
    private var focusedWindow: AXUIElement?

    init(monitor: AppMonitor, pid: pid_t) {
      self.monitor = monitor
      self.pid = pid
    }

    func setFocusedWindow(_ window: AXUIElement?) {
      focusedWindowLock.lock()
      focusedWindow = window
      focusedWindowLock.unlock()
    }

    func isFocusedWindow(_ element: AXUIElement) -> Bool {
      focusedWindowLock.lock()
      defer { focusedWindowLock.unlock() }
      guard let focusedWindow else { return false }
      return CFEqual(focusedWindow, element)
    }
  }

  static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let ctx = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    guard let monitor = ctx.monitor else { return }
    let pid = ctx.pid
    let notificationName = notification as String
    // AXObserver callbacks already run on the run loop that holds the
    // source — we add it to the main run loop below, so we're already
    // on main here. Hop anyway to make the invariant explicit and
    // bullet-proof against future relocation of the source.
    let isFocusedWindow = ctx.isFocusedWindow(element)
    MainThreadHopper.runOrAsync {
      monitor.onAXEvent(
        pid: pid,
        notification: notificationName,
        observedElementIsFocusedWindow: isFocusedWindow,
        observedWindow: isFocusedWindow ? element : nil)
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
  ]

  /// Reduced set for bundles excluded from automatic model warming
  /// (`automaticPreparedModelExcludedBundleIdentifiers`). For those apps a
  /// prepared model is only built on explicit activation and served within
  /// `modelFreshnessMs`, so churn-level invalidation (value / created /
  /// destroyed / layout / rows) buys almost nothing — while forcing the app
  /// to generate a notification on its main thread for every mutation.
  /// Notes re-rendering its note list during an iCloud sync burst is
  /// exactly the moment that cost hurts. Keep only what drives mode,
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
    guard let bundleIdentifier,
      automaticPreparedModelExcludedBundleIdentifiers.contains(bundleIdentifier)
    else { return observedNotifications }
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

  static func notificationMayChangeObservedWindow(_ notification: String) -> Bool {
    notification == kAXFocusedWindowChangedNotification
      || notification == kAXMainWindowChangedNotification
      || notification == kAXWindowCreatedNotification
      || notification == kAXWindowMiniaturizedNotification
      || notification == kAXWindowDeminiaturizedNotification
      || notification == kAXUIElementDestroyedNotification
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
    // The tap source, AX observer sources, and all mode logic share the
    // main run loop; when it stalls, input stalls system-wide. Record it.
    mainThreadWatchdog.start()
    wakeChromiumAccessibilityForAllRunningApps()
    if let app = NSWorkspace.shared.frontmostApplication {
      onFocusedAppChanged(to: app)
    }
  }

  private func wakeChromiumAccessibilityForAllRunningApps() {
    ChromiumAccessibilityWaker.wakeAllRunningApps(on: axQueue)
  }

  func maybeWakeChromiumAccessibility(for app: NSRunningApplication) {
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

  func lookupPreparedModel(for pid: pid_t) -> PreparedModel? {
    preparedModels.lookup(
      pid: pid,
      dirtyToken: dirtyTokens[pid] ?? 0,
      configRevision: configRevision,
      now: DispatchTime.now(),
      freshnessMs: Self.modelFreshnessMs)
  }

}

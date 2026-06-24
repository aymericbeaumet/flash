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
  let registry: SourceRegistry

  let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
  var focusedElementDidChange: ((pid_t, String) -> Void)?
  var focusedElementMayHaveChanged: ((pid_t) -> Void)?
  var focusedWindowGeometryDidChange: ((pid_t, String) -> Void)?

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

  struct ObserverEntry {
    let observer: AXObserver
    let appElement: AXUIElement
    let context: ObserverContext
  }

  /// The `refcon` blob passed to the C AXObserver callback. Held alive
  /// by `observers[pid]` so it stays valid for the observer's lifetime.
  final class ObserverContext {
    weak var monitor: AppMonitor?
    let pid: pid_t
    init(monitor: AppMonitor, pid: pid_t) {
      self.monitor = monitor
      self.pid = pid
    }
  }

  static let observerCallback: AXObserverCallback = { _, _, notification, refcon in
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
    kAXTitleChangedNotification,
    kAXCreatedNotification,
    kAXUIElementDestroyedNotification,
    kAXRowExpandedNotification,
    kAXRowCollapsedNotification,
  ]

  static func notificationShouldSchedulePreparedModelRefresh(_ notification: String) -> Bool {
    notification != kAXValueChangedNotification as String
      && notification != kAXTitleChangedNotification as String
  }

  static func windowGeometryNotificationRequiresBorderSuspension(_ notification: String) -> Bool {
    notification == kAXWindowMovedNotification
      || notification == kAXWindowResizedNotification
      || notification == kAXFocusedWindowChangedNotification
      || notification == kAXMainWindowChangedNotification
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

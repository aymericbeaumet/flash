import AppKit
import ApplicationServices
import FlashCore

/// Workspace + AX observer install/teardown, and the AX event handlers
/// that bump dirty tokens and re-schedule prepared-model refreshes.
extension AppMonitor {
  func installWorkspaceObservers() {
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

  func onFocusedAppChanged(to app: NSRunningApplication) {
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
    } else {
      refreshFocusedWindowObservation(for: pid)
    }
    scheduleModelRefresh(for: pid, reason: "focus")
    focusedElementMayHaveChanged?(pid)
  }

  private func onAppTerminated(pid: pid_t) {
    teardownObserver(for: pid)
    preparedModels.remove(pid: pid)
    dirtyTokens.removeValue(forKey: pid)
    cancelRefreshWork(for: pid)
  }

  func onAXEvent(
    pid: pid_t,
    notification: String,
    observedElementIsFocusedWindow: Bool
  ) {
    noteAXEventForStormDetection(pid: pid, notification: notification)
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    if Self.notificationShouldSchedulePreparedModelRefresh(notification) {
      scheduleModelRefresh(for: pid, reason: "ax:\(notification)")
    }
    if Self.notificationMayChangeObservedWindow(notification) {
      refreshFocusedWindowObservation(for: pid)
    }
    if Self.notificationMayChangeActiveWindowBorder(
      notification,
      observedElementIsFocusedWindow: observedElementIsFocusedWindow)
    {
      activeWindowMayHaveChanged?(pid, notification)
    }
    if Self.notificationMayChangeFocusedElement(notification) {
      focusedElementMayHaveChanged?(pid)
    }
    focusedElementDidChange?(pid, notification)
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

  // MARK: AX event storm visibility

  /// Count observed AX notifications per pid; flush at most one log line
  /// per window, and only for pids whose event rate is storm-like. See the
  /// constants on `AppMonitor` for why this exists at all.
  func noteAXEventForStormDetection(pid: pid_t, notification: String) {
    let now = DispatchTime.now()
    let elapsedMs = Int(
      (now.uptimeNanoseconds - axEventStormWindowStart.uptimeNanoseconds) / 1_000_000)
    if elapsedMs >= Self.axEventStormWindowMs {
      flushAXEventStormWindow(elapsedMs: elapsedMs)
      axEventStormWindowStart = now
    }
    axEventStormCounts[pid, default: [:]][notification, default: 0] += 1
  }

  private func flushAXEventStormWindow(elapsedMs: Int) {
    defer { axEventStormCounts.removeAll(keepingCapacity: true) }
    for (pid, byName) in axEventStormCounts {
      let total = byName.values.reduce(0, +)
      // Rate, not raw count: the flush is triggered by the first event after
      // the window boundary, so a quiet stretch can leave elapsedMs well
      // above the nominal window and a raw-count check would misfire.
      let perSecond = total * 1000 / max(elapsedMs, 1)
      guard perSecond >= Self.axEventStormThresholdPerSecond else { continue }
      let top = byName.sorted { $0.value > $1.value }.prefix(3)
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
      let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
      FlashLog.debug(
        "[ax] event_storm pid=\(pid) bundle=\(bundle) count=\(total) "
          + "window_ms=\(elapsedMs) top=\(top)")
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

  func installObserver(for pid: pid_t) {
    // Without Accessibility permission, AXObserverAddNotification
    // silently fails — no callbacks ever fire and the model silently
    // serves stale hints because dirty tokens never bump. Skip install
    // entirely; we'll retry on the next focus change, by which time
    // the user has likely granted permission.
    if !PermissionCheck.isAccessibilityTrusted {
      if !warnedMissingAXPermission {
        warnedMissingAXPermission = true
        FlashLog.warn(
          "[ax] observer skipped pid=\(pid): Accessibility permission not granted — "
            + "prepared models go stale until it is")
      }
      return
    }
    warnedMissingAXPermission = false
    var observer: AXObserver?
    let err = AXObserverCreate(pid, Self.observerCallback, &observer)
    guard err == .success, let observer else {
      FlashLog.warn("[ax] observer create failed pid=\(pid) err=\(err.rawValue)")
      return
    }

    let appEl = AXApp.make(pid: pid)
    let ctx = ObserverContext(monitor: self, pid: pid)
    let refcon = Unmanaged.passUnretained(ctx).toOpaque()

    let notifications = Self.observedNotifications(
      forBundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)

    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )

    // Store the entry before the registrations land so a second focus
    // change can't double-install; a notification registered before its
    // first event simply queues on the observer's port.
    observers[pid] = ObserverEntry(
      observer: observer, appElement: appEl, context: ctx, notifications: notifications)

    // Register off-main. Each AXObserverAddNotification is a synchronous
    // IPC into the target app, up to the 1.5 s messaging timeout apiece
    // when the app is slow to answer — and this runs on the FIRST focus
    // after the app launches, exactly when it's busiest (cold start,
    // Notes' initial iCloud sync). N registrations inline here was a
    // multi-second main-thread stall waiting to happen; axQueue already
    // hosts the walk's AX IPC. `ctx` is captured strongly so the refcon
    // stays valid even if teardown drops the entry mid-registration —
    // stragglers then die with the observer's port on release.
    axQueue.async { [weak self, ctx, entry = observers[pid]!] in
      _ = ctx
      for n in notifications {
        _ = AXObserverAddNotification(observer, appEl, n as CFString, refcon)
      }
      self?.replaceFocusedWindowObservation(in: entry)
    }
  }

  private func refreshFocusedWindowObservation(for pid: pid_t) {
    guard let entry = observers[pid] else { return }
    axQueue.async { [weak self, entry] in
      self?.replaceFocusedWindowObservation(in: entry)
    }
  }

  private func replaceFocusedWindowObservation(in entry: ObserverEntry) {
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      entry.appElement, kAXFocusedWindowAttribute as CFString, &raw)
    let next: AXUIElement?
    if status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
      next = (raw as! AXUIElement)
    } else {
      next = nil
    }
    if let current = entry.focusedWindow, let next, CFEqual(current, next) {
      return
    }

    if let current = entry.focusedWindow {
      for notification in Self.focusedWindowObservedNotifications {
        _ = AXObserverRemoveNotification(
          entry.observer, current, notification as CFString)
      }
    }
    entry.focusedWindow = next
    entry.context.setFocusedWindow(next)
    if let next {
      let refcon = Unmanaged.passUnretained(entry.context).toOpaque()
      for notification in Self.focusedWindowObservedNotifications {
        _ = AXObserverAddNotification(
          entry.observer, next, notification as CFString, refcon)
      }
    }
  }

  private func teardownObserver(for pid: pid_t) {
    guard let entry = observers.removeValue(forKey: pid) else { return }
    // Removing the run-loop source stops callback delivery immediately
    // (CFRunLoop is thread-safe); the per-notification deregistrations are
    // IPC — usually against an already-dead process here — so they follow
    // on axQueue, off the input path. `entry` is captured strongly, which
    // keeps observer/element/refcon alive until the removals finish.
    CFRunLoopRemoveSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(entry.observer),
      .commonModes
    )
    axQueue.async {
      if let window = entry.focusedWindow {
        for n in Self.focusedWindowObservedNotifications {
          _ = AXObserverRemoveNotification(entry.observer, window, n as CFString)
        }
        entry.focusedWindow = nil
        entry.context.setFocusedWindow(nil)
      }
      for n in entry.notifications {
        _ = AXObserverRemoveNotification(entry.observer, entry.appElement, n as CFString)
      }
    }
  }

  func teardownAllObservers() {
    for pid in Array(observers.keys) {
      teardownObserver(for: pid)
    }
  }
}

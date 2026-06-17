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

  func onAXEvent(pid: pid_t, notification: String) {
    dirtyTokens[pid, default: 0] &+= 1
    invalidatePreparedModel(for: pid)
    scheduleModelRefresh(for: pid, reason: "ax:\(notification)")
    if Self.windowGeometryNotificationRequiresBorderSuspension(notification) {
      focusedWindowGeometryDidChange?(pid, notification)
    }
    if Self.notificationMayChangeFocusedElement(notification) {
      focusedElementMayHaveChanged?(pid)
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

  func focusedInputSnapshot(pid: pid_t, completion: @escaping (InputFocusSnapshot?) -> Void) {
    axQueue.async {
      let snapshot = NormalModeDispatcher.focusedInputSnapshot(pid: pid)
      DispatchQueue.main.async {
        completion(snapshot)
      }
    }
  }

  func focusedDocumentURL(pid: pid_t, completion: @escaping (String?) -> Void) {
    axQueue.async {
      let url = NormalModeDispatcher.documentURL(pid: pid)
      DispatchQueue.main.async {
        completion(url)
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

  func teardownAllObservers() {
    for pid in Array(observers.keys) {
      teardownObserver(for: pid)
    }
  }
}

import AppKit
import ApplicationServices
import FlashCore

// Active-window border: paints a colored stroke around the focused app's
// frontmost window so the user always knows which window is active — a thin
// green stroke in normal mode, a thicker blue one in insert. Especially useful
// for apps with several windows. Focused-window AX and workspace lifecycle
// notifications drive immediate updates; bounded one-shot WindowServer checks
// after those events absorb delayed state propagation without a resident poll.
// The static helpers below are pure decision functions so NormalModeTests can
// exercise the visibility / equality logic without spinning up an `AppDelegate`.

/// One authoritative front-window read for the stroke; see
/// `scheduleActiveWindowBorderRead`.
struct ActiveWindowBorderRead {
  let pid: pid_t
  let reason: String
  let generation: UInt64
  /// Apply through the reconciliation diff (redraw or hide only on change)
  /// rather than repainting unconditionally.
  let reconciles: Bool
}

enum ActiveWindowBorderSessionSuspension: Hashable {
  case session
  case screens
  case systemSleep
  case secureUI
}

extension AppDelegate {
  /// Which app the stroke must frame.
  ///
  /// `NSWorkspace.shared.frontmostApplication` settles asynchronously: for
  /// tens of milliseconds after an activation notification it still names the
  /// app the user just left. Resolving the border target through it drew the
  /// stroke around the *previous* window, and nothing corrected it until the
  /// new app happened to emit an AX geometry notification — several hundred
  /// milliseconds, or the next app switch. The notification names the app that
  /// activated, so when one is in hand it wins.
  static func activeWindowBorderTargetPID(
    activatedPID: pid_t?, frontmostPID: pid_t?
  ) -> pid_t? {
    activatedPID ?? frontmostPID
  }

  func updateActiveWindowBorder(reason: String, activated: NSRunningApplication? = nil) {
    guard
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "hidden_\(reason)")
      return
    }
    FlashLog.trace("[mode] active_border_update reason=\(reason) mode=\(flashMode)")
    activeWindowBorderUpdateGeneration &+= 1
    guard let app = activeWindowBorderApplication(activated: activated) else {
      applyActiveWindowBorder(frame: nil)
      return
    }
    let pid = app.processIdentifier
    // Paint what the AX notifications last told us about this app right away.
    // The authoritative read below supersedes it under the same generation, so
    // a stale entry self-corrects instead of persisting.
    if let cached = activeWindowBorderFrameCache[pid] {
      FlashLog.trace(
        "[mode] active_border_cached reason=\(reason) pid=\(pid) frame=\(Self.describe(cached))")
      applyActiveWindowBorder(frame: cached)
    }
    scheduleActiveWindowBorderRead(
      ActiveWindowBorderRead(
        pid: pid, reason: reason, generation: activeWindowBorderUpdateGeneration,
        reconciles: false))
  }

  /// Read the authoritative front-window frame on the next main-queue turn,
  /// coalescing every request made before then into one read: the latest wins.
  ///
  /// The read runs on main on purpose. `CGWindowListCopyWindowInfo` first
  /// synchronizes with this process's pending Core Animation transaction while
  /// holding the WindowServer connection lock; a main-thread commit carrying
  /// WindowServer actions (the status-bar render every app switch performs)
  /// needs that same lock. Issued from another queue the two waited on each
  /// other until SkyLight's 500 ms timeout (sampled:
  /// `SLSConnectionSynchronizeSLSCATransaction` against
  /// `SLSConnectionSetLastSLSCATransaction`), freezing the main thread and
  /// leaving the stroke on the previous window for half a second on every
  /// switch. On main the read can never overlap a commit, and costs about a
  /// millisecond.
  private func scheduleActiveWindowBorderRead(_ read: ActiveWindowBorderRead) {
    let alreadyScheduled = activeWindowBorderPendingRead != nil
    activeWindowBorderPendingRead = read
    guard !alreadyScheduled else { return }
    DispatchQueue.main.async { [weak self] in self?.performActiveWindowBorderRead() }
  }

  private func performActiveWindowBorderRead() {
    guard let read = activeWindowBorderPendingRead else { return }
    activeWindowBorderPendingRead = nil
    // A hide, a geometry event or a newer identity superseded it.
    guard read.generation == activeWindowBorderUpdateGeneration else { return }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let frame = AppMonitor.topApplicationWindowFrame(
      for: read.pid, primaryH: monitor.primaryScreenHeight())
    FlashLog.trace(
      "[mode] active_border_frame reason=\(read.reason) pid=\(read.pid) "
        + "read_ms=\(Self.elapsedMs(startedAt, DispatchTime.now().uptimeNanoseconds)) "
        + "frame=\(Self.describe(frame))")
    rememberActiveWindowBorderFrame(frame, for: read.pid)
    if read.reconciles {
      applyActiveWindowBorderReconciliation(frame: frame, reason: read.reason)
    } else {
      applyActiveWindowBorder(frame: frame)
    }
  }

  /// Record what the front window of `pid` looks like now, so the next
  /// activation of that app can paint before any WindowServer round trip.
  func rememberActiveWindowBorderFrame(_ frame: CGRect?, for pid: pid_t) {
    if let frame {
      activeWindowBorderFrameCache[pid] = frame
    } else {
      activeWindowBorderFrameCache.removeValue(forKey: pid)
    }
  }

  func forgetActiveWindowBorderFrames(for pid: pid_t) {
    activeWindowBorderFrameCache.removeValue(forKey: pid)
  }

  /// A move or resize names the window that changed, so its geometry is one
  /// AX read on the element that fired — not a `CGWindowListCopyWindowInfo`
  /// scan of every on-screen window, which the old path ran three times per
  /// event (once on main to resolve the context, once to place the stroke,
  /// once more on the settle tick). That scan cost is what made the border
  /// trail a dragged window instead of riding with it, so there is no settle
  /// poll here: the next AX event is the next truth.
  func observedWindowGeometryDidChange(
    pid: pid_t,
    window: AXUIElement,
    notification: String,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let borderVisible = Self.activeWindowBorderShouldBeVisible(
      configEnabled: overlay.overlayConfig.windowBorder,
      modeBadgeEnabled: modeBadgeEnabled,
      hasHints: hintSession.isActive,
      sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    FlashLog.trace("[mode] active_border_geometry reason=\(notification) visible=\(borderVisible)")
    if !borderVisible { hideActiveWindowBorder(reason: "hidden_\(notification)") }
    activeWindowBorderUpdateGeneration &+= 1
    let generation = activeWindowBorderUpdateGeneration
    let primaryHeight = monitor.primaryScreenHeight()
    monitor.geometryQueue.async { [weak self] in
      let frame = WindowMover.readWindowFrameInNSCoords(
        window: window, primaryHeight: primaryHeight)
      DispatchQueue.main.async {
        guard let self else { return }
        if let frame {
          self.windowLayoutManager.observedWindowFrameChange(
            pid: pid, window: window, frame: frame, notification: notification,
            statusBarReservesSpace: statusBarReservesSpace,
            statusBarMonitor: statusBarMonitor)
        }
        self.rememberActiveWindowBorderFrame(frame, for: pid)
        guard borderVisible, self.activeWindowBorderUpdateGeneration == generation else { return }
        self.applyActiveWindowBorder(frame: frame)
      }
    }
  }

  static func elapsedMs(_ from: UInt64, _ to: UInt64) -> String {
    String(format: "%.1f", Double(to &- from) / 1_000_000)
  }

  static func describe(_ frame: CGRect?) -> String {
    guard let frame else { return "nil" }
    return "(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
  }

  private func applyActiveWindowBorder(frame: CGRect?) {
    let style = resolvedActiveWindowBorderStyle()
    overlay.setActiveWindowBorder(
      around: frame, color: style.color, lineWidth: style.lineWidth,
      glow: style.glow)
    activeWindowBorderTrackedFrame = frame
  }

  func hideActiveWindowBorder(reason: String) {
    activeWindowBorderUpdateGeneration &+= 1
    overlay.setActiveWindowBorder(around: nil)
    activeWindowBorderTrackedFrame = nil
    cancelActiveWindowBorderReconciliations(reason: reason)
  }

  func cancelActiveWindowBorderReconciliations(reason: String) {
    activeWindowBorderReconciliationGeneration &+= 1
    FlashLog.trace("[mode] active_border_reconcile_cancel reason=\(reason)")
  }

  func scheduleActiveWindowBorderReconciliation(delaysMs: [Int], reason: String) {
    guard !delaysMs.isEmpty,
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else { return }
    activeWindowBorderReconciliationGeneration &+= 1
    let generation = activeWindowBorderReconciliationGeneration
    for delayMs in delaysMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self, self.activeWindowBorderReconciliationGeneration == generation else {
          return
        }
        self.reconcileActiveWindowBorder(reason: "\(reason)_settled_\(delayMs)ms")
      }
    }
  }

  func reconcileActiveWindowBorder(reason: String) {
    guard
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "reconcile_state")
      return
    }

    activeWindowBorderUpdateGeneration &+= 1
    guard let app = activeWindowBorderApplication() else {
      applyActiveWindowBorderReconciliation(frame: nil, reason: reason)
      return
    }
    scheduleActiveWindowBorderRead(
      ActiveWindowBorderRead(
        pid: app.processIdentifier, reason: reason,
        generation: activeWindowBorderUpdateGeneration, reconciles: true))
  }

  private func applyActiveWindowBorderReconciliation(frame: CGRect?, reason: String) {
    switch Self.activeWindowBorderReconciliationAction(
      trackedFrame: activeWindowBorderTrackedFrame,
      currentFrame: frame,
      tolerance: Self.activeWindowBorderFrameTolerance)
    {
    case .none:
      return
    case .hide:
      FlashLog.trace("[mode] active_border_reconcile action=hide reason=\(reason)")
      activeWindowBorderTrackedFrame = nil
      overlay.setActiveWindowBorder(around: nil)
    case .redraw:
      FlashLog.trace("[mode] active_border_reconcile action=redraw reason=\(reason)")
      activeWindowBorderTrackedFrame = frame
      let style = resolvedActiveWindowBorderStyle()
      overlay.setActiveWindowBorder(
        around: frame, color: style.color, lineWidth: style.lineWidth, glow: style.glow)
    }
  }

  func setActiveWindowBorderSessionSuspended(
    _ suspended: Bool,
    source: ActiveWindowBorderSessionSuspension,
    reason: String
  ) {
    if suspended {
      terminalInputMappings?.flush()
      overlay?.hideStatusBarPopup()
      let inserted = activeWindowBorderSessionSuspensions.insert(source).inserted
      guard inserted else { return }
      FlashLog.trace("[mode] active_border_session_suspend reason=\(reason)")
      hideActiveWindowBorder(reason: reason)
      return
    }

    guard activeWindowBorderSessionSuspensions.remove(source) != nil else { return }
    FlashLog.trace("[mode] active_border_session_resume reason=\(reason)")
    guard activeWindowBorderSessionSuspensions.isEmpty else { return }
    reconcileFrontmostApplication(reason: reason)
    updateActiveWindowBorder(reason: reason)
    scheduleActiveWindowBorderReconciliation(
      delaysMs: Self.activeWindowBorderRecoveryDelaysMs, reason: reason)
  }

  static func activeWindowBorderShouldBeVisible(
    configEnabled: Bool,
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    sessionActive: Bool
  ) -> Bool {
    // The active window carries a frame in BOTH modes — a thin green stroke in
    // normal, a thicker blue one in insert — so the focused window stays
    // identifiable (most useful for apps with several windows). The user can
    // opt out wholesale (`[overlay] window_border = false`). Advanced mode
    // (an all-mode `leave_mode` or `enter_normal_mode` binding) is the gate: without it
    // there's no normal/insert distinction to visualise. Suspended while hints
    // are up (chips aren't double-framed) and whenever the user session or
    // displays are inactive, so Flash never survives over the lock surface.
    guard configEnabled else { return false }
    guard modeBadgeEnabled else { return false }
    if hasHints { return false }
    if !sessionActive { return false }
    return true
  }

  enum ActiveWindowBorderReconciliationAction: Equatable {
    case none
    case hide
    case redraw
  }

  static func activeWindowBorderReconciliationAction(
    trackedFrame: CGRect?,
    currentFrame: CGRect?,
    tolerance: CGFloat
  ) -> ActiveWindowBorderReconciliationAction {
    if currentFrame == nil { return trackedFrame == nil ? .none : .hide }
    return activeWindowBorderFramesApproximatelyEqual(
      trackedFrame, currentFrame, tolerance: tolerance) ? .none : .redraw
  }

  static func activeWindowBorderSecureUISuspendsSession(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return bundleIdentifier == "com.apple.loginwindow"
      || bundleIdentifier.hasPrefix("com.apple.ScreenSaver")
  }

  /// Border stroke style per badge style: a thin green stroke in normal, a thin
  /// purple one in command (the mode-badge accents), and a thicker,
  /// softly-glowing blue one in insert. Normal and command share insert's outer
  /// edge — only insert grows inward (see `activeWindowBorderLocalRect`).
  static func activeWindowBorderStyle(
    for badgeStyle: OverlayModeBadgeStyle,
    sizeOverride: Double = 0,
    colorOverride: CGColor? = nil
  )
    -> (color: CGColor, lineWidth: CGFloat, glow: Bool)
  {
    var style: (color: CGColor, lineWidth: CGFloat, glow: Bool)
    switch badgeStyle {
    case .normal: style = (OverlayPanel.nordAuroraGreenCG, 1, false)
    case .insert: style = (OverlayPanel.nordFrost2CG, 2, true)
    case .command: style = (OverlayPanel.nordAuroraPurpleCG, 1, false)
    }
    // `[overlay] window_border_size` / `window_border_color` apply across
    // every mode; the defaults (0 / nil) keep the per-mode identity above.
    if sizeOverride > 0 { style.lineWidth = sizeOverride }
    if let colorOverride { style.color = colorOverride }
    return style
  }

  /// The configured style for the current mode: the per-mode defaults with
  /// `[overlay]` size/color overrides applied.
  func resolvedActiveWindowBorderStyle() -> (color: CGColor, lineWidth: CGFloat, glow: Bool) {
    let cfg = overlay.overlayConfig
    let colorOverride =
      cfg.windowBorderColor.isEmpty
      ? nil : overlay.nsColor(fromHex: cfg.windowBorderColor)?.cgColor
    return Self.activeWindowBorderStyle(
      for: modeStore.mode.badgeStyle,
      sizeOverride: cfg.windowBorderSize,
      colorOverride: colorOverride)
  }

  static func activeWindowBorderFramesApproximatelyEqual(
    _ lhs: CGRect?,
    _ rhs: CGRect?,
    tolerance: CGFloat
  ) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
      return true
    case (.some(let lhs), .some(let rhs)):
      return abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
    default:
      return false
    }
  }

  /// Mode is global/sticky, so the border target is simply the currently
  /// focused non-Flash app (the old per-insert "owner pid" is gone). Identity
  /// only — no WindowServer geometry.
  private func activeWindowBorderApplication(
    activated: NSRunningApplication? = nil
  ) -> NSRunningApplication? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    let preferred =
      activated.flatMap { $0.bundleIdentifier == flashBundleIdentifier ? nil : $0 }
    guard let app = preferred ?? currentNonFlashRunningApplication(),
      !app.isTerminated,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: app.bundleIdentifier)
    else { return nil }
    return app
  }

}

import AppKit
import ApplicationServices
import FlashCore

// Active modes paint a colored stroke around their input target: the focused
// app in NORMAL/COMMAND, or the popup itself in TERMINAL. PASSTHROUGH is quiet.
// Focused-window AX and workspace lifecycle
// notifications drive immediate updates; bounded one-shot WindowServer checks
// after those events absorb delayed state propagation without a resident poll.
// The static helpers below are pure decision functions so NormalModeTests can
// exercise the visibility / equality logic without spinning up an `AppDelegate`.

enum ActiveWindowBorderSessionSuspension: Hashable {
  case session
  case screens
  case systemSleep
  case secureUI
}

extension AppDelegate {
  func updateActiveWindowBorder(reason: String) {
    guard
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        modeStyle: modeStore.mode.badgeStyle,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "hidden_\(reason)")
      return
    }
    if modeStore.mode.isTerminal {
      hideActiveWindowBorder(reason: "terminal_\(reason)")
      let style = resolvedActiveWindowBorderStyle()
      overlay.statusPopupController.setActiveModeBorder(
        color: style.color, lineWidth: style.lineWidth, glow: style.glow)
      return
    }
    overlay.statusPopupController.setActiveModeBorder()
    FlashLog.trace("[mode] active_border_update reason=\(reason) mode=\(flashMode)")
    // Identity resolves on main; the WindowServer frame lookup is a
    // synchronous round trip, so it runs on the geometry queue and the stroke
    // is applied one hop later unless a newer update or hide superseded it.
    activeWindowBorderUpdateGeneration &+= 1
    let generation = activeWindowBorderUpdateGeneration
    guard let app = activeWindowBorderApplication() else {
      applyActiveWindowBorder(frame: nil)
      return
    }
    let pid = app.processIdentifier
    let primaryH = monitor.primaryScreenHeight()
    let monitor: AppMonitor = self.monitor
    monitor.geometryQueue.async { [weak self] in
      let frame = AppMonitor.topApplicationWindowFrame(for: pid, primaryH: primaryH)
      DispatchQueue.main.async {
        guard let self, self.activeWindowBorderUpdateGeneration == generation else { return }
        self.applyActiveWindowBorder(frame: frame)
      }
    }
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
    overlay.statusPopupController.setActiveModeBorder()
    activeWindowBorderTrackedFrame = nil
    cancelActiveWindowBorderReconciliations(reason: reason)
  }

  func cancelActiveWindowBorderReconciliations(reason: String) {
    activeWindowBorderReconciliationGeneration &+= 1
    FlashLog.trace("[mode] active_border_reconcile_cancel reason=\(reason)")
  }

  func scheduleActiveWindowBorderReconciliation(delaysMs: [Int], reason: String) {
    guard !delaysMs.isEmpty, !modeStore.mode.isTerminal,
      Self.activeWindowBorderShouldBeVisible(
        configEnabled: overlay.overlayConfig.windowBorder,
        modeBadgeEnabled: modeBadgeEnabled,
        modeStyle: modeStore.mode.badgeStyle,
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
        modeStyle: modeStore.mode.badgeStyle,
        hasHints: hintSession.isActive,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "reconcile_state")
      return
    }
    if modeStore.mode.isTerminal {
      updateActiveWindowBorder(reason: reason)
      return
    }

    let frame = activeWindowBorderContext()?.frontWindowFrame
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
    modeStyle: OverlayModeBadgeStyle,
    hasHints: Bool,
    sessionActive: Bool
  ) -> Bool {
    // Only active Flash modes draw emphasis. Hints and inactive user sessions
    // suppress it; the configured window-border switch remains the opt-out.
    guard configEnabled else { return false }
    guard modeBadgeEnabled || modeStyle == .terminal else { return false }
    guard modeStyle != .passthrough else { return false }
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

  /// Active modes share the same stroke weight and focus glow; their colors
  /// match the mode pills.
  static func activeWindowBorderStyle(
    for badgeStyle: OverlayModeBadgeStyle,
    sizeOverride: Double = 0,
    colorOverride: CGColor? = nil
  )
    -> (color: CGColor, lineWidth: CGFloat, glow: Bool)
  {
    var style: (color: CGColor, lineWidth: CGFloat, glow: Bool)
    switch badgeStyle {
    case .normal: style = (OverlayPanel.nordAuroraGreenCG, 2, true)
    case .terminal: style = (OverlayPanel.nordFrost2CG, 2, true)
    case .passthrough: return (NSColor.clear.cgColor, 0, false)
    case .command: style = (OverlayPanel.nordAuroraPurpleCG, 2, true)
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
  /// focused non-Flash app. Identity
  /// only — no WindowServer geometry.
  private func activeWindowBorderApplication() -> NSRunningApplication? {
    guard let app = currentNonFlashRunningApplication(),
      !app.isTerminated,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: app.bundleIdentifier)
    else { return nil }
    return app
  }

  /// Reconciliation ticks run off the keypress path and may resolve the frame
  /// synchronously in one WindowServer snapshot.
  private func activeWindowBorderContext() -> AppContext? {
    guard let app = activeWindowBorderApplication() else { return nil }
    return monitor.appWindowContext(for: app.processIdentifier)
  }

}

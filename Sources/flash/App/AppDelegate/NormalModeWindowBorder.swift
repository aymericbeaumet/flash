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
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "hidden_\(reason)")
      return
    }
    let frame = activeWindowBorderContext()?.frontWindowFrame
    FlashLog.trace("[mode] active_border_update reason=\(reason) mode=\(flashMode)")
    let style = Self.activeWindowBorderStyle(for: modeStore.mode.badgeStyle)
    overlay.setActiveWindowBorder(
      around: frame, color: style.color, lineWidth: style.lineWidth,
      glow: style.glow)
    activeWindowBorderTrackedFrame = frame
  }

  func hideActiveWindowBorder(reason: String) {
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
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty,
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
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty,
        sessionActive: activeWindowBorderSessionSuspensions.isEmpty)
    else {
      hideActiveWindowBorder(reason: "reconcile_state")
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
      let style = Self.activeWindowBorderStyle(for: modeStore.mode.badgeStyle)
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
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    sessionActive: Bool
  ) -> Bool {
    // The active window carries a frame in BOTH modes — a thin green stroke in
    // normal, a thicker blue one in insert — so the focused window stays
    // identifiable (most useful for apps with several windows). Advanced mode
    // (`["flash", "enter_normal_mode"]` bound somewhere) is the gate: without it
    // there's no normal/insert distinction to visualise. Suspended while hints
    // are up (chips aren't double-framed) and whenever the user session or
    // displays are inactive, so Flash never survives over the lock surface.
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
  static func activeWindowBorderStyle(for badgeStyle: OverlayModeBadgeStyle)
    -> (color: CGColor, lineWidth: CGFloat, glow: Bool)
  {
    switch badgeStyle {
    case .normal: return (OverlayPanel.nordAuroraGreenCG, 1, false)
    case .insert: return (OverlayPanel.nordFrost2CG, 2, true)
    case .command: return (OverlayPanel.nordAuroraPurpleCG, 1, false)
    }
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

  private func activeWindowBorderContext() -> AppContext? {
    // Mode is global/sticky, so the typing target is simply the currently
    // focused non-Flash app (the old per-insert "owner pid" is gone). Resolve
    // its WindowServer frame in one snapshot: `currentNonFlashContext` also
    // snapshots window ordering, which would duplicate this reconciliation.
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    let frontmost = NSWorkspace.shared.frontmostApplication
    let app: NSRunningApplication?
    if let frontmost, frontmost.bundleIdentifier != flashBundleIdentifier {
      app = frontmost
    } else if let observedFocusedAppPID {
      app = NSRunningApplication(processIdentifier: observedFocusedAppPID)
    } else {
      app = nil
    }
    guard let app,
      !app.isTerminated,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: app.bundleIdentifier)
    else { return nil }
    return monitor.appWindowContext(for: app.processIdentifier)
  }

}

import AppKit
import ApplicationServices
import FlashCore

// Active-window border: paints a colored stroke around the focused app's
// frontmost window so the user always knows which window is active — a thin
// green stroke in normal mode, a thicker blue one in insert. Especially useful
// for apps with several windows. The timer-driven poll catches window
// moves/resizes that AX doesn't notify us about, and the static helpers below
// are pure decision functions so NormalModeTests can exercise the
// visibility/equality logic without spinning up an `AppDelegate`.

extension AppDelegate {
  func updateActiveWindowBorder(reason: String) {
    let context = activeWindowBorderContext()
    guard
      Self.activeWindowBorderShouldBeVisible(
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty,
        windowGeometryChangeInProgress: windowGeometryChangeInProgress)
    else {
      overlay.setActiveWindowBorder(around: nil)
      if !windowGeometryChangeInProgress {
        stopActiveWindowBorderTracking(reason: "hidden_\(reason)")
      }
      return
    }
    FlashLog.trace("[mode] active_border_update reason=\(reason) mode=\(flashMode)")
    let style = Self.activeWindowBorderStyle(for: flashMode)
    overlay.setActiveWindowBorder(
      around: context?.frontWindowFrame, color: style.color, lineWidth: style.lineWidth)
    startActiveWindowBorderTracking(frame: context?.frontWindowFrame, reason: reason)
  }

  func startActiveWindowBorderTracking(frame: CGRect?, reason: String) {
    activeWindowBorderTrackedFrame = frame
    guard activeWindowBorderTrackingTimer == nil else { return }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .milliseconds(Self.activeWindowBorderTrackingIntervalMs),
      repeating: .milliseconds(Self.activeWindowBorderTrackingIntervalMs),
      leeway: .milliseconds(Self.activeWindowBorderTrackingLeewayMs))
    timer.setEventHandler { [weak self] in
      self?.pollActiveWindowBorderFrame()
    }
    activeWindowBorderTrackingTimer = timer
    FlashLog.trace("[mode] insert_border_tracking_start reason=\(reason)")
    timer.resume()
  }

  func stopActiveWindowBorderTracking(reason: String) {
    guard let timer = activeWindowBorderTrackingTimer else {
      activeWindowBorderTrackedFrame = nil
      return
    }
    timer.cancel()
    activeWindowBorderTrackingTimer = nil
    activeWindowBorderTrackedFrame = nil
    FlashLog.trace("[mode] insert_border_tracking_stop reason=\(reason)")
  }

  func pollActiveWindowBorderFrame() {
    guard
      Self.activeWindowBorderTrackingShouldRun(
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty)
    else {
      stopActiveWindowBorderTracking(reason: "state")
      return
    }

    let frame = activeWindowBorderContext()?.frontWindowFrame
    guard
      Self.activeWindowBorderPollShouldUpdate(
        trackedFrame: activeWindowBorderTrackedFrame,
        currentFrame: frame)
    else { return }
    guard
      !Self.activeWindowBorderFramesApproximatelyEqual(
        activeWindowBorderTrackedFrame,
        frame,
        tolerance: Self.activeWindowBorderFrameTolerance)
    else { return }

    if activeWindowBorderTrackedFrame == nil {
      // The border is appearing — the frame became available after a nil sample
      // (e.g. the window wasn't reported yet at insert entry). Draw it in place
      // rather than running the hide-during-change dance, which would blank the
      // border for ~160ms exactly as it should first show.
      activeWindowBorderTrackedFrame = frame
      let style = Self.activeWindowBorderStyle(for: flashMode)
      overlay.setActiveWindowBorder(around: frame, color: style.color, lineWidth: style.lineWidth)
    } else {
      beginTrackedWindowGeometryChange(reason: "frame_poll", frame: frame)
    }
  }

  static func activeWindowBorderPollShouldUpdate(
    trackedFrame: CGRect?,
    currentFrame: CGRect?
  ) -> Bool {
    // WindowServer can transiently fail to report an app window while a
    // terminal or browser is repainting. Treat a missing sample as "no
    // update" when we already have a frame, otherwise insert-mode typing can
    // make the active border disappear and reappear even though the mode never
    // changed. Real moves/resizes still arrive via AX or a later non-nil poll.
    if trackedFrame != nil, currentFrame == nil { return false }
    return true
  }

  func beginTrackedWindowGeometryChange(reason: String, frame: CGRect?) {
    activeWindowBorderTrackedFrame = frame
    windowGeometryChangeToken &+= 1
    let token = windowGeometryChangeToken
    modeWillBeginWindowGeometryChange(reason: reason)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.windowGeometryQuietMs)) {
      [weak self] in
      guard let self, self.windowGeometryChangeToken == token else { return }
      self.modeDidEndWindowGeometryChange(reason: reason)
    }
  }

  static func activeWindowBorderShouldBeVisible(
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    windowGeometryChangeInProgress: Bool
  ) -> Bool {
    // The active window carries a frame in BOTH modes — a thin green stroke in
    // normal, a thicker blue one in insert — so the focused window stays
    // identifiable (most useful for apps with several windows). Advanced mode
    // (`["flash", "enter_normal_mode"]` bound somewhere) is the gate: without it
    // there's no normal/insert distinction to visualise. Suspended while hints
    // are up (chips aren't double-framed) and while the window is moving/resizing
    // (the stroke would visibly trail the chrome).
    guard modeBadgeEnabled else { return false }
    if hasHints { return false }
    if windowGeometryChangeInProgress { return false }
    return true
  }

  static func activeWindowBorderTrackingShouldRun(
    modeBadgeEnabled: Bool,
    hasHints: Bool
  ) -> Bool {
    modeBadgeEnabled && !hasHints
  }

  /// Border stroke style per mode: a thin green stroke in normal (the
  /// normal-mode accent), a thicker blue one in insert.
  static func activeWindowBorderStyle(for mode: FlashMode) -> (color: CGColor, lineWidth: CGFloat) {
    switch mode {
    case .normal: return (OverlayPanel.nordAuroraGreenCG, 1)
    case .insert: return (OverlayPanel.nordFrost2CG, 2)
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
    // focused non-Flash app (the old per-insert "owner pid" is gone).
    guard let focused = currentNonFlashContext() else { return nil }
    return monitor.appWindowContext(for: focused.processID)
  }

}

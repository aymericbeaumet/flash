import AppKit
import ApplicationServices
import FlashCore

// Insert-mode active-window border: paints a colored stroke around the focused
// app's frontmost window so the user keeps a visual signal of which app will
// receive typing while advanced mode is configured. The timer-driven poll
// catches window moves/resizes that AX doesn't notify us about, and the static
// helpers below are pure decision functions so NormalModeTests can exercise
// the visibility/equality logic without spinning up an `AppDelegate`.

extension AppDelegate {
  func updateInsertModeActiveWindowBorder(reason: String) {
    let context = currentNonFlashContext()
    guard
      Self.activeWindowBorderShouldBeVisible(
        mode: flashMode,
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
    FlashLog.trace("[mode] insert_border_update reason=\(reason)")
    overlay.setActiveWindowBorder(around: context?.frontWindowFrame)
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
        mode: flashMode,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty)
    else {
      stopActiveWindowBorderTracking(reason: "state")
      return
    }

    let frame = currentNonFlashContext()?.frontWindowFrame
    guard
      !Self.activeWindowBorderFramesApproximatelyEqual(
        activeWindowBorderTrackedFrame,
        frame,
        tolerance: Self.activeWindowBorderFrameTolerance)
    else { return }

    beginTrackedWindowGeometryChange(reason: "frame_poll", frame: frame)
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
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    windowGeometryChangeInProgress: Bool
  ) -> Bool {
    // Insert mode keeps the status bar visible and adds a colored frame
    // around the focused window so the typing target remains obvious.
    // Advanced mode (`["flash", "enter_normal_mode"]` bound somewhere) is the gate
    // — without it Flash has no normal/insert distinction to visualise.
    // The border is suspended while hints are up so chips aren't framed
    // by a redundant outline, and while the window is moving/resizing
    // so the stroke doesn't lag visibly behind the chrome.
    guard mode == .insert, modeBadgeEnabled else { return false }
    if hasHints { return false }
    if windowGeometryChangeInProgress { return false }
    return true
  }

  static func activeWindowBorderTrackingShouldRun(
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    hasHints: Bool
  ) -> Bool {
    modeBadgeEnabled && mode == .insert && !hasHints
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

}

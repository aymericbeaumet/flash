import AppKit
import ApplicationServices
import FlashCore

// Vertical step/page keys post mouse-wheel lines directly. Horizontal and edge
// commands keep their focused-window scroller and source-specific behavior.

extension AppDelegate {
  func scrollNormalMode(
    _ kind: NormalModeDispatcher.ScrollKind,
    repeatCount: Int = 1
  ) {
    if let lines = NormalModeDispatcher.scrollLineDelta(for: kind, repeatCount: repeatCount) {
      guard NormalModeDispatcher.synthesizeLineScroll(lines: lines, at: lineScrollLocation())
      else { return }
      extendHeldSelection(after: kind)
      if let pid = observedFocusedAppPID ?? normalModeTargetPID {
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
      }
      return
    }
    // Whatever a smooth line scroll still has to post would move the page
    // after this scroll lands.
    if FlashTunables.scrollSmoothMs > 0 { ActionDispatcher.cancelWheelSteps() }
    // gg/G run the source-command policy: a source such as tmux scrolls
    // inside its own buffer, else an app's declared chord (a browser's
    // Cmd-Up), else the focused-window scroller.
    if kind == .top || kind == .bottom {
      performSourceCommand(URLCommand.scroll(kind).requiredSourceCommand)
      extendHeldSelection(after: kind)
      return
    }
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal] no target app for \(kind)")
      applyModeOverlay()
      return
    }
    scrollViaScroller(kind, context: context, repeats: normalizedRepeatCount(repeatCount))
  }

  /// Where a line scroll lands (`lineScrollPoint`), from what main already
  /// holds: the pointer, the focused window's frame the border strokes, and
  /// the scroll area the focus-region read found. No IPC.
  func lineScrollLocation() -> CGPoint? {
    let pid = lastFocusedApplicationPID ?? normalModeTargetPID
    let window =
      overlay?.activeWindowBorderFrame ?? pid.flatMap { activeWindowBorderFrameCache[$0] }
    let area = pid.flatMap { focusRegionTracker.cachedReading(for: $0)?.scrollFrame }
    return NormalModeDispatcher.lineScrollPoint(
      pointer: NSEvent.mouseLocation, window: window, scrollArea: area)
  }

  /// The focused-window scroller walks the AX tree (up to ~600 nodes) for the
  /// scrollable pane and reads the window list for its frame, so it runs on
  /// `axQueue`, never on main where the keyboard tap lives. Rapid repeats
  /// serialize on the queue instead of blocking input. The mode surface is
  /// untouched by a scroll, so nothing re-renders afterwards.
  func scrollViaScroller(
    _ kind: NormalModeDispatcher.ScrollKind,
    context: AppContext,
    repeats: Int
  ) {
    let pid = context.processID
    let bundleID = context.bundleIdentifier
    let fallbackFrame = context.frontWindowFrame
    let primaryH = ScreenSpace.primaryHeight
    let monitor: AppMonitor = self.monitor
    monitor.axQueue.async {
      let windowFrame = AppMonitor.topWindowFrame(for: pid, primaryH: primaryH) ?? fallbackFrame
      var didScroll = false
      for _ in 0..<repeats {
        if NormalModeDispatcher.scroll(kind, pid: pid, bundleID: bundleID, windowFrame: windowFrame)
        {
          didScroll = true
        }
      }
      guard didScroll else { return }
      DispatchQueue.main.async { [weak self] in
        self?.extendHeldSelection(after: kind)
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
      }
    }
  }

  /// HOLD: the scroll extends a text selection, as a Vim motion extends it
  /// from the cursor. `gg` / `G` drag the pointer to the window's top /
  /// bottom edge, so the selection reaches the first / last line. In HOLD
  /// and HOLD every scroll then re-posts the held button's drag where the
  /// pointer is, so the app sees the pointer over what scrolled under it.
  /// Without a held button, nothing.
  func extendHeldSelection(after kind: NormalModeDispatcher.ScrollKind) {
    guard ActionDispatcher.heldButton != nil else { return }
    // Only a selection extends to the first / last line; a drag stays put.
    if kind == .top || kind == .bottom, modeStore.mode.isHold,
      let window = normalModeContext()?.frontWindowFrame, !window.isNull, !window.isEmpty
    {
      ActionDispatcher.moveCursor(
        to: ScreenPoint<NSSpace>(
          HoldSelection.edgePoint(
            top: kind == .top, pointer: NSEvent.mouseLocation, window: window)))
    }
    ActionDispatcher.catchUpHeldSelection(afterScrollMs: FlashTunables.scrollSmoothMs)
    FlashLog.trace("[drag] selection_follows scroll=\(kind)")
  }
}

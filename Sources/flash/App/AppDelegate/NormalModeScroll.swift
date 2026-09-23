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
      if NormalModeDispatcher.synthesizeLineScroll(lines: lines),
        let pid = observedFocusedAppPID ?? normalModeTargetPID
      {
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
      }
      return
    }
    // gg/G run the source-action policy: a source such as tmux scrolls inside
    // its own buffer, else an app's declared chord (a browser's Cmd-Up), else
    // the focused-window scroller.
    if kind == .top || kind == .bottom {
      performSourceAction(kind == .top ? .scrollTop : .scrollBottom) { [weak self] context, count in
        self?.scrollViaScroller(kind, context: context, repeats: count)
      }
      return
    }
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for \(kind)")
      applyModeOverlay()
      return
    }
    scrollViaScroller(kind, context: context, repeats: normalizedRepeatCount(repeatCount))
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
    let primaryH = monitor.primaryScreenHeight()
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
      DispatchQueue.main.async {
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
      }
    }
  }
}

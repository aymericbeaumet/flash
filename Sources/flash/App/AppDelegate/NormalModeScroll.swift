import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

// Scroll dispatch for normal mode: `j`/`k`/`gg`/`G`/`<c-d>`/`<c-u>` and the
// hermetic Scroller fallback. `gg`/`G` (top/bottom) ask any registered
// `scrollExtremes` source first (tmux runs `history-top` / `cancel`
// instead of bashing the wheel), then fall through to the browser-edge or
// generic wheel paths.

extension AppDelegate {
  func scrollNormalMode(
    _ kind: NormalModeDispatcher.ScrollKind,
    repeatCount: Int = 1
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for \(kind)")
      applyModeOverlay()
      return
    }
    // gg/G: try a `scrollExtremes` source first (e.g. the tmux plugin
    // runs `tmux send-keys -X history-top` / `-X cancel`, which moves
    // *inside* the live buffer rather than blasting wheel ticks at a
    // pane that's already at the bottom). Falls through to the
    // hermetic Scroller path when no source claims it.
    if kind == .top || kind == .bottom {
      performScrollExtreme(kind, context: context, repeatCount: repeatCount)
      return
    }
    var didScroll = false
    for _ in 0..<normalizedRepeatCount(repeatCount) {
      if NormalModeDispatcher.scroll(
        kind,
        pid: context.processID,
        bundleID: context.bundleIdentifier,
        windowFrame: context.frontWindowFrame)
      {
        didScroll = true
      }
    }
    if didScroll {
      monitor.invalidateAfterUserAction(pid: context.processID, reason: "normal_scroll")
    }
    applyModeOverlay()
  }

  func performScrollExtreme(
    _ kind: NormalModeDispatcher.ScrollKind,
    context: AppContext,
    repeatCount: Int
  ) {
    let registry: SourceRegistry = self.registry
    let bundleID = context.bundleIdentifier
    let pid = context.processID
    let windowFrame = context.frontWindowFrame
    let normalized = normalizedRepeatCount(repeatCount)
    let monitor: AppMonitor = self.monitor
    let completion: (SourceActionResult) -> Void = { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll_extreme")
        self.applyModeOverlay()
      case .failed:
        // Source claimed but the underlying command failed — don't
        // double-fire with the Scroller wheel fallback (it would just
        // confuse the user with extra motion). Surface and stop.
        FlashLog.debug("[normal_mode] scroll_extreme failed kind=\(kind) bundle=\(bundleID)")
        self.applyModeOverlay()
      case .unhandled:
        self.scrollViaScroller(
          kind, pid: pid, bundleID: bundleID, windowFrame: windowFrame, repeats: normalized)
      }
    }
    if kind == .top {
      registry.perform(.scrollTop, in: context, completion: completion)
    } else {
      registry.perform(.scrollBottom, in: context, completion: completion)
    }
  }

  func scrollViaScroller(
    _ kind: NormalModeDispatcher.ScrollKind,
    pid: pid_t,
    bundleID: String,
    windowFrame: CGRect?,
    repeats: Int
  ) {
    // gg/G outside a claiming source: in browsers, `cmd+up` /
    // `cmd+down` is the dependable scroll-to-edge gesture (the
    // huge-wheel-delta path only nudges Firefox a viewport at a time).
    // Everything else still goes through the AX scrollbar / wheel
    // hermetic fallback.
    if BrowserTabSources.allBundleIdentifiers.contains(bundleID),
      kind == .top || kind == .bottom
    {
      let key: CGKeyCode =
        kind == .top ? CGKeyCode(kVK_UpArrow) : CGKeyCode(kVK_DownArrow)
      var didScroll = false
      for _ in 0..<repeats {
        if NormalModeDispatcher.sendKey(virtualKey: key, flags: .maskCommand, to: pid) {
          didScroll = true
        }
      }
      if didScroll {
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll_browser_edge")
      }
      applyModeOverlay()
      return
    }
    var didScroll = false
    for _ in 0..<repeats {
      if NormalModeDispatcher.scroll(
        kind, pid: pid, bundleID: bundleID, windowFrame: windowFrame)
      {
        didScroll = true
      }
    }
    if didScroll {
      monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
    }
    applyModeOverlay()
  }

}

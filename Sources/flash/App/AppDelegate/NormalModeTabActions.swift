import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

// Tab-, pane- and window-action surface for normal mode. Every action runs
// one policy, with no knowledge of any particular app:
//   1. a source that performs the action in the focused app (tmux, a browser
//      plugin, the accessibility tab strip);
//   2. else the chord a plugin manifest declares for the action in that app
//      (`action_keystrokes`: a browser's Cmd-Shift-], Firefox's tab move);
//   3. else the platform convention the core owns for a few actions (Cmd-W
//      closes, Cmd-1 is the first tab), or nothing.

extension AppDelegate {
  func tabSelectInNormalMode(index: Int) {
    let index = normalizedRepeatCount(index)
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for tab_select index=\(index)")
      applyModeOverlay()
      return
    }
    registry.perform(.tabSelect(index: index), in: context) { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        if let pid = result.targetPID {
          self.normalModeTargetPID = pid
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        FlashLog.warn(
          "[normal_mode] tab_select failed in claimed source "
            + "source=\(result.source ?? "?") bundle=\(context.bundleIdentifier) "
            + "index=\(index) reason=\(result.failureReason ?? "none")")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        guard let key = Self.tabIndexKeyCode(index) else {
          FlashLog.debug("[normal_mode] tab_select unsupported index=\(index)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(key, flags: .maskCommand)
      }
    }
  }

  /// Cmd-1 is the platform's first tab.
  func tabFirstInNormalMode() {
    performSourceAction(.tabFirst) { [weak self] _, _ in
      self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_1), flags: .maskCommand)
    }
  }

  /// Cmd-W closes the focused tab, or window, of any app. `window_close`
  /// inside a terminal hosting tmux closes the tmux window instead: Cmd-W
  /// would quit the terminal itself and drop the user off their session.
  func closeInNormalMode(_ name: SourceActionName, repeatCount: Int) {
    performSourceAction(name, repeatCount: repeatCount) { [weak self] _, count in
      self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: count)
    }
  }

  /// `resource_next` / `resource_previous` scroll where no source navigates.
  func resourceNavigationInNormalMode(direction: SourceTabDirection, repeatCount: Int) {
    let fallbackScroll: NormalModeDispatcher.ScrollKind = direction == .next ? .down : .up
    performSourceAction(
      direction == .next ? .resourceNext : .resourcePrevious, repeatCount: repeatCount
    ) { [weak self] _, count in
      self?.scrollNormalMode(fallbackScroll, repeatCount: count)
    }
  }

  /// Runs `name` in the focused app `repeatCount` times through the policy
  /// above. `fallback` is the core's platform convention for the action, if
  /// it has one.
  func performSourceAction(
    _ name: SourceActionName,
    repeatCount: Int = 1,
    context resolvedContext: AppContext? = nil,
    fallback: ((AppContext, Int) -> Void)? = nil
  ) {
    guard let context = resolvedContext ?? normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for \(name.rawValue)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)

    func attempt(_ remaining: Int) {
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        return
      }
      registry.perform(name.action, in: context) { [weak self] result in
        guard let self else { return }
        switch result.disposition {
        case .performed:
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          attempt(remaining - 1)
        case .failed:
          // A source claimed the action but couldn't complete it. The
          // keystroke fallback must not fire here — see
          // `SourceActionResult.Disposition.failed`.
          FlashLog.warn(
            "[normal_mode] \(name.rawValue) failed in claimed source "
              + "source=\(result.source ?? "?") bundle=\(context.bundleIdentifier) "
              + "reason=\(result.failureReason ?? "none")")
          self.scheduleNormalModeRecapture()
        case .unhandled:
          self.performUnhandledSourceAction(
            name, context: context, repeatCount: remaining, fallback: fallback)
        }
      }
    }

    attempt(count)
  }

  private func performUnhandledSourceAction(
    _ name: SourceActionName,
    context: AppContext,
    repeatCount: Int,
    fallback: ((AppContext, Int) -> Void)?
  ) {
    if let chord = pluginManager.actionKeystroke(
      name, in: PluginSelectorContext(bundleID: context.bundleIdentifier))
    {
      sendNormalModeKey(chord.keyCode, flags: chord.eventFlags, repeatCount: repeatCount)
      return
    }
    guard let fallback else {
      FlashLog.debug(
        "[normal_mode] \(name.rawValue) unsupported bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      return
    }
    fallback(context, repeatCount)
  }

  static func tabIndexKeyCode(_ index: Int) -> CGKeyCode? {
    let digits = [
      kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    guard (1...digits.count).contains(index) else { return nil }
    return CGKeyCode(digits[index - 1])
  }
}

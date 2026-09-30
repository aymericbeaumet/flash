import AppKit
import ApplicationServices
import FlashCore

// Tab, pane, reload, history and edge actions for NORMAL. Every action is
// high-level and resolves in the focused app's context: a source that performs
// it there wins (tmux, a browser plugin, the accessibility tab strip), and
// `SourceActionFallback` decides what the app gets otherwise.

extension AppDelegate {
  func tabSelectInNormalMode(index: Int) {
    let index = normalizedRepeatCount(index)
    runSourceAction(.tabSelect(index: index), label: "tab_select index=\(index)") { _ in
      .tabSelect(index: index)
    }
  }

  /// Runs `name` in the focused app `repeatCount` times.
  func performSourceAction(_ name: SourceActionName, repeatCount: Int = 1) {
    let plugins = pluginManager
    runSourceAction(name.action, label: name.rawValue, repeatCount: repeatCount) { context in
      SourceActionFallback.resolve(
        name,
        declared: plugins.actionKeystroke(
          name, in: PluginSelectorContext(bundleID: context.bundleIdentifier)))
    }
  }

  private func runSourceAction(
    _ action: SourceAction,
    label: String,
    repeatCount: Int = 1,
    fallback: @escaping (AppContext) -> SourceActionFallback
  ) {
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for \(label)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)

    func attempt(_ remaining: Int) {
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        return
      }
      registry.perform(action, in: context) { [weak self] result in
        guard let self else { return }
        switch result.disposition {
        case .performed:
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          attempt(remaining - 1)
        case .failed:
          // A source claimed the action but couldn't complete it. The
          // fallback must not run here — see
          // `SourceActionResult.Disposition.failed`.
          FlashLog.warn(
            "[normal_mode] \(label) failed in claimed source "
              + "source=\(result.source ?? "?") bundle=\(context.bundleIdentifier) "
              + "reason=\(result.failureReason ?? "none")")
          self.scheduleNormalModeRecapture()
        case .unhandled:
          self.performSourceActionFallback(
            fallback(context), label: label, context: context, repeatCount: remaining)
        }
      }
    }

    attempt(count)
  }

  private func performSourceActionFallback(
    _ fallback: SourceActionFallback,
    label: String,
    context: AppContext,
    repeatCount: Int
  ) {
    switch fallback {
    case .chord(let key, let flags):
      sendNormalModeKey(key, flags: flags, repeatCount: repeatCount)
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
    case .scrollEdge(let kind):
      scrollViaScroller(kind, context: context, repeats: repeatCount)
    case .none:
      FlashLog.debug(
        "[normal_mode] \(label) has no action in bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
    }
  }
}

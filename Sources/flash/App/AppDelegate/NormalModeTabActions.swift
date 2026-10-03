import AppKit
import ApplicationServices
import FlashCore

// Every action NORMAL asks the focused app to perform (tabs, panes, reload,
// history, edges, undo, find, save, the clipboard…) resolves in that app's
// context through one policy: a source that performs it there wins (tmux, a
// browser plugin, the accessibility tab strip), and otherwise the app's
// plugin-declared binding runs (`SourceActionFallback`).

extension AppDelegate {
  func tabSelectInNormalMode(index: Int) {
    performSourceAction(.tabSelect(index: normalizedRepeatCount(index)))
  }

  /// Runs `action` in the focused app `repeatCount` times; `completion` runs
  /// once with how the run ended. `primitive` is a Flash-owned step tried
  /// after the sources and before the binding (`window_close` presses the
  /// window's close button); it reports whether it acted.
  func performSourceAction(
    _ action: SourceAction,
    repeatCount: Int = 1,
    context explicitContext: AppContext? = nil,
    keyTarget: NormalModeKeyDispatchTarget? = nil,
    primitive: ((AppContext, @escaping (Bool) -> Void) -> Void)? = nil,
    completion: @escaping (NormalModeActionOutcome) -> Void = { _ in }
  ) {
    let name = action.name
    let label = action.traceTag
    guard let context = explicitContext ?? normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for \(label)")
      applyModeOverlay()
      completion(.noTarget)
      return
    }
    let count = normalizedRepeatCount(repeatCount)
    let index: Int? = if case .tabSelect(let index) = action { index } else { nil }

    func fallBack(_ remaining: Int) {
      let fallback = SourceActionFallback.resolve(
        name,
        binding: pluginManager.actionBinding(
          name, index: index, in: PluginSelectorContext(bundleID: context.bundleIdentifier)))
      performSourceActionFallback(
        fallback, label: label, context: context, keyTarget: keyTarget, repeatCount: remaining,
        completion: completion)
    }

    func attempt(_ remaining: Int) {
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        completion(.performed)
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
          // binding must not run here — see
          // `SourceActionResult.Disposition.failed`.
          FlashLog.warn(
            "[normal_mode] \(label) failed in claimed source "
              + "source=\(result.source ?? "?") bundle=\(context.bundleIdentifier) "
              + "reason=\(result.failureReason ?? "none")")
          self.scheduleNormalModeRecapture()
          completion(.failed)
        case .unhandled:
          guard let primitive else {
            fallBack(remaining)
            return
          }
          primitive(context) { acted in
            if acted {
              attempt(remaining - 1)
            } else {
              fallBack(remaining)
            }
          }
        }
      }
    }

    attempt(count)
  }

  private func performSourceActionFallback(
    _ fallback: SourceActionFallback,
    label: String,
    context: AppContext,
    keyTarget: NormalModeKeyDispatchTarget?,
    repeatCount: Int,
    completion: @escaping (NormalModeActionOutcome) -> Void
  ) {
    switch fallback {
    case .binding(let binding):
      performActionBinding(
        binding, label: label, context: context, keyTarget: keyTarget,
        repeatCount: repeatCount, completion: completion)
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
      completion(.performed)
    case .scrollEdge(let kind):
      scrollViaScroller(kind, context: context, repeats: repeatCount)
      completion(.performed)
    case .none:
      FlashLog.debug(
        "[normal_mode] \(label) has no action in bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      completion(.unavailable)
    }
  }

  /// Dispatches a plugin-declared binding: chords are posted to the key
  /// target (refused whole where a terminal would type one), a menu item is
  /// pressed through Accessibility on the AX action queue.
  private func performActionBinding(
    _ binding: ActionBinding,
    label: String,
    context: AppContext,
    keyTarget explicitKeyTarget: NormalModeKeyDispatchTarget?,
    repeatCount: Int,
    completion: @escaping (NormalModeActionOutcome) -> Void
  ) {
    guard let keyTarget = explicitKeyTarget ?? normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal_mode] no key target for \(label)")
      applyModeOverlay()
      completion(.noTarget)
      return
    }
    let plan = ActionBindingDispatch.plan(binding) { key, flags in
      commandChordTypesText(key: key, flags: flags, bundleIdentifier: keyTarget.bundleIdentifier)
    }
    switch plan {
    case .sendChords(let chords):
      postNormalModeChords(
        chords, to: keyTarget, repeatCount: repeatCount, completion: completion)
    case .pressMenu(let path):
      ActionBindingDispatch.pressMenu(
        path, pid: keyTarget.processID, repeatCount: repeatCount, presser: menuPathPresser,
        queue: Self.normalModeAXActionQueue
      ) { [weak self] ok in
        guard let self else { return }
        if !ok {
          FlashLog.warn(
            "[normal_mode] \(label) menu item not pressed "
              + "bundle=\(keyTarget.bundleIdentifier) depth=\(path.count)")
        }
        self.scheduleNormalModeRecapture()
        completion(ok ? .performed : .failed)
      }
    case .refused:
      FlashLog.debug(
        "[normal_mode] \(label) refused: a chord would type text "
          + "bundle=\(keyTarget.bundleIdentifier)")
      applyModeOverlay()
      completion(.refused)
    case .unavailable:
      FlashLog.debug(
        "[normal_mode] \(label) has no action in bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      completion(.unavailable)
    }
  }
}

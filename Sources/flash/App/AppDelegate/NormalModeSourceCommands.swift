import AppKit
import ApplicationServices
import FlashCore

// Every command NORMAL asks the focused app to perform (tabs, panes, reload,
// history, edges, undo, find, save, the clipboard…) resolves in that app's
// context through one policy: a source that performs it there wins (tmux, a
// browser plugin, the accessibility tab strip), and otherwise the app's
// plugin-declared binding runs (`SourceCommandFallback`).

extension AppDelegate {
  func tabSelectInNormalMode(
    index: Int, completion: @escaping (NormalModeCommandOutcome) -> Void = { _ in }
  ) {
    performSourceCommand(
      URLCommand.tabSelect(index: normalizedRepeatCount(index)).requiredSourceCommand,
      completion: completion)
  }

  /// Runs `command` in the focused app `repeatCount` times; `completion` runs
  /// once with how the run ended. `primitive` is a Flash-owned step tried
  /// after the sources and before the binding (`window close` presses the
  /// window's close button); it reports whether it acted. `strokeIntervalMs`
  /// spaces a binding's repeated chords instead of `[mode]
  /// send_key_interval_ms` (the arrows of a `move`).
  func performSourceCommand(
    _ command: SourceCommand,
    repeatCount: Int = 1,
    context explicitContext: AppContext? = nil,
    strokeIntervalMs: Int? = nil,
    keyTarget: NormalModeKeyDispatchTarget? = nil,
    stillCurrent: (() -> Bool)? = nil,
    validate: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
    primitive: ((AppContext, @escaping (Bool) -> Void) -> Void)? = nil,
    completion: @escaping (NormalModeCommandOutcome) -> Void = { _ in }
  ) {
    let label = command.description
    guard let context = explicitContext ?? normalModeDispatchContext() else {
      FlashLog.debug("[normal] no target app for \(label)")
      applyModeOverlay()
      completion(.noTarget)
      return
    }
    let contextualTarget = NormalModeKeyDispatchTarget(
      processID: context.processID, bundleIdentifier: context.bundleIdentifier)
    let capturedTarget =
      keyTarget
      ?? (explicitContext == nil ? normalModeKeyDispatchTarget() : nil) ?? contextualTarget
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { [weak self] in
        self?.normalModeCommandTargetIsCurrent(capturedTarget) == true
          && (stillCurrent?() ?? true)
      }, validate: validate, completion: completion)
    let count = normalizedRepeatCount(repeatCount)
    let index = command.argument("index").flatMap(Int.init)

    func fallBack(_ remaining: Int) {
      delivery.perform {
        let fallback = SourceCommandFallback.resolve(
          command.name,
          binding: self.pluginManager.commandBinding(
            CommandBindingKey(command), index: index,
            in: PluginSelectorContext(bundleID: context.bundleIdentifier)))
        self.performSourceCommandFallback(
          fallback, label: label, context: context, keyTarget: capturedTarget,
          repeatCount: remaining, strokeIntervalMs: strokeIntervalMs, delivery: delivery)
      }
    }

    func attempt(_ remaining: Int) {
      guard delivery.isPending else { return }
      if let stillCurrent, !stillCurrent() { return delivery.complete(.noTarget) }
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        delivery.complete(.performed)
        return
      }
      registry.perform(command, in: context) { [weak self] result in
        guard let self, delivery.isPending else { return }
        switch result.disposition {
        case .performed:
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          // A source that names where it landed (a tmux window, a Firefox
          // tab) makes that a stop now, one per press: the catalog it
          // publishes once a burst settles shows only the last, and the
          // observation in flight still names the location just left
          // (`recordPerformedNavigation`).
          if let route = result.navigationURL {
            self.recordPerformedNavigation(
              .route(route, pid: result.targetPID ?? context.processID), source: "source_command")
          }
          attempt(remaining - 1)
        case .failed:
          // A source claimed the command but couldn't complete it. The
          // binding must not run here — see
          // `SourceCommandResult.Disposition.failed`.
          FlashLog.warn(
            "[normal] \(label) failed in claimed source "
              + "source=\(result.source ?? "?") bundle=\(context.bundleIdentifier) "
              + "reason=\(result.failureReason ?? "none")")
          self.scheduleNormalModeRecapture()
          delivery.complete(.failed)
        case .unhandled:
          guard let primitive else {
            fallBack(remaining)
            return
          }
          delivery.perform {
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
    }

    attempt(count)
  }

  private func performSourceCommandFallback(
    _ fallback: SourceCommandFallback,
    label: String,
    context: AppContext,
    keyTarget: NormalModeKeyDispatchTarget?,
    repeatCount: Int,
    strokeIntervalMs: Int?,
    delivery: NormalModeCommandDelivery
  ) {
    switch fallback {
    case .binding(let binding):
      performCommandBinding(
        binding, label: label, context: context, keyTarget: keyTarget,
        repeatCount: repeatCount, strokeIntervalMs: strokeIntervalMs, delivery: delivery)
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
      delivery.complete(.performed)
    case .scrollEdge(let kind):
      scrollViaScroller(kind, context: context, repeats: repeatCount)
      delivery.complete(.performed)
    case .none:
      FlashLog.debug(
        "[normal] \(label) has no binding in bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      delivery.complete(.unavailable)
    }
  }

  /// Dispatches a plugin-declared binding: chords are posted to the key
  /// target (refused whole where a terminal would type one), a menu item is
  /// pressed through Accessibility on the AX action queue.
  private func performCommandBinding(
    _ binding: CommandBinding,
    label: String,
    context: AppContext,
    keyTarget explicitKeyTarget: NormalModeKeyDispatchTarget?,
    repeatCount: Int,
    strokeIntervalMs: Int?,
    delivery: NormalModeCommandDelivery
  ) {
    guard let keyTarget = explicitKeyTarget ?? normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal] no key target for \(label)")
      applyModeOverlay()
      delivery.complete(.noTarget)
      return
    }
    let plan = CommandBindingDispatch.plan(binding) { key, flags in
      commandChordTypesText(key: key, flags: flags, bundleIdentifier: keyTarget.bundleIdentifier)
    }
    switch plan {
    case .sendChords(let chords):
      postNormalModeChords(
        chords, to: keyTarget, repeatCount: repeatCount, strokeIntervalMs: strokeIntervalMs,
        delivery: delivery)
    case .pressMenu(let path):
      pressMenuPath(
        path, label: label, keyTarget: keyTarget, repeatCount: repeatCount, delivery: delivery)
    case .refused:
      FlashLog.debug(
        "[normal] \(label) refused: a chord would type text "
          + "bundle=\(keyTarget.bundleIdentifier)")
      applyModeOverlay()
      delivery.complete(.refused)
    case .unavailable:
      FlashLog.debug(
        "[normal] \(label) has no binding in bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      delivery.complete(.unavailable)
    }
  }

  /// Presses the menu-bar item `path` names in the key target, `repeatCount`
  /// times, through Accessibility on the AX action queue: a binding's menu
  /// item and `menu press` alike. A missing or disabled item fails, and the
  /// presses stop once the target or the input changed.
  func pressMenuPath(
    _ path: [String],
    label: String,
    keyTarget: NormalModeKeyDispatchTarget,
    repeatCount: Int,
    delivery: NormalModeCommandDelivery
  ) {
    let input = delivery.input
    CommandBindingDispatch.pressMenu(
      path, pid: keyTarget.processID, repeatCount: repeatCount, presser: menuPathPresser,
      queue: Self.normalModeAXActionQueue,
      shouldContinue: {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return (front == keyTarget.processID || front == getpid()) && input == .capture()
      },
      completion: { [weak self] ok in
        guard let self else { return }
        if !ok {
          FlashLog.warn(
            "[normal] \(label) menu item not pressed "
              + "bundle=\(keyTarget.bundleIdentifier) depth=\(path.count)")
        }
        self.scheduleNormalModeRecapture()
        delivery.complete(ok ? .performed : .failed)
      })
  }
}

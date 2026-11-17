import AppKit
import FlashCore

// The app operations Flash performs itself rather than asks of the app:
// which apps show (`app hide`, `app hide_others`, `app show_all`,
// `app raise`) and `menu press`, the user's escape hatch to any menu item.
// Every other app operation (print, save as, export, revert, settings, …) is
// a source command resolved through plugin `bindings`.

extension URLCommand {
  /// The question Flash asks before a command asked of the focused app that
  /// loses work nothing brings back: a revert drops the document's unsaved
  /// changes, and closing every window can close unsaved ones. A manifest's
  /// `bindings` declare no question, so the host owns these; nil for every
  /// other command.
  var hostConfirmation: String? {
    switch self {
    case .documentRevert: return "Revert to the last saved version, losing unsaved changes?"
    case .windowCloseAll: return "Close every window of this app?"
    default: return nil
    }
  }
}

extension AppDelegate {
  /// The question asked before `command` in the focused app, or nil to run
  /// it at once. The plugin that performs it destructively asks its own
  /// (`confirm` on its `commands[]` entry); otherwise a command with a
  /// `hostConfirmation` asks Flash's, only where the app has it (a binding
  /// other than `false`), so an app without the command is never asked about
  /// it.
  static func appCommandConfirmation(
    _ command: URLCommand, pluginPrompt: String?, binding: @autoclosure () -> CommandBinding?
  ) -> String? {
    if let pluginPrompt { return pluginPrompt }
    guard let question = command.hostConfirmation, let binding = binding(),
      binding != .unbound
    else { return nil }
    return question
  }

  /// Whether the focus may receive `app cancel`'s Escape, from the cached
  /// focus region (no AX on the keypress): a terminal in web content
  /// (VS Code's) is refused.
  func focusTakesTheAppsCancel(_ done: @escaping (Bool) -> Void) {
    guard let pid = normalModeDispatchContext()?.processID else { return done(false) }
    focusRegionTracker.withReading(for: pid) { reading in
      let takes = reading.region.takesTheAppsCancel
      if !takes {
        FlashLog.debug("[normal] app cancel refused", fields: ["reason": "terminal"])
      }
      done(takes)
    }
  }

  /// `app hide`, `app hide_others`, `app show_all` and `app raise` on the app
  /// a command acts in. Hiding the focused app moves activation to the next
  /// one, as macOS's own Hide does.
  @discardableResult
  func performAppVisibility(_ action: AppVisibilityAction) -> NormalModeCommandOutcome {
    defer { applyModeOverlay() }
    let running = NSWorkspace.shared.runningApplications
    if action == .showAll {
      for app in running where app.isHidden { app.unhide() }
      return .performed
    }
    guard let context = normalModeDispatchContext(),
      let app = NSRunningApplication(processIdentifier: context.processID)
    else {
      FlashLog.debug("[normal] no target app for app \(action.rawValue)")
      return .noTarget
    }
    switch action {
    case .hide:
      app.hide()
    case .hideOthers:
      for other in running
      where Self.hidesWithOthers(
        processID: other.processIdentifier, regular: other.activationPolicy == .regular,
        hidden: other.isHidden, keeping: context.processID)
      {
        other.hide()
      }
    case .raise:
      RunningApplicationActivation.activate(
        app, options: [.activateAllWindows], restoringMinimizedWindows: false)
    case .showAll:
      break
    }
    return .performed
  }

  /// Whether `app hide_others` hides this app: a regular app showing, other
  /// than the one kept and Flash itself.
  static func hidesWithOthers(
    processID: pid_t, regular: Bool, hidden: Bool, keeping kept: pid_t,
    flash: pid_t = getpid()
  ) -> Bool {
    regular && !hidden && processID != kept && processID != flash
  }

  /// `menu press --path=…`: the focused app's menu-bar item, pressed as a
  /// `bindings` menu item is, `repeatCount` times.
  func pressFocusedAppMenuItem(
    _ path: [String], repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let label = "menu press"
    guard let keyTarget = normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal] no key target for \(label)")
      applyModeOverlay()
      return completion(.noTarget)
    }
    let delivery = NormalModeCommandDelivery(
      stillCurrent: { [weak self] in self?.normalModeCommandTargetIsCurrent(keyTarget) == true },
      completion: completion)
    let count = normalizedRepeatCount(repeatCount)
    delivery.perform { [weak self] in
      self?.pressMenuPath(
        path, label: label, keyTarget: keyTarget, repeatCount: count, delivery: delivery)
    }
  }
}

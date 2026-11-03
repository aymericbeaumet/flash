import AppKit
import FlashCore

/// The machine, session and process verbs Flash performs itself. One that
/// nothing undoes asks first through the confirmation alert; `y` runs it
/// again, confirmed. No path here blocks main: power requests and Apple
/// Events run on `SystemActionPerformer`'s queue, process reads on
/// `processCommandQueue`.
extension AppDelegate {
  static let processCommandQueue = DispatchQueue(
    label: "flash.process-commands", qos: .userInitiated)

  func performSystemAction(_ action: SystemAction, confirmed: Bool) {
    let command = URLCommand.systemAction(action)
    switch action.step(confirmed: confirmed) {
    case .ask(let prompt):
      presentConfirmation(prompt, command: command)
    case .refuse(let reason):
      FlashLog.warn("[system] \(action.rawValue) refused: \(reason)")
    case .run:
      FlashLog.debug("[system] run \(action.rawValue)")
      guard action.execution != .lockScreenChord else {
        if !lockScreen() { warnCommandFailure(command.diagnosticDescription) }
        return
      }
      SystemActionPerformer.perform(action.execution) { [weak self] failure in
        guard let failure else { return }
        FlashLog.warn("[system] \(action.rawValue) failed: \(failure)")
        self?.warnCommandFailure(command.diagnosticDescription)
      }
    }
  }

  /// `<surface> show|hide|toggle`, the trackpad gestures for the same
  /// surfaces and Hyper+3: `SystemSurfaceController` runs them off main, one
  /// at a time. `completion` gets nil once done, or why it could not be;
  /// without one, a failure shows in the centred alert.
  func performSystemSurface(
    _ command: SystemSurfaceCommand, completion: ((String?) -> Void)? = nil
  ) {
    systemSurfaces.perform(command) { [weak self] failure in
      if let completion { return completion(failure) }
      guard let failure else { return }
      self?.overlay.displayAlert(.message(failure, style: .error))
    }
  }

  /// macOS's Lock Screen shortcut, posted to the session the way any global
  /// key is: noted first, so the Carbon path does not take the echo for the
  /// user's own binding of the same chord.
  private func lockScreen() -> Bool {
    guard let chord = HotkeySyntax.parse(hotkey: SystemActionExecution.lockScreenShortcut) else {
      return false
    }
    mappings.noteSyntheticKey(virtualKey: chord.virtualKey, flags: chord.eventFlags)
    return NormalModeDispatcher.sendGlobalKey(
      virtualKey: CGKeyCode(chord.virtualKey), flags: chord.eventFlags)
  }

  /// `process kill`: name the process in the question, then SIGTERM it once
  /// the user said `y`. A pid that is gone, or not this user's to inspect,
  /// refuses before anything is asked.
  func performProcessKill(_ pid: pid_t, confirmed: Bool) {
    let command = URLCommand.processKill(pid: pid)
    Self.processCommandQueue.async { [weak self] in
      let step = ProcessKill.step(pid: pid, name: ProcessTable.name(of: pid), confirmed: confirmed)
      let failure: String?
      if case .run = step {
        failure = ProcessTable.terminate(pid)
      } else {
        failure = nil
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        switch step {
        case .ask(let prompt):
          self.presentConfirmation(prompt, command: command)
        case .refuse(let reason):
          FlashLog.warn("[processes] kill pid \(pid) refused: \(reason)")
          self.warnCommandFailure(command.diagnosticDescription)
        case .run:
          guard let failure else {
            FlashLog.info("[processes] SIGTERM pid \(pid)")
            return
          }
          FlashLog.warn("[processes] kill pid \(pid) failed: \(failure)")
          self.warnCommandFailure(command.diagnosticDescription)
        }
      }
    }
  }
}

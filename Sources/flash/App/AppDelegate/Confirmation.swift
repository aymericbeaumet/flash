import AppKit
import FlashCore

/// A confirmation (`alert confirm`, the `confirm` a plugin declares on one of
/// its `commands[]` entries, or the one a flashlight row carries): the
/// question is the status alert, and a hint-session phase owns the keyboard
/// until one key answers it, in every base mode. `y` runs what it gates,
/// marked as confirmed; any other key, Escape and a click included, closes
/// the question and runs nothing.
extension AppDelegate {
  func presentConfirmation(_ prompt: String, command: URLCommand, repeatCount: Int = 1) {
    presentConfirmation(
      HintSession.Confirmation(prompt: prompt, command: command, repeatCount: repeatCount))
  }

  func presentConfirmation(_ confirmation: HintSession.Confirmation) {
    guard prepareHintActivation(.confirm(confirmation)) else { return }
    hintSession.phase = .confirming(confirmation)
    applyModeOverlay()
    overlay.displayAlert(.confirmation(confirmation.prompt), heldWhileFullScreen: false)
    FlashLog.debug("[confirm] ask command=\(confirmation.diagnosticDescription)")
  }

  func overlayDidConfirm(accepted: Bool) {
    guard let confirmation = hintSession.confirmation else {
      cancelOverlay()
      return
    }
    FlashLog.debug(
      "[confirm] answer=\(accepted ? "yes" : "no") command=\(confirmation.diagnosticDescription)")
    // The teardown drops the question with the session; the command then
    // starts from a clean NORMAL/INSERT surface, as if typed there.
    cancelOverlay()
    guard accepted else { return }
    switch confirmation.action {
    case .command(let command, let repeatCount):
      performMappedCommand(command, repeatCount: repeatCount, confirmed: true)
    case .row(let selection):
      openSourceItem(
        selection.candidate, recordMovement: selection.recordMovement,
        insertionTargetPID: selection.insertionTargetPID, variant: selection.variant,
        confirmed: true)
    }
  }

  /// The question a plugin declares for the command `name` in the focused
  /// app, or nil when no applicable plugin gates it.
  func sourceCommandConfirmation(_ name: CommandName, context: AppContext) -> String? {
    pluginManager.commandConfirmation(
      name, in: PluginSelectorContext(bundleID: context.bundleIdentifier))
  }
}

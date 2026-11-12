import AppKit
import FlashCore

/// A confirmation (`alert confirm`, or the `confirm` a plugin declares on a
/// core command it performs in the focused app): the question is the status alert,
/// and a hint-session phase owns the keyboard until one key answers it, in
/// every base mode. `y` runs the gated command; any other key, Escape and a
/// click included, closes the question and runs nothing.
extension AppDelegate {
  func presentConfirmation(_ prompt: String, command: URLCommand, repeatCount: Int = 1) {
    let confirmation = HintSession.Confirmation(
      prompt: prompt, command: command, repeatCount: repeatCount)
    guard prepareHintActivation(.confirm(confirmation)) else { return }
    hintSession.phase = .confirming(confirmation)
    applyModeOverlay()
    overlay.displayAlert(.confirmation(prompt))
    FlashLog.debug("[confirm] ask command=\(command.diagnosticDescription)")
  }

  func overlayDidConfirm(accepted: Bool) {
    guard let confirmation = hintSession.confirmation else {
      cancelOverlay()
      return
    }
    FlashLog.debug(
      "[confirm] answer=\(accepted ? "yes" : "no") "
        + "command=\(confirmation.command.diagnosticDescription)")
    // The teardown drops the question with the session; the command then
    // starts from a clean NORMAL/INSERT surface, as if typed there.
    cancelOverlay()
    guard accepted else { return }
    performMappedCommand(
      confirmation.command, repeatCount: confirmation.repeatCount, confirmed: true)
  }

  /// The question a plugin declares for the command `name` in the focused
  /// app, or nil when no applicable plugin gates it.
  func sourceCommandConfirmation(_ name: CommandName, context: AppContext) -> String? {
    pluginManager.commandConfirmation(
      name, in: PluginSelectorContext(bundleID: context.bundleIdentifier))
  }
}

import AppKit

extension OverlayPanel {
  /// Take a showing popup off the screen because focus left it: another app
  /// came forward, this app resigned active, or the popup panel lost key.
  /// A hover preview is the ephemeral case. A pinned or standalone popup goes
  /// too, so it cannot stay above the window the user just opened. Hiding
  /// keeps a persistent process; it stops a fresh one.
  func relinquishShownStatusPopup(reason: String) {
    guard let name = statusPopupController.presentation.name else {
      dismissEphemeralStatusBarPopup(reason: reason)
      return
    }
    if statusPopupController.presentation.ephemeralName != nil {
      dismissEphemeralStatusBarPopup(reason: reason)
      return
    }
    if !statusPopupController.presentation.isStandalone {
      statusBarHoverGate = .dismissed(name)
    }
    hideStatusBarPopup(reason: reason)
  }

  /// Close the ephemeral status-bar popup — a hover preview, or a terminal
  /// popup still waiting out its hover dwell — because the user moved on: a
  /// click outside Flash's status bar, or a focus change. The hover gate keeps
  /// it shut until the pointer leaves its anchor, so a pointer that never
  /// moved does not summon it straight back. A pinned popup is not ephemeral;
  /// it leaves through `relinquishShownStatusPopup`.
  func dismissEphemeralStatusBarPopup(reason: String) {
    if let pending = statusBarHoverDwellName {
      statusBarHoverDwellWork?.cancel()
      statusBarHoverDwellWork = nil
      statusBarHoverDwellName = nil
      statusBarHoverGate = .dismissed(pending)
    }
    guard let name = statusPopupController.presentation.ephemeralName else { return }
    statusBarHoverGate = .dismissed(name)
    hideStatusBarPopup(reason: reason)
  }
}

import AppKit

extension OverlayPanel {
  /// Close the ephemeral status-bar popup — a hover preview, or a terminal
  /// popup still waiting out its hover dwell — because the user moved on: a
  /// click outside Flash's status bar, or a focus change. The hover gate keeps
  /// it shut until the pointer leaves its anchor, so a pointer that never
  /// moved does not summon it straight back.
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

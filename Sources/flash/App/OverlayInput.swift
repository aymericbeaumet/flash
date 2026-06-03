import AppKit

/// keyDown handling lives in a custom NSPanel subclass so input is strictly scoped
/// to the overlay window; no global event taps or hotkey hooks anywhere in the app.
extension OverlayPanel {
  override func keyDown(with event: NSEvent) {
    guard let coordinator = coordinator else { return }
    // Hardcoded dismissal keys. Not configurable on purpose: arrows /
    // space / escape are common "abort what I was about to do" signals
    // in every macOS app, and matching that intuition keeps the
    // overlay out of the user's way. Scrolling is handled separately
    // by a global event monitor (see OverlayPanel.installScrollMonitor).
    switch event.keyCode {
    case 49,  // space
      53,  // escape
      123, 124, 125, 126:  // arrow_left/right/down/up
      coordinator.overlayDidCancel()
      return
    case 51:  // backspace/delete
      coordinator.overlayDidUpdatePrefix("__BACKSPACE__")
      return
    default:
      break
    }
    guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
    coordinator.overlayDidCommit(prefix: chars)
  }
}

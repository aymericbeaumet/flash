import AppKit

/// keyDown handling lives in a custom NSPanel subclass so input is strictly scoped
/// to the overlay window; no global event taps or hotkey hooks anywhere in the app.
extension OverlayPanel {
    override func keyDown(with event: NSEvent) {
        guard let coordinator = coordinator else { return }
        if event.keyCode == 53 { // escape
            coordinator.overlayDidCancel()
            return
        }
        if event.keyCode == 51 { // delete/backspace
            coordinator.overlayDidUpdatePrefix("__BACKSPACE__")
            return
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let withShift = event.modifierFlags.contains(.shift)
        coordinator.overlayDidCommit(prefix: chars, withShift: withShift)
    }
}

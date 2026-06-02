import AppKit

/// keyDown handling lives in a custom NSPanel subclass so input is strictly scoped
/// to the overlay window; no global event taps or hotkey hooks anywhere in the app.
extension OverlayPanel {
  override func keyDown(with event: NSEvent) {
    guard let coordinator = coordinator else { return }
    if Self.matchesExitKey(event: event, config: overlayConfig.exitKey) {
      coordinator.overlayDidCancel()
      return
    }
    if event.keyCode == 51 {  // delete/backspace
      coordinator.overlayDidUpdatePrefix("__BACKSPACE__")
      return
    }
    guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
    coordinator.overlayDidCommit(prefix: chars)
  }

  /// Karabiner-style key tokens. Special keys are wrapped in `<>` (e.g.
  /// `<escape>`, `<return>`). A bare string is a literal character match
  /// against the typed character (case-insensitive). Empty / malformed
  /// values fall back to Escape.
  static func matchesExitKey(event: NSEvent, config: String) -> Bool {
    let trimmed = config.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return event.keyCode == 53
    }
    if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 3 {
      let name = String(trimmed.dropFirst().dropLast()).lowercased()
      if let code = specialKeyCodes[name] {
        return event.keyCode == code
      }
      // Unknown special token — fail closed to Escape so the overlay
      // is never undismissable.
      return event.keyCode == 53
    }
    if let chars = event.charactersIgnoringModifiers?.lowercased() {
      return chars == trimmed.lowercased()
    }
    return false
  }

  private static let specialKeyCodes: [String: UInt16] = [
    "escape": 53,
    "return": 36,
    "enter": 36,
    "tab": 48,
    "space": 49,
    "backspace": 51,
    "delete_or_backspace": 51,
    "delete": 117,
    "delete_forward": 117,
    "arrow_up": 126,
    "arrow_down": 125,
    "arrow_left": 123,
    "arrow_right": 124,
  ]
}

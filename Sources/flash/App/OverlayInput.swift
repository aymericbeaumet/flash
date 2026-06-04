import AppKit

enum OverlayKeyAction: Equatable {
  case cancel
  case backspace
  case commit(String)
  case ignore
}

enum OverlayInputInterpreter {
  static func action(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) -> OverlayKeyAction {
    switch keyCode {
    case 49,  // space
      53,  // escape
      123, 124, 125, 126:  // arrow_left/right/down/up
      return .cancel
    default:
      break
    }

    let commandModifiers = modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .control, .option])
    if !commandModifiers.isEmpty {
      return .cancel
    }

    if keyCode == 51 {
      return .backspace
    }

    guard let chars = charactersIgnoringModifiers, !chars.isEmpty else {
      return .ignore
    }
    return .commit(chars)
  }
}

/// Hint typing lives in a custom NSPanel subclass so character input is
/// strictly scoped to the overlay window; native shortcuts are handled
/// separately by the explicit `[shortcuts]` Carbon registry.
extension OverlayPanel {
  override func keyDown(with event: NSEvent) {
    guard let coordinator = coordinator else { return }
    // Hardcoded dismissal keys. Not configurable on purpose: arrows /
    // space / escape are common "abort what I was about to do" signals
    // in every macOS app, and matching that intuition keeps the
    // overlay out of the user's way. Scrolling is handled separately
    // by a global event monitor (see OverlayPanel.installScrollMonitor).
    switch OverlayInputInterpreter.action(
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers)
    {
    case .cancel:
      coordinator.overlayDidCancel()
    case .backspace:
      coordinator.overlayDidUpdatePrefix("__BACKSPACE__")
    case .commit(let chars):
      coordinator.overlayDidCommit(prefix: chars)
    case .ignore:
      break
    }
  }
}

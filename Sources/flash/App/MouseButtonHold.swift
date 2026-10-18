import CoreGraphics

/// A button `mouse_button` presses or releases.
enum MouseButtonKind: String, CaseIterable, Hashable {
  case primary
  case secondary
  case middle

  var cgButton: CGMouseButton {
    switch self {
    case .primary: return .left
    case .secondary: return .right
    case .middle: return .center
    }
  }

  func eventType(pressed: Bool) -> CGEventType {
    switch self {
    case .primary: return pressed ? .leftMouseDown : .leftMouseUp
    case .secondary: return pressed ? .rightMouseDown : .rightMouseUp
    case .middle: return pressed ? .otherMouseDown : .otherMouseUp
    }
  }

  /// The event a pointer move becomes while this button is held.
  var draggedEventType: CGEventType {
    switch self {
    case .primary: return .leftMouseDragged
    case .secondary: return .rightMouseDragged
    case .middle: return .otherMouseDragged
    }
  }
}

/// `mouse_button --state=`.
enum MouseButtonState: String, CaseIterable, Hashable {
  case down
  case up
  case toggle
  /// Let go of whichever button is held, where the pointer is: a drag drops
  /// there, a text selection ends and stays selected.
  case release
  /// Put a drag back: the pointer drags to where the button went down, then
  /// lets go there.
  case cancel
}

/// `mouse_button --state=<state> [--secondary|--middle] [--mode=drag]`.
/// The held button enters DRAG.
struct MouseButtonRequest: Hashable {
  var state: MouseButtonState
  var button: MouseButtonKind
  var hold: ButtonHold

  var argTokens: [String] {
    var tokens = ["--state=\(state.rawValue)"]
    switch button {
    case .primary: break
    case .secondary: tokens.append("--secondary")
    case .middle: tokens.append("--middle")
    }
    tokens.append("--mode=\(hold.rawValue)")
    return tokens
  }
}

/// The one button Flash holds between a press and its release, for
/// `mouse_button` and pointer mode's `v`. `ActionDispatcher` owns the only
/// instance; a transition returns the events to post, so the state and the
/// event stream cannot disagree. One button at a time: pressing another
/// releases the held one first.
struct MouseButtonHold: Equatable {
  enum Effect: Equatable {
    case press(MouseButtonKind)
    case release(MouseButtonKind)
  }

  /// The held button, what it is for, and where it went down (NSScreen).
  struct Held: Equatable {
    var button: MouseButtonKind
    var purpose: ButtonHold
    var origin: CGPoint
  }

  private(set) var held: Held?

  mutating func apply(
    _ state: MouseButtonState, _ button: MouseButtonKind, for purpose: ButtonHold,
    at origin: CGPoint
  ) -> [Effect] {
    switch state {
    case .down:
      guard held?.button != button else { return [] }
      let effects = release() + [.press(button)]
      held = Held(button: button, purpose: purpose, origin: origin)
      return effects
    case .up:
      guard held?.button == button else { return [] }
      return release()
    case .release:
      return release()
    case .cancel:
      // The caller drags back to `held.origin` first; any held button goes.
      return release()
    case .toggle:
      return apply(held?.button == button ? .up : .down, button, for: purpose, at: origin)
    }
  }

  /// Give the held button up: Escape in an overlay, `leave_mode`, quit, or a
  /// committed gesture that needs the buttons free.
  mutating func release() -> [Effect] {
    guard let held else { return [] }
    self.held = nil
    return [.release(held.button)]
  }
}

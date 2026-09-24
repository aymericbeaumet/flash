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
}

/// `mouse_button --state=<state> [--secondary|--middle]`.
struct MouseButtonRequest: Hashable {
  var state: MouseButtonState
  var button: MouseButtonKind

  var argTokens: [String] {
    var tokens = ["--state=\(state.rawValue)"]
    switch button {
    case .primary: break
    case .secondary: tokens.append("--secondary")
    case .middle: tokens.append("--middle")
    }
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

  private(set) var held: MouseButtonKind?

  mutating func apply(_ state: MouseButtonState, _ button: MouseButtonKind) -> [Effect] {
    switch state {
    case .down:
      guard held != button else { return [] }
      let effects = release() + [.press(button)]
      held = button
      return effects
    case .up:
      guard held == button else { return [] }
      return release()
    case .toggle:
      return apply(held == button ? .up : .down, button)
    }
  }

  /// Give the held button up: Escape in an overlay, `leave_mode`, quit, or a
  /// committed gesture that needs the buttons free.
  mutating func release() -> [Effect] {
    guard let held else { return [] }
    self.held = nil
    return [.release(held)]
  }
}

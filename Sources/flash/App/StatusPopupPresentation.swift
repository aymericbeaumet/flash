import CoreGraphics

enum StatusPopupPresentation: Equatable {
  case hidden
  case preview(name: String, anchor: CGPoint)
  case focused(name: String, anchor: CGPoint)
  /// Shown by `enter_terminal_mode`: centred on a screen, focused, tied to no
  /// label.
  case standalone(name: String)

  var identity: (name: String, anchor: CGPoint?)? {
    switch self {
    case .hidden: return nil
    case .standalone(let name): return (name, nil)
    case .preview(let name, let anchor), .focused(let name, let anchor):
      return (name, anchor)
    }
  }

  var isFocused: Bool {
    switch self {
    case .focused, .standalone: return true
    case .hidden, .preview: return false
    }
  }

  /// The popup the pointer summoned and nothing else holds: a click
  /// elsewhere or a focus change closes it. A focused popup closes when it
  /// loses key instead, and a standalone popup stays until dismissed.
  var ephemeralName: String? {
    if case .preview(let name, _) = self { return name }
    return nil
  }

  var isStandalone: Bool {
    if case .standalone = self { return true }
    return false
  }

  enum Event {
    case standalone(name: String)
    case anchor(name: String, point: CGPoint)
    case leaveAnchor
    case focus
    case dismiss
  }

  func applying(_ event: Event) -> Self {
    switch event {
    case .dismiss:
      return .hidden
    case .standalone(let name):
      return .standalone(name: name)
    case .leaveAnchor:
      return isFocused ? self : .hidden
    case .anchor(let name, let point):
      guard !isFocused else { return self }
      return .preview(name: name, anchor: point)
    case .focus:
      guard let identity, let anchor = identity.anchor else { return self }
      return .focused(name: identity.name, anchor: anchor)
    }
  }
}

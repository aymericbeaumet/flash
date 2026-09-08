import CoreGraphics

enum StatusPopupPresentation: Equatable {
  case hidden
  case preview(name: String, anchor: CGPoint)
  case focused(name: String, anchor: CGPoint)
  case terminal(name: String)

  var identity: (name: String, anchor: CGPoint?)? {
    switch self {
    case .hidden: return nil
    case .terminal(let name): return (name, nil)
    case .preview(let name, let anchor), .focused(let name, let anchor):
      return (name, anchor)
    }
  }

  var isFocused: Bool {
    switch self {
    case .focused, .terminal: return true
    case .hidden, .preview: return false
    }
  }

  var isStandalone: Bool {
    if case .terminal = self { return true }
    return false
  }

  enum Event {
    case terminal(name: String)
    case anchor(name: String, point: CGPoint)
    case leaveAnchor
    case focus
    case dismiss
  }

  func applying(_ event: Event) -> Self {
    switch event {
    case .dismiss:
      return .hidden
    case .terminal(let name):
      return .terminal(name: name)
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

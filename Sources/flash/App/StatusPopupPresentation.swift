import CoreGraphics

enum StatusPopupPresentation: Equatable {
  case hidden
  case preview(name: String, anchor: CGPoint)
  case focused(name: String, anchor: CGPoint)

  var identity: (name: String, anchor: CGPoint)? {
    switch self {
    case .hidden: return nil
    case .preview(let name, let anchor), .focused(let name, let anchor):
      return (name, anchor)
    }
  }

  var isFocused: Bool {
    if case .focused = self { return true }
    return false
  }

  enum Event {
    case anchor(name: String, point: CGPoint)
    case leaveAnchor
    case focus
    case dismiss
  }

  func applying(_ event: Event) -> Self {
    switch event {
    case .dismiss, .leaveAnchor:
      return .hidden
    case .anchor(let name, let point):
      guard !isFocused else { return self }
      return .preview(name: name, anchor: point)
    case .focus:
      guard let identity else { return self }
      return .focused(name: identity.name, anchor: identity.anchor)
    }
  }
}

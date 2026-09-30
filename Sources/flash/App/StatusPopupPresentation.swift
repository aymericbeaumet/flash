/// Which popup shows and in which state. Where a label's popup shows is its
/// span's business (`OverlayPanel.statusBarPopupFrame`), never the pointer's,
/// so the state carries no position.
enum StatusPopupPresentation: Equatable {
  case hidden
  /// Hovered: hangs below its label while the pointer stays on it.
  case preview(name: String)
  /// Pinned by a click: focused, still hanging below its label.
  case focused(name: String)
  /// Shown by `enter_terminal_mode`: centred on a screen, focused, tied to no
  /// label.
  case standalone(name: String)

  var name: String? {
    switch self {
    case .hidden: return nil
    case .preview(let name), .focused(let name), .standalone(let name): return name
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
    if case .preview(let name) = self { return name }
    return nil
  }

  var isStandalone: Bool {
    if case .standalone = self { return true }
    return false
  }

  enum Event {
    case standalone(name: String)
    case anchor(name: String)
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
    case .anchor(let name):
      guard !isFocused else { return self }
      return .preview(name: name)
    case .focus:
      guard case .preview(let name) = self else { return self }
      return .focused(name: name)
    }
  }
}

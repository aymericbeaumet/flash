public enum JumpAction: Hashable, Sendable {
  case leftClick
  case rightClick
  case middleClick
  case doubleClick
  case tripleClick
}

extension JumpAction {
  /// A primary-button click, single, double or triple.
  public var isPrimaryClick: Bool {
    switch self {
    case .leftClick, .doubleClick, .tripleClick: return true
    case .rightClick, .middleClick: return false
    }
  }
}

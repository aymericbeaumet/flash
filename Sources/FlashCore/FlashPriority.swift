public enum FlashPriority: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case background
  case low
  case normal
  case high
  case critical

  public var rank: Int {
    switch self {
    case .background: return 0
    case .low: return 1
    case .normal: return 2
    case .high: return 3
    case .critical: return 4
    }
  }

  public var rankingWeight: Int {
    switch self {
    case .background: return -40
    case .low: return -20
    case .normal: return 0
    case .high: return 25
    case .critical: return 250
    }
  }

  public var usesAccentHintStyle: Bool {
    self == .critical
  }
}

extension FlashPriority: Comparable {
  public static func < (lhs: FlashPriority, rhs: FlashPriority) -> Bool {
    lhs.rank < rhs.rank
  }
}

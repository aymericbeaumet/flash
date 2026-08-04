public enum FlashPriority: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case low
  case normal
  case high
  case important
  case urgent

  public var rank: Int {
    switch self {
    case .low: return 0
    case .normal: return 1
    case .high: return 2
    case .important: return 3
    case .urgent: return 4
    }
  }

  public var rankingWeight: Int {
    switch self {
    case .low: return -20
    case .normal: return 0
    case .high: return 25
    case .important: return 100
    case .urgent: return 250
    }
  }

  public var usesAccentHintStyle: Bool {
    self == .important || self == .urgent
  }
}

extension FlashPriority: Comparable {
  public static func < (lhs: FlashPriority, rhs: FlashPriority) -> Bool {
    lhs.rank < rhs.rank
  }
}

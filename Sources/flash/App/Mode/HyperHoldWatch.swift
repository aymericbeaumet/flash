import Foundation

/// Backstop for a hyper-key release the session tap never delivered.
///
/// Swallowing the key-down can drop the matching key-up once another key or a
/// synthetic post lands in between. The hold stays latched and HYPER never
/// leaves. One reading of "up" is not enough: a single flicker must not drop
/// the layer. Two consecutive readings do.
struct HyperHoldWatch: Equatable {
  static let missedReleasesBeforeExit = 2
  private(set) var missedReleases = 0

  enum Decision: Equatable {
    case stay
    case exit
  }

  mutating func sample(holding: Bool, keyIsDown: Bool) -> Decision {
    guard holding, !keyIsDown else {
      missedReleases = 0
      return .stay
    }
    missedReleases += 1
    guard missedReleases >= Self.missedReleasesBeforeExit else { return .stay }
    missedReleases = 0
    return .exit
  }

  /// A key arrived while the hold is still latched. That key is its own
  /// witness, so one physical-up reading leaves before it is read as a hyper
  /// command.
  static func keyArrivedWhileUp(holding: Bool, keyIsDown: Bool) -> Bool {
    holding && !keyIsDown
  }
}

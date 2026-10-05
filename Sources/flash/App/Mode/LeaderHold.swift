import Foundation

/// Whether the leader key is physically held, and whether another key arrived
/// during that hold.
///
/// A clean tap (down, then up, with no other key) is what arms a NORMAL
/// `<leader>` sequence. Any other key consumes the hold: hyper mappings and
/// chorded leader sequences both count, so releasing the leader afterwards
/// does not also start a prefix.
struct LeaderHold: Equatable {
  var holding = false
  private(set) var consumed = false

  enum Input: Equatable {
    case leaderDown
    case leaderUp
    case otherKey
  }

  enum Step: Equatable {
    /// The leader went down from rest. Enter hyper.
    case enter
    /// The leader is already held (a key repeat). Swallow it.
    case ignore
    /// A non-leader key arrived while the leader is held.
    case key
    /// The leader was released. `armPrefix` is true only for a clean tap.
    case exit(armPrefix: Bool)
    /// The event does not belong to a hold that is in progress.
    case passthrough
  }

  mutating func step(_ input: Input) -> Step {
    switch input {
    case .leaderDown:
      if holding { return .ignore }
      holding = true
      consumed = false
      return .enter
    case .leaderUp:
      guard holding else { return .passthrough }
      let arm = !consumed
      holding = false
      consumed = false
      return .exit(armPrefix: arm)
    case .otherKey:
      guard holding else { return .passthrough }
      consumed = true
      return .key
    }
  }
}

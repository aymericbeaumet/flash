import Foundation

/// Runs `count` steps on `queue`, one per turn, hopping to main between
/// steps to ask whether the work is still wanted. A multi-app walk (the
/// screen scope) that is cancelled stops after the app in progress instead
/// of walking every remaining one ahead of the activation that replaced it,
/// and the truth about currency stays on main.
enum SteppedWalk {
  /// `step(i)` runs on `queue`; `done(completed)` on main, `false` when
  /// `isCurrent` said no between two steps.
  static func run(
    count: Int, on queue: DispatchQueue, isCurrent: @escaping () -> Bool,
    step: @escaping (Int) -> Void, done: @escaping (Bool) -> Void
  ) {
    func advance(from index: Int) {
      guard index < count else { return done(true) }
      queue.async {
        step(index)
        DispatchQueue.main.async {
          guard isCurrent() else { return done(false) }
          advance(from: index + 1)
        }
      }
    }
    advance(from: 0)
  }
}

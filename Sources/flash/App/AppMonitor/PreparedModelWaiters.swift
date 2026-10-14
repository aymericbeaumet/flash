import Foundation

/// The activation waiting on each app's in-flight model walk.
///
/// One slot per pid: only the latest activation matters, an earlier one is
/// stale by the time the walk ends. A waiter is a promise, though, so a
/// displaced or cancelled one is handed back to its owner to be completed
/// with nil rather than dropped — an activation whose waiter vanished would
/// stay in `discovering`, routing every key into a hint session that never
/// draws.
struct PreparedModelWaiters {
  typealias Waiter = (PreparedModel?) -> Void

  private var waiters: [pid_t: Waiter] = [:]

  var isEmpty: Bool { waiters.isEmpty }

  /// Park `waiter` for `pid`, returning the waiter it displaced, which the
  /// caller completes with nil.
  mutating func park(_ waiter: @escaping Waiter, pid: pid_t) -> Waiter? {
    let displaced = waiters[pid]
    waiters[pid] = waiter
    return displaced
  }

  /// The waiter for `pid`, removed; the caller completes it.
  mutating func take(pid: pid_t) -> Waiter? {
    waiters.removeValue(forKey: pid)
  }

  /// Every waiter, removed; the caller completes each.
  mutating func takeAll() -> [Waiter] {
    let all = Array(waiters.values)
    waiters.removeAll()
    return all
  }
}

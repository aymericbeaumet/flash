import Foundation

/// The app MRU behind `app next` / `app previous` and the refocus after an
/// app quits. Pure value state: the focused app, the apps before it (`back`,
/// oldest first), the apps a navigation stepped past (`forward`, nearest
/// last), and `target`, the app a navigation or a quit's refocus is
/// activating, whose activation lands as that navigation rather than as a new
/// visit. A navigation is a whole new value, so a failed activation puts the
/// previous one back in one assignment.
struct AppNavigationHistory: Equatable {
  private(set) var current: pid_t?
  private(set) var back: [pid_t] = []
  private(set) var forward: [pid_t] = []
  private(set) var target: pid_t?

  init(current: pid_t? = nil, back: [pid_t] = [], forward: [pid_t] = [], target: pid_t? = nil) {
    self.current = current
    self.back = back
    self.forward = forward
    self.target = target
  }

  /// `pid` became the focused app. The activation a navigation asked for
  /// only lands it; any other visit moves `pid` to the front of the ring and
  /// drops what was ahead.
  mutating func record(_ pid: pid_t) {
    if target == pid {
      target = nil
      current = pid
      return
    }
    if current == pid { return }
    var ordered = back
    if let current { ordered.append(current) }
    ordered.append(contentsOf: forward.reversed())
    ordered.removeAll { $0 == pid }
    back = ordered
    current = pid
    forward.removeAll(keepingCapacity: true)
  }

  /// The history after one step in `direction`, aimed at its target; nil when
  /// fewer than two available apps were seen.
  func navigating(
    _ direction: AppDelegate.NavigationDirection, isAvailable: (pid_t) -> Bool
  ) -> AppNavigationHistory? {
    guard
      let step = Self.ring(
        direction: direction, current: current, back: back, forward: forward,
        isAvailable: isAvailable)
    else { return nil }
    return AppNavigationHistory(
      current: step.target, back: step.back, forward: step.forward, target: step.target)
  }

  /// The history that focuses the app to return to once `pid` quits, aimed
  /// at it; nil when no available app is left.
  func refocusing(afterQuitOf pid: pid_t, isAvailable: (pid_t) -> Bool)
    -> AppNavigationHistory?
  {
    guard
      let focus = Self.quitFocus(
        quitting: pid, current: current, back: back, forward: forward, isAvailable: isAvailable)
    else { return nil }
    return AppNavigationHistory(current: focus.target, back: focus.back, target: focus.target)
  }

  /// A history with `apps` behind the focused one: the ring a first
  /// navigation walks when none was recorded yet.
  func seeded(back apps: [pid_t]) -> AppNavigationHistory {
    AppNavigationHistory(current: current, back: apps, target: target)
  }

  /// `pid` quit: it leaves the ring and stops being a navigation's target,
  /// and stops being current when `clearingCurrent`.
  mutating func forget(_ pid: pid_t, clearingCurrent: Bool) {
    back.removeAll { $0 == pid }
    forward.removeAll { $0 == pid }
    if target == pid { target = nil }
    if clearingCurrent, current == pid { current = nil }
  }

  /// Treat the observed activation history as a ring. A normal activation
  /// appends to `back`; navigation partitions that same ring around its
  /// target, so either direction always has somewhere to go once two apps
  /// were seen.
  static func ring(
    direction: AppDelegate.NavigationDirection,
    current: pid_t?,
    back: [pid_t],
    forward: [pid_t],
    isAvailable: (pid_t) -> Bool
  ) -> (target: pid_t, back: [pid_t], forward: [pid_t])? {
    guard let current else { return nil }

    var ordered: [pid_t] = []
    var seen = Set<pid_t>()
    for pid in back + [current] + forward.reversed()
    where isAvailable(pid) && seen.insert(pid).inserted {
      ordered.append(pid)
    }
    guard ordered.count > 1, let currentIndex = ordered.firstIndex(of: current) else {
      return nil
    }

    let targetIndex: Int
    switch direction {
    case .back:
      targetIndex = (currentIndex - 1 + ordered.count) % ordered.count
    case .forward:
      targetIndex = (currentIndex + 1) % ordered.count
    }
    return (
      target: ordered[targetIndex],
      back: Array(ordered[..<targetIndex]),
      forward: Array(ordered[ordered.index(after: targetIndex)...].reversed())
    )
  }

  /// The app to focus after `quitting` goes away, and the back stack that
  /// leaves that app current. Recency is the app focused now, then the one
  /// just left (`forward`'s tail), then older apps. The quitting pid is
  /// never a candidate. `isAvailable` drops terminated apps and Flash itself.
  static func quitFocus(
    quitting: pid_t,
    current: pid_t?,
    back: [pid_t],
    forward: [pid_t],
    isAvailable: (pid_t) -> Bool
  ) -> (target: pid_t, back: [pid_t])? {
    var seen = Set<pid_t>()
    var recentFirst: [pid_t] = []
    let recency = (current.map { [$0] } ?? []) + forward.reversed() + back.reversed()
    for pid in recency where pid != quitting && isAvailable(pid) && seen.insert(pid).inserted {
      recentFirst.append(pid)
    }
    guard let target = recentFirst.first else { return nil }
    return (target: target, back: Array(recentFirst.dropFirst().reversed()))
  }
}

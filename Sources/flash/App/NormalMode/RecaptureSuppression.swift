import Foundation

/// The reasons normal-mode keyboard recapture is briefly held off, each with an
/// expiry. Consolidates what were three parallel `Date?` fields plus three
/// identical `…IsActive` helpers into one tested value, so they can't drift and
/// "is anything holding recapture off right now?" has a single answer.
///
/// These windows are a deliberate *backstop*, not the primary recapture trigger.
/// A native surface (a context menu, or an in-flight pointer→insert handoff) owns
/// the keyboard and the real recapture fires on the user's next interaction. We
/// never force a recapture when a window merely expires: doing so would re-grab
/// the keyboard out from under a menu the user is still holding open — and an
/// in-page menu (e.g. Slack's) exposes no OS "closed" signal to do better. The
/// expiry only bounds how long a *stale* window lingers, via `pruneExpired`.
struct RecaptureSuppression: Equatable {
  /// A menu-bar click is being handled by the system menu.
  var menuBarUntil: Date?
  /// A context menu (right-click / `AXShowMenu`) owns its own modal key session.
  var contextMenuUntil: Date?
  /// A pointer click is being probed for an insert-mode handoff.
  var pointerInsertHandoffUntil: Date?

  func menuBarActive(now: Date) -> Bool { Self.active(menuBarUntil, now: now) }
  func contextMenuActive(now: Date) -> Bool { Self.active(contextMenuUntil, now: now) }
  func pointerInsertHandoffActive(now: Date) -> Bool {
    Self.active(pointerInsertHandoffUntil, now: now)
  }

  /// True while any reason is still holding recapture off.
  func anyActive(now: Date) -> Bool {
    menuBarActive(now: now)
      || contextMenuActive(now: now)
      || pointerInsertHandoffActive(now: now)
  }

  /// Clear windows whose expiry has already elapsed, so a stale `Date?` can't
  /// linger. The single home for the expiry sweep that was inlined per-field.
  mutating func pruneExpired(now: Date) {
    if let until = menuBarUntil, until <= now { menuBarUntil = nil }
    if let until = contextMenuUntil, until <= now { contextMenuUntil = nil }
    if let until = pointerInsertHandoffUntil, until <= now { pointerInsertHandoffUntil = nil }
  }

  /// The single suppression-window predicate (was copy-pasted three times).
  static func active(_ until: Date?, now: Date) -> Bool {
    guard let until else { return false }
    return now < until
  }
}

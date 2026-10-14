import Foundation

/// Everything a HYPER hold owns, as one value: the physical leader hold, the
/// HID backstop watch, and the two sequences typed during the hold. Every
/// exit from HYPER — the release, `leave_mode`, opening the command line, a
/// focus change — ends them together through `modeChanged`, the one reset
/// point, so no exit path can leave a latched hold that swallows the next
/// leader press, or a pending sequence that completes in another mode.
struct HyperHoldState: Equatable {
  var leaderHold = LeaderHold()
  /// Samples of a latched hold whose key-up the tap may have dropped.
  var watch = HyperHoldWatch()
  /// Sequence state for keys typed while the leader is held. Separate from
  /// the NORMAL pending sequence so a hyper sequence cannot leak into NORMAL.
  var pending: String = "" {
    didSet { if pending.isEmpty { pendingUpdatedAt = nil } }
  }
  var pendingUpdatedAt: Date?
  /// NORMAL `<leader>` sequence continued by a key pressed while the leader
  /// is still down. Nil when the hold is not inside that fallback.
  var fallbackPending: String? {
    didSet { if fallbackPending == nil { fallbackUpdatedAt = nil } }
  }
  var fallbackUpdatedAt: Date?

  /// Leaving HYPER, by any event, ends the hold and drops its sequences.
  mutating func modeChanged(from previous: Mode, to next: Mode) {
    if previous.isHyper, !next.isHyper { self = HyperHoldState() }
  }
}

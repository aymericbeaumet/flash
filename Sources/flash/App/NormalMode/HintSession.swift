import CoreGraphics
import Darwin
import FlashCore
import Foundation

/// The transient "hints are showing / mouse-grid in progress" content. Grouping
/// these into one value means the session reset is a single assignment
/// (`hintSession = HintSession()`), so a newly added field can't leak across
/// activations by being forgotten in a hand-maintained reset list — the bug the
/// old `clearHintSessionState()` comment warned about.
///
/// `pendingAction` is deliberately NOT here: the mouse-grid commit reads it
/// *after* the session reset, so it must outlive the reset and stays a separate
/// field on `AppDelegate`.
struct HintSession {
  var hints: [AssignedHint] = []
  var prefix: String = ""
  var commitBehavior: AppDelegate.HintCommitBehavior = .click
  /// Modifiers requested by the command that opened the hints. These are
  /// unioned with any magic modifiers held on the final hint key.
  var presetClickModifiers: ClickModifiers = []
  var sourceAppPID: pid_t?
  var mouseGridRegion: MouseGrid.Region?
  var mouseGridDepth: Int = 0
  /// Two-phase gestures (`--drag`): the point the first commit selected,
  /// nil while the session is still choosing it. Cleared with the session,
  /// so Escape mid-gesture can't leak a grab point into the next activation.
  var dragSourcePoint: CGPoint?
  /// The full-extent grid region captured at activation, so a grid drag can
  /// restart the destination phase from the top instead of the drilled-down
  /// cell the source phase ended on.
  var mouseGridInitialRegion: MouseGrid.Region?
  /// `--adjust` sub-state: the matched hint whose click point is being
  /// refined, and the current point the commit key will click.
  var adjustingHint: AssignedHint?
  var adjustPoint: CGPoint?
  /// Pointer mode (`mouse_pointer`): freestyle cursor control session with
  /// autorepeat acceleration bookkeeping and the drag-toggle button state.
  var pointerModeActive = false
  var pointerDragActive = false
  var pointerMoveStreak = 0
  var pointerLastMoveAt: Date?
}

/// The activation generation-token machine: the async-cancellation core that
/// keeps a stale AX discovery walk from rendering hints over the wrong app after
/// a newer activation, commit, or cancel has taken over. Was three scalars
/// (`activationGen`, `activationInFlight`, `activationInFlightGeneration`)
/// mutated inline across ~7 sites; expressing the operations as named methods
/// makes the "which walk wins" rule one tested unit that can't be half-applied.
struct ActivationLifecycle: Equatable {
  /// Monotonic token; every `begin`/`supersede`/`invalidate` bumps it. A walk's
  /// result renders only while `isCurrent(itsToken)`.
  var generation: UInt64 = 0
  /// True while an AX discovery walk (or a commit's click dispatch) is
  /// outstanding; gates re-entry.
  var inFlight: Bool = false
  /// The generation captured when the outstanding walk began, so its completion
  /// can open the gate even if a newer walk has already superseded it.
  var inFlightGeneration: UInt64?

  /// Start a new walk; returns its generation token.
  mutating func begin() -> UInt64 {
    generation &+= 1
    inFlight = true
    inFlightGeneration = generation
    return generation
  }

  /// Bump the generation so any outstanding walk's result is ignored, without
  /// clearing `inFlight` (that walk's completion still runs to clean up).
  mutating func supersede() {
    generation &+= 1
  }

  /// The walk that owns `token` finished: open the gate iff it is still the
  /// outstanding one (a newer `begin()` may have taken over in the meantime).
  mutating func complete(token: UInt64) {
    guard inFlightGeneration == token else { return }
    inFlight = false
    inFlightGeneration = nil
  }

  /// Fully cancel: bump the generation and open the gate.
  mutating func invalidate() {
    generation &+= 1
    inFlight = false
    inFlightGeneration = nil
  }

  /// Whether a result tagged `token` is still the current walk's.
  func isCurrent(_ token: UInt64) -> Bool {
    generation == token
  }
}

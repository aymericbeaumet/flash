import CoreGraphics
import Darwin
import FlashCore
import Foundation

/// The transient "hints are showing / mouse-grid in progress" content. Grouping
/// these into one value means the session reset is a single assignment
/// (`hintSession = HintSession()`), so a newly added field can't leak across
/// activations by being forgotten in a hand-maintained reset list — the bug the
/// old `clearHintSessionState()` comment warned about.
struct HintSession {
  var action: JumpAction = .leftClick
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
  private(set) var pointerDragActive = false
  var pointerMoveStreak = 0
  var pointerLastMoveAt: Date?
  /// `--search` (seek & click): the typed filter, the current selection
  /// index into the filtered set, and the unfiltered master hint set so
  /// backspace can widen again.
  var searchActive = false
  var searchQuery = ""
  var searchSelectionIndex = 0
  var searchAllHints: [AssignedHint] = []

  var isActive: Bool {
    !hints.isEmpty || pointerModeActive || searchActive || adjustingHint != nil
  }

  enum ExitEffect: Equatable { case releasePrimaryButton }

  mutating func didPressPrimaryButton() { pointerDragActive = true }

  /// Consume ownership before emitting the release, including reentrant teardown.
  mutating func releasePrimaryButton() -> ExitEffect? {
    guard pointerDragActive else { return nil }
    pointerDragActive = false
    return .releasePrimaryButton
  }

  mutating func finish() -> [ExitEffect] {
    let effects = releasePrimaryButton().map { [$0] } ?? []
    self = HintSession()
    return effects
  }
}

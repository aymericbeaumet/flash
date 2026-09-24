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
  /// Where the hints came from: discovered targets, or the mouse grid's cells.
  enum Surface { case targets, grid }

  /// The verb that opened the session — button, click count, the preset
  /// modifiers, and the session shape (move, drag, select, multi, adjust,
  /// search). Magic modifiers held on the final hint key are unioned with the
  /// preset ones at commit.
  var command: MouseCommand = .click(.leftClick, modifiers: [])
  var surface: Surface = .targets
  var hints: [AssignedHint] = []
  var prefix: String = ""
  var sourceAppPID: pid_t?
  /// How this session's keys arrive, fixed when it starts
  /// (`KeyboardCaptureTap.sessionCapture`).
  var capture = KeyboardCaptureTap.SessionCapture.tap
  /// Armed when the activation starts, spent by its first display.
  var latencyProbe: HintLatencyProbe?
  var statusBarPopupSnapshots: [String: StatusBarPopupRegion] = [:]
  /// Where the mouse grid is and how it got there; nil outside the grid.
  var grid: MouseGrid.Navigation?
  /// The grid's key layout, fixed for the session.
  var gridShape = MouseGrid.Shape.keyboard([])
  /// Whether the pointer follows the grid region (`` ` `` toggles it).
  var gridCursorFollows = false
  /// Label → index into `hints` for the displayed grid step, so a key finds
  /// its cell without scanning.
  var gridCellIndex: [Character: Int] = [:]

  /// The first point of a two-phase gesture (`--drag`, `--select`).
  struct Anchor {
    var point: CGPoint
    /// The hint it came from; nil when a grid cell chose it.
    var hint: AssignedHint?
    /// The grid step the point was chosen from, restored when Backspace
    /// undoes the anchor; nil for target hints.
    var grid: MouseGrid.Navigation? = nil
  }

  /// `--search` (seek & click): the typed filter, the selection index into
  /// the filtered set, and the unfiltered set so backspace can widen again.
  struct Search {
    var query = ""
    var selectionIndex = 0
    var allHints: [AssignedHint] = []
  }

  /// `mouse_pointer`: autorepeat acceleration bookkeeping and the button the
  /// drag toggle holds.
  struct Pointer {
    var moveStreak = 0
    var lastMoveAt: Date?
    fileprivate(set) var dragActive = false
  }

  /// What keys do in this session. The phases exclude one another — a session
  /// types labels, filters by text, refines a matched point, or steers the
  /// pointer — so they are one value, never a set of flags.
  enum Phase {
    /// Typing hint labels; `anchor` once a two-phase gesture chose its first
    /// point.
    case labels(anchor: Anchor?)
    case search(Search)
    /// `--adjust`: the matched hint and the point the commit key clicks.
    case adjusting(hint: AssignedHint, point: CGPoint)
    case pointer(Pointer)
  }

  var phase = Phase.labels(anchor: nil)

  /// How the overlay routes keys; a projection of `phase`, with label typing
  /// on the grid surface going to the grid.
  var keyRoute: HintKeyRoute {
    switch phase {
    case .labels:
      guard surface == .grid else { return .labels }
      return .grid(gridShape, cursorFollows: gridCursorFollows)
    case .search: return .search
    case .adjusting: return .adjustment
    case .pointer: return .pointer
    }
  }

  var anchor: Anchor? {
    if case .labels(let anchor) = phase { return anchor }
    return nil
  }

  var search: Search? {
    if case .search(let search) = phase { return search }
    return nil
  }

  var pointer: Pointer? {
    if case .pointer(let pointer) = phase { return pointer }
    return nil
  }

  var pointerDragActive: Bool { pointer?.dragActive ?? false }

  /// Search, adjustment and pointer phases own the keyboard even with no hint
  /// on screen; typing labels needs hints.
  var isActive: Bool {
    if case .labels = phase { return !hints.isEmpty }
    return true
  }

  /// Phase 1 of a grid drag or selection: keep the point with the step it
  /// was chosen from, and restart the grid on the whole display so the second
  /// point can land anywhere.
  mutating func anchorGrid(at point: CGPoint) {
    guard let navigation = grid else { return }
    phase = .labels(anchor: Anchor(point: point, hint: nil, grid: navigation))
    grid = navigation.restarted
  }

  /// Backspace in the grid: undo the last grid keystroke, or, with nothing
  /// left to undo in a gesture's second phase, drop the anchor and return to
  /// the step it was chosen from. False when there is nothing to undo.
  mutating func gridBack() -> Bool {
    guard var navigation = grid else { return false }
    if navigation.back() {
      grid = navigation
      return true
    }
    guard case .labels(let anchor?) = phase, let source = anchor.grid else { return false }
    phase = .labels(anchor: nil)
    grid = source
    return true
  }

  enum ExitEffect: Equatable { case releasePrimaryButton }

  mutating func didPressPrimaryButton() {
    guard case .pointer(var pointer) = phase else { return }
    pointer.dragActive = true
    phase = .pointer(pointer)
  }

  /// Consume ownership before emitting the release, including reentrant teardown.
  mutating func releasePrimaryButton() -> ExitEffect? {
    guard case .pointer(var pointer) = phase, pointer.dragActive else { return nil }
    pointer.dragActive = false
    phase = .pointer(pointer)
    return .releasePrimaryButton
  }

  mutating func finish() -> [ExitEffect] {
    let effects = releasePrimaryButton().map { [$0] } ?? []
    self = HintSession()
    return effects
  }
}

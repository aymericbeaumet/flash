import Foundation

// Owns the one `Mode` value and is its only mutator. Every mode change in the
// app flows through `dispatch` → `ModeReducer.reduce` → `perform(effects)`.
//
// AppKit-free: it holds the pure reducer plus a `perform` closure that the
// AppKit edge (AppDelegate) installs to execute effects. The closure is set
// once during launch; events dispatched before then (there are none in
// practice) simply apply no effects.
final class ModeStore {
  private(set) var mode: Mode

  /// Installed by the executor (AppDelegate). Receives the effects plus the
  /// previous/next mode so it can run leave/enter bookkeeping.
  var perform: ((_ effects: [ModeEffect], _ previous: Mode, _ next: Mode) -> Void)?

  init(initial: Mode = .disabled) {
    mode = initial
  }

  @discardableResult
  func dispatch(_ event: ModeEvent) -> Mode {
    let previous = mode
    let (next, effects) = ModeReducer.reduce(mode, event)
    mode = next
    perform?(effects, previous, next)
    return next
  }
}

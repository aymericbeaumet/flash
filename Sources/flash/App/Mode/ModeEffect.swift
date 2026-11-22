import Foundation

/// Which native mapping set Carbon should own. Terminal input suspends every
/// global registration so only the popup's local mappings can intercept keys.
enum MappingScope: Hashable {
  case normal
  /// Dragging: `[mode.hold.mappings]` over NORMAL.
  case hold
  /// NORMAL acting on the focused text: `[mode.text.mappings]` over
  /// NORMAL. Not a mode of its own; the focus picks it (`TextScope`).
  case text
  /// VISUAL: `[mode.visual.mappings]` over the text table's motions.
  case visual
  case insert
  case command
  case terminal
  /// A layer's own table, then the implicit Escape and `[mode.all]`.
  case layer(String)

  /// The scope as `flash resident status` reports it: the table's name, a
  /// layer by its own.
  var name: String {
    switch self {
    case .normal: return "normal"
    case .hold: return "hold"
    case .text: return "text"
    case .visual: return "visual"
    case .insert: return "insert"
    case .command: return "command"
    case .terminal: return "terminal"
    case .layer(let name): return name
    }
  }
}

// What the reducer asks the AppKit edge (`ModeExecutor`) to do after a
// transition. The reducer DESCRIBES; the executor PERFORMS. Keeping effects as
// data is what lets the reducer stay pure and fully unit-testable.
//
// Effects are intentionally coarse and idempotent — each maps to one existing
// AppDelegate routine — so the executor is a dumb `switch` with no decisions of
// its own.
enum ModeEffect: Equatable {
  /// Resolve tap availability before startup can render a capturing surface.
  case prepareKeyboardCapture

  /// Reset transient capture context once when an explicit transition enters a mode.
  case prepareModeEntry

  /// Recompute and push everything derived from `Mode`: `overlay.inputMode`,
  /// the badge (text/style/visibility/capture), the status-bar label, and the
  /// INSERT active-window border. This is the single write path for all of
  /// those — they cannot drift.
  case renderSurface

  /// Ensure the overlay panel regains key-window status so NORMAL/command/modal
  /// capture works. Replaces the old multi-stage recapture ramp + recovery.
  case scheduleRecapture

  /// Return activation from Flash to the app an explicitly dismissed popup
  /// covered. Ignored once another application already owns activation.
  case restoreCoveredApp(pid: pid_t)

  /// Drop any in-flight hints / activation when leaving to a base mode.
  case clearTransientHintState

  /// Hide the overlay on INSERT entry when no hints are showing.
  case hideOverlayIfIdle

  /// Flush pending local input and dismiss the popup before restoring capture.
  case hideTerminalPopup
}

import Foundation

// What the reducer asks the AppKit edge (`ModeExecutor`) to do after a
// transition. The reducer DESCRIBES; the executor PERFORMS. Keeping effects as
// data is what lets the reducer stay pure and fully unit-testable.
//
// Effects are intentionally coarse and idempotent — each maps to one existing
// AppDelegate routine — so the executor is a dumb `switch` with no decisions of
// its own.
enum ModeEffect: Equatable {
  /// Re-register the scope-bound Carbon hotkeys for this insert/normal axis.
  /// (`mappings.applyForFlashMode`; the executor dedupes no-op re-applies.)
  case setMappingScope(FlashMode)

  /// Recompute and push everything derived from `Mode`: `overlay.inputMode`,
  /// the badge (text/style/visibility/capture), the status-bar label, and the
  /// INSERT active-window border. This is the single write path for all of
  /// those — they cannot drift.
  case renderSurface

  /// Ensure the overlay panel regains key-window status so NORMAL/command/modal
  /// capture works. Replaces the old multi-stage recapture ramp + recovery.
  case scheduleRecapture

  /// Re-activate the focused app on INSERT entry so its window reclaims key
  /// status from the panel (the Messages "first keystroke dropped" fix).
  case activateFocusedApp(pid: pid_t?)

  /// Drop any in-flight hints / activation when leaving to a base mode.
  case clearTransientHintState

  /// Hide the overlay on INSERT entry when no hints are showing.
  case hideOverlayIfIdle
}

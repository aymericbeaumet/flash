import Foundation

// The single source of truth for "what surface is Flash in right now".
//
// This replaces the old two-axis state (`flashMode: FlashMode` × stored
// `overlay.inputMode: OverlayInputMode`) plus the scattered badge/label caches.
// Every UI-facing fact — overlay input routing, status-bar label, badge style,
// keyboard capture, and the active Carbon mapping scope — is a PURE PROJECTION
// of this value (see the computed vars below). Nothing derived is stored, so
// nothing can drift.
//
// Transitions happen only through `ModeReducer.reduce` in response to a
// classified `ModeEvent`. There is no path that mutates `Mode` directly.
//
// Note: this file (and everything under `Sources/flash/App/Mode/`) is
// deliberately AppKit-free. The `ModeReducerTests` assert this — the purity is
// what makes the state machine exhaustively unit-testable.
enum Mode: Equatable {
  /// Advanced mode is OFF (the user has not bound a normal-mode hotkey).
  /// Behaves like a non-capturing insert; the only way out is the config
  /// enabling advanced mode. Keeping this as its own case makes the illegal
  /// "advanced-off but in NORMAL" combination unrepresentable.
  case disabled

  /// Keyboard is handed to the focused app. `locked` distinguishes `I`
  /// (locked) from `i` for the badge/diagnostics; it no longer gates any
  /// transition now that automatic exits are gone.
  case insert(locked: Bool)

  /// The overlay owns the keyboard and interprets keys as commands.
  case normal

  /// Command line / flashlight surface. `restoreTo` records where to land when
  /// the surface closes.
  case command(scope: CommandScope, restoreTo: ReturnMode)

  /// Read-only / selectable modal (`:help`, `:plugins`, `:clipboard`).
  case modal(restoreTo: ReturnMode)
}

/// Which command surface is active. `finder` is the flashlight candidate picker
/// (`:` flashlight seed); `commandLine` is the plain `:` prompt.
enum CommandScope: Equatable {
  case commandLine
  case finder(all: Bool)
}

/// Where a transient surface (command / modal) returns to when it closes.
/// A restricted projection of `Mode` — you can only return to a base mode.
enum ReturnMode: Equatable {
  case disabled
  case insert(locked: Bool)
  case normal

  var mode: Mode {
    switch self {
    case .disabled: return .disabled
    case .insert(let locked): return .insert(locked: locked)
    case .normal: return .normal
    }
  }
}

extension Mode {
  /// The base (non-surface) mode this collapses to, used to compute the
  /// `restoreTo` for a surface opened from here.
  var asReturnMode: ReturnMode {
    switch self {
    case .disabled: return .disabled
    case .insert(let locked): return .insert(locked: locked)
    case .normal: return .normal
    // Surfaces nest at most one deep in practice; collapse to their own base.
    case .command(_, let restoreTo): return restoreTo
    case .modal(let restoreTo): return restoreTo
    }
  }

  var isInsert: Bool {
    if case .insert = self { return true }
    return false
  }

  var isNormal: Bool { self == .normal }
}

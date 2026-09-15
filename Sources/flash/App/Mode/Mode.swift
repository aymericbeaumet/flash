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
  /// Behaves like a non-capturing passthrough; the only way out is the config
  /// enabling advanced mode. Keeping this as its own case makes the illegal
  /// "advanced-off but in NORMAL" combination unrepresentable.
  case disabled

  /// Keyboard is handed to the focused app until an explicit mode change.
  case passthrough

  /// A one-shot entry lasts through one resolved command and its interaction.
  /// Persistent entries retain capture until an explicit handoff or exit.
  case normal(persistent: Bool, action: NormalActionPhase = .ready)

  /// Command line / flashlight surface. `restoreTo` preserves advanced-mode
  /// eligibility while every dismissal returns keyboard ownership to the app.
  case command(scope: CommandScope, restoreTo: ReturnMode)

  /// A popup's local terminal view owns keyboard input; global mappings are suspended.
  case terminal(restoreTo: ReturnMode)
}

enum NormalActionPhase: Equatable {
  case ready
  case dispatching
  case waitingForInteraction
}

/// Which command surface is active. `finder` is the flashlight candidate picker
/// (`:` flashlight seed); `commandLine` is the plain `:` prompt.
enum CommandScope: Equatable {
  case commandLine
  case finder(all: Bool)
}

/// Surfaces always return input to the app; advanced eligibility remains explicit.
enum ReturnMode: Equatable {
  case disabled
  case passthrough

  var mode: Mode {
    switch self {
    case .disabled: return .disabled
    case .passthrough: return .passthrough
    }
  }
}

extension Mode {
  /// The base (non-surface) mode this collapses to, used to compute the
  /// `restoreTo` for a surface opened from here.
  var asReturnMode: ReturnMode {
    switch self {
    case .disabled: return .disabled
    case .passthrough, .normal: return .passthrough
    // Surfaces nest at most one deep in practice; collapse to their own base.
    case .command(_, let restoreTo), .terminal(let restoreTo): return restoreTo
    }
  }

  var isPassthrough: Bool {
    if case .passthrough = self { return true }
    return false
  }

  var isNormal: Bool {
    if case .normal = self { return true }
    return false
  }

  var isTerminal: Bool {
    if case .terminal = self { return true }
    return false
  }

  var advancedEnabled: Bool { asReturnMode != .disabled }
}

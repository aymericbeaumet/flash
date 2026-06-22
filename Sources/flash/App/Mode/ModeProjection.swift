import Foundation

// Pure projections of `Mode`. These are the anti-drift core: every UI-facing
// fact is derived here and nowhere else, so the status bar, badge, overlay
// input routing, keyboard capture, and Carbon mapping scope can never disagree
// about what mode we are in.

/// Which configured label string to show. The executor maps this to the
/// user-configured `Config.Mode.Labels` text, keeping config out of the core.
enum ModeLabel: Equatable {
  case insert
  case normal
  case command
}

extension Mode {
  /// The coarse insert/normal axis used by consumers that only care about that
  /// distinction: the Carbon mapping scope (`mappings.applyForFlashMode`) and
  /// the pointer interaction policy. Surfaces (command/modal) keep NORMAL's
  /// scope so normal-scoped hotkeys stay live while a surface is open.
  var flashMode: FlashMode {
    switch self {
    case .disabled, .insert: return .insert
    case .normal, .command, .modal: return .normal
    }
  }

  /// True when the overlay owns the keyboard as a command surface. For NORMAL
  /// this is only true when idle — while hints are on screen or an activation
  /// is in flight the overlay is routing hint letters, not commands.
  func ownsKeyboard(hasHints: Bool, activationInFlight: Bool) -> Bool {
    switch self {
    case .disabled, .insert:
      return false
    case .normal:
      return !hasHints && !activationInFlight
    case .command, .modal:
      return true
    }
  }

  /// The overlay's input-routing mode. This REPLACES the independently-stored
  /// `overlay.inputMode`; the executor sets `overlay.inputMode` to exactly this
  /// value whenever the mode, hint state, or activation changes.
  func overlayInputMode(hasHints: Bool, activationInFlight: Bool) -> OverlayInputMode {
    switch self {
    case .disabled, .insert:
      return .hints
    case .normal:
      return ownsKeyboard(hasHints: hasHints, activationInFlight: activationInFlight)
        ? .normal : .hints
    case .command(let scope, _):
      switch scope {
      case .commandLine: return .commandLine
      case .finder: return .candidateFinder
      }
    case .modal:
      return .modal
    }
  }

  /// Which label string the status bar / badge shows.
  var label: ModeLabel {
    switch self {
    case .disabled, .insert: return .insert
    case .normal: return .normal
    case .command, .modal: return .command
    }
  }

  /// The badge color/style. This is the projection that closes the "COMMAND is
  /// a lie" bug — `.command` now comes from the mode, not from display code
  /// painting over a badge while the mode stays `.normal`.
  var badgeStyle: OverlayModeBadgeStyle {
    switch self {
    case .disabled, .insert: return .insert
    case .normal: return .normal
    case .command, .modal: return .command
    }
  }

  /// Whether the mode badge is intrinsically shown. The executor ANDs this with
  /// `statusBarVisible` so `[statusbar] enabled` independently gates the bar.
  var badgeVisibleIntrinsic: Bool {
    // Advanced mode keeps the badge in both NORMAL and INSERT; with advanced
    // off the bar still shows "INSERT" when the status bar is enabled.
    true
  }
}

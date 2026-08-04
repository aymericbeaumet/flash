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
  /// distinction and the pointer interaction policy. Command surfaces have a
  /// separate mapping scope effect that unregisters Carbon mappings while the
  /// field editor owns the keyboard.
  var flashMode: FlashMode {
    switch self {
    case .disabled, .insert: return .insert
    case .normal, .command: return .normal
    }
  }

  /// True when the overlay owns the keyboard as a command surface. For NORMAL
  /// this is only true when idle — while hints are on screen or an activation
  /// is in flight the overlay is routing hint letters, not commands.
  func ownsKeyboard(
    hasHints: Bool,
    activationInFlight: Bool,
    nativeSurfaceSuspended: Bool = false
  ) -> Bool {
    // A native surface (a context menu / OS popup) runs its own modal key
    // session, so the overlay must not capture while one is up — even though the
    // base mode is unchanged. This is the projection's single home for the
    // "suspended for a native surface" fact, so `suspendNormalCaptureForNativeSurface`
    // sets a flag and re-renders instead of poking `overlay` fields directly.
    if nativeSurfaceSuspended { return false }
    switch self {
    case .disabled, .insert:
      return false
    case .normal:
      return !hasHints && !activationInFlight
    case .command:
      return true
    }
  }

  /// The overlay's input-routing mode. This REPLACES the independently-stored
  /// `overlay.inputMode`; the executor sets `overlay.inputMode` to exactly this
  /// value whenever the mode, hint state, or activation changes.
  func overlayInputMode(
    hasHints: Bool,
    activationInFlight: Bool,
    nativeSurfaceSuspended: Bool = false
  ) -> OverlayInputMode {
    // While suspended for a native surface, route as `.normal` (never `.hints`):
    // `.hints` hides the mouse cursor, but the user needs a visible cursor to
    // drive the context menu. Capture is off regardless (see `ownsKeyboard`); this
    // only governs cursor visibility / routing for when capture later resumes.
    if nativeSurfaceSuspended, case .normal = self { return .normal }
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
    }
  }

  /// Which label string the status bar / badge shows.
  var label: ModeLabel {
    switch self {
    case .disabled, .insert: return .insert
    case .normal: return .normal
    case .command: return .command
    }
  }

  /// The badge color/style. This is the projection that closes the "COMMAND is
  /// a lie" bug — `.command` now comes from the mode, not from display code
  /// painting over a badge while the mode stays `.normal`.
  var badgeStyle: OverlayModeBadgeStyle {
    switch self {
    case .disabled, .insert: return .insert
    case .normal: return .normal
    case .command: return .command
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

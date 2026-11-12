import FlashCore

/// What a click does to the mode: nothing. A click, made with the mouse, by
/// `f` (`mouse target`) or by `F` (`mouse grid`), never enters INSERT; only
/// `mode insert` does (AGENTS.md hard constraint 9). These decisions say who
/// owns the keyboard once the click is out.
enum NormalModePointerPolicy {
  /// What a physical click in an app does to NORMAL — exactly one outcome.
  enum AppClickDecision: Equatable {
    /// NORMAL doesn't own the click (another mode, the command line).
    case ignore
    /// A right-click's native context menu runs its own modal key session:
    /// NORMAL capture suspends until it closes, and transient hints showing
    /// behind it are dropped first.
    case suspendForNativeSurface(dismissHints: Bool)
    /// A primary or middle click: the app gets it, wherever it lands (a
    /// text field, a password field, a terminal included), and NORMAL keeps
    /// the keyboard.
    case keepNormal
  }

  enum PointerDecision: Equatable {
    case passThrough
    /// A menu-bar click opens a native menu: NORMAL capture suspends,
    /// transient hints showing behind it are dropped first.
    case menuBar(dismissHints: Bool)
    case app(AppClickDecision)
    case cancelOverlay
  }

  static func pointerDecision(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    intent: OverlayPointerIntent,
    pointIsInMenuBar: Bool
  ) -> PointerDecision {
    if case .scroll = intent {
      // The command bar / candidate list is a focused, keyboard-driven
      // surface: a stray scroll (trackpad inertia, reading the page behind
      // it) must NOT tear it down — the user dismisses it with Esc. Hints are
      // different: a scroll there means "let me read the page", so the
      // transient hints get out of the way.
      if overlayInputMode == .commandLine {
        return .passThrough
      }
      if hasHints {
        return .cancelOverlay
      }
      return .passThrough
    }

    guard case .click(let click) = intent else { return .cancelOverlay }
    if pointIsInMenuBar, !activationInFlight {
      return .menuBar(dismissHints: hasHints)
    }

    let decision = appClickDecision(
      mode: mode,
      wasCommandLine: overlayInputMode == .commandLine,
      hasHints: hasHints,
      action: click.action)
    guard decision != .ignore else { return .cancelOverlay }
    return .app(decision)
  }

  static func appClickDecision(
    mode: FlashMode,
    wasCommandLine: Bool,
    hasHints: Bool,
    action: JumpAction
  ) -> AppClickDecision {
    guard mode == .normal, !wasCommandLine else { return .ignore }
    // Right-click opens a native context menu that runs its own modal key
    // session. Suspend normal capture so the menu owns the keyboard, then
    // NORMAL resumes when it dismisses; drop any transient hints first so they
    // don't linger behind the menu.
    if action == .rightClick {
      return .suspendForNativeSurface(dismissHints: hasHints)
    }
    // Any other click goes to the app and NORMAL keeps the keyboard.
    return .keepNormal
  }

  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }
}

/// How a command NORMAL asked of the focused app ended.
enum NormalModeCommandOutcome: Equatable {
  /// A source performed the command in the context it owns.
  case performed
  /// The command's chord was posted to the focused app.
  case chordSent
  /// A source claimed the command and could not complete it.
  case failed
  /// The focused app has no such command.
  case unavailable
  /// There was no app to act in.
  case noTarget
  /// A terminal would have typed the chord as text, so it was not sent.
  case refused
}

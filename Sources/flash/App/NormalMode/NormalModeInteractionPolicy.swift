import FlashCore

enum NormalModePointerPolicy {
  /// What a committed click landed on. `f` knows its target's role from
  /// discovery; `F` hit-tests the grid point before clicking. Either way
  /// `entersInsertMode` is the same text-input judgement.
  enum ClickTarget: Equatable {
    case hint(entersInsertMode: Bool)
    case grid(entersInsertMode: Bool)

    var entersInsertMode: Bool {
      switch self {
      case .hint(let enters), .grid(let enters): return enters
      }
    }
  }

  /// One rule for `f` and `F`: a primary, double or triple click on a text
  /// input enters INSERT; anything else — another target, a secondary or
  /// middle click — keeps NORMAL.
  static func clickShouldEnterInsert(target: ClickTarget, action: JumpAction) -> Bool {
    guard target.entersInsertMode else { return false }
    switch action {
    case .leftClick, .doubleClick, .tripleClick:
      return true
    case .rightClick, .middleClick:
      return false
    }
  }

  /// What a physical click in an app does to NORMAL — exactly one outcome.
  enum AppClickDecision: Equatable {
    /// NORMAL doesn't own the click (another mode, the command line).
    case ignore
    /// A right-click's native context menu runs its own modal key session:
    /// NORMAL capture suspends until it closes, and transient hints showing
    /// behind it are dropped first.
    case suspendForNativeSurface(dismissHints: Bool)
    /// A left / double click hands the keyboard to the app and enters INSERT.
    case handOffToInsert
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
    // session — it must NEVER flip the mode (same rule as the `f`/`F` commits).
    // Suspend normal capture so the menu owns the keyboard, then NORMAL resumes
    // when it dismisses; drop any transient hints first so they don't linger
    // behind the menu.
    if action == .rightClick {
      return .suspendForNativeSurface(dismissHints: hasHints)
    }
    // A physical left / double click always hands the keyboard to the app and
    // enters INSERT. Hint clicks additionally require an input target.
    return .handOffToInsert
  }

  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }
}

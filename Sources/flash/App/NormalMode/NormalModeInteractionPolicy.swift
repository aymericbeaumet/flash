import FlashCore

/// The user intent behind a primary pointer commit. Semantic hints honor the
/// provider's target metadata; physical and grid clicks are pointer simulation
/// and therefore hand the keyboard to the app unconditionally.
enum PointerInsertIntent: Equatable {
  case physicalClick
  case mouseGridClick
  case hintTarget(entersInsertMode: Bool)

  var shouldEnterInsertMode: Bool {
    switch self {
    case .physicalClick, .mouseGridClick:
      return true
    case .hintTarget(let entersInsertMode):
      return entersInsertMode
    }
  }
}

enum NormalModePointerPolicy {
  struct AppClickDecision: Equatable {
    var releaseCapture: Bool
    var enterInsert: Bool
    var suspendForNativeSurface: Bool
    var dismissTransientHintsWithoutRekey: Bool
  }

  struct MenuBarClickDecision: Equatable {
    var suspendForNativeSurface: Bool
    var dismissTransientHintsWithoutRekey: Bool
  }

  enum PointerDecision: Equatable {
    case passThrough
    case menuBar(MenuBarClickDecision)
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
      if overlayInputMode == .commandLine || overlayInputMode == .candidateFinder {
        return .passThrough
      }
      if hasHints {
        return .cancelOverlay
      }
      return .passThrough
    }

    guard case .click(let click) = intent else { return .cancelOverlay }
    if pointIsInMenuBar, !activationInFlight {
      return .menuBar(
        MenuBarClickDecision(
          suspendForNativeSurface: true,
          dismissTransientHintsWithoutRekey: hasHints))
    }

    let decision = appClickDecision(
      mode: mode,
      wasCommandLine: overlayInputMode == .commandLine,
      hasHints: hasHints,
      action: click.action)
    guard decision.releaseCapture || decision.enterInsert || decision.suspendForNativeSurface
    else { return .cancelOverlay }
    return .app(decision)
  }

  static func appClickDecision(
    mode: FlashMode,
    wasCommandLine: Bool,
    hasHints: Bool,
    action: JumpAction
  ) -> AppClickDecision {
    guard mode == .normal, !wasCommandLine else {
      return AppClickDecision(
        releaseCapture: false,
        enterInsert: false,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false)
    }
    // Right-click opens a native context menu that runs its own modal key
    // session — it must NEVER flip the mode (same rule as the `f`/`F` commits).
    // Suspend normal capture so the menu owns the keyboard, then NORMAL resumes
    // when it dismisses; drop any transient hints first so they don't linger
    // behind the menu.
    if action == .rightClick {
      return AppClickDecision(
        releaseCapture: false,
        enterInsert: false,
        suspendForNativeSurface: true,
        dismissTransientHintsWithoutRekey: hasHints)
    }
    // A physical left / double click always hands the keyboard to the app and
    // enters INSERT. Semantic `mouse_target` hints make their own decision from
    // `JumpTarget.entersInsertMode`; a `mouse_grid` click shares this physical
    // pointer intent because it synthesizes the same mouse action.
    return AppClickDecision(
      releaseCapture: true,
      enterInsert: true,
      suspendForNativeSurface: false,
      dismissTransientHintsWithoutRekey: false)
  }

  static func pointerActionMayEnterInsert(_ action: JumpAction) -> Bool {
    switch action {
    case .leftClick, .doubleClick:
      return true
    case .rightClick:
      // Right-click only ever opens a context menu; it never hands the keyboard
      // to the app, so a committed right-click stays in NORMAL (the menu takes
      // its own modal session via `suspendNormalCaptureForNativeSurface`).
      return false
    }
  }

  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }
}

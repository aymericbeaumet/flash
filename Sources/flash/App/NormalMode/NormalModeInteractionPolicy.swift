import FlashCore

enum NormalModePointerPolicy {
  struct AppClickDecision: Equatable {
    var releaseCapture: Bool
    var probeForInsert: Bool
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
      if overlayInputMode == .commandLine || overlayInputMode == .candidateFinder || hasHints {
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
    guard decision.releaseCapture || decision.probeForInsert || decision.suspendForNativeSurface
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
        probeForInsert: false,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false)
    }
    // Any click in NORMAL — left, right, or double — hands the keyboard to the
    // app and enters INSERT. Right-click opens a native context menu that does
    // its own modal key tracking, so releasing capture there is correct too,
    // and it keeps NORMAL free of "shown but not capturing" states.
    return AppClickDecision(
      releaseCapture: true,
      probeForInsert: true,
      suspendForNativeSurface: false,
      dismissTransientHintsWithoutRekey: false)
  }

  static func pointerActionMayEnterInsert(_ action: JumpAction) -> Bool {
    switch action {
    case .leftClick, .doubleClick, .rightClick:
      return true
    }
  }

  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }
}

import FlashCore

enum NormalModePointerPolicy {
  struct AppClickDecision: Equatable {
    var releaseCapture: Bool
    var probeForInsert: Bool
    var suspendForNativeSurface: Bool
    var dismissTransientHintsWithoutRekey: Bool
  }

  struct MenuBarClickDecision: Equatable {
    var suppressRecapture: Bool
    var suspendForNativeSurface: Bool
    var dismissTransientHintsWithoutRekey: Bool
  }

  enum PointerDecision: Equatable {
    case suppressScrollAndRecapture
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
      return pointerScrollShouldBeSuppressed(mode: mode, hasHints: hasHints)
        ? .suppressScrollAndRecapture
        : .cancelOverlay
    }

    guard case .click(let click) = intent else { return .cancelOverlay }
    if pointIsInMenuBar, !activationInFlight {
      return .menuBar(
        MenuBarClickDecision(
          suppressRecapture: true,
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
    switch action {
    case .leftClick, .doubleClick:
      return AppClickDecision(
        releaseCapture: true,
        probeForInsert: true,
        suspendForNativeSurface: false,
        dismissTransientHintsWithoutRekey: false)
    case .rightClick:
      return AppClickDecision(
        releaseCapture: false,
        probeForInsert: false,
        suspendForNativeSurface: true,
        dismissTransientHintsWithoutRekey: hasHints)
    }
  }

  static func pointerActionMayEnterInsert(_ action: JumpAction) -> Bool {
    switch action {
    case .leftClick, .doubleClick:
      return true
    case .rightClick:
      return false
    }
  }

  static func pointerScrollShouldBeSuppressed(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }
}

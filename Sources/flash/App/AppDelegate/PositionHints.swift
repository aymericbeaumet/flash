import AppKit
import FlashCore

/// `mouse_position`: save where the pointer is, hint the saved positions,
/// cycle through them, forget them. The history is in memory, like the
/// movement history; `[hints] position_history_size` bounds it and
/// `position_history_scope` keeps one list per app.
extension AppDelegate {
  static let positionsProviderID = "positions"

  func performMousePosition(_ request: MousePositionRequest) {
    let app = (normalModeContext() ?? currentNonFlashContext())?.bundleIdentifier
    let scope = config.hints.positionHistoryScope
    let pointer = NSEvent.mouseLocation
    switch request {
    case .save:
      let count = positionHistory.save(
        pointer, app: app, scope: scope, maxSize: config.hints.positionHistorySize)
      overlay.displayBanner("Saved position \(count)", durationMs: config.overlay.bannerDurationMs)
      FlashLog.debug("[mouse_position] saved count=\(count) scope=\(scope.rawValue)")
    case .unsave:
      let removed = positionHistory.unsave(near: pointer, app: app, scope: scope)
      if removed {
        overlay.displayBanner("Forgot position", durationMs: config.overlay.bannerDurationMs)
      }
      FlashLog.debug("[mouse_position] unsave removed=\(removed)")
    case .clear:
      positionHistory.clear(app: app, scope: scope)
      overlay.displayBanner("Forgot saved positions", durationMs: config.overlay.bannerDurationMs)
      FlashLog.debug("[mouse_position] cleared scope=\(scope.rawValue)")
    case .next, .previous:
      let target =
        request == .next
        ? positionHistory.next(from: pointer, app: app, scope: scope)
        : positionHistory.previous(from: pointer, app: app, scope: scope)
      guard let target else {
        FlashLog.debug("[mouse_position] no_positions")
        return
      }
      _ = ActionDispatcher.moveCursor(to: target)
    case .hints(let command):
      activatePositionHints(command)
    }
    debugStateDidChange()
  }

  /// `mouse_position --action=hints`: one hint per saved position; the pick
  /// gets the command's click, or the pointer with `--move`.
  func activatePositionHints(_ command: MouseCommand) {
    guard prepareHintActivation(.positions(command)) else { return }
    let context = normalModeContext() ?? currentNonFlashContext()
    let positions = positionHistory.positions(
      app: context?.bundleIdentifier, scope: config.hints.positionHistoryScope)
    let targets = Self.positionTargets(positions, pid: context?.processID)
    guard !targets.isEmpty else {
      FlashLog.debug("[mouse_position] no_positions")
      endHintActivationEmpty(
        bundleIdentifier: context?.bundleIdentifier, path: "no_positions", surface: "positions",
        countsForApp: false)
      applyModeOverlay()
      return
    }
    hintSession.command = command
    hintSession.surface = .targets
    hintSession.prefix = ""
    hintSession.sourceAppPID = context?.processID
    overlay.debugConfig = config.debug
    let hints = assignHints(targets, region: context?.frontWindowFrame)
    hintSession.hints = hints
    applyModeOverlay()
    presentHints(
      hints, prepared: .none, outcome: .none, bundleIdentifier: context?.bundleIdentifier,
      surface: "positions")
    FlashLog.debug("[mouse_position] displayed positions=\(hints.count)")
  }

  /// A coordinate target on each saved position, newest last.
  static func positionTargets(_ positions: [CGPoint], pid: pid_t?) -> [JumpTarget] {
    positions.enumerated().map { index, point in
      JumpTarget(
        id: "position_\(index)",
        frame: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
        role: "FlashPosition",
        accessibilityLabel: "Position \(index + 1)",
        pid: pid,
        entersInsertMode: false,
        providerID: positionsProviderID)
    }
  }
}

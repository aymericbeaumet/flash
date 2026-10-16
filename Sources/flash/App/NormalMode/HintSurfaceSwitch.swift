import Foundation

/// Where Tab and Shift-Tab take a session whose labels are up: the same
/// click on the mouse grid, or the same click widened to every app on the
/// screen (and back). Backspace with nothing left to undo returns to the
/// surface the session came from.
enum HintSurfaceSwitch: Equatable {
  /// Tab: the grid, on the display of the same window.
  case grid
  /// Shift-Tab: the focused app's targets ⇄ every app on the screen.
  case scope
}

enum HintSurfaceSwitching {
  /// The activation `kind` leads to from `current`, or nil when that surface
  /// has no equivalent of the session's shape. The grid has no adjustment,
  /// search, path or sticky session, so those become the click they carry;
  /// screen scope is click-only, as `mouse_target --scope=screen` is.
  static func request(
    from current: HintActivationRequest, kind: HintSurfaceSwitch
  ) -> HintActivationRequest? {
    switch (kind, current) {
    case (.grid, .target(let command, let context)), (.grid, .words(let command, let context)):
      return .grid(MouseGridRequest(command.asClick), context)
    case (.grid, .screen(let command)), (.grid, .positions(let command)):
      return .grid(MouseGridRequest(command.asClick), nil)
    case (.scope, .target(let command, _)):
      guard case .click = command else { return nil }
      return .screen(command)
    case (.scope, .screen(let command)):
      return .target(command, nil)
    case (.grid, _), (.scope, _):
      return nil
    }
  }
}

/// The coordinator side of a surface switch. Declared apart from
/// `OverlayCoordinator` so the panel's key route reaches it through a cast.
protocol OverlaySurfaceSwitching: AnyObject {
  /// Tab / Shift-Tab on the label route.
  func overlayDidSwitchSurface(_ kind: HintSurfaceSwitch)
  /// Backspace with nothing left to undo: back to the surface the session
  /// came from. False when it came from nowhere.
  @discardableResult
  func overlayDidReturnToOrigin() -> Bool
}

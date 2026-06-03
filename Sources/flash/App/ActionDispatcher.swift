import AppKit
import CoreGraphics
import FlashCore
import FlashProviders

enum ActionDispatcher {
  /// Click pipeline, tried in order until one succeeds:
  ///
  ///   1. `target.activate(action)` — provider-owned best-known path.
  ///      AccessibilityProvider tries focus-set (text inputs) +
  ///      AXPress/AXOpen/AXConfirm.
  ///   2. AX hit-test at the click point (`AXClick.clickAtPoint`).
  ///      Recovers inert-wrapper cases — the hint element advertised no
  ///      AX action but the AX node actually under the click point (or
  ///      one of its ancestors) does. Cursor never moves.
  ///   3. Synthesized `CGEvent` mouse click (`synthesizeClick`). Last
  ///      resort: the cursor briefly visits the click site and warps
  ///      back, hidden so the user never sees the motion.
  ///
  /// `clickPoint`, when supplied, is the screen-coord point we should
  /// click in steps 2 + 3. The expected value is the target's geometric
  /// centre — the same point AX uses internally for its press-to-click
  /// fallback. For small AX targets that's also the centre of the
  /// rendered chip; for wide targets the chip anchors to top-left but
  /// the click still goes to the target middle.
  static func perform(
    _ action: JumpAction, on target: JumpTarget, pid _: pid_t? = nil, clickPoint: CGPoint? = nil
  ) -> Bool {
    if let activate = target.activate, activate(action) {
      return true
    }
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
    if let pid = target.pid,
      AXClick.clickAtPoint(pid: pid, nsScreenPoint: point, action: action)
    {
      return true
    }
    return synthesizeClick(at: point, action: action)
  }

  /// Synthesize a real mouse click at `screenPoint` (NSScreen, bottom-left
  /// origin of primary screen).
  ///
  /// We must move the cursor to the click point so the target app's
  /// hit-test resolves to the intended UI element — but we hide the cursor
  /// while we do it, warp, click, warp back, then unhide. The user never
  /// sees the cursor leave its resting place; they see it stay perfectly
  /// still even though under the hood it has briefly visited the click
  /// site to deliver the event.
  @discardableResult
  static func synthesizeClick(at screenPoint: CGPoint, action: JumpAction) -> Bool {
    let screenH =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)

    let source = CGEventSource(stateID: .combinedSessionState)
    let originalCursor = CGEvent(source: source)?.location ?? cgPoint

    let button: CGMouseButton = action == .leftClick ? .left : .right
    let downType: CGEventType = action == .leftClick ? .leftMouseDown : .rightMouseDown
    let upType: CGEventType = action == .leftClick ? .leftMouseUp : .rightMouseUp

    guard
      let down = CGEvent(
        mouseEventSource: source, mouseType: downType, mouseCursorPosition: cgPoint,
        mouseButton: button),
      let up = CGEvent(
        mouseEventSource: source, mouseType: upType, mouseCursorPosition: cgPoint,
        mouseButton: button)
    else { return false }

    // Hide the system cursor *before* the warp so the visible jump never
    // happens on screen. CGDisplayHideCursor/ShowCursor pair must be
    // balanced — defer guarantees we always unhide on the way out.
    CGDisplayHideCursor(CGMainDisplayID())
    defer { CGDisplayShowCursor(CGMainDisplayID()) }

    CGWarpMouseCursorPosition(cgPoint)
    CGAssociateMouseAndMouseCursorPosition(1)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    CGWarpMouseCursorPosition(originalCursor)
    CGAssociateMouseAndMouseCursorPosition(1)
    return true
  }
}

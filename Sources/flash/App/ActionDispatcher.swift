import AppKit
import CoreGraphics
import FlashCore

enum ActionDispatcher {
  /// `clickPoint`, when supplied, is the screen-coord point we should click
  /// if (and only if) we fall back to a synthesized mouse event. The
  /// expected value is the target's geometric centre — the same point
  /// AX uses for its internal AXPress→click fallback. For small AX
  /// targets that's also the centre of the rendered chip (chipFrame
  /// centres the chip on the target there); for wide targets the chip
  /// anchors to top-left but the click still goes to the target middle.
  static func perform(
    _ action: JumpAction, on target: JumpTarget, pid _: pid_t? = nil, clickPoint: CGPoint? = nil
  ) -> Bool {
    // AXPress (and its AXOpen / AXConfirm friends, tried inside the
    // provider's `activate` closure) is the only no-cursor-movement
    // option. It works for the majority of native AX targets — the
    // cursor stays exactly where the user left it.
    if let activate = target.activate, activate(action) {
      return true
    }
    // No AX action accepted. Fall back to a real mouse event. The cursor
    // *will* move; we warp it to the chip's exact centre so the visible
    // motion matches where the user expected to click.
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
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

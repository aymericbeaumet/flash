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
    _ action: JumpAction,
    on target: JumpTarget,
    pid _: pid_t? = nil,
    clickPoint: CGPoint? = nil,
    modifiers: ClickModifiers = []
  ) -> Bool {
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
    if !modifiers.isEmpty {
      return synthesizeClick(at: point, action: action, modifiers: modifiers)
    }
    if let activate = target.activate, activate(action) {
      return true
    }
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
  static func synthesizeClick(
    at screenPoint: CGPoint, action: JumpAction, modifiers: ClickModifiers = []
  ) -> Bool {
    let screenH =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)

    let source = CGEventSource(stateID: .combinedSessionState)
    let originalCursor = CGEvent(source: source)?.location ?? cgPoint

    let button: CGMouseButton = action == .rightClick ? .right : .left
    let downType: CGEventType = action == .rightClick ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = action == .rightClick ? .rightMouseUp : .leftMouseUp

    let clickCount = action == .doubleClick ? 2 : 1
    var events: [CGEvent] = []
    events.reserveCapacity(clickCount * 2)
    for clickIndex in 1...clickCount {
      guard
        let down = CGEvent(
          mouseEventSource: source, mouseType: downType, mouseCursorPosition: cgPoint,
          mouseButton: button),
        let up = CGEvent(
          mouseEventSource: source, mouseType: upType, mouseCursorPosition: cgPoint,
          mouseButton: button)
      else { return false }
      down.flags = modifiers.cgEventFlags
      up.flags = modifiers.cgEventFlags
      down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      events.append(down)
      events.append(up)
    }

    // Hide the system cursor *before* the warp so the visible jump never
    // happens on screen. CGDisplayHideCursor/ShowCursor pair must be
    // balanced — defer guarantees we always unhide on the way out.
    CGDisplayHideCursor(CGMainDisplayID())
    defer { CGDisplayShowCursor(CGMainDisplayID()) }

    CGWarpMouseCursorPosition(cgPoint)
    CGAssociateMouseAndMouseCursorPosition(1)
    for event in events {
      event.post(tap: .cghidEventTap)
    }
    CGWarpMouseCursorPosition(originalCursor)
    CGAssociateMouseAndMouseCursorPosition(1)
    return true
  }

  enum MouseButtonPhase {
    case down
    case dragged
    case up
  }

  /// Magic number stamped on every mouse event we synthesize so we can
  /// recognise our own events bouncing back through `NSEvent` monitors
  /// and drop them instead of recursing.
  static let syntheticMouseEventTag: Int64 = 0x46_4C_53_44  // "FLSD"

  /// Post a single mouse-button event (down / dragged / up) at the given
  /// screen point without warping the cursor. Used by the normal-mode
  /// click+drag pipeline: the physical cursor is already where the user
  /// pressed, so we just need to deliver matching `CGEvent`s in real time
  /// as the user drags and releases.
  @discardableResult
  static func synthesizeMouseButton(
    at screenPoint: CGPoint,
    phase: MouseButtonPhase,
    action: JumpAction,
    modifiers: ClickModifiers = []
  ) -> Bool {
    let screenH =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    let isRight = action == .rightClick
    let button: CGMouseButton = isRight ? .right : .left
    let eventType: CGEventType = {
      switch phase {
      case .down: return isRight ? .rightMouseDown : .leftMouseDown
      case .up: return isRight ? .rightMouseUp : .leftMouseUp
      case .dragged: return isRight ? .rightMouseDragged : .leftMouseDragged
      }
    }()
    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let event = CGEvent(
        mouseEventSource: source,
        mouseType: eventType,
        mouseCursorPosition: cgPoint,
        mouseButton: button)
    else { return false }
    event.flags = modifiers.cgEventFlags
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
    event.post(tap: .cghidEventTap)
    return true
  }

  /// Move the visible pointer to `screenPoint` without clicking.
  @discardableResult
  static func moveCursor(to screenPoint: CGPoint) -> Bool {
    let screenH =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    CGWarpMouseCursorPosition(cgPoint)
    CGAssociateMouseAndMouseCursorPosition(1)
    return true
  }

  @discardableResult
  static func forwardKeyDown(_ event: NSEvent, to pid: pid_t?) -> Bool {
    if let forwarded = event.cgEvent?.copy() {
      if let pid {
        forwarded.postToPid(pid)
      } else {
        forwarded.post(tap: .cghidEventTap)
      }
      return true
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    guard
      let down = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(event.keyCode),
        keyDown: true)
    else { return false }
    down.flags = NormalModeDispatcher.cgFlags(from: event.modifierFlags)
    if let pid {
      down.postToPid(pid)
    } else {
      down.post(tap: .cghidEventTap)
    }
    return true
  }
}

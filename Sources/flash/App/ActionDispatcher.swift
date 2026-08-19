import AppKit
import CoreGraphics
import FlashCore
import FlashProviders

enum ActionDispatcher {
  enum DispatchRoute: Equatable {
    case accessibilityThenHostClick
    case hostClick
  }

  /// Serial queue for the timed parts of click synthesis (the settle pause and
  /// the mouse-down hold). Those sleeps space the posted CGEvents the way real
  /// hardware does — they are *inter-event* timing, not a main-thread
  /// requirement — so they must never run on the main run loop, which also
  /// services the keyboard capture tap. Serial so concurrent commits can't
  /// interleave their cursor warp/restore.
  private static let clickQueue = DispatchQueue(label: "flash.action.click", qos: .userInitiated)

  /// Height of the primary screen (the one whose origin is (0,0)), used for the
  /// AX(top-left) → NSScreen(bottom-left) Y-flip. `NSScreen` is main-affine, so
  /// callers must invoke this on the main thread.
  static func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
  }

  /// Click pipeline. By default click actions do not move the visible cursor —
  /// `synthesizeClick` hides, warps, clicks, then restores. Hint commits pass
  /// `leaveCursorAtClickPoint: true` so the cursor lands, and stays, on the hint
  /// the user picked (the click point is the hint chip). `mf`/`mF` remain the
  /// explicit move-only commands.
  ///
  /// Pipeline:
  ///   1. Modified click → straight to `synthesizeClick`. AX activate
  ///      can't carry a shift/cmd modifier, and most modifier-clicks
  ///      (shift+click selection, opt+click in code editors, …) only
  ///      mean anything when a real mouse event reaches the app.
  ///      Targets marked `preferHostClick` take the same path: those
  ///      surfaces expose AX actions that report success without
  ///      delivering the click the host app expects.
  ///   2. `target.activate(action)` — provider-owned best-known path.
  ///      AccessibilityProvider tries focus-set (text inputs) +
  ///      AXPress/AXOpen/AXConfirm.
  ///   3. AX hit-test at the click point (`AXClick.clickAtPoint`) —
  ///      recovers inert-wrapper cases where the chip's element
  ///      exposes no AX action but the node under the point does.
  ///   4. Synthesized `CGEvent` mouse click (`synthesizeClick`) — last
  ///      resort.
  ///
  /// `clickPoint`, when supplied, is the screen-coord point we click in
  /// steps 3 + 4. The expected value is the target's geometric centre
  /// — the same point AX uses for its own press-to-click fallback.
  ///
  /// `completion` (if supplied) runs on the main thread once the click has been
  /// delivered: synchronously for the AX paths, and after the off-main posting
  /// for the synthesized-click paths. Hint-commit relies on this to probe the
  /// target's focus *after* the click lands.
  static func perform(
    _ action: JumpAction,
    on target: JumpTarget,
    pid _: pid_t? = nil,
    clickPoint: CGPoint? = nil,
    modifiers: ClickModifiers = [],
    leaveCursorAtClickPoint: Bool = false,
    completion: (() -> Void)? = nil
  ) {
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
    if dispatchRoute(for: target, action: action, modifiers: modifiers) == .hostClick {
      synthesizeClick(
        at: point, action: action, modifiers: modifiers,
        preserveCursor: !leaveCursorAtClickPoint, completion: completion)
      return
    }
    if let activate = target.activate, activate(action) {
      // The AX path never moved the pointer; place it on the hint so a hint
      // commit leaves the cursor where the user aimed. AX activate is
      // synchronous, so the caller's completion can run now.
      if leaveCursorAtClickPoint { _ = moveCursor(to: point) }
      completion?()
      return
    }
    if let pid = target.pid,
      AXClick.clickAtPoint(pid: pid, nsScreenPoint: point, action: action)
    {
      if leaveCursorAtClickPoint { _ = moveCursor(to: point) }
      completion?()
      return
    }
    synthesizeClick(
      at: point, action: action, preserveCursor: !leaveCursorAtClickPoint,
      completion: completion)
  }

  static func dispatchRoute(
    for target: JumpTarget,
    action: JumpAction,
    modifiers: ClickModifiers
  ) -> DispatchRoute {
    // Right-click must land as a real mouse-down at the click point. A genuine
    // right-click makes the app anchor its context menu at the cursor, whereas
    // the AX `AXShowMenu` action (the first step of `.accessibilityThenHostClick`)
    // opens the *correct* menu but at the element's own default spot — typically
    // the top-left of the screen, never where the user aimed. Mouse-grid clicks
    // already synthesize; routing target right-clicks here keeps the two
    // consistent.
    if action == .rightClick || !modifiers.isEmpty || target.preferHostClick {
      return .hostClick
    }
    return .accessibilityThenHostClick
  }

  /// Synthesize a real mouse click at `screenPoint` (NSScreen, bottom-left
  /// origin of primary screen). By default the cursor is hidden, warped to the
  /// click point, clicked, then restored so fallback clicks are transparent.
  ///
  /// Returns `true` once the click is enqueued. The blocking posting (settle +
  /// mouse-down-hold sleeps, ~40–60ms) runs on `clickQueue`, off the main run
  /// loop, so it no longer starves the keyboard tap; `completion` (if supplied)
  /// runs on main after the click has been posted.
  @discardableResult
  static func synthesizeClick(
    at screenPoint: CGPoint,
    action: JumpAction,
    modifiers: ClickModifiers = [],
    preserveCursor: Bool = true,
    completion: (() -> Void)? = nil
  ) -> Bool {
    // NSScreen / NSWorkspace are main-affine; resolve them on the calling thread
    // (callers invoke this on main) and hand the constants down to the queue.
    let screenH = primaryScreenHeight()
    let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    clickQueue.async {
      postSynthesizedClick(
        screenPoint: screenPoint, screenH: screenH, action: action, modifiers: modifiers,
        preserveCursor: preserveCursor, frontmostBundleID: frontmostBundleID)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// The blocking body of `synthesizeClick`, run on `clickQueue`: builds and
  /// posts the CGEvents with the inter-event sleeps the receiving app expects.
  private static func postSynthesizedClick(
    screenPoint: CGPoint,
    screenH: CGFloat,
    action: JumpAction,
    modifiers: ClickModifiers,
    preserveCursor: Bool,
    frontmostBundleID: String
  ) {
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)

    let source = CGEventSource(stateID: .combinedSessionState)
    let originalCursor = CGEvent(source: source)?.location ?? cgPoint

    let button: CGMouseButton = action == .rightClick ? .right : .left
    let downType: CGEventType = action == .rightClick ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = action == .rightClick ? .rightMouseUp : .leftMouseUp

    let clickCount = action == .doubleClick ? 2 : 1
    struct ClickPair {
      let down: CGEvent
      let up: CGEvent
    }
    var pairs: [ClickPair] = []
    pairs.reserveCapacity(clickCount)
    for clickIndex in 1...clickCount {
      guard
        let down = CGEvent(
          mouseEventSource: source, mouseType: downType, mouseCursorPosition: cgPoint,
          mouseButton: button),
        let up = CGEvent(
          mouseEventSource: source, mouseType: upType, mouseCursorPosition: cgPoint,
          mouseButton: button)
      else {
        FlashLog.warn("[click] could not create CGEvent for synthesized click")
        return
      }
      down.flags = modifiers.cgEventFlags
      up.flags = modifiers.cgEventFlags
      down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      // Stamp synthetic tag so our own pointer monitors drop this event
      // instead of treating it as a real user click that would dismiss
      // the overlay or flip mode. Matches `synthesizeMouseButton`.
      down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      pairs.append(ClickPair(down: down, up: up))
    }

    let postMove = {
      if let move = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: cgPoint,
        mouseButton: .left)
      {
        move.setIntegerValueField(
          .mouseEventDeltaX, value: Int64((cgPoint.x - originalCursor.x).rounded()))
        move.setIntegerValueField(
          .mouseEventDeltaY, value: Int64((cgPoint.y - originalCursor.y).rounded()))
        move.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
        move.post(tap: .cghidEventTap)
      }
    }

    if preserveCursor {
      CGDisplayHideCursor(CGMainDisplayID())
      CGWarpMouseCursorPosition(cgPoint)
      postMove()
    } else {
      // Visibly move the cursor to the click site. The warp is accompanied by a
      // synthetic `mouseMoved` with the actual delta so the window server
      // hit-tests it like a real hover-in.
      CGWarpMouseCursorPosition(cgPoint)
      CGAssociateMouseAndMouseCursorPosition(1)
      postMove()
    }
    // Brief settle pause: gives the user a frame to register the move
    // before the click lands, and lets the receiving app's hover
    // tracking apply so apps that gate click handling on hover state
    // (think hover-only "open" buttons) see the expected sequence.
    usleep(20_000)
    // Real hardware spaces mouseDown→mouseUp by ~30–80ms; some terminal
    // emulators (alacritty, kitty) need a non-zero hold to forward a
    // modified click to the application instead of treating it as a
    // selection gesture. With the events posted back-to-back the
    // tmux/alacritty pipeline intermittently saw "press" then "click",
    // and shift-click would silently fall through to ExpandSelection.
    // 18ms is comfortably above the threshold without being perceptible.
    let mouseDownHoldUs = useconds_t(max(0, FlashTunables.clickHoldMs) * 1_000)
    for pair in pairs {
      pair.down.post(tap: .cghidEventTap)
      usleep(mouseDownHoldUs)
      pair.up.post(tap: .cghidEventTap)
    }
    if preserveCursor {
      CGWarpMouseCursorPosition(originalCursor)
      CGDisplayShowCursor(CGMainDisplayID())
    }
    FlashLog.trace(
      "[click] synthesize at=(\(Int(screenPoint.x)),\(Int(screenPoint.y))) "
        + "action=\(action) flags=\(modifiers.cgEventFlags.rawValue) "
        + "modifiers=cmd:\(modifiers.contains(.command)) "
        + "shift:\(modifiers.contains(.shift)) ctrl:\(modifiers.contains(.control)) "
        + "alt:\(modifiers.contains(.option)) frontmost=\(frontmostBundleID)")
  }

  /// Magic number stamped on every mouse event we synthesize so we can
  /// recognise our own events bouncing back through `NSEvent` monitors
  /// and drop them instead of recursing.
  static let syntheticMouseEventTag: Int64 = 0x46_4C_53_44  // "FLSD"

  /// Move the visible pointer to `screenPoint` without clicking.
  ///
  /// A warp alone is invisible to the app under the pointer, so the
  /// destination never lights up its hover/highlight state. After the
  /// warp we deliver a single synthetic `mouseMoved` carrying the real
  /// delta from the old position, which the window server hit-tests like
  /// a genuine move (driving hover, tracking-area enter/exit, etc.).
  @discardableResult
  static func moveCursor(to screenPoint: CGPoint) -> Bool {
    let screenH = primaryScreenHeight()
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    let previous = CGEvent(source: nil)?.location ?? cgPoint
    CGWarpMouseCursorPosition(cgPoint)
    CGAssociateMouseAndMouseCursorPosition(1)
    let source = CGEventSource(stateID: .combinedSessionState)
    if let move = CGEvent(
      mouseEventSource: source,
      mouseType: .mouseMoved,
      mouseCursorPosition: cgPoint,
      mouseButton: .left)
    {
      move.setIntegerValueField(
        .mouseEventDeltaX, value: Int64((cgPoint.x - previous.x).rounded()))
      move.setIntegerValueField(
        .mouseEventDeltaY, value: Int64((cgPoint.y - previous.y).rounded()))
      move.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      move.post(tap: .cghidEventTap)
    }
    return true
  }

}

import AppKit
import CoreGraphics
import FlashCore

enum ActionDispatcher {
  /// Native links preserve the target command's requested modifiers. Firefox
  /// links additionally require Command; terminal links require Shift so the
  /// emulator handles the link instead of forwarding the click to tmux. Every
  /// non-link target receives a plain click for both commands.
  static func hintClickModifiers(
    for target: JumpTarget,
    bundleIdentifier: String?,
    requested modifiers: ClickModifiers
  ) -> ClickModifiers {
    switch target.role {
    case "AXLink" where FirefoxAccessibility.matches(bundleIdentifier: bundleIdentifier):
      modifiers.union(.command)
    case "AXLink":
      modifiers
    case JumpTarget.terminalLinkRole:
      modifiers.union(.shift)
    default:
      []
    }
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

  /// Deliver a hint selection as one real mouse event to the underlying app.
  /// There is deliberately no provider-owned activation or AXPress fallback:
  /// Alacritty/tmux, browsers, native apps, and plugin targets all receive the
  /// same real click and interpret it themselves. Semantic links apply the
  /// `f` / `F` primary/new-context gesture appropriate to their surface;
  /// every other target is plain.
  ///
  /// `completion` runs on the main thread after the off-main event posting.
  static func perform(
    _ action: JumpAction,
    on target: JumpTarget,
    clickPoint: CGPoint? = nil,
    bundleIdentifier: String? = nil,
    modifiers: ClickModifiers = [],
    leaveCursorAtClickPoint: Bool = false,
    completion: (() -> Void)? = nil
  ) {
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
    synthesizeClick(
      at: point, action: action,
      modifiers: hintClickModifiers(
        for: target,
        bundleIdentifier: bundleIdentifier,
        requested: modifiers),
      preserveCursor: !leaveCursorAtClickPoint,
      completion: completion)
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

    let button: CGMouseButton
    let downType: CGEventType
    let upType: CGEventType
    switch action {
    case .rightClick:
      button = .right
      downType = .rightMouseDown
      upType = .rightMouseUp
    case .middleClick:
      button = .center
      downType = .otherMouseDown
      upType = .otherMouseUp
    case .leftClick, .doubleClick, .tripleClick:
      button = .left
      downType = .leftMouseDown
      upType = .leftMouseUp
    }

    let clickCount: Int
    switch action {
    case .doubleClick: clickCount = 2
    case .tripleClick: clickCount = 3
    case .leftClick, .rightClick, .middleClick: clickCount = 1
    }
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

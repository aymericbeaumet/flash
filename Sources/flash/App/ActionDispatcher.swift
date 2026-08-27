import AppKit
import CoreGraphics
import FlashCore

enum ActionDispatcher {
  /// Preserve the caller's click gesture for every target. Terminal links add
  /// Shift as a transport requirement so the emulator handles the link instead
  /// of forwarding the click to tmux.
  static func hintClickModifiers(
    for target: JumpTarget,
    requested modifiers: ClickModifiers
  ) -> ClickModifiers {
    target.role == JumpTarget.terminalLinkRole ? modifiers.union(.shift) : modifiers
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
  /// same real click and interpret it themselves. `f` is a plain click (with the
  /// terminal-link Shift transport exception); `F` carries Command-Shift to every
  /// target as the uniform new-context gesture.
  ///
  /// `completion` runs on the main thread after the off-main event posting.
  static func perform(
    _ action: JumpAction,
    on target: JumpTarget,
    clickPoint: CGPoint? = nil,
    modifiers: ClickModifiers = [],
    leaveCursorAtClickPoint: Bool = false,
    completion: (() -> Void)? = nil
  ) {
    let point = clickPoint ?? CGPoint(x: target.frame.midX, y: target.frame.midY)
    synthesizeClick(
      at: point, action: action,
      modifiers: hintClickModifiers(
        for: target, requested: modifiers),
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

  /// Synthesize a continuous left-button drag from `from` to `to` (both
  /// NSScreen, bottom-left origin). Unlike clicks, the cursor stays visible
  /// for the whole gesture — drop targets light up from the interpolated
  /// `leftMouseDragged` stream exactly as they do for a hardware drag — and it
  /// is left at the drop point. `modifiers` are held on every event so
  /// option-drag copy / cmd-drag semantics reach the receiving app.
  ///
  /// `completion` runs on the main thread after the gesture has been posted.
  @discardableResult
  static func synthesizeDrag(
    from: CGPoint,
    to: CGPoint,
    modifiers: ClickModifiers = [],
    completion: (() -> Void)? = nil
  ) -> Bool {
    let screenH = primaryScreenHeight()
    clickQueue.async {
      postSynthesizedDrag(from: from, to: to, screenH: screenH, modifiers: modifiers)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// The blocking body of `synthesizeDrag`, run on `clickQueue`.
  private static func postSynthesizedDrag(
    from: CGPoint,
    to: CGPoint,
    screenH: CGFloat,
    modifiers: ClickModifiers
  ) {
    let start = CGPoint(x: from.x, y: screenH - from.y)
    let end = CGPoint(x: to.x, y: screenH - to.y)
    let source = CGEventSource(stateID: .combinedSessionState)
    let flags = modifiers.cgEventFlags
    let previous = CGEvent(source: source)?.location ?? start

    func post(_ type: CGEventType, at point: CGPoint, deltaFrom: CGPoint? = nil) {
      guard
        let event = CGEvent(
          mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
          mouseButton: .left)
      else {
        FlashLog.warn("[drag] could not create CGEvent for synthesized drag")
        return
      }
      event.flags = flags
      if let deltaFrom {
        event.setIntegerValueField(
          .mouseEventDeltaX, value: Int64((point.x - deltaFrom.x).rounded()))
        event.setIntegerValueField(
          .mouseEventDeltaY, value: Int64((point.y - deltaFrom.y).rounded()))
      }
      event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      event.post(tap: .cghidEventTap)
    }

    CGWarpMouseCursorPosition(start)
    CGAssociateMouseAndMouseCursorPosition(1)
    post(.mouseMoved, at: start, deltaFrom: previous)
    usleep(20_000)
    post(.leftMouseDown, at: start)
    // Dwell before the first movement: apps distinguish a drag from a sloppy
    // click by press duration + movement threshold, and Finder-style
    // spring-loading arms on the initial hold.
    usleep(60_000)
    var last = start
    for waypoint in dragWaypoints(from: start, to: end) {
      post(.leftMouseDragged, at: waypoint, deltaFrom: last)
      last = waypoint
      usleep(12_000)
    }
    // Dwell at the destination so hover-sensitive drop targets register the
    // pointer before the release commits the drop.
    usleep(60_000)
    post(.leftMouseUp, at: end)
    FlashLog.trace(
      "[drag] synthesize from=(\(Int(from.x)),\(Int(from.y))) "
        + "to=(\(Int(to.x)),\(Int(to.y))) flags=\(flags.rawValue)")
  }

  /// Synthesize a two-click text selection: a plain click at `from` sets the
  /// caret, then a shift-click at `to` extends the selection — the standard
  /// macOS gesture, so it survives line wraps and never turns into an
  /// accidental drag of an already-selected range (which a down→dragged→up
  /// stream starting on a selection would). `modifiers` are applied to both
  /// clicks; shift is forced onto the second. The cursor is left at `to`.
  ///
  /// `completion` runs on the main thread after both clicks have been posted.
  @discardableResult
  static func synthesizeSelection(
    from: CGPoint,
    to: CGPoint,
    modifiers: ClickModifiers = [],
    completion: (() -> Void)? = nil
  ) -> Bool {
    let screenH = primaryScreenHeight()
    let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    clickQueue.async {
      postSynthesizedClick(
        screenPoint: from, screenH: screenH, action: .leftClick, modifiers: modifiers,
        preserveCursor: false, frontmostBundleID: frontmostBundleID)
      // Let the caret placement settle before extending — text views that are
      // still processing the first click interpret an instant shift-click as
      // one sloppy gesture instead of an extension.
      usleep(120_000)
      postSynthesizedClick(
        screenPoint: to, screenH: screenH, action: .leftClick,
        modifiers: modifiers.union(.shift),
        preserveCursor: false, frontmostBundleID: frontmostBundleID)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// Pointer-mode movement: a visible cursor move that becomes a
  /// `leftMouseDragged` while the drag toggle holds the button, so drop
  /// targets track the gesture like a hardware drag.
  @discardableResult
  static func movePointer(to screenPoint: CGPoint, dragging: Bool) -> Bool {
    guard dragging else { return moveCursor(to: screenPoint) }
    let screenH = primaryScreenHeight()
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    clickQueue.async {
      let source = CGEventSource(stateID: .combinedSessionState)
      let previous = CGEvent(source: source)?.location ?? cgPoint
      CGWarpMouseCursorPosition(cgPoint)
      CGAssociateMouseAndMouseCursorPosition(1)
      guard
        let event = CGEvent(
          mouseEventSource: source, mouseType: .leftMouseDragged,
          mouseCursorPosition: cgPoint, mouseButton: .left)
      else { return }
      event.setIntegerValueField(
        .mouseEventDeltaX, value: Int64((cgPoint.x - previous.x).rounded()))
      event.setIntegerValueField(
        .mouseEventDeltaY, value: Int64((cgPoint.y - previous.y).rounded()))
      event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      event.post(tap: .cghidEventTap)
    }
    return true
  }

  /// Press / release the primary button without its paired counterpart —
  /// pointer mode's drag toggle. Tagged synthetic like every other event.
  @discardableResult
  static func pressPrimaryButton(at screenPoint: CGPoint) -> Bool {
    postSingleButtonEvent(.leftMouseDown, at: screenPoint)
  }

  @discardableResult
  static func releasePrimaryButton(at screenPoint: CGPoint) -> Bool {
    postSingleButtonEvent(.leftMouseUp, at: screenPoint)
  }

  private static func postSingleButtonEvent(
    _ type: CGEventType, at screenPoint: CGPoint
  ) -> Bool {
    let screenH = primaryScreenHeight()
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    clickQueue.async {
      let source = CGEventSource(stateID: .combinedSessionState)
      guard
        let event = CGEvent(
          mouseEventSource: source, mouseType: type, mouseCursorPosition: cgPoint,
          mouseButton: .left)
      else { return }
      event.setIntegerValueField(.mouseEventClickState, value: 1)
      event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
      event.post(tap: .cghidEventTap)
    }
    return true
  }

  /// Interpolated waypoints for a synthesized drag, excluding the start point
  /// and ending exactly on `to`. Roughly one waypoint per 40pt of travel,
  /// clamped to 2…`maxSteps` so short drags still produce a recognisable
  /// movement stream and long ones stay under ~200ms of dragged events.
  /// Pure and orientation-agnostic — operates on whatever coordinate space
  /// its inputs share.
  static func dragWaypoints(from: CGPoint, to: CGPoint, maxSteps: Int = 16) -> [CGPoint] {
    let dx = to.x - from.x
    let dy = to.y - from.y
    let distance = (dx * dx + dy * dy).squareRoot()
    let steps = max(2, min(maxSteps, Int(distance / 40)))
    return (1...steps).map { step in
      let fraction = CGFloat(step) / CGFloat(steps)
      return CGPoint(x: from.x + dx * fraction, y: from.y + dy * fraction)
    }
  }

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

import AppKit
import CoreGraphics
import FlashCore

enum ActionDispatcher {
  /// The modifiers a hint click carries: the verb's preset ones plus whatever
  /// magic modifiers were held on the final hint key, preserved for every
  /// target. Terminal links add Shift as a transport requirement so the
  /// emulator handles the link instead of forwarding the click to tmux.
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

  /// Termination must allow an already-posted mouse-down to reach its mouse-up.
  /// This barrier is shutdown-only; ordinary input never waits on the main thread.
  static func waitForPendingMouseEvents() {
    dispatchPrecondition(condition: .notOnQueue(clickQueue))
    clickQueue.sync {}
  }

  /// Owner of the smooth scroll still posting; a newer scroll bumps it and
  /// the older one's remaining steps drop out. Read and written only on
  /// `clickQueue`.
  private static var wheelGeneration: UInt64 = 0

  /// Post the steps of one line scroll (`SmoothScroll`) on `clickQueue`,
  /// each at its delay after the keypress. The queue stays free between
  /// steps — clicks never wait behind a scroll — and a later call supersedes
  /// whatever this one has left.
  static func postWheelSteps(_ steps: [SmoothScroll.Step], post: @escaping (Int32) -> Void) {
    let start = DispatchTime.now()
    clickQueue.async {
      wheelGeneration &+= 1
      let generation = wheelGeneration
      for step in steps {
        let postStep = {
          guard wheelGeneration == generation else { return }
          post(step.lines)
        }
        if step.delayMs <= 0 {
          postStep()
        } else {
          clickQueue.asyncAfter(
            deadline: start + .milliseconds(step.delayMs), execute: postStep)
        }
      }
    }
  }

  /// Drop what a smooth scroll has left, ahead of a scroll that is not a
  /// line step (`gg` / `G`, `h` / `l`) and must not be undone by it.
  static func cancelWheelSteps() {
    clickQueue.async { wheelGeneration &+= 1 }
  }

  /// Height of the primary screen (the one whose origin is (0,0)), used for the
  /// AX(top-left) → NSScreen(bottom-left) Y-flip. `NSScreen` is main-affine, so
  /// callers must invoke this on the main thread.
  static func primaryScreenHeight() -> CGFloat {
    ScreenSpace.primaryHeight
  }

  /// Where the pointer is left once a committed gesture has been posted.
  enum PointerRestore: Equatable {
    /// On the gesture's last point, as a hardware click leaves it.
    case stay
    /// Back where it was when the gesture started posting.
    case gestureStart
    /// Back on this NSScreen point: where the mouse grid found the pointer
    /// before cursor-follow moved it.
    case point(CGPoint)

    /// The restore a committed hint or grid gesture gets:
    /// `[hints] restore_pointer`, returning to the grid's origin when
    /// cursor-follow moved the pointer before the gesture.
    static func afterCommit(restorePointer: Bool, gridOrigin: CGPoint?) -> PointerRestore {
      guard restorePointer else { return .stay }
      return gridOrigin.map(PointerRestore.point) ?? .gestureStart
    }
  }

  /// Synthesize a real mouse click at `screenPoint` (NSScreen, bottom-left
  /// origin of primary screen). The pointer moves to the target and stays
  /// there, as with a hardware click, unless `restoring` sends it back. Every
  /// committed hint — Alacritty/tmux links, browser and native controls,
  /// plugin targets, grid cells — is delivered this way and interpreted by the
  /// app itself; there is deliberately no provider-owned activation or AXPress
  /// fallback.
  ///
  /// Returns `true` once the click is enqueued. The blocking posting (settle +
  /// mouse-down-hold sleeps, ~40–60ms) runs on `clickQueue`, off the main run
  /// loop, so it no longer starves the keyboard tap; `completion` (if supplied)
  /// runs on main after the click has been posted and the pointer restored.
  @discardableResult
  static func synthesizeClick(
    at screenPoint: CGPoint,
    action: JumpAction,
    modifiers: ClickModifiers = [],
    restoring restore: PointerRestore = .stay,
    completion: (() -> Void)? = nil
  ) -> Bool {
    releaseHeldButtonBeforeGesture()
    // NSScreen / NSWorkspace are main-affine; resolve them on the calling thread
    // (callers invoke this on main) and hand the constants down to the queue.
    let screenH = primaryScreenHeight()
    let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    clickQueue.async {
      let start = postSynthesizedClick(
        screenPoint: screenPoint, screenH: screenH, action: action, modifiers: modifiers,
        frontmostBundleID: frontmostBundleID)
      restorePointer(restore, gestureStart: start, screenH: screenH)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// The blocking body of `synthesizeClick`, run on `clickQueue`: builds and
  /// posts the CGEvents with the inter-event sleeps the receiving app expects.
  /// Returns where the pointer was before the click (event space), nil when
  /// nothing was posted.
  @discardableResult
  private static func postSynthesizedClick(
    screenPoint: CGPoint,
    screenH: CGFloat,
    action: JumpAction,
    modifiers: ClickModifiers,
    frontmostBundleID: String
  ) -> CGPoint? {
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)

    let source = CGEventSource(stateID: .combinedSessionState)
    let originalCursor = CGEvent(source: source)?.location ?? cgPoint

    guard
      let events = clickEvents(
        at: cgPoint, from: originalCursor, action: action, modifiers: modifiers, source: source)
    else {
      FlashLog.warn("[click] could not create CGEvent for synthesized click")
      return nil
    }
    warpCursor(to: cgPoint)
    events[0].post(tap: .cghidEventTap)
    usleep(20_000)
    // Terminals need a nonzero down/up interval to recognize modified clicks.
    let mouseDownHoldUs = useconds_t(max(0, FlashTunables.clickHoldMs) * 1_000)
    for event in events.dropFirst() {
      event.post(tap: .cghidEventTap)
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
        usleep(mouseDownHoldUs)
      }
    }
    FlashLog.trace(
      "[click] synthesize at=(\(Int(screenPoint.x)),\(Int(screenPoint.y))) "
        + "action=\(action) flags=\(modifiers.cgEventFlags.rawValue) "
        + "modifiers=cmd:\(modifiers.contains(.command)) "
        + "shift:\(modifiers.contains(.shift)) ctrl:\(modifiers.contains(.control)) "
        + "alt:\(modifiers.contains(.option)) frontmost=\(frontmostBundleID)")
    return originalCursor
  }

  /// Put the pointer back after a posted gesture (`[hints] restore_pointer`),
  /// run on `clickQueue` behind the gesture's last event. The warp alone is
  /// invisible to the app under the pointer, so a tagged `mouseMoved` follows
  /// it, like `moveCursor`. Modifier flags are cleared: a magic modifier still
  /// held from the final hint key must not turn the move into a modified hover.
  private static func restorePointer(
    _ restore: PointerRestore, gestureStart: CGPoint?, screenH: CGFloat
  ) {
    guard let gestureStart,
      let destination = restoreDestination(restore, gestureStart: gestureStart, screenH: screenH)
    else { return }
    // Let the release reach the app before the pointer leaves the target.
    usleep(20_000)
    let source = CGEventSource(stateID: .combinedSessionState)
    let current = CGEvent(source: source)?.location ?? destination
    warpCursor(to: destination)
    guard let move = pointerMoveEvent(to: destination, from: current, source: source) else {
      return
    }
    move.flags = []
    move.post(tap: .cghidEventTap)
    FlashLog.trace(
      "[click] restore_pointer to=(\(Int(destination.x)),\(Int(screenH - destination.y)))")
  }

  /// Where `restore` puts the pointer, in event space (top-left origin); nil
  /// when it stays. `gestureStart` is already in event space.
  static func restoreDestination(
    _ restore: PointerRestore, gestureStart: CGPoint, screenH: CGFloat
  ) -> CGPoint? {
    switch restore {
    case .stay: return nil
    case .gestureStart: return gestureStart
    case .point(let point): return CGPoint(x: point.x, y: screenH - point.y)
    }
  }

  /// A tagged `mouseMoved` at `point` carrying the real delta from `origin`,
  /// both in event space, which the window server hit-tests like a genuine
  /// move (hover, tracking-area enter/exit). While `holding` a button it is
  /// that button's dragged event instead, so drop targets track it like a
  /// hardware drag.
  static func pointerMoveEvent(
    to point: CGPoint, from origin: CGPoint, holding button: MouseButtonKind? = nil,
    source: CGEventSource?
  ) -> CGEvent? {
    guard
      let move = CGEvent(
        mouseEventSource: source, mouseType: button?.draggedEventType ?? .mouseMoved,
        mouseCursorPosition: point, mouseButton: button?.cgButton ?? .left)
    else { return nil }
    move.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
    move.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
    move.setIntegerValueField(.eventSourceUserData, value: syntheticMouseEventTag)
    return move
  }

  static func clickEvents(
    at point: CGPoint,
    from origin: CGPoint,
    action: JumpAction,
    modifiers: ClickModifiers,
    source: CGEventSource?
  ) -> [CGEvent]? {
    // Terminals resolve clickable links from cached hover state. Prime it with
    // the click's modifiers even when the cursor is already at the target.
    guard
      let move = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)
    else { return nil }
    move.flags = modifiers.cgEventFlags
    move.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
    move.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
    move.setIntegerValueField(.eventSourceUserData, value: syntheticMouseEventTag)
    var events = [move]

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
    for clickIndex in 1...clickCount {
      for type in [downType, upType] {
        guard
          let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
            mouseButton: button)
        else { return nil }
        event.flags = modifiers.cgEventFlags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMouseEventTag)
        events.append(event)
      }
    }
    return events
  }

  /// Magic number stamped on every mouse event we synthesize so we can
  /// recognise our own events bouncing back through `NSEvent` monitors
  /// and drop them instead of recursing.
  static let syntheticMouseEventTag: Int64 = 0x46_4C_53_44  // "FLSD"

  /// Warp and immediately re-associate. A bare warp suppresses local HID
  /// movement for the source's suppression interval (0.25 s), which would eat
  /// the user's next physical nudge.
  private static func warpCursor(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
  }

  /// Synthesize a continuous left-button drag from `from` to `to` (both
  /// NSScreen, bottom-left origin). Drop targets light up from the
  /// interpolated `leftMouseDragged` stream exactly as they do for a hardware
  /// drag, and the pointer stays at the drop point unless `restoring` sends it
  /// back. `modifiers` are held on every event so option-drag copy / cmd-drag
  /// semantics reach the receiving app.
  ///
  /// `completion` runs on the main thread after the gesture has been posted.
  @discardableResult
  static func synthesizeDrag(
    from: CGPoint,
    to: CGPoint,
    modifiers: ClickModifiers = [],
    restoring restore: PointerRestore = .stay,
    completion: (() -> Void)? = nil
  ) -> Bool {
    releaseHeldButtonBeforeGesture()
    let screenH = primaryScreenHeight()
    clickQueue.async {
      let start = postSynthesizedDrag(from: from, to: to, screenH: screenH, modifiers: modifiers)
      restorePointer(restore, gestureStart: start, screenH: screenH)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// The blocking body of `synthesizeDrag`, run on `clickQueue`. Returns where
  /// the pointer was before the drag (event space).
  private static func postSynthesizedDrag(
    from: CGPoint,
    to: CGPoint,
    screenH: CGFloat,
    modifiers: ClickModifiers
  ) -> CGPoint {
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
    return previous
  }

  /// Synthesize a two-click text selection: a plain click at `from` sets the
  /// caret, then a shift-click at `to` extends the selection — the standard
  /// macOS gesture, so it survives line wraps and never turns into an
  /// accidental drag of an already-selected range (which a down→dragged→up
  /// stream starting on a selection would). `modifiers` are applied to both
  /// clicks; shift is forced onto the second. The pointer stays at `to` unless
  /// `restoring` sends it back to where it was before the first click.
  ///
  /// `completion` runs on the main thread after both clicks have been posted.
  @discardableResult
  static func synthesizeSelection(
    from: CGPoint,
    to: CGPoint,
    modifiers: ClickModifiers = [],
    restoring restore: PointerRestore = .stay,
    completion: (() -> Void)? = nil
  ) -> Bool {
    releaseHeldButtonBeforeGesture()
    let screenH = primaryScreenHeight()
    let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    clickQueue.async {
      let start = postSynthesizedClick(
        screenPoint: from, screenH: screenH, action: .leftClick, modifiers: modifiers,
        frontmostBundleID: frontmostBundleID)
      // Let the caret placement settle before extending — text views that are
      // still processing the first click interpret an instant shift-click as
      // one sloppy gesture instead of an extension.
      usleep(120_000)
      postSynthesizedClick(
        screenPoint: to, screenH: screenH, action: .leftClick,
        modifiers: modifiers.union(.shift),
        frontmostBundleID: frontmostBundleID)
      restorePointer(restore, gestureStart: start, screenH: screenH)
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
    return true
  }

  /// The button `mouse_button` or pointer mode's `v` holds down. Main thread
  /// only: every transition happens there, and the events it implies are
  /// queued on `clickQueue` in the same turn, so they post in order.
  private static var buttonHold = MouseButtonHold()

  static var heldButton: MouseButtonKind? { buttonHold.held }

  /// Press, release or toggle `button` at `screenPoint` (NSScreen; the
  /// pointer's location for `mouse_button`). Returns what was posted.
  @discardableResult
  static func setMouseButton(
    _ state: MouseButtonState, _ button: MouseButtonKind, at screenPoint: CGPoint
  ) -> [MouseButtonHold.Effect] {
    let effects = buttonHold.apply(state, button)
    postButtonEffects(effects, at: screenPoint)
    return effects
  }

  /// Let go of the held button, if any: Escape in a Flash overlay,
  /// `leave_mode` and quit. Idempotent.
  @discardableResult
  static func releaseHeldButton(at screenPoint: CGPoint) -> Bool {
    let effects = buttonHold.release()
    postButtonEffects(effects, at: screenPoint)
    return !effects.isEmpty
  }

  /// A committed click, drag or selection presses buttons of its own, so a
  /// held one is released first, where the pointer is, keeping every press
  /// paired with its release.
  private static func releaseHeldButtonBeforeGesture() {
    guard heldButton != nil else { return }
    releaseHeldButton(at: NSEvent.mouseLocation)
  }

  private static func postButtonEffects(
    _ effects: [MouseButtonHold.Effect], at screenPoint: CGPoint
  ) {
    guard !effects.isEmpty else { return }
    let screenH = primaryScreenHeight()
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    clickQueue.async {
      let source = CGEventSource(stateID: .combinedSessionState)
      for effect in effects {
        let button: MouseButtonKind
        let pressed: Bool
        switch effect {
        case .press(let pressedButton): (button, pressed) = (pressedButton, true)
        case .release(let releasedButton): (button, pressed) = (releasedButton, false)
        }
        guard
          let event = CGEvent(
            mouseEventSource: source, mouseType: button.eventType(pressed: pressed),
            mouseCursorPosition: cgPoint, mouseButton: button.cgButton)
        else { continue }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMouseEventTag)
        event.post(tap: .cghidEventTap)
        FlashLog.trace("[mouse_button] \(pressed ? "press" : "release") button=\(button.rawValue)")
      }
    }
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
  ///
  /// While a button is held (`mouse_button`, pointer mode's `v`) the move is
  /// that button's drag, posted on `clickQueue` behind the press it follows,
  /// so pointer mode, `--move` commits and grid cursor-follow all drag.
  @discardableResult
  static func moveCursor(to screenPoint: CGPoint) -> Bool {
    let screenH = primaryScreenHeight()
    let cgPoint = CGPoint(x: screenPoint.x, y: screenH - screenPoint.y)
    if let held = heldButton {
      clickQueue.async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let previous = CGEvent(source: source)?.location ?? cgPoint
        warpCursor(to: cgPoint)
        pointerMoveEvent(to: cgPoint, from: previous, holding: held, source: source)?
          .post(tap: .cghidEventTap)
      }
      return true
    }
    let previous = CGEvent(source: nil)?.location ?? cgPoint
    warpCursor(to: cgPoint)
    let source = CGEventSource(stateID: .combinedSessionState)
    pointerMoveEvent(to: cgPoint, from: previous, source: source)?.post(tap: .cghidEventTap)
    return true
  }

}

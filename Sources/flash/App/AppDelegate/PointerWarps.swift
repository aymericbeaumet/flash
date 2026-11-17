import AppKit
import FlashCore

/// Pointer jumps: `mouse screens` (monitor select), `mouse warp` (an edge or
/// the centre of the focused window or its screen), and
/// `[hints] pointer_follows_focus`.
extension AppDelegate {
  static let screensProviderID = "screens"

  /// The displays as `mouse screens` numbers them (`ScreenSelect.arranged`),
  /// with the bar's reservation.
  func arrangedScreenLayouts() -> [WindowScreenLayout] {
    ScreenSelect.arranged(
      WindowMover.screenLayouts(
        statusBarReservesSpace: statusBarVisible, statusBarMonitor: config.statusBar.monitor))
  }

  /// `mouse screens`: a display named by its index, a step or, with one
  /// display, the only one, is acted on at once; otherwise every display
  /// shows its number at its centre, a hint session like `f`'s, and typing
  /// one acts on that display (`commitScreenHint`). Escape cancels; the mode
  /// never changes. `layouts` and `pointer` default to the live displays and
  /// pointer.
  func activateScreens(
    _ request: ScreenSelectRequest, layouts: [WindowScreenLayout]? = nil,
    pointer: CGPoint? = nil
  ) {
    let layouts = layouts.map(ScreenSelect.arranged) ?? arrangedScreenLayouts()
    let pointer = pointer ?? NSEvent.mouseLocation
    switch ScreenSelect.plan(request.pick, displays: layouts.map(\.frame), pointer: pointer) {
    case .none:
      FlashLog.debug("[screens] no_display pick=\(request.pick) displays=\(layouts.count)")
    case .display(let index):
      selectScreen(layouts[index].identity, request: request, layouts: layouts)
    case .labels:
      presentScreenLabels(request, layouts: layouts)
    }
  }

  private func presentScreenLabels(_ request: ScreenSelectRequest, layouts: [WindowScreenLayout]) {
    guard prepareHintActivation(.screens(request)) else { return }
    let targets = ScreenSelect.targets(layouts)
    hintSession.command = .move
    hintSession.surface = .targets
    hintSession.prefix = ""
    hintSession.sourceAppPID = currentNonFlashContext()?.processID
    overlay.debugConfig = config.debug
    let hints =
      ScreenSelect.numberedHints(targets)
      ?? assignHints(targets, region: OverlayPanel.unionScreenFrame())
    hintSession.hints = hints
    applyModeOverlay()
    presentHints(hints, prepared: .none, outcome: .none, bundleIdentifier: nil, surface: "screens")
    FlashLog.debug("[screens] displayed displays=\(hints.count)")
  }

  /// A display label was typed. The display is looked up again by identity:
  /// one unplugged since the labels went up cancels, never its old centre.
  func commitScreenHint(_ hint: AssignedHint) {
    let layouts = arrangedScreenLayouts()
    guard case .screens(let request)? = hintSession.request,
      let identity = ScreenSelect.identity(of: hint.target),
      layouts.contains(where: { $0.identity == identity })
    else {
      FlashLog.debug("[screens] display_gone; pick cancelled")
      cancelOverlay()
      return
    }
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.invalidate()
    selectScreen(identity, request: request, layouts: layouts)
    applyModeOverlay()
  }

  /// The pointer leaves its display (remembered for `--to=last`) and lands
  /// on `identity`'s; with `--focus`, the frontmost window there takes
  /// keyboard focus. Nothing happens when that display is gone.
  func selectScreen(
    _ identity: String, request: ScreenSelectRequest, layouts: [WindowScreenLayout]
  ) {
    guard
      let selection = ScreenSelect.select(
        identity: identity, landing: request.landing, layouts: layouts,
        pointer: NSEvent.mouseLocation, memory: screenPointerMemory)
    else {
      FlashLog.debug("[screens] display_gone; pick cancelled")
      return
    }
    screenPointerMemory = selection.memory
    _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(selection.point))
    if request.focus { focusFrontmostWindow(on: selection.display, layouts: layouts) }
    FlashLog.trace(
      "[screens] landing=\(request.landing.rawValue) focus=\(request.focus) "
        + "point=(\(Int(selection.point.x)),\(Int(selection.point.y)))")
  }

  /// `mouse warp`: the pointer jumps to an edge or the centre of the focused
  /// window, or of the display that window is on (the pointer's display when
  /// no window is focused). Nothing is clicked and the mode is untouched.
  func performMouseWarp(_ request: MouseWarpRequest) {
    let context = normalModeContext() ?? currentNonFlashContext()
    let window = context?.frontWindowFrame
    let frame: CGRect?
    switch request.area {
    case .window:
      frame = window
    case .screen:
      let layouts = WindowMover.screenLayouts(
        statusBarReservesSpace: statusBarVisible, statusBarMonitor: config.statusBar.monitor)
      frame = Self.warpScreenFrame(
        layouts: layouts, window: window, pointer: NSEvent.mouseLocation)
    }
    guard let frame, !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
      FlashLog.debug("[warp] no_\(request.area.rawValue)")
      return
    }
    let point = request.point(in: frame)
    _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(point))
    FlashLog.trace(
      "[warp] area=\(request.area.rawValue) edge=\(request.edge.rawValue) "
        + "point=(\(Int(point.x)),\(Int(point.y)))")
  }

  /// `mouse step`: one text line or character from the glyph under the
  /// pointer, read from Accessibility on the geometry queue, never on main.
  /// In HOLD a horizontal step lands one point past the character's centre
  /// (as `s` does), so the held button's selection takes that character.
  func performMouseStep(_ direction: TextStep.Direction) {
    let primaryH = ScreenSpace.primaryHeight
    let pointer = ScreenPoint<NSSpace>(NSEvent.mouseLocation).toAX(primaryHeight: primaryH)
    let selectingThrough = modeStore.mode.isHold
    monitor.geometryQueue.async {
      let target = ScreenPoint<AXSpace>(
        TextStep.target(
          pointer: pointer.cgPoint, direction: direction,
          landing: { BigramMatcher.clickPoint(in: $0, selectingThrough: selectingThrough) }))
      DispatchQueue.main.async {
        let point = target.toNS(primaryHeight: primaryH)
        _ = ActionDispatcher.moveCursor(to: point)
        FlashLog.trace(
          "[step] direction=\(direction.rawValue) point=(\(Int(point.x)),\(Int(point.y)))")
      }
    }
  }

  /// `mouse step --to`: a word or line jump from the glyph under the pointer,
  /// read on the geometry queue. In HOLD it lands just past the glyph's
  /// centre, so the selection takes that character.
  func performMouseJump(_ jump: TextStep.Jump) {
    let primaryH = ScreenSpace.primaryHeight
    let pointer = ScreenPoint<NSSpace>(NSEvent.mouseLocation).toAX(primaryHeight: primaryH)
    let selectingThrough = modeStore.mode.isHold
    monitor.geometryQueue.async {
      let target = ScreenPoint<AXSpace>(
        TextStep.target(
          pointer: pointer.cgPoint, jump: jump,
          landing: { BigramMatcher.clickPoint(in: $0, selectingThrough: selectingThrough) }))
      DispatchQueue.main.async {
        _ = ActionDispatcher.moveCursor(to: target.toNS(primaryHeight: primaryH))
      }
    }
  }

  /// `mouse gesture`: a trackpad gesture at the pointer, by the means
  /// `TrackpadGesture` documents for it.
  func performGesture(fingers: Int, motion: TrackpadGesture.Motion) {
    guard let action = TrackpadGesture.action(fingers: fingers, motion: motion) else { return }
    let pointer = ScreenPoint<NSSpace>(NSEvent.mouseLocation)
    switch action {
    case .secondaryClick: ActionDispatcher.synthesizeClick(at: pointer, action: .rightClick)
    case .smartZoom: TrackpadGesture.post(.smartMagnify, at: pointer)
    case .zoom(let zoomIn): TrackpadGesture.post(.magnify(zoomIn ? 0.5 : -0.5), at: pointer)
    case .rotate(let left): TrackpadGesture.post(.rotate(left ? 15 : -15), at: pointer)
    case .historyBack: performMappedCommand(.historyBack)
    case .historyForward: performMappedCommand(.historyForward)
    case .lookUp: performMappedCommand(.lookUp)
    case .surface(let surface): performSystemSurface(SystemSurfaceCommand(surface, .toggle))
    case .spaceLeft: SystemKeyboard.switchSpace(toTheRight: false)
    case .spaceRight: SystemKeyboard.switchSpace(toTheRight: true)
    }
    FlashLog.trace("[gesture] fingers=\(fingers) motion=\(motion.rawValue) action=\(action)")
  }

  /// How long a released selection settles before the action that reads it:
  /// the app sees the button go up first.
  static let selectionSettleMs = 60

  /// `selection <action>`: end a text selection (the held button lets go,
  /// leaving the text selected), then copy it or paste over it. The mode
  /// stays NORMAL: typing a replacement starts from an explicit INSERT entry.
  func performSelection(_ action: SelectionAction, register: String? = nil) {
    if modeStore.mode.isVisual {
      return performVisualOperator(action, register: register)
    }
    let held = ActionDispatcher.heldButton != nil
    if held { releaseHeldMouseButton(reason: "selection_\(action.rawValue)") }
    let targetPID = currentNonFlashRunningApplication()?.processIdentifier
    let commandToken = normalModePendingCommandToken
    let act = { [weak self] in
      guard let self,
        self.currentNonFlashRunningApplication()?.processIdentifier == targetPID,
        self.normalModePendingCommandToken == commandToken
      else { return }
      switch action {
      case .copy: self.yankSelection(into: register)
      case .paste: self.performMappedCommand(.paste(register: register))
      case .swapEnds: break
      }
    }
    guard held else { return act() }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.selectionSettleMs), execute: act)
  }

  /// `mouse nudge`: the pointer moves `distance` points; while a button is
  /// held (HOLD) the move drags.
  func performMouseNudge(_ direction: TextStep.Direction, distance: Int) {
    let pointer = ScreenPoint<NSSpace>(NSEvent.mouseLocation)
    let step = CGFloat(distance)
    let target: ScreenPoint<NSSpace>
    switch direction {
    case .up: target = ScreenPoint(x: pointer.x, y: pointer.y + step)
    case .down: target = ScreenPoint(x: pointer.x, y: pointer.y - step)
    case .left: target = ScreenPoint(x: pointer.x - step, y: pointer.y)
    case .right: target = ScreenPoint(x: pointer.x + step, y: pointer.y)
    }
    _ = ActionDispatcher.moveCursor(to: target)
  }

  /// The display a screen warp uses: the focused window's, else the
  /// pointer's, else the first.
  static func warpScreenFrame(
    layouts: [WindowScreenLayout], window: CGRect?, pointer: CGPoint
  ) -> CGRect? {
    if let window, !window.isNull, !window.isEmpty,
      let layout = layouts.max(by: { lhs, rhs in
        area(lhs.frame.intersection(window)) < area(rhs.frame.intersection(window))
      }), area(layout.frame.intersection(window)) > 0
    {
      return layout.usableFrame
    }
    if let layout = layouts.first(where: { $0.frame.contains(pointer) }) {
      return layout.usableFrame
    }
    return layouts.first?.usableFrame
  }

  private static func area(_ rect: CGRect) -> CGFloat {
    rect.isNull ? 0 : rect.width * rect.height
  }

  /// `[hints] pointer_follows_focus`: a newly focused app brings the pointer
  /// to the centre of its window, as mousemaster does after Alt-Tab, so the
  /// next scroll or pointer move lands there. Only when the pointer is
  /// outside that window, no hint session owns it, and no button is held.
  func followFocusWithPointer(pid: pid_t) {
    guard config.hints.pointerFollowsFocus, !hintSession.isActive, !activationInFlight,
      ActionDispatcher.heldButton == nil,
      let frame = monitor.context(for: pid)?.frontWindowFrame,
      !frame.isNull, !frame.isInfinite, !frame.isEmpty
    else { return }
    let pointer = NSEvent.mouseLocation
    guard !frame.contains(pointer) else { return }
    _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(x: frame.midX, y: frame.midY))
    FlashLog.trace("[pointer] follows_focus pid=\(pid)")
  }
}

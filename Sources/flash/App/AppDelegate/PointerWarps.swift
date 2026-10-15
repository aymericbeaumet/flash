import AppKit
import FlashCore

/// Pointer jumps that need no labels: `mouse_screens` (one hint per display),
/// `mouse_warp` (an edge or the centre of the focused window or its screen),
/// and `[hints] pointer_follows_focus`.
extension AppDelegate {
  static let screensProviderID = "screens"

  /// `mouse_screens`: a hint at the centre of every display. Committing one
  /// moves the pointer there, so the next grid or pointer session starts on
  /// that display.
  func activateScreenHints() {
    guard prepareHintActivation(.screens) else { return }
    let layouts = WindowMover.screenLayouts(
      statusBarReservesSpace: statusBarVisible, statusBarMonitor: config.statusBar.monitor)
    let targets = Self.screenTargets(layouts.map(\.usableFrame))
    guard !targets.isEmpty else {
      endHintActivationEmpty(bundleIdentifier: nil, path: "no_screens", surface: "screens")
      applyModeOverlay()
      return
    }
    hintSession.command = .move
    hintSession.surface = .targets
    hintSession.prefix = ""
    hintSession.sourceAppPID = currentNonFlashContext()?.processID
    overlay.debugConfig = config.debug
    let hints = assignHints(targets, region: OverlayPanel.unionScreenFrame())
    hintSession.hints = hints
    applyModeOverlay()
    presentHints(hints, prepared: .none, outcome: .none, bundleIdentifier: nil, surface: "screens")
    FlashLog.debug("[screens] displayed displays=\(hints.count)")
  }

  /// One coordinate target per display frame, centred, in `NSScreen.screens`
  /// order. The chip sits on the centre; the commit moves the pointer there.
  static func screenTargets(_ frames: [CGRect]) -> [JumpTarget] {
    frames.enumerated().compactMap { index, frame in
      guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return nil }
      return JumpTarget(
        id: "screen_\(index)",
        frame: CGRect(x: frame.midX - 1, y: frame.midY - 1, width: 2, height: 2),
        role: "FlashScreen",
        accessibilityLabel: "Display \(index + 1)",
        entersInsertMode: false,
        priority: .important,
        providerID: screensProviderID)
    }
  }

  /// `mouse_warp`: the pointer jumps to an edge or the centre of the focused
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
      FlashLog.debug("[mouse_warp] no_\(request.area.rawValue)")
      return
    }
    let point = request.point(in: frame)
    _ = ActionDispatcher.moveCursor(to: point)
    FlashLog.trace(
      "[mouse_warp] area=\(request.area.rawValue) edge=\(request.edge.rawValue) "
        + "point=(\(Int(point.x)),\(Int(point.y)))")
  }

  /// `mouse_step`: one text line or character from the glyph under the
  /// pointer, read from Accessibility on the geometry queue, never on main.
  /// In VISUAL a horizontal step lands one point past the character's centre
  /// (as `s` does), so the held button's selection takes that character.
  func performMouseStep(_ direction: TextStep.Direction) {
    let primaryH = ScreenSpace.primaryHeight
    let pointer = NSEvent.mouseLocation
    let topLeft = CGPoint(x: pointer.x, y: primaryH - pointer.y)
    let selectingThrough = modeStore.mode.isVisual
    monitor.geometryQueue.async {
      let target = TextStep.target(
        pointer: topLeft, direction: direction,
        landing: { BigramMatcher.clickPoint(in: $0, selectingThrough: selectingThrough) })
      DispatchQueue.main.async {
        let point = CGPoint(x: target.x, y: primaryH - target.y)
        _ = ActionDispatcher.moveCursor(to: point)
        FlashLog.trace(
          "[mouse_step] direction=\(direction.rawValue) point=(\(Int(point.x)),\(Int(point.y)))")
      }
    }
  }

  /// `mouse_step --to`: a word or line jump from the glyph under the pointer,
  /// read on the geometry queue. In VISUAL it lands just past the glyph's
  /// centre, so the selection takes that character.
  func performMouseJump(_ jump: TextStep.Jump) {
    let primaryH = ScreenSpace.primaryHeight
    let pointer = NSEvent.mouseLocation
    let topLeft = CGPoint(x: pointer.x, y: primaryH - pointer.y)
    let selectingThrough = modeStore.mode.isVisual
    monitor.geometryQueue.async {
      let target = TextStep.target(
        pointer: topLeft, jump: jump,
        landing: { BigramMatcher.clickPoint(in: $0, selectingThrough: selectingThrough) })
      DispatchQueue.main.async {
        _ = ActionDispatcher.moveCursor(to: CGPoint(x: target.x, y: primaryH - target.y))
      }
    }
  }

  /// `gesture`: a trackpad gesture at the pointer, by the means
  /// `TrackpadGesture` documents for it.
  func performGesture(fingers: Int, motion: TrackpadGesture.Motion) {
    guard let action = TrackpadGesture.action(fingers: fingers, motion: motion) else { return }
    let pointer = NSEvent.mouseLocation
    switch action {
    case .secondaryClick: ActionDispatcher.synthesizeClick(at: pointer, action: .rightClick)
    case .smartZoom: TrackpadGesture.post(.smartMagnify, at: pointer)
    case .zoom(let zoomIn): TrackpadGesture.post(.magnify(zoomIn ? 0.5 : -0.5), at: pointer)
    case .rotate(let left): TrackpadGesture.post(.rotate(left ? 15 : -15), at: pointer)
    case .historyBack: performMappedCommand(.historyBack)
    case .historyForward: performMappedCommand(.historyForward)
    case .lookUp: performMappedCommand(.lookUp)
    case .missionControl: SystemKeyboard.perform(.missionControl)
    case .appExpose, .launchpad, .showDesktop: TrackpadGesture.dock(action)
    case .spaceLeft: SystemKeyboard.switchSpace(toTheRight: false)
    case .spaceRight: SystemKeyboard.switchSpace(toTheRight: true)
    }
    FlashLog.trace("[gesture] fingers=\(fingers) motion=\(motion.rawValue) action=\(action)")
  }

  /// How long a released selection settles before the action that reads it:
  /// the app sees the button go up first.
  static let selectionSettleMs = 60

  /// `selection`: end a visual selection (the held button lets go, leaving
  /// the text selected), then copy, cut, change or paste over it.
  func performSelection(_ action: SelectionAction) {
    let held = ActionDispatcher.heldButton != nil
    if held { releaseHeldMouseButton(reason: "selection_\(action.rawValue)") }
    let act = { [weak self] in
      guard let self else { return }
      switch action {
      case .copy: self.performMappedCommand(.yankSelection(register: nil))
      case .cut: self.performMappedCommand(.clipboardCut)
      case .paste: self.performMappedCommand(.paste(register: nil))
      case .change:
        self.performMappedCommand(.clipboardCut)
        self.enterInsertMode(reason: .explicitCommand)
      }
    }
    guard held else { return act() }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.selectionSettleMs), execute: act)
  }

  /// `mouse_nudge`: the pointer moves `distance` points; while a button is
  /// held (DRAG) the move drags.
  func performMouseNudge(_ direction: TextStep.Direction, distance: Int) {
    let pointer = NSEvent.mouseLocation
    let step = CGFloat(distance)
    let target: CGPoint
    switch direction {
    case .up: target = CGPoint(x: pointer.x, y: pointer.y + step)
    case .down: target = CGPoint(x: pointer.x, y: pointer.y - step)
    case .left: target = CGPoint(x: pointer.x - step, y: pointer.y)
    case .right: target = CGPoint(x: pointer.x + step, y: pointer.y)
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
    _ = ActionDispatcher.moveCursor(to: CGPoint(x: frame.midX, y: frame.midY))
    FlashLog.trace("[pointer_follows_focus] pid=\(pid)")
  }
}

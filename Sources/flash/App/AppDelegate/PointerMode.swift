import AppKit
import FlashCore

/// Pointer mode (`mouse_pointer`): freestyle keyboard cursor control.
/// h/j/k/l or arrows move with autorepeat acceleration (shift = 2px fine),
/// `m` / `,` / `.` click left/middle/right in place, `v` toggles a drag,
/// Return or space clicks and returns to NORMAL; Escape (or `q`) exits.
/// `mouse_button` presses and releases outside it; both share
/// `ActionDispatcher`'s held button, so a move with a button down drags.
/// Runs as a hint-session variant:
/// `inputMode` stays `.hints` so the capture policy is untouched, and the
/// session's pointer phase routes keys to `PointerModeInterpreter`.
extension AppDelegate {
  func enterPointerMode() {
    guard prepareHintActivation(.pointer) else { return }
    hintSession.phase = .pointer(.init())
    applyModeOverlay()
    overlay.presentPointerMode(at: NSEvent.mouseLocation)
    FlashLog.trace("[pointer_mode] enter")
  }

  func overlayDidPointer(_ command: PointerModeCommand) {
    guard var pointer = hintSession.pointer else {
      cancelOverlay()
      return
    }
    if activationLifecycle.isCommitting {
      if case .exit = command { cancelOverlay() }
      return
    }
    let location = NSEvent.mouseLocation
    switch command {
    case .exit:
      FlashLog.trace("[pointer_mode] exit")
      cancelOverlay()
    case .move(let dx, let dy, let fine):
      let now = Date()
      let sinceMs = pointer.lastMoveAt.map { Int(now.timeIntervalSince($0) * 1000) }
      let streak = PointerModeInterpreter.nextStreak(
        previous: pointer.moveStreak, sinceLastMoveMs: sinceMs)
      pointer.moveStreak = streak
      pointer.lastMoveAt = now
      hintSession.phase = .pointer(pointer)
      let step = PointerModeInterpreter.step(streak: streak, fine: fine)
      let target = Self.clampToScreens(
        CGPoint(x: location.x + CGFloat(dx) * step, y: location.y + CGFloat(dy) * step))
      _ = ActionDispatcher.moveCursor(to: target)
      overlay.movePointerMarker(to: target)
    case .clickLeft:
      pointerModeClickInPlace(.leftClick, at: location)
    case .clickMiddle:
      pointerModeClickInPlace(.middleClick, at: location)
    case .clickRight:
      // A context menu takes its own modal session; leave pointer mode and
      // suspend like every other right-click commit.
      guard ActionDispatcher.heldButton == nil else { return }
      clearHintSessionState()
      overlay.hide()
      let committedClick = LastCommittedClick(
        point: location, action: .rightClick, modifiers: [], pid: nil)
      performHintCommit(recording: committedClick) { finished in
        ActionDispatcher.synthesizeClick(
          at: location, action: .rightClick, modifiers: [],
          completion: finished)
      } completion: { owner in
        owner.suspendNormalCaptureForNativeSurface(reason: "pointer_mode_right_click")
      }
    case .toggleDrag:
      // The same hold as `mouse_button --state=toggle`: a button another
      // press left down is released first.
      ActionDispatcher.setMouseButton(.toggle, .primary, at: location)
      FlashLog.trace("[pointer_mode] drag held=\(ActionDispatcher.heldButton != nil)")
    case .commitClick:
      commitPointerModeClick(at: location)
    }
  }

  /// `m` / `,`: click without leaving pointer mode, so several targets can be
  /// hit in one session (mirrors `--multi`). Ignored while a button is held
  /// — a click mid-drag would corrupt the gesture.
  private func pointerModeClickInPlace(_ action: JumpAction, at location: CGPoint) {
    guard ActionDispatcher.heldButton == nil else { return }
    let committedClick = LastCommittedClick(
      point: location, action: action, modifiers: [], pid: nil)
    performHintCommit(recording: committedClick) { finished in
      ActionDispatcher.synthesizeClick(
        at: location, action: action, modifiers: [],
        completion: finished)
    } completion: { owner in
      owner.applyModeOverlay()
    }
  }

  /// Return / space: finish the session. With a button held this releases
  /// it (completing the drag); otherwise it left-clicks and restores NORMAL
  /// capture.
  private func commitPointerModeClick(at location: CGPoint) {
    if ActionDispatcher.releaseHeldButton(at: location) {
      cancelOverlay()
      return
    }
    let pid = currentNonFlashRunningApplication()?.processIdentifier ?? normalModeTargetPID
    let committedClick = LastCommittedClick(
      point: location, action: .leftClick, modifiers: [], pid: pid)
    clearHintSessionState()
    overlay.hide()
    applyModeOverlay(captureOverride: false)
    performHintCommit(recording: committedClick) { finished in
      ActionDispatcher.synthesizeClick(
        at: location, action: .leftClick, modifiers: [],
        completion: finished)
    } completion: { owner in
      guard owner.flashMode == .normal else { return }
      owner.restoreNormalModeAfterCommit(action: .leftClick, at: location)
    }
  }

  static func clampToScreens(_ point: CGPoint) -> CGPoint {
    let frame = OverlayPanel.unionScreenFrame()
    return CGPoint(
      x: min(max(point.x, frame.minX), frame.maxX - 1),
      y: min(max(point.y, frame.minY), frame.maxY - 1))
  }

  /// `focus_input`: focus the count-th editable text input of
  /// the focused window via the AX focused attribute, preserving the mode.
  /// The bounded AX walk runs off the main thread.
  func focusTextInputInNormalMode(index: Int) {
    guard let context = normalModeContext() ?? currentNonFlashContext() else {
      applyModeOverlay()
      return
    }
    let pid = context.processID
    let normalized = max(1, index)
    let generation = activationGen
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let focused = NormalModeDispatcher.focusTextInput(pid: pid, index: normalized)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.isCurrent(generation) else { return }
        if focused {
          FlashLog.trace("[focus_input] focused index=\(normalized) pid=\(pid)")
        } else {
          FlashLog.debug("[focus_input] no_text_input pid=\(pid)")
        }
        self.applyModeOverlay()
      }
    }
  }
}

extension AppDelegate {
  /// `mouse_button`: press, release or toggle a button where the pointer is.
  /// `ActionDispatcher` owns the hold; pointer moves drag until the button
  /// is released here, by Escape in a Flash overlay, `leave_mode` or quit.
  func performMouseButton(_ request: MouseButtonRequest) {
    let effects = ActionDispatcher.setMouseButton(
      request.state, request.button, at: NSEvent.mouseLocation)
    FlashLog.debug(
      "[mouse_button] state=\(request.state.rawValue) button=\(request.button.rawValue) "
        + "effects=\(effects.count) held=\(ActionDispatcher.heldButton?.rawValue ?? "none")")
  }

  /// Escape in a Flash overlay, `leave_mode` and quit let go of a held
  /// button.
  func releaseHeldMouseButton(reason: String) {
    guard ActionDispatcher.releaseHeldButton(at: NSEvent.mouseLocation) else { return }
    FlashLog.debug("[mouse_button] released reason=\(reason)")
  }
}

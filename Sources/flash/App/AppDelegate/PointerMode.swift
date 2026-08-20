import AppKit
import FlashCore

/// Pointer mode (`mouse_pointer`): freestyle keyboard cursor control.
/// h/j/k/l or arrows move with autorepeat acceleration (shift = 2px fine),
/// `m` / `,` / `.` click left/middle/right in place, `v` toggles a drag,
/// Return or space clicks and exits with the same INSERT handoff as a
/// mouse-grid commit, Escape (or `q`) exits. Runs as a hint-session variant:
/// `inputMode` stays `.hints` so the capture policy is untouched, and the
/// panel's `pointerModeActive` flag routes keys to `PointerModeInterpreter`.
extension AppDelegate {
  func enterPointerMode() {
    if activationInFlight || !currentHints.isEmpty {
      cancelOverlay()
    }
    clearHintSessionState()
    hintSession.pointerModeActive = true
    applyModeOverlay()
    // `.hints` hides the cursor for chip picking; pointer mode is the
    // opposite — the cursor IS the interface.
    overlay.showHintCursor()
    overlay.presentPointerMode(at: NSEvent.mouseLocation)
    FlashLog.trace("[pointer_mode] enter")
  }

  func overlayDidPointer(_ command: PointerModeCommand) {
    guard hintSession.pointerModeActive else {
      cancelOverlay()
      return
    }
    let location = NSEvent.mouseLocation
    switch command {
    case .exit:
      FlashLog.trace("[pointer_mode] exit")
      cancelOverlay()
    case .move(let dx, let dy, let fine):
      let now = Date()
      let sinceMs = hintSession.pointerLastMoveAt.map {
        Int(now.timeIntervalSince($0) * 1000)
      }
      let streak = PointerModeInterpreter.nextStreak(
        previous: hintSession.pointerMoveStreak, sinceLastMoveMs: sinceMs)
      hintSession.pointerMoveStreak = streak
      hintSession.pointerLastMoveAt = now
      let step = PointerModeInterpreter.step(streak: streak, fine: fine)
      let target = Self.clampToScreens(
        CGPoint(x: location.x + CGFloat(dx) * step, y: location.y + CGFloat(dy) * step))
      _ = ActionDispatcher.movePointer(to: target, dragging: hintSession.pointerDragActive)
      overlay.movePointerMarker(to: target)
    case .clickLeft:
      pointerModeClickInPlace(.leftClick, at: location)
    case .clickMiddle:
      pointerModeClickInPlace(.middleClick, at: location)
    case .clickRight:
      // A context menu takes its own modal session; leave pointer mode and
      // suspend like every other right-click commit.
      guard !hintSession.pointerDragActive else { return }
      clearHintSessionState()
      overlay.hide()
      _ = ActionDispatcher.synthesizeClick(
        at: location, action: .rightClick, modifiers: [], preserveCursor: false)
      pointerModeSuspendForContextMenu()
    case .toggleDrag:
      if hintSession.pointerDragActive {
        _ = ActionDispatcher.releasePrimaryButton(at: location)
        hintSession.pointerDragActive = false
        FlashLog.trace("[pointer_mode] drag_release")
      } else {
        _ = ActionDispatcher.pressPrimaryButton(at: location)
        hintSession.pointerDragActive = true
        FlashLog.trace("[pointer_mode] drag_press")
      }
    case .commitClick:
      commitPointerModeClick(at: location)
    }
  }

  /// `m` / `,`: click without leaving pointer mode, so several targets can be
  /// hit in one session (mirrors `--multi`). Ignored while the drag toggle
  /// holds the button — a click mid-drag would corrupt the gesture.
  private func pointerModeClickInPlace(_ action: JumpAction, at location: CGPoint) {
    guard !hintSession.pointerDragActive else { return }
    lastCommittedClick = LastCommittedClick(
      point: location, action: action, modifiers: [], pid: nil)
    _ = ActionDispatcher.synthesizeClick(
      at: location, action: action, modifiers: [], preserveCursor: false)
  }

  /// Return / space: finish the session. With the drag toggle held this
  /// releases the button (completing the drag); otherwise it left-clicks with
  /// the same INSERT handoff as a mouse-grid commit.
  private func commitPointerModeClick(at location: CGPoint) {
    if hintSession.pointerDragActive {
      _ = ActionDispatcher.releasePrimaryButton(at: location)
      hintSession.pointerDragActive = false
      cancelOverlay()
      return
    }
    let pid = currentNonFlashContext()?.processID ?? normalModeTargetPID
    lastCommittedClick = LastCommittedClick(
      point: location, action: .leftClick, modifiers: [], pid: pid)
    clearHintSessionState()
    overlay.hide()
    let handoffToken = notePointerInsertHandoff(reason: "pointer_mode_commit")
    applyModeOverlay(captureOverride: false)
    _ = ActionDispatcher.synthesizeClick(
      at: location, action: .leftClick, modifiers: [], preserveCursor: false
    ) { [weak self] in
      guard let self else { return }
      self.resolvePointerModeInsert(pid: pid, handoffToken: handoffToken)
    }
  }

  private func pointerModeSuspendForContextMenu() {
    noteContextMenuInteraction(reason: "pointer_mode_right_click")
    nativeSurfaceSuspended = true
    applyModeOverlay()
  }

  static func clampToScreens(_ point: CGPoint) -> CGPoint {
    let frame = OverlayPanel.unionScreenFrame()
    return CGPoint(
      x: min(max(point.x, frame.minX), frame.maxX - 1),
      y: min(max(point.y, frame.minY), frame.maxY - 1))
  }

  /// `focus_input` (Vimium `gi`): focus the count-th editable text input of
  /// the focused window via the AX focused attribute, then enter INSERT so
  /// typing flows immediately. The bounded AX walk runs off the main thread.
  func focusTextInputInNormalMode(index: Int) {
    guard let context = normalModeContext() ?? currentNonFlashContext() else {
      applyModeOverlay()
      return
    }
    let pid = context.processID
    let normalized = max(1, index)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let focused = NormalModeDispatcher.focusTextInput(pid: pid, index: normalized)
      DispatchQueue.main.async {
        guard let self else { return }
        if focused {
          FlashLog.trace("[focus_input] focused index=\(normalized) pid=\(pid)")
          if self.flashMode == .normal {
            self.enterInsertMode(reason: .explicitCommand, targetPID: pid)
          }
        } else {
          FlashLog.debug("[focus_input] no_text_input pid=\(pid)")
          self.applyModeOverlay()
        }
      }
    }
  }
}

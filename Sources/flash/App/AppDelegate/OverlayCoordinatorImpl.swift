import AppKit
import FlashCore

private enum PointerInsertHandoffOutcome {
  case enteredInsert
  case recaptureNormal
}

/// `OverlayCoordinator` protocol conformance: the callback surface the
/// `OverlayPanel` uses to report user input + state transitions back to
/// AppDelegate.
extension AppDelegate {
  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {
    cancelPointerInsertHandoff(reason: "new_pointer_interaction")
    let pointIsInMenuBar: Bool
    let pointerClick: OverlayPointerClick?
    if case .click(let click) = intent {
      pointIsInMenuBar = Self.pointIsInMenuBar(click.location)
      pointerClick = click
    } else {
      pointIsInMenuBar = false
      pointerClick = nil
    }
    let decision = NormalModePointerPolicy.pointerDecision(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: hintSession.isActive,
      activationInFlight: activationInFlight,
      intent: intent,
      pointIsInMenuBar: pointIsInMenuBar)

    switch decision {
    case .passThrough:
      FlashLog.trace("[mode] pointer_pass_through reason=idle_scroll")
      return
    case .menuBar(let menuDecision):
      noteMenuBarInteraction(reason: "pointer_click")
      FlashLog.trace(
        "[mode] pointer_in_menu_bar mode=\(flashMode) suspend_native="
          + "\(menuDecision.suspendForNativeSurface)")
      if menuDecision.dismissTransientHintsWithoutRekey {
        dismissTransientPointerStateWithoutRekey(reason: "menu_bar_click")
      }
      if menuDecision.suspendForNativeSurface {
        suspendNormalCaptureForNativeSurface(reason: "menu_bar_pointer")
      }
      return
    case .app(let appDecision):
      handleAppPointerDecision(appDecision, click: pointerClick)
      return
    case .cancelOverlay:
      cancelOverlay()
      return
    }
  }

  func handleAppPointerDecision(
    _ decision: NormalModePointerPolicy.AppClickDecision,
    click: OverlayPointerClick?
  ) {
    // `finishCommandLineInteraction` (called via `cancelOverlay`) already
    // restores the prior mode (the one that was active when the command
    // line was entered), so forcing `enterInsertMode` there would clobber
    // that restoration. Plain app clicks while NORMAL is capturing are
    // different: the user deliberately chose the app with the pointer, so
    // Flash releases keyboard capture and hands input to that app.
    let clickedContext = click.flatMap { currentNonFlashContext(at: $0.location) }
    let targetPID =
      clickedContext?.processID ?? currentDirectNonFlashContext()?.processID
      ?? normalModeTargetPID
    if let clickedContext, flashMode == .normal {
      normalModeTargetPID = clickedContext.processID
    }
    if decision.dismissTransientHintsWithoutRekey {
      dismissTransientPointerStateWithoutRekey(reason: "physical_native_surface")
    }
    if decision.suspendForNativeSurface {
      suspendNormalCaptureForNativeSurface(reason: "physical_native_surface")
      return
    }
    let handoffToken: UInt64?
    if decision.enterInsert {
      handoffToken = notePointerInsertHandoff(reason: "physical_pointer_click")
    } else {
      handoffToken = nil
    }
    if decision.releaseCapture {
      releaseNormalCaptureForPointerHandoff(reason: "physical_pointer_click")
    } else {
      cancelOverlay()
    }
    if decision.enterInsert {
      // A physical left / double click ALWAYS hands the keyboard to the app and
      // enters INSERT — no editability probe. The user clicked with the mouse to
      // work in that app. Hint commits additionally require an input target.
      // Right-click never reaches here; it suspends above.
      resolvePhysicalPointerInsertMode(
        pid: targetPID,
        handoffToken: handoffToken
      ) {
        [weak self] outcome in
        guard let self else { return }
        switch outcome {
        case .enteredInsert:
          self.clearPointerInsertHandoff(
            reason: "physical_pointer_entered_insert",
            token: handoffToken)
          // Deliver the click to the app too. When Flash was the active app
          // the original physical click is consumed by macOS as a focus
          // transfer and never reaches the control under the cursor, so the
          // target (e.g. a tmux status-bar tab in a terminal) sees the mode
          // flip to INSERT but no actual click — the window/tab never
          // switches. Re-synthesise it so entering INSERT *and* acting on the
          // click happen together. The forward guard already no-ops when Flash
          // wasn't active (the click reached the app on its own then), so this
          // can't double-deliver.
          self.forwardPhysicalPointerClickIfNeeded(
            decision: decision,
            click: click,
            targetPID: targetPID)
        case .recaptureNormal:
          self.clearPointerInsertHandoff(
            reason: "physical_pointer_stayed_normal", token: handoffToken)
          self.forwardPhysicalPointerClickIfNeeded(
            decision: decision,
            click: click,
            targetPID: targetPID)
          guard self.flashMode == .normal else { return }
          self.scheduleNormalModeRecapture()
        }
      }
    }
  }

  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int) {
    guard flashMode == .normal else { return }
    normalModePendingCommandToken &+= 1
    guard let action else {
      schedulePendingNormalModeCommandIfNeeded()
      return
    }
    dispatchNormalModeAction(action, repeatCount: repeatCount, reason: "key_match")
  }

  private func schedulePendingNormalModeCommandIfNeeded() {
    guard
      let pending = NormalModeInterpreter.pendingCommand(
        pending: overlay.normalModePending,
        mappings: overlay.normalModeMappings)
    else { return }

    let token = normalModePendingCommandToken
    let pendingText = overlay.normalModePending
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(config.mode.sequenceTimeoutMs)
    ) { [weak self] in
      guard let self, self.normalModePendingCommandToken == token else { return }
      guard self.flashMode == .normal, self.overlay.normalModePending == pendingText else { return }
      self.overlay.normalModePending = ""
      self.overlay.normalModeRepeatAnchor = pending.repeatAnchor
      if pending.repeatAnchor != nil {
        self.overlay.normalModeRepeatAnchorUpdatedAt = Date()
      }
      self.normalModePendingCommandToken &+= 1
      self.dispatchNormalModeAction(
        pending.action,
        repeatCount: pending.repeatCount,
        reason: "pending_timeout")
    }
  }

  private func dispatchNormalModeAction(
    _ action: MappingCommand,
    repeatCount: Int,
    reason: String
  ) {
    // The accepted mapping owns the whole pending sequence. Clear it before
    // any side effect can activate another app, so a fast follow-up chord
    // starts from a fresh stack instead of leaking into the newly focused
    // window while Flash is recapturing normal mode.
    overlay.normalModePending = ""
    FlashLog.trace(
      "[input] normal dispatch reason=\(reason) action=\(action.diagnosticDescription)")
    let dispatchStartedAt = DispatchTime.now()
    performMappingCommand(action, repeatCount: repeatCount)
    FlashLog.debug(
      "[latency] normal_dispatch action=\(action.diagnosticDescription) sync_ms="
        + String(
          format: "%.2f",
          Double(DispatchTime.now().uptimeNanoseconds - dispatchStartedAt.uptimeNanoseconds)
            / 1_000_000))
    let focusChanging = Self.normalModeActionMayChangeKeyboardFocus(action)
    if guardNormalModeInputAfterActionDispatch(force: focusChanging) {
      scheduleNormalModeRecapture(
        delaysMs: focusChanging
          ? Self.normalModeFocusChangingRecaptureDelaysMs
          : Self.normalModeRecaptureDelaysMs)
    }
  }

  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {
    if prefix == "__BACKSPACE__" {
      if !hintSession.prefix.isEmpty {
        hintSession.prefix.removeLast()
        overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
      }
      return
    }
    for ch in prefix.lowercased() {
      hintSession.prefix.append(ch)
    }
    overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)

    // Single pass: count matches and remember the first one. Avoids
    // building a [AssignedHint] array per keystroke (was a 1-N alloc
    // every time the user typed a character). The hints carry a
    // pre-uppercased `display` field, so we don't pay an `uppercased()`
    // per chip per keystroke either.
    let upper = hintSession.prefix.uppercased()
    var matchCount = 0
    var firstMatch: AssignedHint?
    for h in hintSession.hints where h.display.hasPrefix(upper) {
      matchCount += 1
      if matchCount == 1 {
        firstMatch = h
      } else {
        break
      }
    }
    if matchCount == 0 {
      cancelOverlay()
    } else if matchCount == 1, let m = firstMatch, m.display == upper {
      commit(hint: m, clickModifiers: clickModifiers)
    }
  }

  /// `<space>` in mouse-grid mode commits the grid's centre cell — the
  /// exact middle of the current region, reachable with one fixed key
  /// regardless of which letter the layout assigned there. It recurses
  /// like any cell commit (centre-of-centre stays centred), so repeated
  /// `<space>` homes in on the dead centre and then clicks. Returns
  /// `false` when not in mouse-grid mode so the caller falls back to the
  /// universal "space cancels the overlay" gesture.
  func overlayDidCommitCenter(clickModifiers: ClickModifiers) -> Bool {
    guard hintSession.surface == .grid, let grid = hintSession.mouseGridRegion?.grid else {
      return false
    }
    let centerIndex = grid.centerCellIndex
    guard hintSession.hints.indices.contains(centerIndex) else { return false }
    commit(hint: hintSession.hints[centerIndex], clickModifiers: clickModifiers)
    return true
  }

  func overlayDidUpdatePrefix(_ prefix: String) {
    if prefix == "__BACKSPACE__" {
      if !hintSession.prefix.isEmpty {
        hintSession.prefix.removeLast()
        overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
      }
    } else {
      hintSession.prefix = prefix
      overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
    }
  }

  private func commit(hint: AssignedHint, clickModifiers held: ClickModifiers) {
    guard !activationLifecycle.inFlight else { return }
    if hintSession.surface == .grid {
      commitMouseGridCell(hint: hint, clickModifiers: held)
      return
    }
    if hint.target.providerID == "statusbar", let raw = hint.target.url,
      let url = URL(string: raw)
    {
      overlay.hide()
      clearHintSessionState(preservingStatusBarSnapshot: true)
      activationLifecycle.invalidate()
      applyModeOverlay()
      overlay.activateStatusBarLink(url)
      overlay.releaseStatusBarHintSnapshot()
      return
    }
    if hint.target.role == AppDelegate.statusBarHoverHintRole {
      let point = CGPoint(x: hint.target.frame.midX, y: hint.target.frame.midY)
      let popup = hintSession.statusBarPopupSnapshots[hint.target.id]
      overlay.hide()
      clearHintSessionState(preservingStatusBarSnapshot: true)
      activationLifecycle.invalidate()
      applyModeOverlay()
      _ = ActionDispatcher.moveCursor(to: point)
      if let popup { overlay.showStatusBarPopup(popup, at: point, preservingContent: true) }
      overlay.releaseStatusBarHintSnapshot()
      return
    }
    let chipRect = OverlayPanel.chipFrame(
      for: hint, fontSize: CGFloat(config.overlay.fontSize))
    let preferredPoint = CGPoint(x: chipRect.midX, y: chipRect.midY)
    switch hintSession.command {
    case .adjust:
      guard hintSession.adjustingHint == nil else { return }
      hintSession.adjustingHint = hint
      hintSession.adjustPoint = preferredPoint
      overlay.showAdjustment(markerAt: preferredPoint, targetFrame: hint.target.frame)
    case .drag, .select:
      if let source = hintSession.dragSourcePoint, let sourceHint = hintSession.dragSourceHint {
        resolveHintPoints([(sourceHint.target, source), (hint.target, preferredPoint)]) {
          owner, points in
          owner.performTwoPhaseGesture(from: points[0], to: points[1], clickModifiers: held)
        }
      } else {
        hintSession.dragSourcePoint = preferredPoint
        hintSession.dragSourceHint = hint
        hintSession.prefix = ""
        overlay.filter(prefix: "", hints: hintSession.hints)
      }
    case .move:
      resolveHintPoints([(hint.target, preferredPoint)]) { owner, points in
        owner.movePointerAndFinish(to: points[0])
      }
    case .click, .multi, .search:
      resolveHintPoints([(hint.target, preferredPoint)]) { owner, points in
        owner.performTargetClick(hint: hint, at: points[0], clickModifiers: held)
      }
    }
  }

  /// A resolved click on a discovered target. `--multi` keeps the hint set up
  /// afterwards; every other session ends with this click.
  private func performTargetClick(
    hint: AssignedHint, at point: CGPoint, clickModifiers held: ClickModifiers
  ) {
    let target = hint.target
    let gesture = PointerGesture(
      kind: .click(hintSession.command.action),
      point: point,
      modifiers: ActionDispatcher.hintClickModifiers(
        for: target, requested: hintSession.command.modifiers.union(held)),
      target: target,
      // The target carries its owning pid (the focused app at walk time); fall
      // back to the activation-time pid when the provider didn't set one.
      pid: target.pid ?? hintSession.sourceAppPID)
    let followUp: PointerCommitFollowUp
    if hintSession.command.isMulti {
      followUp = .rearmHints
    } else if target.role == AppDelegate.statusItemHintRole {
      followUp = .statusItemMenu
    } else {
      followUp = .finish(.hint(entersInsertMode: target.entersInsertMode))
    }
    performPointerGesture(gesture, followUp: followUp)
  }

  /// Phase 2 of `--drag` / `--select`: both points are known, so the session
  /// ends and the gesture goes out as one continuous drag, or a click plus
  /// shift-click selection. Neither carries typing intent, so NORMAL just
  /// recaptures once the gesture has been posted.
  private func performTwoPhaseGesture(
    from source: CGPoint, to destination: CGPoint, clickModifiers held: ClickModifiers
  ) {
    let kind: PointerGesture.Kind =
      hintSession.command.isSelect ? .select(from: source) : .drag(from: source)
    performPointerGesture(
      PointerGesture(
        kind: kind, point: destination,
        modifiers: hintSession.command.modifiers.union(held),
        target: nil, pid: hintSession.sourceAppPID),
      followUp: .recapture)
  }

  /// `--move`: the pointer lands on the point and the session is over. There is
  /// no event to wait for, so NORMAL recaptures at once.
  private func movePointerAndFinish(to point: CGPoint) {
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.invalidate()
    _ = ActionDispatcher.moveCursor(to: point)
    applyModeOverlay()
  }

  /// One pointer gesture, resolved from the session and the modifiers held on
  /// the final hint key.
  struct PointerGesture {
    enum Kind {
      case click(JumpAction)
      case drag(from: CGPoint)
      case select(from: CGPoint)
    }
    var kind: Kind
    var point: CGPoint
    var modifiers: ClickModifiers
    /// The discovered target, or nil for grid cells and two-phase gestures.
    var target: JumpTarget?
    var pid: pid_t?

    var action: JumpAction? {
      if case .click(let action) = kind { return action }
      return nil
    }
  }

  /// What the mode does once the gesture has been posted.
  enum PointerCommitFollowUp {
    /// The session is over: enter INSERT per the pointer policy, else recapture.
    case finish(NormalModePointerPolicy.ClickTarget)
    /// A status item's menu now owns the keyboard.
    case statusItemMenu
    /// `--multi` on targets: keep the hint set up for the next selection.
    case rearmHints
    /// `--multi` on the grid: restart it at its full extent.
    case rearmGrid(MouseGrid.Region?)
    /// Drags and selections have no typing intent: recapture NORMAL.
    case recapture
  }

  /// The single delivery path for every committed gesture — hint, grid cell,
  /// adjusted point, drag, selection: raise the owning app, tear the session
  /// down (or keep it for `--multi`), post the events off-main, then hand the
  /// mode back.
  private func performPointerGesture(_ gesture: PointerGesture, followUp: PointerCommitFollowUp) {
    let wasNormalMode = flashMode == .normal
    FlashLog.trace(
      "[commit] kind=\(gesture.kind) role=\(gesture.target?.role ?? "-") "
        + "provider=\(gesture.target?.providerID ?? "-") "
        + "point=(\(Int(gesture.point.x)),\(Int(gesture.point.y))) "
        + "modifiers=cmd:\(gesture.modifiers.contains(.command)) "
        + "shift:\(gesture.modifiers.contains(.shift)) "
        + "ctrl:\(gesture.modifiers.contains(.control)) "
        + "alt:\(gesture.modifiers.contains(.option))")
    if let pid = gesture.pid, gesture.target != nil {
      recordMovement(.app(pid: pid), source: "hint_commit")
    }
    if wasNormalMode {
      applyModeOverlay(captureOverride: false)
    }
    switch followUp {
    case .finish, .statusItemMenu, .recapture:
      overlay.hide()
      clearHintSessionState(preservingStatusBarSnapshot: true)
    case .rearmHints:
      hintSession.prefix = ""
      overlay.filter(prefix: "", hints: hintSession.hints)
    case .rearmGrid:
      break
    }
    // Raise the owning app before posting so the surface interprets the event.
    // The hinted window is on screen by construction, so no minimized-window
    // AX probe; and when the app already is frontmost there is nothing to
    // settle, so the events go out on this turn.
    let targetApp = gesture.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    let needsHandoff = Self.hintCommitNeedsFrontmostHandoff(
      targetPID: gesture.pid,
      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    if let targetApp, needsHandoff {
      RunningApplicationActivation.activate(
        targetApp, options: [], restoringMinimizedWindows: false)
    }
    let recorded = gesture.action.map {
      LastCommittedClick(
        point: gesture.point, action: $0, modifiers: gesture.modifiers, pid: gesture.pid)
    }
    performHintCommit(
      awaitingFrontmost: needsHandoff ? gesture.pid : nil, recording: recorded
    ) { finished in
      switch gesture.kind {
      case .click(let action):
        ActionDispatcher.synthesizeClick(
          at: gesture.point, action: action, modifiers: gesture.modifiers, completion: finished)
      case .drag(let source):
        ActionDispatcher.synthesizeDrag(
          from: source, to: gesture.point, modifiers: gesture.modifiers, completion: finished)
      case .select(let source):
        ActionDispatcher.synthesizeSelection(
          from: source, to: gesture.point, modifiers: gesture.modifiers, completion: finished)
      }
    } completion: { owner in
      owner.finishPointerGesture(gesture, followUp: followUp, wasNormalMode: wasNormalMode)
    }
  }

  private func finishPointerGesture(
    _ gesture: PointerGesture, followUp: PointerCommitFollowUp, wasNormalMode: Bool
  ) {
    let action = gesture.action ?? .leftClick
    switch followUp {
    case .finish(let target):
      guard wasNormalMode, flashMode == .normal else { return }
      completeHintClick(target: target, action: action, at: gesture.point, pid: gesture.pid)
    case .statusItemMenu:
      guard wasNormalMode, flashMode == .normal else { return }
      suspendNormalCaptureForNativeSurface(reason: "status_item_menu")
    case .recapture:
      guard wasNormalMode, flashMode == .normal else { return }
      scheduleNormalModeRecapture()
    case .rearmHints:
      let target = NormalModePointerPolicy.ClickTarget.hint(
        entersInsertMode: gesture.target?.entersInsertMode ?? false)
      if flashMode == .normal,
        NormalModePointerPolicy.clickShouldEnterInsert(target: target, action: action)
      {
        completeHintClick(target: target, action: action, at: gesture.point, pid: gesture.pid)
        return
      }
      guard !hintSession.hints.isEmpty else { return }
      // Re-present the surviving hint set so the panel re-keys: in
      // non-advanced mode capture rides on panel key status, and the app
      // activation above may have taken it.
      overlay.display(hints: hintSession.hints)
    case .rearmGrid(let initial):
      if flashMode == .normal {
        completeHintClick(target: .grid, action: action, at: gesture.point, pid: nil)
        return
      }
      if let initial {
        hintSession.mouseGridDepth = 0
        hintSession.prefix = ""
        displayMouseGridRegion(initial, depth: 0)
      } else {
        cancelOverlay()
      }
    }
  }

  private func completeHintClick(
    target: NormalModePointerPolicy.ClickTarget,
    action: JumpAction,
    at point: CGPoint,
    pid: pid_t?
  ) {
    guard flashMode == .normal else { return }
    if NormalModePointerPolicy.clickShouldEnterInsert(target: target, action: action) {
      let targetPID: pid_t?
      switch target {
      case .hint: targetPID = pid
      case .grid: targetPID = currentNonFlashRunningApplication()?.processIdentifier
      }
      enterInsertMode(reason: .hintCommit, targetPID: targetPID)
    } else {
      restoreNormalModeAfterCommit(action: action, at: point)
    }
  }

  /// After a hint-commit click lands, hand control back to normal
  /// mode without stealing key from anything the click just opened.
  /// Left-click commits run the standard recapture — the panel
  /// reclaims the key window so the next keystroke is captured
  /// without leaning on the session event tap. Right-click commits
  /// skip the `makeKey()` step because the menu the click just
  /// opened owns its own modal keyboard session; the tap continues
  /// to route normal-mode keys after the menu dismisses, so we just
  /// refresh the badge + inputMode without poking the panel.
  func restoreNormalModeAfterCommit(action: JumpAction, at point: CGPoint) {
    clearPointerInsertHandoff(reason: "restore_normal_after_commit")
    let hitsFlashStatusBar = overlay.statusBarClickWindows.contains {
      $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point)
    }
    if action == .rightClick || (Self.pointIsInMenuBar(point) && !hitsFlashStatusBar) {
      suspendNormalCaptureForNativeSurface(reason: "command_native_menu")
      return
    }
    scheduleNormalModeRecapture()
  }

  private func suspendNormalCaptureForNativeSurface(reason: String) {
    noteContextMenuInteraction(reason: reason)
    // Record the native surface as mode context and let the single
    // projection-driven writer set inputMode + capture — no direct `overlay.*`
    // pokes, so the badge and routing can't drift from the mode. Cleared when
    // capture is re-established (recapture / a mode transition).
    nativeSurfaceSuspended = true
    applyModeOverlay()
  }

  private func dismissTransientPointerStateWithoutRekey(reason: String) {
    let hadActivation = activationInFlight
    guard !hintSession.hints.isEmpty || hadActivation else { return }
    overlay.hide()
    clearHintSessionState()
    if hadActivation {
      invalidateActivation(reason: reason)
    }
  }

  private func releaseNormalCaptureForPointerHandoff(reason: String) {
    overlay.hide()
    let hadActivation = activationInFlight
    let hadTransientState = !hintSession.hints.isEmpty || hadActivation
    clearHintSessionState()
    if hadTransientState {
      invalidateActivation(reason: reason)
    }
    applyModeOverlay(captureOverride: false)
  }

  private func forwardPhysicalPointerClickIfNeeded(
    decision: NormalModePointerPolicy.AppClickDecision,
    click: OverlayPointerClick?,
    targetPID: pid_t?
  ) {
    guard
      Self.physicalPointerClickShouldBeForwarded(
        decision: decision, click: click, targetPID: targetPID),
      let click
    else { return }
    let needsHandoff = Self.hintCommitNeedsFrontmostHandoff(
      targetPID: targetPID,
      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    if let targetPID, needsHandoff,
      let app = NSRunningApplication(processIdentifier: targetPID)
    {
      // The clicked window is on screen by construction.
      RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
    }
    FlashLog.trace(
      "[mode] pointer_forward_host_click action=\(click.action) "
        + "point=(\(Int(click.location.x)),\(Int(click.location.y))) "
        + "modifiers=cmd:\(click.modifiers.contains(.command)) "
        + "shift:\(click.modifiers.contains(.shift)) "
        + "ctrl:\(click.modifiers.contains(.control)) "
        + "alt:\(click.modifiers.contains(.option))")
    let post = {
      _ = ActionDispatcher.synthesizeClick(
        at: click.location,
        action: click.action,
        modifiers: click.modifiers)
    }
    // Same race as a hint commit: the click this replaces was spent on
    // activation, so re-posting before the app is forward spends it again.
    if let targetPID, needsHandoff {
      whenFrontmost(pid: targetPID, then: post)
    } else {
      post()
    }
  }

  static func physicalPointerClickShouldBeForwarded(
    decision: NormalModePointerPolicy.AppClickDecision,
    click: OverlayPointerClick?,
    targetPID: pid_t?
  ) -> Bool {
    guard decision.releaseCapture, let click else { return false }
    switch click.action {
    case .rightClick:
      return false
    case .leftClick, .middleClick, .doubleClick, .tripleClick:
      break
    }
    // Forward (re-synthesise) the click whenever the original physical click
    // could not have reached the target on its own:
    //   - Flash was the active app → the OS consumed the click as a focus
    //     transfer away from Flash, or
    //   - the clicked window belongs to an app that was NOT frontmost → the
    //     click was consumed activating that app, so the control under the
    //     cursor (e.g. a tmux status-bar tab) never received it.
    // When the target was already the frontmost app the physical click landed
    // directly, so forwarding would double-deliver — skip it.
    if click.flashWasActive { return true }
    if let targetPID, click.frontmostPIDAtClick > 0, targetPID != click.frontmostPIDAtClick {
      return true
    }
    return false
  }

  private func commitMouseGridCell(hint: AssignedHint, clickModifiers held: ClickModifiers) {
    let nextRegion = MouseGrid.Region(
      frame: hint.target.frame, grid: hintSession.mouseGridRegion?.grid)
    let nextDepth = hintSession.mouseGridDepth + 1
    if !MouseGrid.shouldCommit(
      region: nextRegion, depth: nextDepth, steps: config.hints.mouseGridSteps)
    {
      hintSession.mouseGridRegion = nextRegion
      hintSession.mouseGridDepth = nextDepth
      hintSession.prefix = ""
      displayMouseGridRegion(nextRegion, depth: nextDepth)
      return
    }

    let point = CGPoint(x: nextRegion.frame.midX, y: nextRegion.frame.midY)
    switch hintSession.command {
    case .drag, .select:
      if let source = hintSession.dragSourcePoint {
        performTwoPhaseGesture(from: source, to: point, clickModifiers: held)
      } else if let initial = hintSession.mouseGridInitialRegion {
        // Phase 1: remember the anchor point and restart the grid from its full
        // extent so the second point can land anywhere, not only inside the
        // drilled-down source cell.
        hintSession.dragSourcePoint = point
        hintSession.mouseGridDepth = 0
        hintSession.prefix = ""
        displayMouseGridRegion(initial, depth: 0)
        FlashLog.trace(
          "[commit] grid_two_phase_anchor=(\(Int(point.x)),\(Int(point.y))) "
            + "command=\(hintSession.command) awaiting_second_point")
      } else {
        cancelOverlay()
      }
    case .move:
      movePointerAndFinish(to: point)
    case .click, .multi, .adjust, .search:
      performPointerGesture(
        PointerGesture(
          kind: .click(hintSession.command.action), point: point,
          modifiers: hintSession.command.modifiers.union(held),
          target: nil, pid: hintSession.sourceAppPID),
        followUp: hintSession.command.isMulti
          ? .rearmGrid(hintSession.mouseGridInitialRegion) : .finish(.grid))
    }
  }

  /// One keystroke of the `--search` sub-state (seek & click), forwarded by
  /// the panel while `searchModeActive` is set: printable characters filter
  /// the target set by visible text, Tab cycles the selection, Return commits
  /// it through the standard click path.
  func overlayDidSearch(_ command: HintSearchCommand, clickModifiers: ClickModifiers) {
    guard hintSession.searchActive else {
      cancelOverlay()
      return
    }
    switch command {
    case .cancel:
      cancelOverlay()
    case .append(let char):
      hintSession.searchQuery.append(char)
      refreshSearchMatches()
    case .backspace:
      guard !hintSession.searchQuery.isEmpty else { return }
      hintSession.searchQuery.removeLast()
      refreshSearchMatches()
    case .cycle:
      guard !hintSession.hints.isEmpty else { return }
      hintSession.searchSelectionIndex =
        (hintSession.searchSelectionIndex + 1) % hintSession.hints.count
      updateSearchSelectionMarker()
    case .commit:
      guard !hintSession.hints.isEmpty else { return }
      let index = min(hintSession.searchSelectionIndex, hintSession.hints.count - 1)
      let selected = hintSession.hints[index]
      hintSession.searchActive = false
      overlay.searchModeActive = false
      overlay.hideAdjustment()
      commit(hint: selected, clickModifiers: clickModifiers)
    }
  }

  private func refreshSearchMatches() {
    let matches = HintSearchInterpreter.filter(
      hintSession.searchAllHints, query: hintSession.searchQuery)
    hintSession.searchSelectionIndex = 0
    hintSession.hints = matches
    overlay.display(hints: matches)
    // display() re-arms hint-prefix routing state on the panel; restore the
    // search flag it does not know about.
    overlay.searchModeActive = true
    updateSearchSelectionMarker()
    FlashLog.trace(
      "[search] query_len=\(hintSession.searchQuery.count) matches=\(matches.count)")
  }

  func updateSearchSelectionMarker() {
    guard hintSession.searchActive || hintSession.command.isSearch,
      !hintSession.hints.isEmpty
    else {
      overlay.hideAdjustment()
      return
    }
    let index = min(hintSession.searchSelectionIndex, hintSession.hints.count - 1)
    let frame = hintSession.hints[index].target.frame
    overlay.showSelectionMarker(
      at: CGPoint(x: frame.midX, y: frame.midY), targetFrame: frame)
  }

  /// One keystroke of the `--adjust` sub-state, forwarded by the panel while
  /// `adjustmentActive` is set: move/snap keys update the marker; the commit
  /// key fires the pending action at the refined point.
  func overlayDidAdjust(_ command: HintAdjustmentCommand, clickModifiers: ClickModifiers) {
    guard let hint = hintSession.adjustingHint, let point = hintSession.adjustPoint else {
      cancelOverlay()
      return
    }
    switch command {
    case .cancel:
      cancelOverlay()
    case .commit:
      resolveHintPoints([(hint.target, point)]) { owner, points in
        owner.performTargetClick(hint: hint, at: points[0], clickModifiers: clickModifiers)
      }
    case .snapLeft, .snapRight, .snapTop, .snapBottom, .interpolate, .reset:
      let updated = HintAdjustmentInterpreter.apply(command, to: point, in: hint.target.frame)
      hintSession.adjustPoint = updated
      overlay.showAdjustment(markerAt: updated, targetFrame: hint.target.frame)
    }
  }

  /// Replay the last Flash-committed click (`mouse_repeat`). Re-raises the
  /// owning app first so the click is interpreted, then posts `repeatCount`
  /// identical clicks. Stays in the current mode — repeating a click is
  /// manipulation, not typing intent.
  func performMouseRepeat(repeatCount: Int = 1) {
    guard let last = lastCommittedClick else {
      FlashLog.debug("[mouse_repeat] no_previous_click")
      applyModeOverlay()
      return
    }
    guard prepareHintActivation(.repeatLast(repeatCount)) else { return }
    let wasNormalMode = flashMode == .normal
    let needsHandoff = Self.hintCommitNeedsFrontmostHandoff(
      targetPID: last.pid,
      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    if let pid = last.pid, needsHandoff,
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
    {
      // Re-clicking a point Flash already clicked: that window is on screen.
      RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
    }
    FlashLog.trace(
      "[mouse_repeat] point=(\(Int(last.point.x)),\(Int(last.point.y))) "
        + "action=\(last.action) count=\(max(1, repeatCount))")
    // The click queue is serial, so posting the repeats back-to-back keeps
    // them ordered; only the final one carries the recapture completion.
    let count = max(1, repeatCount)
    performHintCommit(awaitingFrontmost: needsHandoff ? last.pid : nil) { finished in
      for index in 1...count {
        _ = ActionDispatcher.synthesizeClick(
          at: last.point,
          action: last.action,
          modifiers: last.modifiers,
          completion: index < count ? nil : finished)
      }
    } completion: { owner in
      if wasNormalMode, owner.flashMode == .normal {
        owner.scheduleNormalModeRecapture()
      }
    }
  }

  /// Physical app clicks release NORMAL capture without an editability probe.
  private func resolvePhysicalPointerInsertMode(
    pid: pid_t?,
    handoffToken: UInt64?,
    completion: (PointerInsertHandoffOutcome) -> Void
  ) {
    guard pointerInsertHandoffIsCurrent(handoffToken) else { return }
    guard flashMode == .normal else {
      completion(.recaptureNormal)
      return
    }
    let targetPID = pid ?? currentNonFlashContext()?.processID
    enterInsertMode(reason: .pointerClick, targetPID: targetPID)
    completion(.enteredInsert)
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  /// Forward the `[flashlight.aliases]` lookup to the pure helper on
  /// `CandidateFinder` so the panel can rewrite `!g ` → `!google ` in
  /// place. Empty alias map (the default) short-circuits inside the
  /// helper.
  func overlayExpandFlashlightAlias(
    _ text: String, cursorIndex: Int
  ) -> (text: String, cursorIndex: Int)? {
    CandidateFinder.expandFlashlightAlias(
      text: text,
      cursorIndex: cursorIndex,
      aliases: config.flashlight.aliases)
  }

  func overlayDidCancelCommandLine() {
    returnActivationToCoveredApp(reason: "command_cancel")
    finishCommandLineInteraction(reason: "command_cancel")
  }

  /// Hand activation back to the app the command bar covered when the bar
  /// closes without running anything; a submit that opens an app hands it
  /// over through that app's own activation instead.
  ///
  /// `NSApp.deactivate()` and a bare `activate(options:)` are both ignored on
  /// this macOS: Flash stays active with no key window, macOS never makes the
  /// panel key again on the next open, and the command line shows no caret.
  /// The cooperative handoff — yield, then activate from Flash — is the
  /// request that actually moves activation, so the next open starts from a
  /// clean activation and keys the panel.
  func returnActivationToCoveredApp(reason: String) {
    guard NSApp.isActive,
      let context = currentNonFlashContext() ?? normalModeContext(),
      let app = NSRunningApplication(processIdentifier: context.processID),
      !app.isTerminated
    else { return }
    NSApp.yieldActivation(to: app)
    let accepted = app.activate(from: .current, options: [])
    FlashLog.trace(
      "[mode] return_activation reason=\(reason) "
        + "to=\(app.bundleIdentifier ?? "nil"):\(app.processIdentifier) accepted=\(accepted)")
  }

  func overlayDidUpdateCommandLine(
    _ command: String,
    cursorIndex: Int,
    resetSelection: Bool
  ) {
    guard command.hasPrefix(":") else {
      FlashLog.trace("[input] command_line cancel reason=prompt_erased")
      overlayDidCancelCommandLine()
      return
    }
    if resetSelection {
      finder.selectedIndex = 0
    }
    // A real edit ends history recall: the next up/down stashes this buffer and
    // starts from the newest entry again.
    commandLineHistoryCursor = nil
    refreshCommandLine(text: command, cursorIndex: cursorIndex)
  }

  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    // History recall claims up/down (and ctrl+p/n) on an empty prompt or once a
    // recall is under way; otherwise the flashlight candidate list or the
    // command-completion list keeps the arrows. See `commandLineMoveTarget`.
    let target = NormalModeDispatcher.commandLineMoveTarget(
      bodyIsEmpty: NormalModeDispatcher.commandLineBodyIsEmpty(overlay.commandLineText),
      isRecalling: commandLineHistoryCursor != nil,
      hasCandidateQuery:
        NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil,
      hasCompletions: !commandLineCompletionMatches.isEmpty)
    // A list re-render must keep the caret where the user actually has it (they
    // may have moved it with an arrow/click without notifying us) rather than
    // forcing the stale stored index and jumping it to the line end.
    if target == .candidates || target == .completions {
      overlay.syncCommandLineCursorFromField()
    }
    switch target {
    case .candidates:
      guard !finder.matches.isEmpty else {
        refreshCommandLine(
          text: overlay.commandLineText,
          cursorIndex: overlay.commandLineCursorIndex)
        return true
      }
      // At the top candidate, one more "up" crosses into history (the stash
      // holds the current query, so stepping back down returns to this list).
      if NormalModeDispatcher.commandLineListTopEntersHistory(
        delta: delta, selectedIndex: finder.selectedIndex)
      {
        return recallCommandLineHistory(delta: delta)
      }
      finder.selectedIndex = min(
        max(finder.selectedIndex + delta, 0),
        finder.matches.count - 1)
      // Re-render the suggestion list with the new highlighted row only;
      // skip `refreshCommandLine` so we don't re-run the candidate search
      // for an unchanged query.
      overlay.displayCommandLine(
        overlay.commandLineText,
        suggestions: candidateFinderDisplayItems(),
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    case .completions:
      // Same crossover as the candidate list: "up" from the top completion
      // steps into history rather than clamping.
      if NormalModeDispatcher.commandLineListTopEntersHistory(
        delta: delta, selectedIndex: commandLineCompletionSelectedIndex)
      {
        return recallCommandLineHistory(delta: delta)
      }
      commandLineCompletionSelectedIndex = min(
        max(commandLineCompletionSelectedIndex + delta, 0),
        commandLineCompletionMatches.count - 1)
      overlay.displayCommandLine(
        overlay.commandLineText,
        suggestions: commandLineCompletionDisplayItems(),
        emptyText: "no matching command",
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    case .history:
      return recallCommandLineHistory(delta: delta)
    }
  }

  /// up/down (and ctrl+n/p, which route here) recall past commands when no
  /// candidate or completion list is active — `delta < 0` steps to older
  /// entries; `delta > 0` steps toward newer and finally back to the
  /// in-progress buffer the user had typed before recalling.
  private func recallCommandLineHistory(delta: Int) -> Bool {
    guard !commandLineHistory.isEmpty else { return false }
    let next: Int?
    if delta < 0 {
      switch commandLineHistoryCursor {
      case nil:
        commandLineHistoryStash = overlay.commandLineText
        next = commandLineHistory.count - 1
      case let cursor?:
        next = max(0, cursor - 1)
      }
    } else {
      switch commandLineHistoryCursor {
      case nil:
        return false
      case let cursor? where cursor >= commandLineHistory.count - 1:
        next = nil
      case let cursor?:
        next = cursor + 1
      }
    }
    commandLineHistoryCursor = next
    let text = next.map { commandLineHistory[$0] } ?? commandLineHistoryStash
    refreshCommandLine(text: text, cursorIndex: text.count)
    return true
  }

  /// `<tab>` in command-line mode. Two paths:
  ///
  ///   * Command-line *completions* (`:help <topic>`, `:plugins <sub>`,
  ///     `:<plugin> <action>`): insert the selected completion's
  ///     `value` into the buffer without sending — the user can keep
  ///     typing args, or hit `<cr>` to send.
  ///   * Candidate *finder* (`:flashlight` / `:emojis`):
  ///     `<tab>` submits final location rows, otherwise inserts the selected
  ///     candidate's canonical command text.
  ///     Cycling moves to arrow keys and `<shift-tab>`.
  func overlayDidInsertCommandLineSelection() -> Bool {
    if NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil {
      actOnSelectedCandidateFinderCandidate(
        submit: false, allowFinisher: false, submitFinalDestinations: true)
      return true
    }
    if applySelectedCommandLineCompletionInPlace() {
      return true
    }
    return overlayDidMoveCommandLineSelection(1)
  }

  /// `<cmd+cr>` in command-line mode: force-submit the selected
  /// flashlight candidate (dispatch for bangs, open for real
  /// candidates). Synthetic source-filter completion rows still only
  /// insert `@source `. The `<cr>` path is insert-first unless a
  /// source marks the row as a finisher or the typed primary title is
  /// exact; `<tab>` submits final location rows and otherwise inserts.
  func overlayDidForceSubmitCommandLineSelection() {
    if NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) == nil {
      // No flashlight active; mirror plain `<cr>` for a regular command
      // line so the chord stays predictable.
      submitCommandLine(overlay.commandLineText)
      return
    }
    actOnSelectedCandidateFinderCandidate(submit: true)
  }

  func overlayDidSubmitCommandLine(_ command: String) {
    submitCommandLine(command)
  }

  func overlayDidCancelCandidateFinder() {
    clearCandidateFinderState()
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidUpdateCandidateFinderQuery(_ query: String) {
    finder.selectedIndex = 0
    refreshCandidateFinder(query: query)
  }

  func overlayDidMoveCandidateFinderSelection(_ delta: Int) {
    guard !finder.matches.isEmpty else {
      refreshCandidateFinder(query: overlay.candidateFinderQuery)
      return
    }
    finder.selectedIndex = min(
      max(finder.selectedIndex + delta, 0),
      finder.matches.count - 1)
    // Just rerender with the new selection; re-scoring an unchanged query is
    // unnecessary work.
    overlay.displayCandidateFinder(
      query: overlay.candidateFinderQuery,
      items: candidateFinderDisplayItems())
  }

  func overlayDidSubmitCandidateFinder() {
    guard !finder.matches.isEmpty else {
      overlayDidCancelCandidateFinder()
      return
    }
    let candidate = finder.matches[
      min(finder.selectedIndex, finder.matches.count - 1)
    ]
    .candidate
    // A bang row carries its token in `sourcePayload`; the selection always
    // wins, so arrowing onto a non-bang result opens it even when the query
    // still starts with `!`.
    if dispatchBangCandidate(candidate, query: finder.currentQuery) {
      clearCandidateFinderState()
      overlay.hide()
      applyModeOverlay()
      return
    }
    openSourceItem(candidate, insertionTargetPID: finder.invocationTargetPID)
  }

  func openSourceItem(matching target: String) {
    sourceItemResolutionGeneration &+= 1
    let generation = sourceItemResolutionGeneration
    registry.resolveCandidate(matching: target) { [weak self] item in
      guard let self, generation == self.sourceItemResolutionGeneration else { return }
      guard let item else {
        FlashLog.warn("[app_open] no source item found")
        return
      }
      self.openSourceItem(item)
    }
  }

  func openSourceItem(
    _ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true,
    insertionTargetPID: pid_t? = nil, movementGeneration: UInt64? = nil
  ) {
    switch candidate.effect {
    case .copyText(let text):
      overlay.hide()
      resetCommandLineState()
      applyModeOverlay(captureOverride: true)
      NormalModeDispatcher.copy(text)
      return
    case .insertText(let text):
      insertText(text, viaClipboard: true, targetPID: insertionTargetPID)
      return
    case .openURL(let raw):
      overlay.hide()
      resetCommandLineState()
      applyModeOverlay(captureOverride: true)
      if let url = URL(string: raw), url.scheme != nil {
        // Async: the synchronous variant is a LaunchServices round trip on main.
        NSWorkspace.shared.open(
          url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
      }
      return
    case .openApplication(let bundleID):
      overlay.hide()
      resetCommandLineState()
      applyModeOverlay(captureOverride: true)
      if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(
          at: appURL, configuration: NSWorkspace.OpenConfiguration())
      } else {
        FlashLog.warn("[candidate_finder] open effect: no app for bundle id \(bundleID)")
      }
      return
    case nil:
      break
    }
    if CandidateFinder.insertsText(candidate) {
      // Emoji type directly (no clipboard); other inserted values (e.g. a
      // clipboard-history entry, which can be long) keep the reliable
      // copy + paste.
      insertText(
        candidate.sourcePayload ?? "",
        viaClipboard: candidate.kind != CandidateFinder.emojiKind,
        targetPID: insertionTargetPID)
      return
    }
    if shouldRecordMovement {
      recordMovement(.candidate(candidate), source: "source_open")
      // Frecency persists across restarts via the flat-JSON store,
      // not the movement stack — record it here so a chosen
      // candidate sorts higher next time.
      if let key = FrecencyMapper.itemKey(for: candidate) {
        frecencyStore?.recordOpen(itemKey: key)
      }
    }
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay(captureOverride: true)

    registry.resolveCandidate(candidate) { [weak self] result in
      guard let self else { return }
      if let movementGeneration {
        guard movementGeneration == self.movementLocationResolutionGeneration else { return }
        if !result.didResolve { self.movementNavigationTargetKey = nil }
      }
      if let pid = result.targetPID {
        // Plugin candidates (e.g. a tmux window) run their side effect
        // inside the plugin process and hand back a `target_pid` for the
        // app that hosts the result — the plugin can't raise a macOS app
        // itself, so the core must. App/browser candidates already
        // activate inside their own source; re-raising the same pid here
        // is idempotent and keeps the one code path correct for both.
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
          RunningApplicationActivation.activate(app, options: [.activateAllWindows])
        }
        self.normalModeTargetPID = pid
      } else if !result.didResolve {
        // Bumped to `warn` because a silent failure here is exactly the
        // "I picked the tmux window and nothing happened" case — the
        // log line is the only breadcrumb the user can correlate with
        // the plugin's own log inside `~/Library/Logs/Flash/flash.log`.
        FlashLog.warn(
          "[candidate_finder] unresolved candidate source=\(candidate.sourceID) kind=\(candidate.kind)"
        )
      }
      if shouldRecordMovement, let navigationURL = result.navigationURL {
        self.movementCurrent = .route(
          navigationURL,
          pid: result.targetPID ?? candidate.pid)
        self.pruneMovementStacks()
      }
      self.refreshCurrentModeSideEffects(reason: "source_resolved")
      self.scheduleNormalModeRecapture()
    }
  }
}

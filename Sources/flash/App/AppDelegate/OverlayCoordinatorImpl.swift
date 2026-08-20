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
      hasHints: !currentHints.isEmpty,
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
      suppressEditableFocus(for: clickedContext.processID)
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
      // work in that app, so that intent is unconditional (unlike the `f`/`F`
      // keyboard-driven commits, which still gate on the target's role).
      // Right-click never reaches here; it suspends above.
      resolvePointerInsertMode(
        pid: targetPID,
        reason: .pointerClick,
        handoffToken: handoffToken,
        intent: .physicalClick
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
    performMappingCommand(action, repeatCount: repeatCount)
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
      if !currentPrefix.isEmpty {
        currentPrefix.removeLast()
        overlay.filter(prefix: currentPrefix, hints: currentHints)
      }
      return
    }
    for ch in prefix.lowercased() {
      currentPrefix.append(ch)
    }
    overlay.filter(prefix: currentPrefix, hints: currentHints)

    // Single pass: count matches and remember the first one. Avoids
    // building a [AssignedHint] array per keystroke (was a 1-N alloc
    // every time the user typed a character). The hints carry a
    // pre-uppercased `display` field, so we don't pay an `uppercased()`
    // per chip per keystroke either.
    let upper = currentPrefix.uppercased()
    var matchCount = 0
    var firstMatch: AssignedHint?
    for h in currentHints where h.display.hasPrefix(upper) {
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
    guard
      pendingHintCommitBehavior == .mouseGridClick
        || pendingHintCommitBehavior == .mouseGridMove
        || pendingHintCommitBehavior == .mouseGridDrag
        || pendingHintCommitBehavior == .mouseGridSelect
        || pendingHintCommitBehavior == .mouseGridMulti,
      let grid = mouseGridRegion?.grid
    else {
      return false
    }
    let centerIndex = grid.centerCellIndex
    guard currentHints.indices.contains(centerIndex) else { return false }
    commit(hint: currentHints[centerIndex], clickModifiers: clickModifiers)
    return true
  }

  func overlayDidUpdatePrefix(_ prefix: String) {
    if prefix == "__BACKSPACE__" {
      if !currentPrefix.isEmpty {
        currentPrefix.removeLast()
        overlay.filter(prefix: currentPrefix, hints: currentHints)
      }
    } else {
      currentPrefix = prefix
      overlay.filter(prefix: currentPrefix, hints: currentHints)
    }
  }

  private func commit(hint: AssignedHint, clickModifiers: ClickModifiers) {
    switch pendingHintCommitBehavior {
    case .mouseGridClick, .mouseGridMove, .mouseGridDrag, .mouseGridSelect, .mouseGridMulti:
      commitMouseGridCell(hint: hint, clickModifiers: clickModifiers)
      return
    case .click, .copyURL, .moveMouse, .drag, .select, .multiClick, .adjustClick, .searchClick:
      break
    }
    if pendingHintCommitBehavior == .copyURL {
      if let url = hint.target.url {
        NormalModeDispatcher.copy(url)
      }
      overlay.hide()
      clearHintSessionState()
      activationLifecycle.supersede()
      applyModeOverlay()
      return
    }
    if pendingHintCommitBehavior == .moveMouse {
      let chipRect = OverlayPanel.chipFrame(
        for: hint, fontSize: CGFloat(config.overlay.fontSize))
      let point = CGPoint(x: chipRect.midX, y: chipRect.midY)
      _ = ActionDispatcher.moveCursor(to: point)
      overlay.hide()
      clearHintSessionState()
      activationLifecycle.supersede()
      applyModeOverlay()
      return
    }
    if pendingHintCommitBehavior == .multiClick {
      commitMultiClick(hint: hint, clickModifiers: clickModifiers)
      return
    }
    if pendingHintCommitBehavior == .adjustClick {
      guard adjustingHint == nil else { return }
      let chipRect = OverlayPanel.chipFrame(
        for: hint, fontSize: CGFloat(config.overlay.fontSize))
      let start =
        hint.target.resolveClickPoint?() ?? CGPoint(x: chipRect.midX, y: chipRect.midY)
      adjustingHint = hint
      adjustPoint = start
      overlay.showAdjustment(markerAt: start, targetFrame: hint.target.frame)
      FlashLog.trace(
        "[commit] adjust_enter point=(\(Int(start.x)),\(Int(start.y))) "
          + "frame=\(hint.target.frame.debugDescription)")
      return
    }
    if pendingHintCommitBehavior == .drag || pendingHintCommitBehavior == .select {
      let chipRect = OverlayPanel.chipFrame(
        for: hint, fontSize: CGFloat(config.overlay.fontSize))
      let point =
        hint.target.resolveClickPoint?() ?? CGPoint(x: chipRect.midX, y: chipRect.midY)
      if let source = dragSourcePoint {
        performTwoPhaseCommit(from: source, to: point, clickModifiers: clickModifiers)
      } else {
        // Phase 1: remember the anchor point and keep the same hint set up for
        // the second point — no re-walk, no overlay teardown, just an un-filter.
        dragSourcePoint = point
        currentPrefix = ""
        overlay.filter(prefix: "", hints: currentHints)
        FlashLog.trace(
          "[commit] two_phase_anchor=(\(Int(point.x)),\(Int(point.y))) "
            + "behavior=\(pendingHintCommitBehavior) awaiting_second_point")
      }
      return
    }

    let action = pendingAction
    // The target carries its owning pid (always the focused app at walk time).
    // Fall back to the activation-time focused pid if the provider didn't set
    // one, then resolve the owning bundle once for app-specific click gestures.
    let pid = hint.target.pid ?? sourceAppPID
    let targetApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    let targetBundleIdentifier = targetApp?.bundleIdentifier
    let resolvedClickModifiers = ActionDispatcher.hintClickModifiers(
      for: hint.target,
      bundleIdentifier: targetBundleIdentifier,
      requested: pendingClickModifiers.union(clickModifiers))
    let wasNormalMode = flashMode == .normal
    let actionMayEnterInsert = Self.pointerActionMayEnterInsert(action)
    if let pid {
      recordMovement(.app(pid: pid), source: "hint_commit")
    }
    // Land the click — and the cursor — on the hint chip itself, where the
    // user sees the label, not the element's geometric centre. For small
    // targets `chipFrame` centres the chip on the target so the two coincide;
    // for wide/tall targets (long tmux words, big AX rows, wrapped web links)
    // the chip anchors near the leading edge, which also keeps the click off a
    // wrapped link's empty inter-line gap. A provider-resolved point (e.g. a
    // browser DOM first-character) still wins when present.
    let chipRect = OverlayPanel.chipFrame(
      for: hint, fontSize: CGFloat(config.overlay.fontSize))
    let chipCenter = CGPoint(x: chipRect.midX, y: chipRect.midY)
    let clickPoint = hint.target.resolveClickPoint?() ?? chipCenter
    lastCommittedClick = LastCommittedClick(
      point: clickPoint, action: action, modifiers: resolvedClickModifiers, pid: pid)
    FlashLog.trace(
      "[commit] action=\(action) role=\(hint.target.role ?? "?") "
        + "provider=\(hint.target.providerID) "
        + "click=(\(Int(clickPoint.x)),\(Int(clickPoint.y))) "
        + "modifiers=cmd:\(resolvedClickModifiers.contains(.command)) "
        + "shift:\(resolvedClickModifiers.contains(.shift)) "
        + "ctrl:\(resolvedClickModifiers.contains(.control)) "
        + "alt:\(resolvedClickModifiers.contains(.option)) "
        + "enters_insert=\(hint.target.entersInsertMode)")

    let mayResolveInsert = wasNormalMode && actionMayEnterInsert
    let handoffToken: UInt64?
    if mayResolveInsert {
      handoffToken = notePointerInsertHandoff(reason: "hint_commit")
    } else {
      handoffToken = nil
    }
    if wasNormalMode {
      applyModeOverlay(captureOverride: false)
    }
    overlay.hide()
    // Restore focus to the target app before posting the mouse event so the
    // underlying surface receives and interprets the click.
    if let targetApp {
      RunningApplicationActivation.activate(targetApp, options: [])
    }
    // Hold the activation gate closed across the click dispatch. Without
    // this, the 20-ms delay below opens a window where a fresh
    // ctrl+space can land and start a second walk, and *this* commit's
    // click would then fire during the new activation (clicking
    // whatever the user was about to hint, not what they committed to).
    activationInFlight = true
    activationLifecycle.supersede()
    clearHintSessionState()
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      // The click's blocking work now runs off the main run loop; settle Flash's
      // mode in the completion so it still happens *after* the click lands.
      ActionDispatcher.perform(
        action, on: hint.target, clickPoint: clickPoint,
        bundleIdentifier: targetBundleIdentifier,
        modifiers: resolvedClickModifiers,
        leaveCursorAtClickPoint: true
      ) { [weak self] in
        guard let self else { return }
        self.activationInFlight = false
        if mayResolveInsert {
          self.resolvePointerInsertMode(
            pid: pid,
            reason: .hintCommit,
            handoffToken: handoffToken,
            intent: .hintTarget(entersInsertMode: hint.target.entersInsertMode)
          ) {
            [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .enteredInsert:
              self.clearPointerInsertHandoff(
                reason: "hint_commit_entered_insert",
                token: handoffToken)
            case .recaptureNormal:
              self.clearPointerInsertHandoff(
                reason: "hint_commit_stayed_normal", token: handoffToken)
              guard self.flashMode == .normal else { return }
              self.restoreNormalModeAfterCommit(action: action)
            }
          }
        } else if wasNormalMode {
          self.restoreNormalModeAfterCommit(action: action)
        }
      }
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
  private func restoreNormalModeAfterCommit(action: JumpAction) {
    clearPointerInsertHandoff(reason: "restore_normal_after_commit")
    if action == .rightClick {
      suspendNormalCaptureForNativeSurface(reason: "hint_right_click")
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

  /// Reset the transient "hints showing / mouse-grid in progress" session to its
  /// idle values in one assignment. Resetting `HintSession` to its default means
  /// a newly added session field is cleared automatically — no per-field reset
  /// line to forget (the leak the previous copy-pasted-in-8-places reset risked).
  /// Call sites keep any *non-session* side effects they also perform (the
  /// activation generation bump, `pendingAction` reset, `overlay.hide()`).
  func clearHintSessionState() {
    hintSession = HintSession()
  }

  private func dismissTransientPointerStateWithoutRekey(reason: String) {
    let hadActivation = activationInFlight || activationInFlightGeneration != nil
    guard !currentHints.isEmpty || hadActivation else { return }
    overlay.hide()
    clearHintSessionState()
    pendingAction = .leftClick
    if hadActivation {
      invalidateActivation(reason: reason)
    }
  }

  private func releaseNormalCaptureForPointerHandoff(reason: String) {
    overlay.hide()
    let hadActivation = activationInFlight || activationInFlightGeneration != nil
    let hadTransientState = !currentHints.isEmpty || hadActivation
    clearHintSessionState()
    pendingAction = .leftClick
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
    if let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) {
      RunningApplicationActivation.activate(app, options: [])
    }
    FlashLog.trace(
      "[mode] pointer_forward_host_click action=\(click.action) "
        + "point=(\(Int(click.location.x)),\(Int(click.location.y))) "
        + "modifiers=cmd:\(click.modifiers.contains(.command)) "
        + "shift:\(click.modifiers.contains(.shift)) "
        + "ctrl:\(click.modifiers.contains(.control)) "
        + "alt:\(click.modifiers.contains(.option))")
    _ = ActionDispatcher.synthesizeClick(
      at: click.location,
      action: click.action,
      modifiers: click.modifiers)
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

  private func commitMouseGridCell(hint: AssignedHint, clickModifiers: ClickModifiers) {
    let nextRegion = MouseGrid.Region(frame: hint.target.frame, grid: mouseGridRegion?.grid)
    let nextDepth = mouseGridDepth + 1
    if !MouseGrid.shouldCommit(
      region: nextRegion, depth: nextDepth, steps: config.hints.mouseGridSteps)
    {
      mouseGridRegion = nextRegion
      mouseGridDepth = nextDepth
      currentPrefix = ""
      displayMouseGridRegion(nextRegion, depth: nextDepth)
      return
    }

    let point = CGPoint(x: nextRegion.frame.midX, y: nextRegion.frame.midY)
    if pendingHintCommitBehavior == .mouseGridMulti {
      _ = ActionDispatcher.synthesizeClick(
        at: point,
        action: pendingAction,
        modifiers: pendingClickModifiers.union(clickModifiers),
        preserveCursor: false)
      if let initial = mouseGridInitialRegion {
        mouseGridDepth = 0
        currentPrefix = ""
        displayMouseGridRegion(initial, depth: 0)
      } else {
        cancelOverlay()
      }
      return
    }
    if pendingHintCommitBehavior == .mouseGridDrag || pendingHintCommitBehavior == .mouseGridSelect
    {
      if let source = dragSourcePoint {
        performTwoPhaseCommit(from: source, to: point, clickModifiers: clickModifiers)
      } else if let initial = mouseGridInitialRegion {
        // Phase 1: remember the anchor point and restart the grid from its full
        // extent so the second point can land anywhere, not only inside the
        // drilled-down source cell.
        dragSourcePoint = point
        mouseGridDepth = 0
        currentPrefix = ""
        displayMouseGridRegion(initial, depth: 0)
        FlashLog.trace(
          "[commit] grid_two_phase_anchor=(\(Int(point.x)),\(Int(point.y))) "
            + "behavior=\(pendingHintCommitBehavior) awaiting_second_point")
      } else {
        cancelOverlay()
      }
      return
    }
    let shouldMove = pendingHintCommitBehavior == .mouseGridMove
    let priorPID = sourceAppPID
    let resolvedClickModifiers = pendingClickModifiers.union(clickModifiers)
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.supersede()
    if shouldMove {
      _ = ActionDispatcher.moveCursor(to: point)
      applyModeOverlay()
      return
    }
    let clickAction = pendingAction
    lastCommittedClick = LastCommittedClick(
      point: point, action: clickAction, modifiers: resolvedClickModifiers, pid: priorPID)
    let handoffToken: UInt64?
    if clickAction != .rightClick {
      handoffToken = notePointerInsertHandoff(reason: "mouse_grid_commit")
    } else {
      handoffToken = nil
    }
    _ = ActionDispatcher.synthesizeClick(
      at: point,
      action: clickAction,
      modifiers: resolvedClickModifiers)
    if clickAction == .rightClick {
      // Right-click opened a context menu — same rule as `commit()`:
      // do not render or re-key the panel, or the menu loses its modal
      // session the same instant it appears.
      suspendNormalCaptureForNativeSurface(reason: "mouse_grid_right_click")
    } else {
      applyModeOverlay(captureOverride: false)
      resolvePointerInsertMode(
        pid: priorPID,
        reason: .pointerClick,
        handoffToken: handoffToken,
        intent: .mouseGridClick
      ) {
        [weak self] outcome in
        guard let self else { return }
        switch outcome {
        case .enteredInsert:
          self.clearPointerInsertHandoff(
            reason: "mouse_grid_entered_insert",
            token: handoffToken)
        case .recaptureNormal:
          self.clearPointerInsertHandoff(reason: "mouse_grid_stayed_normal", token: handoffToken)
          guard self.flashMode == .normal else { return }
          self.scheduleNormalModeRecapture()
        }
      }
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
      guard !currentHints.isEmpty else { return }
      hintSession.searchSelectionIndex =
        (hintSession.searchSelectionIndex + 1) % currentHints.count
      updateSearchSelectionMarker()
    case .commit:
      guard !currentHints.isEmpty else { return }
      let index = min(hintSession.searchSelectionIndex, currentHints.count - 1)
      let selected = currentHints[index]
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
    currentHints = matches
    overlay.display(hints: matches)
    // display() re-arms hint-prefix routing state on the panel; restore the
    // search flag it does not know about.
    overlay.searchModeActive = true
    updateSearchSelectionMarker()
    FlashLog.trace(
      "[search] query_len=\(hintSession.searchQuery.count) matches=\(matches.count)")
  }

  func updateSearchSelectionMarker() {
    guard hintSession.searchActive || pendingHintCommitBehavior == .searchClick,
      !currentHints.isEmpty
    else {
      overlay.hideAdjustment()
      return
    }
    let index = min(hintSession.searchSelectionIndex, currentHints.count - 1)
    let frame = currentHints[index].target.frame
    overlay.showSelectionMarker(
      at: CGPoint(x: frame.midX, y: frame.midY), targetFrame: frame)
  }

  /// One keystroke of the `--adjust` sub-state, forwarded by the panel while
  /// `adjustmentActive` is set: move/snap keys update the marker; the commit
  /// key fires the pending action at the refined point.
  func overlayDidAdjust(_ command: HintAdjustmentCommand, clickModifiers: ClickModifiers) {
    guard let hint = adjustingHint, let point = adjustPoint else {
      cancelOverlay()
      return
    }
    switch command {
    case .cancel:
      cancelOverlay()
    case .commit:
      performAdjustedCommit(hint: hint, at: point, clickModifiers: clickModifiers)
    case .snapLeft, .snapRight, .snapTop, .snapBottom, .interpolate, .reset:
      let updated = HintAdjustmentInterpreter.apply(command, to: point, in: hint.target.frame)
      adjustPoint = updated
      overlay.showAdjustment(markerAt: updated, targetFrame: hint.target.frame)
    }
  }

  /// Fire the adjusted click. Mirrors the mouse-grid commit tail: the refined
  /// point is pointer simulation, so a primary click enters INSERT
  /// unconditionally and a right-click suspends for the context menu.
  private func performAdjustedCommit(
    hint: AssignedHint,
    at point: CGPoint,
    clickModifiers: ClickModifiers
  ) {
    let action = pendingAction
    let pid = hint.target.pid ?? sourceAppPID
    let targetApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    let modifiers = pendingClickModifiers.union(clickModifiers)
    lastCommittedClick = LastCommittedClick(
      point: point, action: action, modifiers: modifiers, pid: pid)
    FlashLog.trace(
      "[commit] adjust action=\(action) point=(\(Int(point.x)),\(Int(point.y)))")
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.supersede()
    if let targetApp {
      RunningApplicationActivation.activate(targetApp, options: [])
    }
    let handoffToken: UInt64?
    if action != .rightClick {
      handoffToken = notePointerInsertHandoff(reason: "adjust_commit")
    } else {
      handoffToken = nil
    }
    _ = ActionDispatcher.synthesizeClick(
      at: point, action: action, modifiers: modifiers, preserveCursor: false)
    if action == .rightClick {
      suspendNormalCaptureForNativeSurface(reason: "adjust_right_click")
    } else {
      applyModeOverlay(captureOverride: false)
      resolvePointerInsertMode(
        pid: pid,
        reason: .pointerClick,
        handoffToken: handoffToken,
        intent: .mouseGridClick
      ) { [weak self] outcome in
        guard let self else { return }
        switch outcome {
        case .enteredInsert:
          self.clearPointerInsertHandoff(reason: "adjust_entered_insert", token: handoffToken)
        case .recaptureNormal:
          self.clearPointerInsertHandoff(reason: "adjust_stayed_normal", token: handoffToken)
          guard self.flashMode == .normal else { return }
          self.scheduleNormalModeRecapture()
        }
      }
    }
  }

  /// Insert-handoff tail for a pointer-mode committing click — identical to
  /// the mouse-grid commit outcome handling.
  func resolvePointerModeInsert(pid: pid_t?, handoffToken: UInt64?) {
    resolvePointerInsertMode(
      pid: pid,
      reason: .pointerClick,
      handoffToken: handoffToken,
      intent: .mouseGridClick
    ) { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .enteredInsert:
        self.clearPointerInsertHandoff(
          reason: "pointer_mode_entered_insert", token: handoffToken)
      case .recaptureNormal:
        self.clearPointerInsertHandoff(
          reason: "pointer_mode_stayed_normal", token: handoffToken)
        guard self.flashMode == .normal else { return }
        self.scheduleNormalModeRecapture()
      }
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
    let wasNormalMode = flashMode == .normal
    if let pid = last.pid,
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
    {
      RunningApplicationActivation.activate(app, options: [])
    }
    FlashLog.trace(
      "[mouse_repeat] point=(\(Int(last.point.x)),\(Int(last.point.y))) "
        + "action=\(last.action) count=\(max(1, repeatCount))")
    // The click queue is serial, so posting the repeats back-to-back keeps
    // them ordered; only the final one carries the recapture completion.
    let count = max(1, repeatCount)
    for index in 1...count {
      _ = ActionDispatcher.synthesizeClick(
        at: last.point,
        action: last.action,
        modifiers: last.modifiers,
        preserveCursor: false,
        completion: index < count
          ? nil
          : { [weak self] in
            guard let self else { return }
            if wasNormalMode, self.flashMode == .normal {
              self.scheduleNormalModeRecapture()
            }
          })
    }
  }

  /// One commit of a `--multi` session: perform the pending action on the
  /// selected target, then re-arm the same hint set for the next selection
  /// instead of tearing the session down. The session never enters INSERT —
  /// multi-clicking is target manipulation, and a mode flip would end it.
  /// Escape (cancelOverlay) finishes the session.
  private func commitMultiClick(hint: AssignedHint, clickModifiers: ClickModifiers) {
    let action = pendingAction
    let pid = hint.target.pid ?? sourceAppPID
    let targetApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    let targetBundleIdentifier = targetApp?.bundleIdentifier
    let resolvedClickModifiers = ActionDispatcher.hintClickModifiers(
      for: hint.target,
      bundleIdentifier: targetBundleIdentifier,
      requested: pendingClickModifiers.union(clickModifiers))
    let chipRect = OverlayPanel.chipFrame(
      for: hint, fontSize: CGFloat(config.overlay.fontSize))
    let clickPoint =
      hint.target.resolveClickPoint?() ?? CGPoint(x: chipRect.midX, y: chipRect.midY)
    FlashLog.trace(
      "[commit] multi action=\(action) role=\(hint.target.role ?? "?") "
        + "click=(\(Int(clickPoint.x)),\(Int(clickPoint.y)))")
    lastCommittedClick = LastCommittedClick(
      point: clickPoint, action: action, modifiers: resolvedClickModifiers, pid: pid)
    if let targetApp {
      RunningApplicationActivation.activate(targetApp, options: [])
    }
    currentPrefix = ""
    overlay.filter(prefix: "", hints: currentHints)
    ActionDispatcher.perform(
      action, on: hint.target, clickPoint: clickPoint,
      bundleIdentifier: targetBundleIdentifier,
      modifiers: resolvedClickModifiers,
      leaveCursorAtClickPoint: true
    ) { [weak self] in
      guard let self, !self.currentHints.isEmpty else { return }
      // Re-present the surviving hint set so the panel re-keys: in
      // non-advanced mode capture rides on panel key status, and the app
      // activation above may have taken it.
      self.overlay.display(hints: self.currentHints)
    }
  }

  /// Phase 2 of a `--drag` / `--select` commit: both points are known, so tear
  /// the session down and synthesize the gesture — a continuous drag, or a
  /// click + shift-click selection. Both manipulate the pointer without typing
  /// intent, so they never enter INSERT — NORMAL just recaptures once the
  /// gesture has been posted.
  private func performTwoPhaseCommit(
    from source: CGPoint,
    to destination: CGPoint,
    clickModifiers: ClickModifiers
  ) {
    let isSelect =
      pendingHintCommitBehavior == .select || pendingHintCommitBehavior == .mouseGridSelect
    let modifiers = pendingClickModifiers.union(clickModifiers)
    let wasNormalMode = flashMode == .normal
    let targetApp = sourceAppPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    FlashLog.trace(
      "[commit] two_phase kind=\(isSelect ? "select" : "drag") "
        + "from=(\(Int(source.x)),\(Int(source.y))) "
        + "to=(\(Int(destination.x)),\(Int(destination.y))) "
        + "modifiers=cmd:\(modifiers.contains(.command)) "
        + "shift:\(modifiers.contains(.shift)) ctrl:\(modifiers.contains(.control)) "
        + "alt:\(modifiers.contains(.option))")
    if wasNormalMode {
      applyModeOverlay(captureOverride: false)
    }
    overlay.hide()
    if let targetApp {
      RunningApplicationActivation.activate(targetApp, options: [])
    }
    // Same re-entry gate as a click commit: hold activation closed across the
    // gesture so a fresh hotkey can't start a walk mid-gesture.
    activationInFlight = true
    activationLifecycle.supersede()
    clearHintSessionState()
    let finish: () -> Void = { [weak self] in
      guard let self else { return }
      self.activationInFlight = false
      if wasNormalMode, self.flashMode == .normal {
        self.scheduleNormalModeRecapture()
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
      if isSelect {
        ActionDispatcher.synthesizeSelection(
          from: source, to: destination, modifiers: modifiers, completion: finish)
      } else {
        ActionDispatcher.synthesizeDrag(
          from: source, to: destination, modifiers: modifiers, completion: finish)
      }
    }
  }

  /// Resolve whether a primary pointer commit hands the keyboard to the focused
  /// app (INSERT) or keeps NORMAL:
  ///
  ///   - Physical and `mouse_grid` clicks are pointer simulation, so they enter
  ///     INSERT unconditionally.
  ///   - `mouse_target` hints honor `JumpTarget.entersInsertMode`. A link hint
  ///     stays in NORMAL even when its owning app (such as a terminal) already
  ///     exposes an editable focused element.
  ///
  /// Right-click never reaches here — it opens a context menu and stays in
  /// NORMAL via `suspendNormalCaptureForNativeSurface`.
  private func resolvePointerInsertMode(
    pid: pid_t?,
    reason: InsertModeTransitionReason,
    handoffToken: UInt64? = nil,
    intent: PointerInsertIntent,
    completion: ((PointerInsertHandoffOutcome) -> Void)? = nil
  ) {
    guard pointerInsertHandoffIsCurrent(handoffToken) else { return }
    guard flashMode == .normal else {
      completion?(.recaptureNormal)
      return
    }
    guard intent.shouldEnterInsertMode else {
      completion?(.recaptureNormal)
      return
    }
    let targetPID = pid ?? currentNonFlashContext()?.processID
    enterInsertMode(reason: reason, targetPID: targetPID)
    completion?(.enteredInsert)
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  /// The Accessibility tap is unavailable, so the panel already received and
  /// consumed the original event. Replay the equivalent chord to the focused
  /// app while NORMAL mappings are still registered, then enter INSERT on the
  /// following main-loop turn. The normal-scope matcher already rejected this
  /// chord before this method was called.
  func overlayDidPassthroughNormalModeKey(_ event: NSEvent) {
    guard flashMode == .normal,
      let pid = currentNonFlashContext()?.processID ?? normalModeTargetPID
    else { return }
    let keyCode = CGKeyCode(event.keyCode)
    let flags = ClickModifiers(eventFlags: event.modifierFlags).cgEventFlags
    DispatchQueue.main.async {
      _ = NormalModeDispatcher.sendKey(virtualKey: keyCode, flags: flags, to: pid)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.flashMode == .normal, self.overlay.inputMode == .normal else { return }
        self.enterInsertMode(reason: .normalModePassthrough, targetPID: pid)
      }
    }
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
    // Hand activation back to the app the bar covered, the way a *submit* does via
    // its app switch. `NSApp.deactivate()` is advisory and ignored on this macOS
    // (Flash stays "active"), so the non-activating panel couldn't regain key on
    // the next open and showed no caret. Activating another app reliably
    // deactivates Flash, so reopening forces a clean re-activation → the panel
    // keys → the caret returns. Mirrors the working submit path.
    if let context = currentNonFlashContext() ?? normalModeContext(),
      let app = NSRunningApplication(processIdentifier: context.processID),
      !app.isTerminated
    {
      RunningApplicationActivation.activate(app, options: [])
    }
    finishCommandLineInteraction(reason: "command_cancel")
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
      candidateFinderSelectedIndex = 0
    }
    // A real edit ends history recall: the next up/down stashes this buffer and
    // starts from the newest entry again.
    commandLineHistoryCursor = nil
    refreshCommandLine(text: command, cursorIndex: cursorIndex)
  }

  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    if NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil {
      guard !candidateFinderMatches.isEmpty else {
        refreshCommandLine(
          text: overlay.commandLineText,
          cursorIndex: overlay.commandLineCursorIndex)
        return true
      }
      candidateFinderSelectedIndex = min(
        max(candidateFinderSelectedIndex + delta, 0),
        candidateFinderMatches.count - 1)
      // Re-render the suggestion list with the new highlighted row only;
      // skip `refreshCommandLine` so we don't re-run the candidate search
      // for an unchanged query.
      overlay.displayCommandLine(
        overlay.commandLineText,
        suggestions: candidateFinderDisplayItems(),
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    if !commandLineCompletionMatches.isEmpty {
      commandLineCompletionSelectedIndex = min(
        max(commandLineCompletionSelectedIndex + delta, 0),
        commandLineCompletionMatches.count - 1)
      overlay.displayCommandLine(
        overlay.commandLineText,
        suggestions: commandLineCompletionDisplayItems(),
        emptyText: "no matching command",
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    return recallCommandLineHistory(delta: delta)
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
    candidateFinderSelectedIndex = 0
    refreshCandidateFinder(query: query)
  }

  func overlayDidMoveCandidateFinderSelection(_ delta: Int) {
    guard !candidateFinderMatches.isEmpty else {
      refreshCandidateFinder(query: overlay.candidateFinderQuery)
      return
    }
    candidateFinderSelectedIndex = min(
      max(candidateFinderSelectedIndex + delta, 0),
      candidateFinderMatches.count - 1)
    // Just rerender with the new selection; re-scoring an unchanged query is
    // unnecessary work.
    overlay.displayCandidateFinder(
      query: overlay.candidateFinderQuery,
      items: candidateFinderDisplayItems())
  }

  func overlayDidSubmitCandidateFinder() {
    guard !candidateFinderMatches.isEmpty else {
      overlayDidCancelCandidateFinder()
      return
    }
    let candidate = candidateFinderMatches[
      min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)
    ]
    .candidate
    // A bang row carries its token in `sourcePayload`; the selection always
    // wins, so arrowing onto a non-bang result opens it even when the query
    // still starts with `!`.
    if dispatchBangCandidate(candidate, query: candidateFinderCurrentQuery) {
      clearCandidateFinderState()
      overlay.hide()
      applyModeOverlay()
      return
    }
    openSourceItem(candidate)
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

  func openSourceItem(_ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true) {
    switch candidate.effect {
    case .copyText(let text):
      overlay.hide()
      resetCommandLineState()
      applyModeOverlay(captureOverride: true)
      NormalModeDispatcher.copy(text)
      return
    case .insertText(let text):
      insertText(text, viaClipboard: true)
      return
    case .openURL(let raw):
      overlay.hide()
      resetCommandLineState()
      applyModeOverlay(captureOverride: true)
      if let url = URL(string: raw), url.scheme != nil {
        NSWorkspace.shared.open(url)
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
        viaClipboard: candidate.kind != CandidateFinder.emojiKind)
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
        self.suppressEditableFocus(for: pid)
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

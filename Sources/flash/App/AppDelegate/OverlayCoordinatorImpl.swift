import AppKit
import FlashCore

/// `OverlayCoordinator` protocol conformance: the callback surface the
/// `OverlayPanel` uses to report user input + state transitions back to
/// AppDelegate.
extension AppDelegate {
  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {
    Trace.ensure(.pointer) { handlePointerIntent(intent) }
  }

  private func handlePointerIntent(_ intent: OverlayPointerIntent) {
    // A click or a scroll is not the key a half-typed sequence waits for:
    // drop it, and the palette listing what could follow it.
    if !overlay.normalModePending.isEmpty || whichKeyShown {
      resetPendingNormalSequence(reason: "pointer")
    }
    // A click replaces the app's selection: VISUAL no longer knows its ends.
    if case .click = intent, modeStore.mode.isVisual {
      FlashLog.debug("[visual] leave", fields: ["reason": "click"])
      leaveVisual(collapse: false)
    }
    // A primary click in an app engages the field its focus settles on.
    if case .click(let click) = intent, click.action.isPrimaryClick,
      modeStore.mode == .normal, !Self.pointIsInMenuBar(click.location)
    {
      awaitTextFocus(in: nil, reason: .click)
    }
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
    case .menuBar(let dismissHints):
      noteMenuBarInteraction(reason: "pointer_click")
      FlashLog.trace("[mode] pointer_in_menu_bar mode=\(flashMode)")
      if dismissHints {
        dismissTransientPointerStateWithoutRekey(reason: "menu_bar_click")
      }
      suspendNormalCaptureForNativeSurface(reason: "menu_bar_pointer")
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
    // `finishCommandLineInteraction` (called via `cancelOverlay`) restores
    // the prior mode (the one that was active when the command line was
    // entered). Plain app clicks while NORMAL is capturing keep NORMAL.
    let clickedContext = click.flatMap { currentNonFlashContext(at: $0.location) }
    let targetPID =
      clickedContext?.processID ?? currentDirectNonFlashContext()?.processID
      ?? normalModeTargetPID
    if let clickedContext, flashMode == .normal {
      normalModeTargetPID = clickedContext.processID
    }
    switch decision {
    case .ignore:
      cancelOverlay()
    case .suspendForNativeSurface(let dismissHints):
      if dismissHints {
        dismissTransientPointerStateWithoutRekey(reason: "physical_native_surface")
      }
      suspendNormalCaptureForNativeSurface(reason: "physical_native_surface")
    case .keepNormal:
      guard let click else { return }
      // The click ends hints showing behind it. NORMAL keeps the keyboard
      // whatever the click landed on.
      let hadTransientState = !hintSession.hints.isEmpty || activationInFlight
      dismissTransientPointerStateWithoutRekey(reason: "physical_pointer_click")
      if hadTransientState { applyModeOverlay() }
      // When Flash was the active app, or the clicked window's app was not
      // frontmost, macOS spent the physical click on activation and the
      // control under the cursor (a field, a tmux status-bar tab) never saw
      // it: Flash delivers it again, and recaptures once it is posted. When
      // the target was already frontmost the click landed on its own, so
      // forwarding would double-deliver.
      guard
        Self.physicalPointerClickShouldBeForwarded(
          decision: decision, click: click, targetPID: targetPID)
      else {
        scheduleNormalModeRecaptureAfterClick()
        return
      }
      forwardPhysicalPointerClick(click, targetPID: targetPID) { [weak self] in
        self?.scheduleNormalModeRecaptureAfterClick()
      }
    }
  }

  /// NORMAL takes the keyboard back after a physical click, unless the mode
  /// changed in between.
  private func scheduleNormalModeRecaptureAfterClick() {
    guard flashMode == .normal else { return }
    scheduleNormalModeRecapture()
  }

  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int) {
    guard flashMode == .normal else { return }
    // A click's or `gi`'s wait for its focus ends at the next key.
    textScope.keyTyped(readPending: focusRegionTracker.isReading)
    normalModePendingCommandToken &+= 1
    hideWhichKey()
    guard let action else {
      schedulePendingNormalModeCommandIfNeeded()
      scheduleWhichKeyIfNeeded()
      return
    }
    dispatchNormalModeAction(action, repeatCount: repeatCount, reason: "key_match")
    if modeStore.mode.isHyper || modeStore.mode.isLayer { scheduleWhichKeyIfNeeded() }
  }

  /// After `which_key_ms` on an unchanged prefix, list what can follow it.
  var whichKeyPending: String {
    modeStore.mode.isHyper
      ? (overlay.leaderFallbackPending ?? overlay.hyperPending) : overlay.normalModePending
  }

  func scheduleWhichKeyIfNeeded() {
    let mode = modeStore.mode
    let pending = whichKeyPending
    guard config.mode.whichKeyMs > 0, !hintSession.isActive,
      mode == .normal || mode.isHold || mode.isHyper || mode.isLayer,
      !pending.isEmpty || mode.isHyper || mode.isLayer
    else { return }
    whichKeyDeadline.arm(afterMs: config.mode.whichKeyMs) { [weak self] in
      self?.showWhichKey(for: pending, mode: mode)
    }
  }

  func showWhichKey(for pending: String, mode: Mode) {
    guard modeStore.mode == mode, overlay.inputMode == .normal, !hintSession.isActive,
      whichKeyPending == pending
    else { return }
    let hyper = mode.isHyper && overlay.leaderFallbackPending == nil
    let palette = WhichKey.rows(
      after: pending, in: hyper ? overlay.hyperModeMappings : overlay.normalModeMappings,
      literal: hyper, includeRoot: mode.isHyper || mode.isLayer)
    guard !palette.entries.isEmpty else { return }
    // The palette waits for the key it lists: the prefix no longer expires.
    overlay.normalModePendingUpdatedAt = nil
    overlay.hyperPendingUpdatedAt = nil
    overlay.leaderFallbackUpdatedAt = nil
    whichKeyShown = true
    let focusedFrame =
      overlay.activeWindowBorderFrame
      ?? lastFocusedApplicationPID.flatMap { activeWindowBorderFrameCache[$0] }
    overlay.displayWindowSwitcher(
      WindowSwitcherDisplay(
        rows: palette.entries.map {
          WindowSwitcherDisplay.Row(
            label: $0.label, app: "", title: $0.title, badge: nil, icon: nil)
        },
        selection: 0, typed: palette.typed,
        anchor: focusedFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation,
        highlightsSelection: false))
    FlashLog.debug("[input] which_key_shown", fields: ["keys": String(palette.entries.count)])
  }

  /// Take the palette down, and any pause still counting toward it.
  func hideWhichKey() {
    whichKeyDeadline.cancel()
    guard whichKeyShown else { return }
    whichKeyShown = false
    // Out of NORMAL, the new mode's surface already replaced the palette.
    guard flashMode == .normal else { return }
    overlay.hide()
    applyModeOverlay()
  }

  private func schedulePendingNormalModeCommandIfNeeded() {
    guard !modeStore.mode.isHyper else { return }
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
      // The palette lists what can follow: the sequence waits for the key.
      guard !self.whichKeyShown else { return }
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

  func dispatchNormalModeAction(
    _ action: MappingCommand,
    repeatCount: Int,
    reason: String
  ) {
    // The accepted mapping owns the whole pending sequence. Clear it before
    // any side effect can activate another app, so a fast follow-up chord
    // starts from a fresh stack instead of leaking into the newly focused
    // window while Flash is recapturing normal mode.
    overlay.normalModePending = ""
    hideWhichKey()
    leaveOneShotLayer(before: action)
    FlashLog.trace(
      "[input] normal dispatch reason=\(reason) action=\(action.diagnosticDescription)")
    let dispatchStartedAt = DispatchTime.now()
    noteNormalModeStep(action, repeatCount: repeatCount)
    performMappingCommand(action, repeatCount: repeatCount)
    FlashLog.trace(
      "[latency] normal_dispatch action=\(action.diagnosticDescription) sync_ms="
        + String(
          format: "%.2f",
          Double(DispatchTime.now().uptimeNanoseconds - dispatchStartedAt.uptimeNanoseconds)
            / 1_000_000))
    recaptureAfterNormalAction(action)
  }

  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {
    if prefix == "__BACKSPACE__" {
      if !hintSession.prefix.isEmpty {
        hintSession.prefix.removeLast()
        overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
        clickChainPrefixDidChange()
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

  func overlayDidUpdatePrefix(_ prefix: String) {
    if prefix == "__BACKSPACE__" {
      if hintSession.prefix.isEmpty, hintSession.retreatBigram() {
        retreatFromBigramLabels()
        return
      }
      if hintSession.prefix.isEmpty, hintSession.anchor == nil, overlayDidReturnToOrigin() {
        return
      }
      if !hintSession.prefix.isEmpty {
        hintSession.prefix.removeLast()
        overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
      }
    } else {
      hintSession.prefix = prefix
      overlay.filter(prefix: hintSession.prefix, hints: hintSession.hints)
    }
    clickChainPrefixDidChange()
  }

  func commit(hint: AssignedHint, clickModifiers held: ClickModifiers) {
    guard !activationLifecycle.inFlight else { return }
    // A pick: the chain's labels stay as they are until its click went out.
    supersedeClickChainRefresh()
    if hint.target.providerID == AppDelegate.statusBarProviderID {
      noteHintCommitted()
      commitStatusBarHint(hint)
      return
    }
    if Self.pickCommits(hintSession.command, anchored: hintSession.anchor?.hint != nil, grid: false)
    {
      noteHintCommitted()
    }
    if hint.target.providerID == AppDelegate.screensProviderID {
      commitScreenHint(hint)
      return
    }
    let preferredPoint = Self.hintCommitPoint(
      for: hint, fontSize: CGFloat(config.overlay.fontSize),
      selectingThrough: modeStore.mode.isHold)
    switch hintSession.command {
    case .adjust:
      guard case .labels = hintSession.phase else { return }
      hintSession.phase = .adjusting(hint: hint, point: preferredPoint)
      overlay.showSelectionMarker(at: preferredPoint, targetFrame: hint.target.frame)
    case .drag, .select:
      if let anchor = hintSession.anchor, let sourceHint = anchor.hint {
        resolveHintPoints([(sourceHint.target, anchor.point), (hint.target, preferredPoint)]) {
          owner, points in
          owner.performTwoPhaseGesture(from: points[0], to: points[1], clickModifiers: held)
        }
      } else {
        anchorTwoPhaseGesture(at: preferredPoint, hint: hint)
      }
    case .path:
      if let anchor = hintSession.anchor, let sourceHint = anchor.hint {
        performPathClicks(from: sourceHint, to: hint, clickModifiers: held)
      } else {
        anchorTwoPhaseGesture(at: preferredPoint, hint: hint)
      }
    case .move:
      resolveHintPoints([(hint.target, preferredPoint)]) { owner, points in
        owner.movePointerAndFinish(to: points[0])
      }
    case .copyURL:
      copyHintURLAndFinish(hint)
    case .copyText:
      copyHintTextAndFinish(hint)
    case .gesture(let gesture):
      resolveHintPoints([(hint.target, preferredPoint)]) { owner, points in
        owner.performTargetGestureAndFinish(gesture, at: points[0])
      }
    case .click, .multi, .search, .sticky:
      resolveHintPoints([(hint.target, preferredPoint)]) { owner, points in
        owner.performTargetClick(hint: hint, at: points[0], clickModifiers: held)
      }
    }
  }

  /// Phase 1 of a drag, selection or path: keep the first point, clear the
  /// typed prefix so the second label starts fresh, and mark the anchor so
  /// the second pick is made against something visible.
  private func anchorTwoPhaseGesture(at point: CGPoint, hint: AssignedHint) {
    hintSession.phase = .labels(anchor: .init(point: point, hint: hint))
    hintSession.prefix = ""
    overlay.filter(prefix: "", hints: hintSession.hints)
    overlay.showSelectionMarker(at: point, targetFrame: hint.target.frame)
  }

  /// `--path`: every target from the first pick to the second, in reading
  /// order, gets the session's click, one after the other on the click
  /// queue. Status-bar spans are not app targets and are skipped. Each point
  /// is validated off the main thread before anything is posted; one target
  /// that is gone cancels the whole path rather than clicking around it.
  private func performPathClicks(
    from first: AssignedHint, to second: AssignedHint, clickModifiers held: ClickModifiers
  ) {
    let hints = hintSession.hints
    guard let start = hints.firstIndex(where: { $0.label == first.label }),
      let end = hints.firstIndex(where: { $0.label == second.label })
    else {
      cancelOverlay()
      return
    }
    let fontSize = CGFloat(config.overlay.fontSize)
    let path = HintPath.indexes(from: start, to: end, count: hints.count)
      .map { hints[$0] }
      .filter { $0.target.providerID != AppDelegate.statusBarProviderID }
    guard !path.isEmpty else {
      cancelOverlay()
      return
    }
    let selections = path.map {
      (
        $0.target,
        Self.hintCommitPoint(for: $0, fontSize: fontSize, selectingThrough: modeStore.mode.isHold)
      )
    }
    resolveHintPoints(selections) { owner, points in
      owner.postPathClicks(hints: path, at: points, clickModifiers: held)
    }
  }

  private func postPathClicks(
    hints: [AssignedHint], at points: [CGPoint], clickModifiers held: ClickModifiers
  ) {
    guard hints.count == points.count, let last = points.last else {
      cancelOverlay()
      return
    }
    let wasNormalMode = flashMode == .normal
    let action = hintSession.command.action
    let requested = hintSession.command.modifiers.union(held)
    let pid = hints.first?.target.pid ?? hintSession.sourceAppPID
    let restore = ActionDispatcher.PointerRestore.afterCommit(
      restorePointer: config.hints.restorePointer, gridOrigin: nil)
    FlashLog.trace("[commit] kind=path targets=\(hints.count) action=\(action)")
    if let pid { recordMovement(.app(pid: pid), source: "hint_commit") }
    if wasNormalMode { applyModeOverlay(captureOverride: false) }
    overlay.hide()
    clearHintSessionState(preservingStatusBarSnapshot: true)
    let targetApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    let needsHandoff = Self.hintCommitNeedsFrontmostHandoff(
      targetPID: pid, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    if let targetApp, needsHandoff {
      RunningApplicationActivation.activate(
        targetApp, options: [], restoringMinimizedWindows: false)
    }
    let modifiers = hints.map {
      ActionDispatcher.hintClickModifiers(for: $0.target, requested: requested)
    }
    let recorded = LastCommittedClick(
      point: last, action: action, modifiers: modifiers.last ?? requested, pid: pid)
    performHintCommit(awaitingFrontmost: needsHandoff ? pid : nil, recording: recorded) {
      finished in
      // The click queue is serial, so the path lands in order; only the last
      // click restores the pointer and reports completion.
      for (index, point) in points.enumerated() {
        let isLast = index == points.count - 1
        _ = ActionDispatcher.synthesizeClick(
          at: ScreenPoint<NSSpace>(point), action: action, modifiers: modifiers[index],
          restoring: isLast ? restore : .stay, completion: isLast ? finished : nil)
      }
    } completion: { owner in
      guard wasNormalMode, owner.flashMode == .normal else { return }
      owner.restoreNormalModeAfterCommit(action: action, at: last)
    }
  }

  /// A status-bar hint acts on its span. `f` uses the centre of the visible
  /// text; `s` lands one point left of the glyph centre. Only the action
  /// differs (`statusBarHintCommit`). A followed link opens from the URL the
  /// hint carried, without moving the pointer into the menu-bar band.
  private func commitStatusBarHint(_ hint: AssignedHint) {
    let point = Self.statusBarHintPoint(
      hint.target.frame, bigram: hintSession.isBigramCapture,
      selectingThrough: modeStore.mode.isHold)
    let popup = hintSession.statusBarPopupSnapshots[hint.target.id]
    let commit = Self.statusBarHintCommit(
      command: hintSession.command, url: hint.target.url.flatMap { URLParsing.url($0) })
    overlay.hide()
    clearHintSessionState(preservingStatusBarSnapshot: true)
    activationLifecycle.invalidate()
    applyModeOverlay()
    switch commit {
    case .follow(let url):
      overlay.activateStatusBarLink(url)
    case .hover:
      _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(point))
      if let popup { overlay.showStatusBarPopup(popup, at: point, preservingContent: true) }
    case .pin:
      if let popup { overlay.activateStatusBarPopup(popup, at: point) }
    }
    overlay.releaseStatusBarHintSnapshot()
  }

  /// A resolved click on a discovered target. A chain (`--multi`,
  /// `--sticky`) keeps the session up for its next pick (`ClickChain`);
  /// every other session ends with this click.
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
    } else if hintSession.command.isSticky {
      followUp = .rearmSticky
    } else if Self.hintOpensMenuBarMenu(target) {
      followUp = .menuBarMenu
    } else if MissionControlSurface.kind(of: target) != nil {
      // The Dock's view has no input and no menu: NORMAL simply recaptures,
      // and keeps letting the Dock read its keys while the view stays open.
      followUp = .recapture
    } else {
      followUp = .finish
    }
    performPointerGesture(gesture, followUp: followUp)
  }

  /// Phase 2 of `--drag` / `--select`: both points are known, so the session
  /// ends and the gesture goes out as one continuous drag, or a click plus
  /// shift-click selection. NORMAL recaptures once the gesture has been
  /// posted, as after every click.
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
  /// `--copy-url` (Vimium's `yf`): the chosen target's URL goes on the
  /// clipboard. Nothing is clicked, the pointer stays and so does the mode.
  private func copyHintURLAndFinish(_ hint: AssignedHint) {
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.invalidate()
    if let url = hint.target.url, !url.isEmpty { NormalModeDispatcher.copy(url) }
    applyModeOverlay()
  }

  /// `--copy-text`: the chosen target's text, as hint search matches it,
  /// goes on the clipboard; nothing is clicked.
  private func copyHintTextAndFinish(_ hint: AssignedHint) {
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.invalidate()
    if let text = hint.target.accessibilityLabel?.trimmed, !text.isEmpty {
      NormalModeDispatcher.copy(text)
    }
    applyModeOverlay()
  }

  private func movePointerAndFinish(to point: CGPoint) {
    overlay.hide()
    clearHintSessionState()
    activationLifecycle.invalidate()
    _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(point))
    applyModeOverlay()
  }

  /// `--gesture`: the pointer lands on the point as with `--move`, then the
  /// trackpad gesture runs there. Look Up is the focused app's own action on
  /// the word under the pointer; smart zoom posts the two-finger double tap.
  /// Neither types into the app, so NORMAL recaptures as for a move.
  private func performTargetGestureAndFinish(_ gesture: TargetGesture, at point: CGPoint) {
    movePointerAndFinish(to: point)
    switch gesture {
    case .lookUp: performMappedCommand(.lookUp)
    case .smartZoom: TrackpadGesture.post(.smartMagnify, at: ScreenPoint<NSSpace>(point))
    }
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

  /// What the mode does once the gesture has been posted. None enters
  /// INSERT: a click keeps the mode, whatever it landed on.
  enum PointerCommitFollowUp {
    /// The session is over: NORMAL recaptures, unless the click opened a
    /// menu, which keeps the keyboard.
    case finish
    /// A menu-bar title's or status item's menu now owns the keyboard.
    case menuBarMenu
    /// `--multi` on targets: discover again for the next selection.
    case rearmHints
    /// `--sticky` on targets: the same labels stay up for the next selection.
    case rearmSticky
    /// `--multi` on the grid: restart it at its full extent.
    case rearmGrid(MouseGrid.Navigation?)
    /// Drags and selections: recapture NORMAL.
    case recapture
  }

  /// The single delivery path for every committed gesture — hint, grid cell,
  /// adjusted point, drag, selection: raise the owning app, tear the session
  /// down (or keep it for `--multi`), post the events off-main, then hand the
  /// mode back.
  private func performPointerGesture(_ gesture: PointerGesture, followUp: PointerCommitFollowUp) {
    let wasNormalMode = flashMode == .normal
    // Read before the session is torn down below: cursor-follow's origin lives
    // on the grid navigation.
    let restore = ActionDispatcher.PointerRestore.afterCommit(
      restorePointer: config.hints.restorePointer,
      gridOrigin: hintSession.grid?.pointerOrigin.map { ScreenPoint<NSSpace>($0) })
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
    case .finish, .menuBarMenu, .recapture:
      overlay.hide()
      clearHintSessionState(preservingStatusBarSnapshot: true)
    case .rearmHints, .rearmSticky:
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
      let point = ScreenPoint<NSSpace>(gesture.point)
      switch gesture.kind {
      case .click(let action):
        ActionDispatcher.synthesizeClick(
          at: point, action: action, modifiers: gesture.modifiers, restoring: restore,
          completion: finished)
      case .drag(let source):
        ActionDispatcher.synthesizeDrag(
          from: ScreenPoint<NSSpace>(source), to: point, modifiers: gesture.modifiers,
          restoring: restore, completion: finished)
      case .select(let source):
        ActionDispatcher.synthesizeSelection(
          from: ScreenPoint<NSSpace>(source), to: point, modifiers: gesture.modifiers,
          restoring: restore, completion: finished)
      }
    } completion: { owner in
      owner.finishPointerGesture(gesture, followUp: followUp, wasNormalMode: wasNormalMode)
    }
  }

  func finishPointerGesture(
    _ gesture: PointerGesture, followUp: PointerCommitFollowUp, wasNormalMode: Bool
  ) {
    let action = gesture.action ?? .leftClick
    switch followUp {
    case .finish:
      guard wasNormalMode, flashMode == .normal else { return }
      restoreNormalModeAfterCommit(action: action, at: gesture.point)
      // A primary click on a text input engages it once the focus settles
      // there; the mouse grid's has no target, so it counts as a click.
      if case .click = gesture.kind, action.isPrimaryClick, modeStore.mode == .normal {
        if gesture.target?.isTextInput == true {
          awaitTextFocus(in: gesture.pid, reason: .hint)
        } else if gesture.target == nil {
          awaitTextFocus(in: gesture.pid, reason: .click)
        }
      }
    case .menuBarMenu:
      guard wasNormalMode, flashMode == .normal else { return }
      suspendNormalCaptureForNativeSurface(reason: "menu_bar_menu")
    case .recapture:
      guard wasNormalMode, flashMode == .normal else { return }
      scheduleNormalModeRecapture()
    case .rearmHints, .rearmSticky:
      let sticky: Bool
      if case .rearmSticky = followUp { sticky = true } else { sticky = false }
      switch ClickChain.step(after: chainClick(gesture), sticky: sticky) {
      case .rediscover:
        guard !hintSession.hints.isEmpty else { return }
        rediscoverMultiTargets()
      case .relabel:
        guard !hintSession.hints.isEmpty else { return }
        // Re-present the same set so the panel re-keys after the app
        // activation above; no walk, the labels are the point of the session.
        overlay.display(hints: hintSession.hints)
        applyModeOverlay()
      case let step:
        endChain(step)
      }
    case .rearmGrid(let fresh):
      switch ClickChain.step(after: chainClick(gesture), sticky: false) {
      case .rediscover, .relabel:
        if let fresh {
          displayMouseGrid(fresh)
        } else {
          cancelOverlay()
        }
      case let step:
        endChain(step)
      }
    }
  }

  /// One click of a chain, as `ClickChain.step` reads it.
  private func chainClick(_ gesture: PointerGesture) -> ClickChain.Click {
    let action = gesture.action ?? .leftClick
    // Mission Control hides the menu bar: its Spaces bar is no menu.
    let inMenuBar =
      gesture.target.flatMap(MissionControlSurface.kind(of:)) == nil
      && pointOpensNativeMenuBar(gesture.point)
    return ClickChain.Click(
      action: action, modifiers: gesture.modifiers, inMenuBar: inMenuBar,
      leavesSurface: MissionControlSurface.clickLeavesView(gesture.target))
  }

  /// A chain's click ended it: the labels go, and the keyboard goes where a
  /// single click would send it — the menu a secondary click opened, else
  /// back to NORMAL.
  private func endChain(_ step: ClickChain.Step) {
    FlashLog.debug("[multi] chain_ended step=\(step)")
    overlay.hide()
    clearHintSessionState()
    guard flashMode == .normal else {
      applyModeOverlay()
      return
    }
    switch step {
    case .nativeMenu:
      suspendNormalCaptureForNativeSurface(reason: "chain_menu")
    case .end, .rediscover, .relabel:
      applyModeOverlay()
      scheduleNormalModeRecapture()
    }
  }

  /// `--multi`: the click may have changed the app, so its targets are
  /// discovered again rather than the old set shown once more. The walk is
  /// fresh — the click is a user action that invalidates the prepared model —
  /// and targets that persist keep their labels. The old set stays drawn until
  /// the new one replaces it; a commit waits for the walk like any other
  /// activation, and Escape cancels it. An app left with no targets ends the
  /// session silently.
  func rediscoverMultiTargets() {
    // A fresh walk supersedes a refresh still waiting or walking.
    supersedeClickChainRefresh()
    if hintSession.missionControl != nil {
      rediscoverMissionControlTargets()
      return
    }
    guard let pid = hintSession.sourceAppPID, let context = monitor.context(for: pid) else {
      cancelOverlay()
      return
    }
    let previous = hintSession.hints
    // Re-present the current set so the panel re-keys: in non-advanced mode
    // capture rides on panel key status, and the app activation above may
    // have taken it.
    overlay.display(hints: previous)
    monitor.invalidateAfterUserAction(pid: pid, reason: "multi_click")
    let token = activationLifecycle.begin()
    applyModeOverlay()
    // A repair still waiting on the app stops once this activation is gone.
    let isCurrent: () -> Bool = { [weak self] in
      self?.activationLifecycle.isCurrent(token) ?? false
    }
    monitor.discoverAsync(context: context, isCurrent: isCurrent) { [weak self] hints, _ in
      guard let self, self.activationLifecycle.complete(token: token) else { return }
      guard !hints.isEmpty else {
        FlashLog.debug("[multi] no_targets pid=\(pid)")
        self.cancelOverlay()
        return
      }
      let relabelled = self.assignHints(
        hints.map(\.target), preserving: previous, region: context.frontWindowFrame)
      self.hintSession.hints = relabelled
      self.hintSession.prefix = ""
      self.overlay.display(hints: relabelled)
      FlashLog.debug("[multi] rediscovered pid=\(pid) hints=\(relabelled.count)")
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
    if action == .rightClick || pointOpensNativeMenuBar(point) {
      suspendNormalCaptureForNativeSurface(reason: "command_native_menu")
      return
    }
    scheduleNormalModeRecapture()
  }

  /// A click at `point` lands in the native menu bar's band, not on Flash's
  /// own bar drawn over it: the menu it opens takes the keyboard.
  func pointOpensNativeMenuBar(_ point: CGPoint) -> Bool {
    let hitsFlashStatusBar = overlay.statusBarClickWindows.contains {
      $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point)
    }
    return Self.pointIsInMenuBar(point) && !hitsFlashStatusBar
  }

  func suspendNormalCaptureForNativeSurface(reason: String) {
    noteContextMenuInteraction(reason: reason)
    // Record the native surface as mode context and let the single
    // projection-driven writer set inputMode + capture — no direct `overlay.*`
    // pokes, so the badge and routing can't drift from the mode. Ended by the
    // surface closing, a mode transition, or another app coming forward.
    nativeSurfaceOwnership.begin()
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

  /// Deliver a physical click again; `posted` runs on main once it is.
  private func forwardPhysicalPointerClick(
    _ click: OverlayPointerClick, targetPID: pid_t?, posted: @escaping () -> Void
  ) {
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
        at: ScreenPoint<NSSpace>(click.location),
        action: click.action,
        modifiers: click.modifiers,
        completion: posted)
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
    guard decision == .keepNormal, let click else { return false }
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

  // MARK: Mouse grid

  /// One keystroke of the mouse grid, forwarded by the panel while the
  /// session routes keys to the grid. Every step is a pure `Navigation`
  /// transition, redrawn by `displayMouseGrid`.
  func overlayDidGrid(_ command: MouseGridKeyCommand) {
    guard hintSession.surface == .grid, var navigation = hintSession.grid else {
      cancelOverlay()
      return
    }
    if case .cancel = command {
      let origin = navigation.pointerOrigin
      cancelOverlay()
      // Cursor-follow moved the pointer; a cancelled grid puts it back.
      if let origin { _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(origin)) }
      return
    }
    // A click is being resolved or posted: later keys wait for its outcome.
    guard !activationLifecycle.inFlight else { return }
    let shape = hintSession.gridShape
    let steps = config.hints.mouseGridSteps
    let current = navigation.current
    let commits = MouseGrid.selectionCommits(
      region: current.region, depth: current.depth, steps: steps, shape: shape)
    switch command {
    case .cancel:
      break  // handled above
    case .cell(let key, let held):
      guard let index = hintSession.gridCellIndex[key], hintSession.hints.indices.contains(index)
      else {
        cancelOverlay()
        return
      }
      let cell = hintSession.hints[index].target.frame
      if commits {
        commitMouseGrid(at: CGPoint(x: cell.midX, y: cell.midY), clickModifiers: held)
      } else {
        navigation.drill(into: cell)
        displayMouseGrid(navigation)
      }
    case .half(let direction, let held):
      let kept = MouseGrid.half(of: current.region, direction)
      if MouseGrid.keepCommits(kept) {
        commitMouseGrid(at: CGPoint(x: kept.midX, y: kept.midY), clickModifiers: held)
      } else {
        navigation.drill(into: kept)
        displayMouseGrid(navigation)
      }
    case .centre(let held):
      if commits {
        commitMouseGrid(
          at: CGPoint(x: current.region.midX, y: current.region.midY), clickModifiers: held)
      } else {
        navigation.centre(shape: shape)
        displayMouseGrid(navigation)
      }
    case .commitHere(let held):
      commitMouseGrid(
        at: CGPoint(x: current.region.midX, y: current.region.midY), clickModifiers: held)
    case .back:
      if hintSession.gridBack(), let restored = hintSession.grid {
        displayMouseGrid(restored)
      } else {
        overlayDidReturnToOrigin()
      }
    case .snap(let direction):
      // The pointer lands on that edge of the region, a hair inside it, so a
      // drag or a hold can start from a grid line. A cancel puts it back.
      if navigation.pointerOrigin == nil {
        navigation.pointerOrigin = NSEvent.mouseLocation
        hintSession.grid = navigation
      }
      _ = ActionDispatcher.moveCursor(
        to: ScreenPoint<NSSpace>(MouseGrid.edgePoint(of: current.region, direction)))
    case .reset:
      navigation.reset()
      displayMouseGrid(navigation)
    case .move(let direction):
      if navigation.move(direction) { displayMouseGrid(navigation) }
    case .screen(let delta):
      let roots = WindowMover.screenLayouts(
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: config.statusBar.monitor
      ).map { MouseGrid.gridRoot(of: $0, includeStatusBar: statusBarVisible) }
      if navigation.switchScreen(delta, roots: roots) { displayMouseGrid(navigation) }
    case .toggleFollow:
      hintSession.gridCursorFollows.toggle()
      followMouseGridIfNeeded()
    }
  }

  /// Draw the grid step `navigation` is on and make it the session's.
  func displayMouseGrid(_ navigation: MouseGrid.Navigation) {
    let fontSize = CGFloat(config.overlay.fontSize)
    // The cluster step lays chips out itself, so it needs the exact rendered
    // chip size; the geometry then cannot disagree with what the user sees.
    let chipSize = CGSize(
      width: OverlayPanel.chipWidth(forLabelLength: 1, fontSize: fontSize),
      height: OverlayPanel.chipHeight(forFontSize: fontSize))
    let hints = MouseGrid.hints(
      region: navigation.current.region,
      depth: navigation.current.depth,
      shape: hintSession.gridShape,
      steps: config.hints.mouseGridSteps,
      chipSize: chipSize,
      previewChipSize: config.hints.mouseGridPreview
        ? CGSize(
          width: OverlayPanel.chipWidth(forLabelLength: 2, fontSize: fontSize),
          height: chipSize.height)
        : nil)
    guard !hints.isEmpty else {
      applyModeOverlay()
      return
    }
    activationLifecycle.invalidate()
    var session = hintSession
    session.grid = navigation
    session.hints = hints
    session.gridCellIndex.removeAll(keepingCapacity: true)
    // Only the step's own cells answer a key; the preview is drawn, not typed.
    for (index, hint) in hints.enumerated()
    where hint.target.role != MouseGrid.previewCellRole {
      if let key = hint.label.first { session.gridCellIndex[key] = index }
    }
    session.prefix = ""
    hintSession = session
    // Single projection-driven writer (yields `.hints` with the grid hints up),
    // not a direct `overlay.inputMode` poke.
    applyModeOverlay()
    presentHints(
      hints, prepared: .none, outcome: .none,
      bundleIdentifier: hintSession.sourceAppPID.flatMap {
        NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
      },
      surface: "grid")
    followMouseGridIfNeeded()
  }

  /// Cursor-follow: put the pointer on the region's centre, remembering where
  /// it was the first time so a cancel can restore it.
  private func followMouseGridIfNeeded() {
    guard hintSession.gridCursorFollows, var navigation = hintSession.grid else { return }
    if navigation.pointerOrigin == nil {
      navigation.pointerOrigin = NSEvent.mouseLocation
      hintSession.grid = navigation
    }
    let region = navigation.current.region
    _ = ActionDispatcher.moveCursor(to: ScreenPoint<NSSpace>(x: region.midX, y: region.midY))
  }

  /// Whether picking a target commits the session (`core:hints.committed`)
  /// rather than starting it: not the first point of a drag or selection,
  /// nor of a path on labels, nor the pick an `--adjust` session refines
  /// before its commit key; nor a copy on the grid, which has nothing to
  /// copy. On the grid `--path` and `--adjust` click.
  static func pickCommits(_ command: MouseCommand, anchored: Bool, grid: Bool) -> Bool {
    switch command {
    case .drag, .select: return anchored
    case .path: return grid || anchored
    case .adjust: return grid
    case .copyURL, .copyText: return !grid
    case .click, .move, .gesture, .multi, .search, .sticky: return true
    }
  }

  /// The grid chose `point`: act on it with the session's command.
  private func commitMouseGrid(at point: CGPoint, clickModifiers held: ClickModifiers) {
    if Self.pickCommits(hintSession.command, anchored: hintSession.anchor != nil, grid: true) {
      noteHintCommitted()
    }
    switch hintSession.command {
    case .drag, .select:
      if let anchor = hintSession.anchor {
        performTwoPhaseGesture(from: anchor.point, to: point, clickModifiers: held)
      } else if hintSession.grid != nil {
        // Phase 1: keep the anchor and restart the grid from its full extent
        // so the second point can land anywhere, not only inside the
        // drilled-down source cell. Backspace can still return to it.
        hintSession.anchorGrid(at: point)
        if let restarted = hintSession.grid { displayMouseGrid(restarted) }
        FlashLog.trace(
          "[commit] grid_two_phase_anchor=(\(Int(point.x)),\(Int(point.y))) "
            + "command=\(hintSession.command) awaiting_second_point")
      } else {
        cancelOverlay()
      }
    case .move:
      movePointerAndFinish(to: point)
    case .copyURL, .copyText:
      // The grid has no targets, so nothing to copy; its parser never makes one.
      cancelOverlay()
    case .gesture(let gesture):
      performTargetGestureAndFinish(gesture, at: point)
    case .click, .multi, .adjust, .search, .path, .sticky:
      let command = hintSession.command
      // `--multi` restarts on the same display; its clicks moved the pointer,
      // so there is no origin left to restore.
      let fresh = hintSession.grid.map {
        MouseGrid.Navigation(root: $0.root, screenIndex: $0.screenIndex)
      }
      performPointerGesture(
        PointerGesture(
          kind: .click(command.action), point: point,
          modifiers: command.modifiers.union(held), target: nil, pid: hintSession.sourceAppPID),
        followUp: command.isMulti ? .rearmGrid(fresh) : .finish)
    }
  }

  /// One keystroke of the `--search` sub-state (seek & click), forwarded by
  /// the panel while the session is in its search phase: printable characters
  /// filter the target set by visible text, Tab cycles the selection, Return
  /// commits it through the standard click path.
  func overlayDidSearch(_ command: HintSearchCommand, clickModifiers: ClickModifiers) {
    guard var search = hintSession.search else {
      cancelOverlay()
      return
    }
    switch command {
    case .cancel:
      cancelOverlay()
    case .append(let char):
      search.query.append(char)
      refreshSearchMatches(search)
    case .backspace:
      guard !search.query.isEmpty else { return }
      search.query.removeLast()
      refreshSearchMatches(search)
    case .cycle:
      guard !hintSession.hints.isEmpty else { return }
      search.selectionIndex = (search.selectionIndex + 1) % hintSession.hints.count
      hintSession.phase = .search(search)
      updateSearchSelectionMarker()
    case .commit:
      guard !hintSession.hints.isEmpty else { return }
      let index = min(search.selectionIndex, hintSession.hints.count - 1)
      let selected = hintSession.hints[index]
      hintSession.phase = .labels(anchor: nil)
      overlay.hideSelectionMarker()
      commit(hint: selected, clickModifiers: clickModifiers)
    }
  }

  private func refreshSearchMatches(_ search: HintSession.Search) {
    var search = search
    let matches = HintSearchInterpreter.filter(search.allHints, query: search.query)
    search.selectionIndex = 0
    hintSession.phase = .search(search)
    hintSession.hints = matches
    overlay.display(hints: matches)
    updateSearchSelectionMarker()
    FlashLog.trace("[search] query_len=\(search.query.count) matches=\(matches.count)")
  }

  func updateSearchSelectionMarker() {
    guard let search = hintSession.search, !hintSession.hints.isEmpty else {
      overlay.hideSelectionMarker()
      return
    }
    let index = min(search.selectionIndex, hintSession.hints.count - 1)
    let frame = hintSession.hints[index].target.frame
    overlay.showSelectionMarker(
      at: CGPoint(x: frame.midX, y: frame.midY), targetFrame: frame)
  }

  /// One keystroke of the `--adjust` sub-state, forwarded by the panel while
  /// the session is adjusting: move/snap keys update the marker; the commit
  /// key fires the pending action at the refined point.
  func overlayDidAdjust(_ command: HintAdjustmentCommand, clickModifiers: ClickModifiers) {
    guard case .adjusting(let hint, let point) = hintSession.phase else {
      cancelOverlay()
      return
    }
    switch command {
    case .cancel:
      cancelOverlay()
    case .commit:
      noteHintCommitted()
      resolveHintPoints([(hint.target, point)]) { owner, points in
        owner.performTargetClick(hint: hint, at: points[0], clickModifiers: clickModifiers)
      }
    case .snapLeft, .snapRight, .snapTop, .snapBottom, .interpolate, .reset:
      let updated = HintAdjustmentInterpreter.apply(
        command, to: point, in: hint.target.frame, digits: config.hints.adjustDigits)
      hintSession.phase = .adjusting(hint: hint, point: updated)
      overlay.showSelectionMarker(at: updated, targetFrame: hint.target.frame)
    }
  }

  /// Replay the last Flash-committed click (`mouse repeat`). Re-raises the
  /// owning app first so the click is interpreted, then posts `repeatCount`
  /// identical clicks. Stays in the current mode, as every click does.
  func performMouseRepeat(repeatCount: Int = 1) {
    guard let last = lastCommittedClick else {
      FlashLog.debug("[repeat] no_previous_click")
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
      "[repeat] point=(\(Int(last.point.x)),\(Int(last.point.y))) "
        + "action=\(last.action) count=\(max(1, repeatCount))")
    // The click queue is serial, so posting the repeats back-to-back keeps
    // them ordered; only the final one carries the recapture completion and
    // restores the pointer, to where it was before the first repeat.
    let count = max(1, repeatCount)
    let restore = ActionDispatcher.PointerRestore.afterCommit(
      restorePointer: config.hints.restorePointer, gridOrigin: nil)
    let origin = NSEvent.mouseLocation
    performHintCommit(awaitingFrontmost: needsHandoff ? last.pid : nil, feedbackAt: last.point) {
      finished in
      for index in 1...count {
        let isLast = index == count
        _ = ActionDispatcher.synthesizeClick(
          at: ScreenPoint<NSSpace>(last.point),
          action: last.action,
          modifiers: last.modifiers,
          restoring: isLast && restore != .stay ? .point(ScreenPoint<NSSpace>(origin)) : .stay,
          completion: isLast ? finished : nil)
      }
    } completion: { owner in
      if wasNormalMode, owner.flashMode == .normal {
        owner.scheduleNormalModeRecapture()
      }
    }
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
    releaseHeldMouseButton(reason: "command_cancel")
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
    yieldActivation(to: app, reason: reason)
  }

  /// The one request that moves activation from Flash to `app` on this
  /// macOS: yield, then activate it from Flash
  /// (`RunningApplicationActivation.handOff`).
  func yieldActivation(to app: NSRunningApplication, reason: String) {
    let accepted = RunningApplicationActivation.handOff(to: app, yielding: true)
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
    commandLineHistory.endRecall()
    refreshCommandLine(text: command, cursorIndex: cursorIndex)
  }

  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    // History recall claims up/down (and ctrl+p/n) on an empty prompt or once a
    // recall is under way; otherwise the flashlight candidate list or the
    // command-completion list keeps the arrows. See `commandLineMoveTarget`.
    let target = NormalModeDispatcher.commandLineMoveTarget(
      bodyIsEmpty: NormalModeDispatcher.commandLineBodyIsEmpty(overlay.commandLineText),
      isRecalling: commandLineHistory.isRecalling,
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
      if commandLineCompletionSelection.entersHistory(movingBy: delta) {
        return recallCommandLineHistory(delta: delta)
      }
      // From no highlighted row, the first move lands on the first row.
      commandLineCompletionSelection = commandLineCompletionSelection.moved(
        by: delta, count: commandLineCompletionMatches.count)
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
    guard let text = commandLineHistory.step(delta, buffer: overlay.commandLineText) else {
      return false
    }
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
  /// insert `@type `. The `<cr>` path is insert-first unless a
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
    Trace.ensure(.commandLine) { submitCommandLine(command) }
  }

  func overlayDidSubmitCommandLine(_ command: String, variant: CommandLineSubmitVariant) {
    Trace.ensure(.commandLine) { submitCommandLine(command, variant: variant) }
  }

  func overlayDidTogglePinOfCommandLineSelection() -> Bool {
    togglePinOfSelectedClipboardRow()
  }

  /// `ctrl+r {x}` on the command line: Vim's `":` is the last command line,
  /// every other name a register (`RegisterStore`), the clipboard included.
  func overlayRegisterText(_ name: Character) -> String? {
    Self.commandLineRegisterText(
      name, registers: registers, lastCommandLine: macros.lastCommandLine)
  }

  static func commandLineRegisterText(
    _ name: Character, registers: RegisterStore, lastCommandLine: String?
  ) -> String? {
    if name == ":" {
      return lastCommandLine.map { $0.hasPrefix(":") ? String($0.dropFirst()) : $0 }
    }
    guard NormalModeInterpreter.isRegisterNameChar(name), name != "_" else { return nil }
    return registers.read(register: String(name))
  }

  func openSourceItem(matching target: String) {
    sourceItemResolutionGeneration &+= 1
    let generation = sourceItemResolutionGeneration
    registry.resolveCandidate(
      matching: target, precedence: buildCandidateFinderPrecedenceTable()
    ) { [weak self] item in
      guard let self, generation == self.sourceItemResolutionGeneration else { return }
      guard let item else {
        FlashLog.warn("[app] open_no_source_item")
        return
      }
      self.openSourceItem(item)
    }
  }

  /// `variant` is the modified Return that chose the row, which only a
  /// clipboard row reads (``ClipboardRowDelivery``).
  func openSourceItem(
    _ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true,
    insertionTargetPID: pid_t? = nil, movementGeneration: UInt64? = nil,
    variant: CommandLineSubmitVariant? = nil
  ) {
    if candidate.sourceID == ClipboardFlashlight.sourceID {
      // A copy is no place: no movement history, no frecency.
      deliverClipboardRow(
        candidate, ClipboardRowDelivery(variant), targetPID: insertionTargetPID)
      return
    }
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
      if let url = URLParsing.url(raw), url.scheme != nil {
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
        FlashLog.warn("[flashlight] open effect: no app for bundle id \(bundleID)")
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
          "[flashlight] unresolved candidate source=\(candidate.sourceID) kind=\(candidate.kind)"
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

extension AppDelegate: OverlaySurfaceSwitching {
  func overlayDidSwitchSurface(_ kind: HintSurfaceSwitch) {
    guard !activationLifecycle.inFlight, let current = hintSession.request,
      let next = HintSurfaceSwitching.request(from: current, kind: kind)
    else { return }
    FlashLog.trace("[overlay] switch_surface kind=\(kind)")
    activateSwitchedSurface(next, origin: hintSession.origin ?? current)
  }

  @discardableResult
  func overlayDidReturnToOrigin() -> Bool {
    guard !activationLifecycle.inFlight, let origin = hintSession.origin else { return false }
    FlashLog.trace("[overlay] return_to_origin")
    performHintActivation(origin)
    return true
  }
}

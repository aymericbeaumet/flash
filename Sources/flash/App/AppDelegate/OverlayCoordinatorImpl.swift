import AppKit
import FlashCore
import FlashProviders

/// `OverlayCoordinator` protocol conformance: the callback surface the
/// `OverlayPanel` uses to report user input + state transitions back to
/// AppDelegate.
extension AppDelegate {
  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {
    if case .scroll = intent,
      Self.pointerScrollShouldBeSuppressed(
        mode: flashMode,
        hasHints: !currentHints.isEmpty,
        suppressionUntil: normalModeScrollSuppressionUntil)
    {
      FlashLog.trace("[mode] suppress_pointer_scroll reason=explicit_normal_momentum")
      applyModeOverlay()
      scheduleNormalModeRecapture()
      return
    }
    // Menu-bar clicks need to land on the menu service. Both `cancelOverlay`
    // and `enterInsertMode` `orderOut` / re-apply the overlay panel, and
    // that re-order trips the menu's modal tracking session before the
    // menu has even rendered — so the first click "fails" (menu opens
    // and immediately closes) and the user has to click again. Bail
    // before any of that: dismiss only transient hints, keep the mode
    // as-is, and let macOS deliver the click to SystemUIServer.
    if case .click(let click) = intent,
      Self.pointIsInMenuBar(click.location),
      !activationInFlight
    {
      FlashLog.trace("[mode] pointer_in_menu_bar mode=\(flashMode) keep_mode=true")
      if !currentHints.isEmpty {
        overlay.hide()
        currentHints = []
        currentPrefix = ""
        invalidateActivation(reason: "menu_bar_click")
      }
      normalModeScrollSuppressionUntil = nil
      return
    }
    let replayClick: OverlayPointerClick?
    if case .click(let click) = intent,
      flashMode == .normal,
      currentHints.isEmpty
    {
      replayClick = click
    } else {
      replayClick = nil
    }
    normalModeScrollSuppressionUntil = nil
    cancelOverlay()
    if flashMode != .insert {
      enterInsertMode(reason: .pointerClick)
    }
    if let replayClick {
      beginNormalModeDrag(initial: replayClick)
    }
  }

  /// Replay the user's in-progress mouse gesture so the underlying app
  /// sees either a single click (release with no movement) or a real
  /// drag (press → drag → release). The mouseDown is deferred until we
  /// detect actual movement, so a quick press-release degrades cleanly
  /// to the prior `synthesizeClick` behavior.
  ///
  /// We stamp synthetic events via `eventSourceUserData` and ignore the
  /// tag in our own monitor — otherwise the dragged events we post would
  /// re-trigger the monitor and feed themselves back in a tight loop.
  private func beginNormalModeDrag(initial: OverlayPointerClick) {
    stopNormalModeDrag()
    normalModeDragAction = initial.action
    normalModeDragModifiers = initial.modifiers
    let initialLocation = initial.location
    let initialAction = initial.action
    let initialModifiers = initial.modifiers
    let isDoubleClick = initialAction == .doubleClick
    var dragStarted = false
    let dragThreshold: CGFloat = 4

    if isDoubleClick {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
        _ = ActionDispatcher.synthesizeClick(
          at: initialLocation,
          action: initialAction,
          modifiers: initialModifiers)
      }
      return
    }

    let mask: NSEvent.EventTypeMask = [
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    let handle: (NSEvent) -> Void = { [weak self] event in
      guard let self else { return }
      if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
        == ActionDispatcher.syntheticMouseEventTag
      {
        return
      }
      let point = NSEvent.mouseLocation
      switch event.type {
      case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        let dx = point.x - initialLocation.x
        let dy = point.y - initialLocation.y
        if !dragStarted, (dx * dx + dy * dy) < dragThreshold * dragThreshold {
          return
        }
        if !dragStarted {
          dragStarted = true
          _ = ActionDispatcher.synthesizeMouseButton(
            at: initialLocation,
            phase: .down,
            action: initialAction,
            modifiers: initialModifiers)
        }
        _ = ActionDispatcher.synthesizeMouseButton(
          at: point,
          phase: .dragged,
          action: initialAction,
          modifiers: initialModifiers)
      case .leftMouseUp, .rightMouseUp, .otherMouseUp:
        if dragStarted {
          _ = ActionDispatcher.synthesizeMouseButton(
            at: point,
            phase: .up,
            action: initialAction,
            modifiers: initialModifiers)
        } else {
          _ = ActionDispatcher.synthesizeClick(
            at: initialLocation,
            action: initialAction,
            modifiers: initialModifiers)
        }
        self.stopNormalModeDrag()
      default:
        break
      }
    }

    normalModeDragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
      handle(event)
    }
    normalModeDragLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
      handle(event)
      return event
    }
  }

  private func stopNormalModeDrag() {
    if let m = normalModeDragGlobalMonitor { NSEvent.removeMonitor(m) }
    if let m = normalModeDragLocalMonitor { NSEvent.removeMonitor(m) }
    normalModeDragGlobalMonitor = nil
    normalModeDragLocalMonitor = nil
  }

  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int) {
    guard flashMode == .normal else { return }
    normalModePendingCommandToken &+= 1
    guard let action else {
      schedulePendingNormalModeCommandIfNeeded()
      return
    }
    performMappingCommand(action, repeatCount: repeatCount)
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
      self.normalModePendingCommandToken &+= 1
      self.performMappingCommand(pending.action, repeatCount: pending.repeatCount)
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
    if pendingHintCommitBehavior == .mouseGridClick || pendingHintCommitBehavior == .mouseGridMove {
      commitMouseGridCell(hint: hint, clickModifiers: clickModifiers)
      return
    }
    if pendingHintCommitBehavior == .copyURL {
      if let url = hint.target.url {
        NormalModeDispatcher.copy(url)
      }
      overlay.hide()
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
      mouseGridRegion = nil
      mouseGridDepth = 0
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      applyModeOverlay()
      return
    }
    if pendingHintCommitBehavior == .moveMouse {
      let targetFrame = hint.target.frame
      let point = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
      _ = ActionDispatcher.moveCursor(to: point)
      overlay.hide()
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
      mouseGridRegion = nil
      mouseGridDepth = 0
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      applyModeOverlay()
      return
    }

    // Shift-modified hint commits open a preview modal instead of
    // activating, for targets whose label carries useful context that
    // got truncated to a single hint character. Tmux link chips fall
    // in that bucket: the chip renders as one cell ("h" of "https://…")
    // but the full URL is the AX label. The shift toggle is a quick way
    // to read a URL before deciding to follow it.
    if clickModifiers.contains(.shift),
      let role = hint.target.role,
      role.hasPrefix("tmux-"),
      let label = hint.target.accessibilityLabel,
      !label.isEmpty
    {
      overlay.displayModal(label)
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
      mouseGridRegion = nil
      mouseGridDepth = 0
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      return
    }

    let action = pendingAction
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.mouseTargetCommitShouldEnterInsertMode(action: action)
    let shouldRestoreNormalMode = flashMode == .normal && !shouldEnterInsertAfterCommit
    // The target carries its owning pid (always the focused app at
    // walk time). Fall back to the activation-time focused pid if the
    // provider didn't set one.
    let pid = hint.target.pid ?? sourceAppPID
    if let pid {
      recordMovement(.app(pid: pid), source: "hint_commit")
    }
    // Click the middle of the underlying target. For small targets
    // (most AX buttons / links / inputs) `chipFrame` already centres
    // the chip on the target, so target-centre and chip-centre
    // coincide. For wide targets (long tmux words, big AX buttons,
    // table rows) the chip anchors to the target's top-left for
    // visibility — but the *click* should still land in the middle of
    // the underlying element. Clicking near the left edge of a word
    // ("f" of "filename") instead of its middle felt wrong, and AX's
    // own AXPress fallback already uses the target's geometric centre
    // for the same reason, so this keeps the two paths consistent.
    let targetFrame = hint.target.frame
    let clickPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

    if shouldRestoreNormalMode {
      applyModeOverlay(captureOverride: false)
    }
    overlay.hide()
    // Restore focus to the target app before dispatching, so AXPress / the
    // synthesized click both reach the intended window.
    if let pid, let app = NSRunningApplication(processIdentifier: pid) {
      RunningApplicationActivation.activate(app, options: [])
    }
    // Hold the activation gate closed across the click dispatch. Without
    // this, the 20-ms delay below opens a window where a fresh
    // ctrl+space can land and start a second walk, and *this* commit's
    // click would then fire during the new activation (clicking
    // whatever the user was about to hint, not what they committed to).
    activationInFlight = true
    activationGen &+= 1
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    mouseGridRegion = nil
    mouseGridDepth = 0
    pendingHintCommitBehavior = .click
    if shouldEnterInsertAfterCommit {
      enterInsertMode(reason: .hintCommit)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      _ = ActionDispatcher.perform(
        action, on: hint.target, pid: pid, clickPoint: clickPoint, modifiers: clickModifiers)
      guard let self else { return }
      self.activationInFlight = false
      if shouldRestoreNormalMode {
        self.scheduleNormalModeRecapture()
      }
    }
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
    let shouldMove = pendingHintCommitBehavior == .mouseGridMove
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.mouseGridCommitShouldEnterInsertMode(isMove: shouldMove)
    overlay.hide()
    currentHints = []
    currentPrefix = ""
    mouseGridRegion = nil
    mouseGridDepth = 0
    activationGen &+= 1
    sourceAppPID = nil
    pendingHintCommitBehavior = .click
    if shouldMove {
      _ = ActionDispatcher.moveCursor(to: point)
    } else {
      _ = ActionDispatcher.synthesizeClick(
        at: point,
        action: pendingAction,
        modifiers: clickModifiers)
    }
    if shouldEnterInsertAfterCommit {
      enterInsertMode(reason: .hintCommit)
    } else {
      applyModeOverlay()
    }
  }

  static func mouseTargetCommitShouldEnterInsertMode(action: JumpAction = .leftClick) -> Bool {
    switch action {
    case .leftClick, .rightClick, .doubleClick:
      return true
    }
  }

  static func mouseGridCommitShouldEnterInsertMode(isMove: Bool) -> Bool {
    !isMove
  }

  func usesTmuxProvider(_ context: AppContext?) -> Bool {
    guard let context else { return false }
    return registry.chain(for: context).contains { $0.identifier == "plugin.tmux" }
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  func overlayDidCancelModal() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.hide()
    applyModeOverlay()
  }

  /// Modal mode is hermetic: keys are swallowed, never forwarded to the
  /// focused app. Dismissal flows through `cancelOperation` (Esc / Ctrl-C)
  /// or click-outside via the modal dismiss monitors, never via an
  /// arbitrary keystroke leaking into the underlying window. Only Insert
  /// mode forwards input to the focused app.
  func overlayDidPassThroughModalKey(_ event: NSEvent) {
    FlashLog.trace(
      "[modal] consume key=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "")")
  }

  func overlayDidCancelCommandLine() {
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
      refreshCommandLine(
        text: overlay.commandLineText,
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    if !commandLineCompletionMatches.isEmpty {
      commandLineCompletionSelectedIndex = min(
        max(commandLineCompletionSelectedIndex + delta, 0),
        commandLineCompletionMatches.count - 1)
      refreshCommandLine(
        text: overlay.commandLineText,
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    return false
  }

  /// `<tab>` in command-line mode. For command/sub-command completions
  /// this inserts the selected candidate's value (no submit) — the user
  /// can then keep typing args or hit `<CR>` to send. The candidate
  /// finder (`:flashlight`/`:open`/`:emojis`) has no insertable value,
  /// so there `<tab>` keeps its documented role of cycling the
  /// selection.
  func overlayDidInsertCommandLineSelection() -> Bool {
    if NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil {
      return overlayDidMoveCommandLineSelection(1)
    }
    if applySelectedCommandLineCompletionInPlace() {
      return true
    }
    return overlayDidMoveCommandLineSelection(1)
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
    refreshCandidateFinder(query: overlay.candidateFinderQuery)
  }

  func overlayDidSubmitCandidateFinder() {
    guard !candidateFinderMatches.isEmpty else {
      overlayDidCancelCandidateFinder()
      return
    }
    let candidate = candidateFinderMatches[min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)]
      .candidate
    openSourceItem(candidate)
  }

  func openSourceItem(matching target: String) {
    guard let item = registry.candidate(matching: target) else {
      FlashLog.warn("[app_open] no source item found for \"\(target)\"")
      return
    }
    openSourceItem(item)
  }

  func openSourceItem(_ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true) {
    if candidate.kind == CandidateFinder.emojiKind || candidate.kind == CandidateFinder.clipboardKind {
      insertText(candidate.sourcePayload ?? "")
      return
    }
    if shouldRecordMovement {
      recordMovement(.candidate(candidate), source: "source_open")
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
          "[candidate_finder] unresolved candidate source=\(candidate.sourceID) name=\(candidate.name) display=\(candidate.displayTitle)")
      }
      self.refreshCurrentModeSideEffects(reason: "source_resolved")
      self.scheduleNormalModeRecapture()
    }
  }
}

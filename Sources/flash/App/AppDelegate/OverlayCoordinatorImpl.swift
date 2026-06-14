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
        hasHints: !currentHints.isEmpty)
    {
      FlashLog.trace("[mode] suppress_pointer_scroll reason=idle_normal_mode")
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
      return
    }
    cancelOverlay()
    if flashMode != .insert {
      enterInsertMode(reason: .pointerClick)
    }
    // The overlay panel has `ignoresMouseEvents = true`, so the user's
    // real mouseDown/drag/mouseUp pass through to the underlying app
    // unaltered. Replaying a synthetic click here was the prior approach;
    // it doubled left-clicks (cursor jumped, second hit re-triggered the
    // target) and dismissed the context menu on right-click (the synth
    // click landed outside the just-opened menu). The transition into
    // INSERT is enough — the original gesture is the click.
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

    let action = pendingAction
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.mouseTargetCommitShouldEnterInsertMode(target: hint.target)
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
    FlashLog.trace(
      "[commit] action=\(action) role=\(hint.target.role ?? "?") "
        + "provider=\(hint.target.providerID) "
        + "click=(\(Int(clickPoint.x)),\(Int(clickPoint.y))) "
        + "modifiers=cmd:\(clickModifiers.contains(.command)) "
        + "shift:\(clickModifiers.contains(.shift)) "
        + "ctrl:\(clickModifiers.contains(.control)) "
        + "alt:\(clickModifiers.contains(.option)) "
        + "enters_insert=\(hint.target.entersInsertMode)")

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
        self.restoreNormalModeAfterCommit(action: action)
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
    if action == .rightClick {
      applyModeOverlay(captureOverride: false)
      overlay.inputMode = .normal
      return
    }
    scheduleNormalModeRecapture()
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
    let priorPID = sourceAppPID
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
      applyModeOverlay()
      return
    }
    let clickAction = pendingAction
    _ = ActionDispatcher.synthesizeClick(
      at: point,
      action: clickAction,
      modifiers: clickModifiers)
    if clickAction == .rightClick {
      // Right-click opened a context menu — same rule as `commit()`:
      // refresh the badge but don't `makeKey()` on the panel, or the
      // menu loses its modal session the same instant it appears.
      applyModeOverlay(captureOverride: false)
      overlay.inputMode = .normal
    } else {
      applyModeOverlay()
      enterInsertModeIfClickedOnTextInput(pid: priorPID, reason: .hintCommit)
    }
  }

  /// Geometric clicks (`F`/`sF`/`dF` mouse-grid commits, `pointerClick`
  /// replays) don't know what element they're hitting until the click
  /// has landed and the focused app has updated AX. After a short
  /// settle delay, query the focused element's role and only enter
  /// insert mode if it is a true text-input surface. Otherwise the
  /// user stays in normal mode (per the explicit-only insert rule —
  /// they press `i` if they want to type into whatever they just
  /// clicked).
  private func enterInsertModeIfClickedOnTextInput(
    pid: pid_t?,
    reason: InsertModeTransitionReason
  ) {
    guard let pid, flashMode == .normal else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
      guard let self, self.flashMode == .normal else { return }
      self.monitor.focusedElementIsEditable(pid: pid) { [weak self] editable in
        guard let self, editable, self.flashMode == .normal else { return }
        self.enterInsertMode(reason: reason)
      }
    }
  }

  static func mouseTargetCommitShouldEnterInsertMode(target: JumpTarget) -> Bool {
    // `f`/`sf`/`df` commit a precise click on a known element. Enter insert
    // only when that element is a typing surface (the owning provider sets
    // `entersInsertMode`); clicking a link or button stays in normal mode
    // so keyboard navigation chains keep going.
    target.entersInsertMode
  }

  // `mouseGridCommitShouldEnterInsertMode` removed: `F`/`sF`/`dF` no
  // longer auto-enter insert. The geometric click can land anywhere —
  // a button, a tab, a text field, blank canvas — so the only correct
  // signal is the post-click AX role, queried by
  // `enterInsertModeIfClickedOnTextInput`. Move (`mF`) was already a
  // no-op for insert.

  func usesTmuxProvider(_ context: AppContext?) -> Bool {
    guard let context else { return false }
    return registry.chain(for: context).contains { $0.identifier == "plugin:tmux" }
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  func overlayDidCancelModal() {
    clipboardModalEntries = []
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.hide()
    applyModeOverlay()
  }

  /// Paste the highlighted `:clipboard` entry. The panel owns the selected
  /// index; map it back to the full value and route through `insertText`
  /// (stash on the pasteboard, synth ⌘V into the focused app), same as an
  /// emoji picked from the flashlight.
  func overlayDidSubmitSelectableModal() {
    let index = overlay.selectableModalSelectedIndex
    guard clipboardModalEntries.indices.contains(index) else {
      overlayDidCancelModal()
      return
    }
    let value = clipboardModalEntries[index].value
    clipboardModalEntries = []
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    insertText(value)
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
    candidateFinderLastInputAt = Date()
    candidateFinderUserHasTyped = true
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
      // Re-render the suggestion list with the new highlighted row only;
      // skip `refreshCommandLine` so we don't re-run the candidate search
      // for an unchanged query. Re-running it would reshuffle results as
      // late async DB hits land while the user is just paging through.
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
    return false
  }

  /// `<tab>` in command-line mode. Two paths:
  ///
  ///   * Command-line *completions* (`:help <topic>`, `:plugins <sub>`,
  ///     `:<plugin> <action>`): insert the selected completion's
  ///     `value` into the buffer without sending — the user can keep
  ///     typing args, or hit `<cr>` to send.
  ///   * Candidate *finder* (`:flashlight` / `:open` / `:emojis`):
  ///     `<tab>` submits final app/tmux-window destinations, otherwise
  ///     inserts the selected candidate's canonical command text.
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
  /// exact; `<tab>` submits final app/tmux-window destinations and
  /// otherwise inserts.
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
    candidateFinderLastInputAt = Date()
    candidateFinderUserHasTyped = true
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
    // Just rerender with the new selection — re-scoring against the
    // same query would reshuffle results when a late async DB hit
    // lands mid-navigation.
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
    guard let item = registry.candidate(matching: target) else {
      FlashLog.warn("[app_open] no source item found for \"\(target)\"")
      return
    }
    openSourceItem(item)
  }

  func openSourceItem(_ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true) {
    if CandidateFinder.insertsText(candidate) {
      insertText(candidate.sourcePayload ?? "")
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
          "[candidate_finder] unresolved candidate source=\(candidate.sourceID) name=\(candidate.name) display=\(candidate.displayTitle)"
        )
      }
      self.refreshCurrentModeSideEffects(reason: "source_resolved")
      self.scheduleNormalModeRecapture()
    }
  }
}

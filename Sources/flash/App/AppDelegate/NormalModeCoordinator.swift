import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

/// One `:clipboard` history row: `preview` is the one-line label rendered in
/// the modal, `value` the full text pasted on selection. Decoded from the
/// clipboard plugin's `:clipboard` JSON response.
struct ClipboardModalEntry: Decodable {
  let preview: String
  let value: String
}

/// Normal-mode coordination — the big one. Handles mode transitions,
/// the normal-mode interpreter's callbacks, command-line entry, help
/// rendering, plugin invocation, scroll suppression, the per-app
/// active-window border tracker, candidate-finder lifecycle, and the
/// movement-history stacks that back `ctrl-o` / `ctrl-i`.
extension AppDelegate {
  // MARK: Normal mode

  func enterNormalMode() {
    FlashLog.trace(
      "[mode] enter_normal from=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight)")
    transitionMode(to: .normal, reason: "explicit_normal")
  }

  func enterInsertMode(
    reason: InsertModeTransitionReason = .explicitCommand,
    force: Bool = false
  ) {
    if flashMode == .normal, modeBadgeEnabled, !force,
      !Self.normalModeMayEnterInsert(reason: reason)
    {
      FlashLog.debug(
        "[mode] enter_insert_denied reason=\(reason.logValue) "
          + "rule=normal_requires_user_mouse_or_input")
      normalModePendingCommandToken &+= 1
      clearTransientHintState(reason: "enter_insert_denied_\(reason.logValue)")
      resetModeInputState()
      if overlay.inputMode == .commandLine || overlay.inputMode == .candidateFinder || overlay.inputMode == .modal {
        overlay.hide()
      }
      applyModeOverlay()
      scheduleNormalModeRecapture()
      return
    }
    FlashLog.debug("[mode] insert reason=\(reason.logValue)")
    FlashLog.trace(
      "[mode] enter_insert reason=\(reason.logValue) from=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight)")
    transitionMode(to: .insert, reason: reason.logValue)
  }

  private func transitionMode(to nextMode: FlashMode, reason: String) {
    let previousMode = flashMode
    normalModePendingCommandToken &+= 1
    resetModeInputState()
    closeModalStateForModeExit(reason: "enter_\(nextMode)_\(reason)")
    if previousMode != nextMode {
      modeWillLeave(previousMode, to: nextMode, reason: reason)
      flashMode = nextMode
    }
    clearTransientHintState(reason: "enter_\(nextMode)_\(reason)")
    modeDidEnter(nextMode, from: previousMode, reason: reason)
  }

  func invalidateActivation(reason: String) {
    if activationInFlight || activationInFlightGeneration != nil {
      FlashLog.trace(
        "[activation] invalidate reason=\(reason) gen=\(activationGen) "
          + "in_flight_gen=\(String(describing: activationInFlightGeneration))")
    }
    activationGen &+= 1
    activationInFlight = false
    activationInFlightGeneration = nil
  }

  private func clearTransientHintState(reason: String) {
    let hadHints = !currentHints.isEmpty
    let hadActivation = activationInFlight || activationInFlightGeneration != nil
    if hadHints || hadActivation {
      FlashLog.trace(
        "[mode] clear_hints reason=\(reason) hints=\(currentHints.count) "
          + "in_flight=\(activationInFlight)")
    }
    if hadHints {
      overlay.hide()
    }
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    mouseGridRegion = nil
    mouseGridDepth = 0
    pendingAction = .leftClick
    pendingHintCommitBehavior = .click
    if hadActivation {
      invalidateActivation(reason: reason)
    }
  }

  private func modeWillLeave(_ mode: FlashMode, to nextMode: FlashMode, reason: String) {
    FlashLog.trace("[mode] leave mode=\(mode) next=\(nextMode) reason=\(reason)")
    switch mode {
    case .insert:
      windowGeometryChangeInProgress = false
      windowGeometryChangeToken &+= 1
      stopActiveWindowBorderTracking(reason: "leave_insert_\(reason)")
      overlay.setActiveWindowBorder(around: nil)
    case .normal:
      normalModeRecaptureToken &+= 1
      closeModalStateForModeExit(reason: "leave_normal_\(reason)")
    }
  }

  private func modeDidEnter(_ mode: FlashMode, from previousMode: FlashMode, reason: String) {
    FlashLog.trace("[mode] did_enter mode=\(mode) from=\(previousMode) reason=\(reason)")
    // Re-register scope-bound Carbon hotkeys. `.normal`-scope shortcuts
    // (e.g. cmd+tab) need to be unregistered on insert entry so the
    // system handler can see the key combo again.
    mappings.applyForFlashMode(mode)
    switch mode {
    case .normal:
      modeDidEnterNormal(reason: reason)
    case .insert:
      modeDidEnterInsert(reason: reason)
    }
  }

  private func modeDidEnterNormal(reason _: String) {
    resetModeInputState()
    if let context = currentNonFlashContext() ?? normalModeContext() {
      normalModeTargetPID = context.processID
      suppressEditableFocus(for: context.processID)
      if !usesTmuxProvider(context) {
        _ = NormalModeDispatcher.defocusFocusedEditableElement(pid: context.processID)
      }
    }
    applyModeOverlay()
    scheduleNormalModeRecapture()
  }

  private func modeDidEnterInsert(reason: String) {
    let insertTarget = currentNonFlashContext()
    let panelKeyAtEntry = overlay.isKeyWindow
    normalModeRecaptureToken &+= 1
    normalModePendingCommandToken &+= 1
    resetModeInputState()
    normalModeTargetPID = nil
    editableFocusSuppressedPID = nil
    if currentHints.isEmpty {
      overlay.hide()
    }
    applyModeOverlay()
    // Stuck-input safeguard: explicitly re-activate the focused app so
    // its main window reclaims key status from the overlay panel.
    // Without this, apps like Messages can end up in a state where the
    // text field shows focus (caret blinks) but the first few keystrokes
    // land on the resigned panel instead of the field — the
    // `[mode] insert_handoff_settled` trace previously captured this as
    // `panel_key=true` 120ms after entry. Re-activating is idempotent
    // when key already moved cleanly, defensive when it didn't.
    if let target = insertTarget,
      let app = NSRunningApplication(processIdentifier: target.processID),
      !app.isTerminated
    {
      RunningApplicationActivation.activate(app, options: [])
    }
    traceInsertKeyHandoff(
      target: insertTarget, panelKeyAtEntry: panelKeyAtEntry, reason: reason)
  }

  /// Diagnostic trace for the INSERT key-window handoff (#1: Messages drops
  /// the first keystroke). The overlay is a `.nonactivatingPanel`, so the
  /// focused app stays the *active application* while the panel merely holds
  /// the *key window*; on INSERT entry the panel resigns key via `orderOut`
  /// and macOS is meant to hand key back to the app's window. Sample the
  /// panel key state at entry and again after a short settle delay — if the
  /// panel still holds key when the user would start typing, the first
  /// keystroke lands on the resigned panel instead of the app.
  private func traceInsertKeyHandoff(
    target: AppContext?,
    panelKeyAtEntry: Bool,
    reason: String
  ) {
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    FlashLog.trace(
      "[mode] insert_handoff reason=\(reason) "
        + "target=\(target?.bundleIdentifier ?? "nil") "
        + "pid=\(target.map { String($0.processID) } ?? "nil") "
        + "panel_key_entry=\(panelKeyAtEntry) panel_key_now=\(overlay.isKeyWindow) "
        + "frontmost=\(frontmost)")
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
      guard let self else { return }
      let frontmostLater =
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
      FlashLog.trace(
        "[mode] insert_handoff_settled reason=\(reason) "
          + "panel_key=\(self.overlay.isKeyWindow) frontmost=\(frontmostLater) "
          + "mode=\(self.flashMode)")
    }
  }

  func refreshCurrentModeSideEffects(reason: String) {
    switch flashMode {
    case .insert:
      updateInsertModeActiveWindowBorder(reason: reason)
    case .normal:
      break
    }
  }

  func focusedWindowGeometryDidChange(pid: pid_t, notification: String) {
    guard let context = currentNonFlashContext(), context.processID == pid else { return }
    pluginManager.emit(
      PluginEvent(
        name: "core:ax.changed",
        payload: ["notification": notification, "pid": Int(pid)],
        bundleID: context.bundleIdentifier,
        configPath: nil,
        focused: true))
    beginTrackedWindowGeometryChange(reason: notification, frame: context.frontWindowFrame)
  }

  private func modeWillBeginWindowGeometryChange(reason: String) {
    windowGeometryChangeInProgress = true
    FlashLog.trace("[mode] window_geometry_begin mode=\(flashMode) reason=\(reason)")
    switch flashMode {
    case .insert:
      overlay.setActiveWindowBorder(around: nil)
    case .normal:
      break
    }
  }

  private func modeDidEndWindowGeometryChange(reason: String) {
    windowGeometryChangeInProgress = false
    FlashLog.trace("[mode] window_geometry_end mode=\(flashMode) reason=\(reason)")
    switch flashMode {
    case .insert:
      updateInsertModeActiveWindowBorder(reason: "window_geometry_end_\(reason)")
    case .normal:
      break
    }
  }

  private func resetModeInputState() {
    overlay.normalModePending = ""
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    overlay.candidateFinderQuery = ""
    candidateFinderCandidates = []
    candidateFinderMatches = []
    candidateFinderSelectedIndex = 0
    candidateFinderCurrentQuery = ""
    currentPrefix = ""
  }

  private func closeModalStateForModeExit(reason: String) {
    switch overlay.inputMode {
    case .commandLine:
      FlashLog.trace("[mode] close_modal input=command_line reason=\(reason)")
      resetCommandLineState()
      overlay.hide()
    case .candidateFinder:
      FlashLog.trace("[mode] close_modal input=candidate_finder reason=\(reason)")
      clearCandidateFinderState()
      overlay.hide()
    case .modal:
      FlashLog.trace("[mode] close_modal input=modal reason=\(reason)")
      overlay.hide()
    case .hints, .normal:
      break
    }
  }

  private func updateInsertModeActiveWindowBorder(reason: String) {
    let context = currentNonFlashContext()
    guard
      Self.activeWindowBorderShouldBeVisible(
        mode: flashMode,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty,
        windowGeometryChangeInProgress: windowGeometryChangeInProgress)
    else {
      overlay.setActiveWindowBorder(around: nil)
      if !windowGeometryChangeInProgress {
        stopActiveWindowBorderTracking(reason: "hidden_\(reason)")
      }
      return
    }
    FlashLog.trace("[mode] insert_border_update reason=\(reason)")
    overlay.setActiveWindowBorder(around: context?.frontWindowFrame)
    startActiveWindowBorderTracking(frame: context?.frontWindowFrame, reason: reason)
  }

  private func startActiveWindowBorderTracking(frame: CGRect?, reason: String) {
    activeWindowBorderTrackedFrame = frame
    guard activeWindowBorderTrackingTimer == nil else { return }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .milliseconds(Self.activeWindowBorderTrackingIntervalMs),
      repeating: .milliseconds(Self.activeWindowBorderTrackingIntervalMs),
      leeway: .milliseconds(Self.activeWindowBorderTrackingLeewayMs))
    timer.setEventHandler { [weak self] in
      self?.pollActiveWindowBorderFrame()
    }
    activeWindowBorderTrackingTimer = timer
    FlashLog.trace("[mode] insert_border_tracking_start reason=\(reason)")
    timer.resume()
  }

  private func stopActiveWindowBorderTracking(reason: String) {
    guard let timer = activeWindowBorderTrackingTimer else {
      activeWindowBorderTrackedFrame = nil
      return
    }
    timer.cancel()
    activeWindowBorderTrackingTimer = nil
    activeWindowBorderTrackedFrame = nil
    FlashLog.trace("[mode] insert_border_tracking_stop reason=\(reason)")
  }

  private func pollActiveWindowBorderFrame() {
    guard
      Self.activeWindowBorderTrackingShouldRun(
        mode: flashMode,
        modeBadgeEnabled: modeBadgeEnabled,
        hasHints: !currentHints.isEmpty)
    else {
      stopActiveWindowBorderTracking(reason: "state")
      return
    }

    let frame = currentNonFlashContext()?.frontWindowFrame
    guard
      !Self.activeWindowBorderFramesApproximatelyEqual(
        activeWindowBorderTrackedFrame,
        frame,
        tolerance: Self.activeWindowBorderFrameTolerance)
    else { return }

    beginTrackedWindowGeometryChange(reason: "frame_poll", frame: frame)
  }

  private func beginTrackedWindowGeometryChange(reason: String, frame: CGRect?) {
    activeWindowBorderTrackedFrame = frame
    windowGeometryChangeToken &+= 1
    let token = windowGeometryChangeToken
    modeWillBeginWindowGeometryChange(reason: reason)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.windowGeometryQuietMs)) {
      [weak self] in
      guard let self, self.windowGeometryChangeToken == token else { return }
      self.modeDidEndWindowGeometryChange(reason: reason)
    }
  }

  static func activeWindowBorderShouldBeVisible(
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    hasHints: Bool,
    windowGeometryChangeInProgress: Bool
  ) -> Bool {
    // Insert mode keeps the status bar visible and adds a colored frame
    // around the focused window so the typing target remains obvious.
    // Advanced mode (`flash://mode_normal` bound somewhere) is the gate
    // — without it Flash has no normal/insert distinction to visualise.
    // The border is suspended while hints are up so chips aren't framed
    // by a redundant outline, and while the window is moving/resizing
    // so the stroke doesn't lag visibly behind the chrome.
    guard mode == .insert, modeBadgeEnabled else { return false }
    if hasHints { return false }
    if windowGeometryChangeInProgress { return false }
    return true
  }

  static func activeWindowBorderTrackingShouldRun(
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    hasHints: Bool
  ) -> Bool {
    modeBadgeEnabled && mode == .insert && !hasHints
  }

  static func activeWindowBorderFramesApproximatelyEqual(
    _ lhs: CGRect?,
    _ rhs: CGRect?,
    tolerance: CGFloat
  ) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
      return true
    case let (.some(lhs), .some(rhs)):
      return abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
    default:
      return false
    }
  }

  static func normalModeMayEnterInsert(reason: InsertModeTransitionReason) -> Bool {
    reason == .hintCommit || reason == .normalModeInput || reason == .pointerClick
  }

  /// Scroll wheel events in idle normal mode are passive: the overlay
  /// panel has `ignoresMouseEvents=true` so the scroll already reaches the
  /// focused app, and we never want a wheel tick to silently flip Flash
  /// into insert mode. (Hints visible → still cancel: the user is
  /// scrolling away from the picker.)
  static func pointerScrollShouldBeSuppressed(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    mode == .normal && !hasHints
  }

  static func modeOverlaySnapshot(
    mode: FlashMode,
    labels: Config.Mode.Labels,
    visible: Bool,
    hasHints: Bool,
    activationInFlight: Bool,
    captureOverride: Bool?
  ) -> ModeOverlaySnapshot {
    let canCapture = mode == .normal && !hasHints && !activationInFlight
    let wantsCapture = captureOverride ?? canCapture
    let capture = canCapture && wantsCapture
    return ModeOverlaySnapshot(
      text: mode == .normal ? labels.normal : labels.insert,
      // Advanced mode keeps the status bar visible in both NORMAL and
      // INSERT. Keyboard capture remains a NORMAL-only concern.
      visible: visible,
      captureInput: capture,
      inputMode: capture ? .normal : .hints,
      // Always re-evaluate so a transition out of insert clears the
      // stale border via `updateInsertModeActiveWindowBorder`'s built-in
      // hide branch.
      refreshActiveWindowBorder: true)
  }

  func applyModeOverlay(captureOverride: Bool? = nil) {
    let snapshot = Self.modeOverlaySnapshot(
      mode: flashMode,
      labels: config.mode.labels,
      visible: modeBadgeEnabled,
      hasHints: !currentHints.isEmpty,
      activationInFlight: activationInFlight,
      captureOverride: captureOverride)
    FlashLog.trace(
      "[mode] overlay mode=\(flashMode) capture=\(snapshot.captureInput) "
        + "override=\(String(describing: captureOverride)) "
        + "visible=\(modeBadgeEnabled) hints=\(currentHints.count) in_flight=\(activationInFlight)")
    statusBarController?.updateModeLabel(snapshot.text)
    overlay.inputMode = snapshot.inputMode
    if snapshot.refreshActiveWindowBorder {
      updateInsertModeActiveWindowBorder(reason: "apply_mode_overlay")
    }
    overlay.setModeBadge(
      text: snapshot.text,
      visible: snapshot.visible,
      captureInput: snapshot.captureInput,
      mode: flashMode)
    if snapshot.captureInput {
      verifyNormalModeCapture(reason: "apply_mode_overlay")
    }
  }

  func suppressEditableFocus(for pid: pid_t) {
    guard pid > 0 else { return }
    editableFocusSuppressedPID = pid
  }

  func scheduleNormalModeRecapture() {
    // Flip `overlay.inputMode` to `.normal` synchronously before
    // scheduling the retries. The 0 ms entry below is still a
    // `DispatchQueue.main.asyncAfter` — it doesn't run until the next
    // runloop turn — so a key event reaching the session tap between
    // the caller dropping `activationInFlight = false` and that entry
    // executing would see the stale `inputMode == .hints` left over
    // from `commit()`'s pre-dispatch `applyModeOverlay(captureOverride:
    // false)` and route through the hint-typing path. Plain mappings
    // (`i`, `n`, `t`, `:`, …) get treated as stray hint commits against
    // an empty hint list and silently cancel instead of firing their
    // normal-mode action. The scheduled retries still run — they
    // exist for the panel-didn't-become-key-window case, which is a
    // separate concern from the inputMode-cache-is-stale race.
    if shouldCaptureNormalModeInput {
      applyModeOverlay(captureOverride: true)
    }
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    FlashLog.trace(
      "[mode] schedule_recapture token=\(token) delays="
        + Self.normalModeRecaptureDelaysMs.map(String.init).joined(separator: ","))
    for delayMs in Self.normalModeRecaptureDelaysMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self else { return }
        guard self.normalModeRecaptureToken == token else {
          FlashLog.trace("[mode] recapture_skip token=\(token) delay=\(delayMs) reason=stale")
          return
        }
        guard self.shouldCaptureNormalModeInput else {
          FlashLog.trace(
            "[mode] recapture_skip token=\(token) delay=\(delayMs) reason=state "
              + "mode=\(self.flashMode) hints=\(self.currentHints.count) "
              + "in_flight=\(self.activationInFlight) input=\(self.overlay.inputMode)")
          return
        }
        FlashLog.trace("[mode] recapture_apply token=\(token) delay=\(delayMs)")
        self.applyModeOverlay(captureOverride: true)
      }
    }
  }

  private func verifyNormalModeCapture(reason: String) {
    normalModeCaptureVerificationToken &+= 1
    let token = normalModeCaptureVerificationToken
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
      guard let self, self.normalModeCaptureVerificationToken == token else { return }
      guard self.shouldCaptureNormalModeInput else { return }
      guard !self.overlay.keyboardCaptureIsActive else { return }
      FlashLog.debug(
        "[mode] capture_inactive reason=\(reason) key=\(self.overlay.isKeyWindow) "
          + "first_responder=\(String(describing: self.overlay.firstResponder))")
      self.scheduleNormalModeRecapture()
    }
  }

  func scheduleNormalModeRecaptureAfterPointerFocusLoss() {
    if Self.pointIsInMenuBar(NSEvent.mouseLocation) {
      // The user clicked the menu bar (system menu, app menu, or status
      // item). Recapturing key window here races the menu's open: the
      // 0ms recapture entry fires before the async pointer-monitor path
      // can transition to insert, and steals key back so the menu closes
      // the same instant it opened. The user then has to click again to
      // reopen it. Letting the menu interact freely is the right call —
      // `overlayDidCancelByPointer` will still flip Flash into insert
      // mode on the async path, so the badge updates without disturbing
      // the menu.
      FlashLog.trace("[mode] pointer_recapture_skip target=menu_bar")
      return
    }
    FlashLog.trace(
      "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
        + "reason=normal_mode_focus_contract")
    scheduleNormalModeRecapture()
  }

  static let normalModeRecaptureDelaysMs = [0, 10, 30, 60, 120, 250, 500, 900, 1_400]
  static let windowGeometryQuietMs = 160
  static let activeWindowBorderTrackingIntervalMs = 50
  static let activeWindowBorderTrackingLeewayMs = 10
  static let activeWindowBorderFrameTolerance: CGFloat = 1

  private static func pointerFocusLossTarget() -> String {
    pointIsInMenuBar(NSEvent.mouseLocation) ? "menu_bar" : "window_or_popup"
  }

  static func pointIsInMenuBar(_ point: CGPoint) -> Bool {
    for screen in NSScreen.screens {
      let menuBand = CGRect(
        x: screen.frame.minX,
        y: screen.visibleFrame.maxY,
        width: screen.frame.width,
        height: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
      if menuBand.contains(point) {
        return true
      }
    }
    return false
  }

  var shouldCaptureNormalModeInput: Bool {
    guard flashMode == .normal, currentHints.isEmpty, !activationInFlight else { return false }
    switch overlay.inputMode {
    case .commandLine, .modal, .candidateFinder:
      return false
    case .hints, .normal:
      return true
    }
  }

  func hasNormalModeBinding(_ cfg: Config) -> Bool {
    cfg.mode.containsAdvancedModeMapping
  }

  func performMappedCommand(_ command: URLCommand, repeatCount: Int = 1) {
    let repeatCount = normalizedRepeatCount(repeatCount)
    FlashLog.debug(
      "[mappings] action=\(command.diagnosticDescription) repeat=\(repeatCount)")
    switch command {
    case .insertMode:
      enterInsertMode(reason: .normalModeInput)
    case .normalMode:
      enterNormalMode()
    case .commandMode:
      enterCommandLineMode()
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
    case .reload(let force):
      let flags: CGEventFlags = force ? [.maskCommand, .maskShift] : .maskCommand
      sendNormalModeKey(CGKeyCode(kVK_ANSI_R), flags: flags, repeatCount: repeatCount)
    case .sendKey(_, let keyCode, let flagsRawValue):
      sendNormalModeKey(
        keyCode, flags: CGEventFlags(rawValue: flagsRawValue), repeatCount: repeatCount)
    case .undo:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_Z),
        flags: .maskCommand,
        repeatCount: repeatCount,
        suppressInTerminalFor: command)
    case .redo:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_Z),
        flags: [.maskCommand, .maskShift],
        repeatCount: repeatCount,
        suppressInTerminalFor: command)
    case .close:
      windowCloseInNormalMode(repeatCount: repeatCount)
    case .tabClose:
      tabCloseInNormalMode(repeatCount: repeatCount)
    case .find:
      // ⌘F only — the find bar opens, but Flash stays in normal so the
      // user controls when they actually want to type into it. Per the
      // explicit-only insert rule, `i` is the user's intent signal; an
      // auto-flip here would be Flash inferring intent.
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
    case .candidateFinder(let all):
      enterCommandLineMode(initialText: "flashlight ", candidateFinderScope: all ? .all : .running)
    case .flashlight:
      enterCommandLineMode(initialText: "flashlight ", candidateFinderScope: .all)
    case .emojiPicker:
      enterCommandLineMode(initialText: "emojis ", candidateFinderScope: .all)
    case .mouseTarget(let command):
      activateMouseTarget(command, contextOverride: normalModeContext())
    case .mouseGrid(let command):
      activateMouseGrid(command, contextOverride: normalModeContext())
    case .copyURL:
      copyFocusedDocumentURL()
      applyModeOverlay()
    case .tabNext:
      tabNextInNormalMode(repeatCount: repeatCount)
    case .tabPrev:
      tabPrevInNormalMode(repeatCount: repeatCount)
    case .tabFirst:
      tabSelectInNormalMode(index: 1)
    case .tabLast:
      tabLastInNormalMode()
    case .tabSelect(let explicitIndex):
      tabSelectInNormalMode(index: explicitIndex ?? repeatCount)
    case .tabMovePrev:
      tabMoveInNormalMode(direction: .previous, repeatCount: repeatCount)
    case .tabMoveNext:
      tabMoveInNormalMode(direction: .next, repeatCount: repeatCount)
    case .tabReopen:
      tabReopenInNormalMode(repeatCount: repeatCount)
    case .historyBack:
      navigateTargetHistory(direction: .back, repeatCount: repeatCount)
    case .historyForward:
      navigateTargetHistory(direction: .forward, repeatCount: repeatCount)
    case .movementBack:
      navigateMovementHistory(direction: .back)
    case .movementForward:
      navigateMovementHistory(direction: .forward)
    case .appPrev:
      navigateAppMRU(direction: .back)
    case .appNext:
      navigateAppMRU(direction: .forward)
    case .setMark(let letter):
      setMark(letter: letter)
    case .jumpToMark(let letter):
      jumpToMark(letter: letter)
    case .quitApp(let force):
      quitNormalModeTargetApp(force: force)
    case .save:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_S), flags: .maskCommand, repeatCount: repeatCount)
    case .saveAndQuit(let force):
      sendNormalModeKey(CGKeyCode(kVK_ANSI_S), flags: .maskCommand, repeatCount: repeatCount)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
        self?.performMappedCommand(.quitApp(force: force))
      }
    case .print:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_P), flags: .maskCommand, repeatCount: repeatCount)
    case .openDocument:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_O), flags: .maskCommand, repeatCount: repeatCount)
    case .newWindow:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_N), flags: .maskCommand, repeatCount: repeatCount)
    case .tabNew:
      tabNewInNormalMode(repeatCount: repeatCount)
    case .copy:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand, repeatCount: repeatCount)
    case .cut:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_X), flags: .maskCommand, repeatCount: repeatCount)
    case .paste:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, repeatCount: repeatCount)
    case .copyAll:
      for _ in 0..<repeatCount {
        sendNormalModeKeySequence([
          (CGKeyCode(kVK_ANSI_A), .maskCommand),
          (CGKeyCode(kVK_ANSI_C), .maskCommand),
        ])
      }
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showPlugins:
      showPlugins()
    case .showAlert, .dismissAlert, .dismissHints, .quit, .openApp, .pluginCommand, .moveWindow:
      handleURLCommand(command)
    }
  }

  func performMappingCommand(_ action: MappingCommand, repeatCount: Int = 1) {
    switch action {
    case .flashCommand(let command):
      performMappedCommand(command, repeatCount: repeatCount)
    case .shellCommand(let argv):
      let repeatCount = normalizedRepeatCount(repeatCount)
      FlashLog.debug(
        "[mappings] action=\(action.diagnosticDescription) repeat=\(repeatCount)")
      for _ in 0..<repeatCount {
        CommandMappingRunner.run(argv)
      }
    }
  }

  private func normalizedRepeatCount(_ repeatCount: Int) -> Int {
    min(max(repeatCount, 1), 999)
  }

  func enterCommandLineMode(
    initialText: String = "",
    candidateFinderScope: CandidateScope? = nil
  ) {
    guard
      Self.commandLineEntryIsAllowed(
        mode: flashMode,
        hasHints: !currentHints.isEmpty,
        activationInFlight: activationInFlight)
    else { return }
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    closeModalStateForModeExit(reason: "enter_command")
    clearTransientHintState(reason: "enter_command")
    resetCommandLineState()
    candidateFinderUserHasTyped = false
    if let candidateFinderScope {
      self.candidateFinderScope = candidateFinderScope
      candidateFinderCandidates = candidateFinderCandidates(for: candidateFinderScope)
      candidateFinderSelectedIndex = 0
    } else {
      self.candidateFinderScope = .all
      clearCandidateFinderState()
    }
    overlay.setActiveWindowBorder(around: nil)
    refreshVolatileCandidateSources(reason: "command_line_open")
    prewarmCandidateFinderCaches(reason: "command_line_open")
    let command = Self.commandLineBuffer(from: initialText)
    refreshCommandLine(text: command, cursorIndex: command.count)
  }

  static func commandLineEntryIsAllowed(
    mode: FlashMode,
    hasHints: Bool,
    activationInFlight: Bool
  ) -> Bool {
    switch mode {
    case .normal, .insert:
      return true
    }
  }

  static func commandLineExitMode(currentMode: FlashMode) -> FlashMode {
    .normal
  }

  func showHelp(topic: String? = nil) {
    presentModal(reason: "enter_help") { [self] in
      HelpDocs.render(topic: topic, config: config, showModes: modeBadgeEnabled)
    }
  }

  func showPlugins() {
    presentModal(reason: "enter_plugins") { [self] in
      pluginManager.statusText()
    }
  }

  private func runPluginsSubcommand(_ sub: NormalModeDispatcher.PluginsSubcommand) {
    switch sub {
    case .modal, .list:
      // Both surface the same status table; `:plugins` opens the modal
      // (legacy), `:plugins list` aliases to it explicitly.
      showPlugins()
    case .reload:
      let ids = pluginManager.reloadAll()
      let summary: String
      if ids.isEmpty {
        summary = "No plugins are loaded."
      } else {
        summary = "Reloading: \(ids.joined(separator: ", "))"
      }
      FlashLog.info("[plugins] reload command ids=\(ids.joined(separator: ","))")
      presentModal(reason: "plugins_reload") { "PLUGINS RELOAD\n\n\(summary)" }
    }
  }

  private func showMappings() {
    presentModal(reason: "enter_mappings") { [self] in
      NormalModeDispatcher.mappingsText(config: config)
    }
  }

  /// Single entry point for every modal surface (`:help`, `:plugins`,
  /// `:mappings`, plugin-reload toast, `:clipboard`, future modals).
  /// Centralises the pre-modal cleanup so call sites can't drift on a
  /// missed step; the renderer is the only thing variants pass in.
  private func presentModal(
    reason: String,
    body: () -> String
  ) {
    prepareModalPresentation(reason: reason)
    overlay.displayModal(body())
  }

  /// Shared pre-modal cleanup: mode-pending token bump, hint /
  /// candidate-finder reset, active-window border clear, overlay
  /// hide. `presentModal` and `presentSelectableModal` both go through
  /// it so the surfaces start from an identical state regardless of
  /// what the user was doing before.
  private func prepareModalPresentation(reason: String) {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearTransientHintState(reason: reason)
    clearCandidateFinderState()
    overlay.hide()
    overlay.setActiveWindowBorder(around: nil)
  }

  /// `:clipboard` — fetch the full history from the clipboard plugin and open
  /// the dedicated selectable modal. The history travels over the plugin
  /// command RPC (keeping this surface decoupled from the flashlight candidate
  /// pool); previews render the list while the full values are stashed in
  /// `clipboardModalEntries` for the paste on Return.
  func openClipboardModal() {
    let dispatched = pluginManager.invoke(
      command: "clipboard", subcommand: "", args: [], raw: ":clipboard",
      forBundleID: currentNonFlashContext()?.bundleIdentifier
    ) { [weak self] ok, _, stdout in
      guard let self else { return }
      let entries = (ok ? stdout : nil).flatMap(Self.decodeClipboardModalEntries) ?? []
      self.clipboardModalEntries = entries
      guard !entries.isEmpty else {
        self.presentModal(reason: "clipboard_empty") { "CLIPBOARD\n\nNo history yet." }
        return
      }
      self.presentSelectableModal(reason: "clipboard", lines: entries.map(\.preview))
    }
    if !dispatched {
      clipboardModalEntries = []
      presentModal(reason: "clipboard_unavailable") { "CLIPBOARD\n\nPlugin unavailable." }
    }
  }

  /// Selectable counterpart to `presentModal` — same `prepareModal-
  /// Presentation` setup, but renders `lines` as the navigable list
  /// surface (currently only `:clipboard`).
  private func presentSelectableModal(reason: String, lines: [String]) {
    prepareModalPresentation(reason: reason)
    overlay.displaySelectableModal(lines: lines)
  }

  static func decodeClipboardModalEntries(_ json: String) -> [ClipboardModalEntry]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([ClipboardModalEntry].self, from: data)
  }

  private func enterCandidateFinderMode(scope: CandidateScope) {
    guard flashMode == .normal else { return }
    overlay.normalModePending = ""
    clearTransientHintState(reason: "enter_candidate_finder")
    overlay.candidateFinderQuery = ""
    overlay.commandLineCursorIndex = 0
    candidateFinderEmojiMode = false
    candidateFinderScope = scope
    candidateFinderCandidates = candidateFinderCandidates(for: scope)
    candidateFinderSelectedIndex = 0
    overlay.setActiveWindowBorder(around: nil)
    refreshVolatileCandidateSources(reason: "candidate_finder_open")
    prewarmCandidateFinderCaches(reason: "candidate_finder_open")
    refreshCandidateFinder(query: "")
  }

  /// Prompt volatile candidate plugins (Firefox tabs, tmux panes, Slack
  /// channels) to re-walk their source app and republish a fresh snapshot.
  /// Those plugins refresh on `core:focus.changed`, but while their app stays
  /// frontmost the cached snapshot goes stale as tabs/panes open and close —
  /// so flashlight would list tabs from whenever the app last gained focus.
  /// Re-emitting the focus event for the frontmost app on flashlight open
  /// pulls a current snapshot; the resulting `snapshot.updated` flows back
  /// through `pluginStateDidChange` to refresh the still-open finder. Emitted
  /// only on a genuine user open (never from the plugin-state refresh path) so
  /// it can't feed back into an emit→snapshot→emit loop.
  private func refreshVolatileCandidateSources(reason: String) {
    if let context = currentNonFlashContext() {
      FlashLog.trace(
        "[candidate_finder] refresh_volatile reason=\(reason) bundle=\(context.bundleIdentifier)")
      pluginManager.emit(
        PluginEvent(
          name: "core:focus.changed",
          payload: [
            "bundle_id": context.bundleIdentifier,
            "pid": Int(context.processID),
          ],
          bundleID: context.bundleIdentifier,
          configPath: nil,
          focused: true))
    }
    // Also emit a synthetic `focus.changed` for every running app
    // whose bundle id any loaded plugin claims — without this prompt
    // the plugin only re-walks its AX tree when its app gains focus,
    // so a user opening flashlight from a different app sees the
    // last-emitted (or empty) candidate snapshot. The previous
    // implementation hard-coded the browser carve-out; the union of
    // plugin `bundle_ids` from `pluginManager.claimedBundleIDs()`
    // generalises the same logic to slack channels, firefox tabs,
    // and any future bundle-gated source without per-plugin
    // book-keeping here.
    let currentBundleID = currentNonFlashContext()?.bundleIdentifier
    let claimedBundleIDs = pluginManager.claimedBundleIDs()
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
      guard let bundleID = app.bundleIdentifier,
        claimedBundleIDs.contains(bundleID),
        bundleID != currentBundleID,
        !app.isTerminated
      else { continue }
      pluginManager.emit(
        PluginEvent(
          name: "core:focus.changed",
          payload: [
            "bundle_id": bundleID,
            "pid": Int(app.processIdentifier),
          ],
          bundleID: bundleID,
          configPath: nil,
          focused: false))
    }
  }

  func prewarmCandidateFinderCaches(reason: String) {
    refreshCandidatesAsync(scope: .running, reason: reason)
    refreshCandidatesAsync(scope: .all, reason: reason)
  }

  /// True only while the command-line or candidate-finder surface is on
  /// screen. Used to skip background source queries (live refresh,
  /// plugin-state churn) while nothing is consuming candidates.
  var candidateFinderSurfaceActive: Bool {
    guard overlay != nil else { return false }
    switch overlay.inputMode {
    case .commandLine, .candidateFinder:
      return true
    case .hints, .normal, .modal:
      return false
    }
  }

  func invalidateCandidateFinderCaches(reason: String, refreshApps: Bool) {
    FlashLog.trace("[candidate_finder] refresh_cache reason=\(reason) refresh_apps=\(refreshApps)")
    if refreshApps {
      registry.refreshRunningApplications()
    }
    prewarmCandidateFinderCaches(reason: reason)
  }

  func startCandidateFinderLiveRefresh() {
    candidateFinderLiveRefreshTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // 5-second cadence (was 2s) — flashlight tab/window inventories
    // don't change second-to-second in normal use, and each refresh
    // pays a SafariTabsSource + ChromiumTabsSource AppleScript round-
    // trip. The leeway gives Dispatch room to coalesce with other
    // main-queue work instead of preempting it.
    timer.schedule(
      deadline: .now() + .seconds(5),
      repeating: .seconds(5),
      leeway: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self, self.candidateFinderSurfaceActive else { return }
      // Skip the refresh if the user is actively typing — swapping
      // the candidate pool under their fingers makes the results
      // strobe between the old and new snapshot, which reads as a
      // stutter. They'll get the fresh pool on the next quiet tick.
      if let last = self.candidateFinderLastInputAt,
        Date().timeIntervalSince(last) < 0.4
      {
        return
      }
      self.prewarmCandidateFinderCaches(reason: "live")
    }
    timer.resume()
    candidateFinderLiveRefreshTimer = timer
  }

  private func refreshVisibleCandidateFinderResultsFromCache() {
    guard overlay != nil else { return }
    // Initial snapshot is locked until the user types — see
    // `candidateFinderUserHasTyped`. The async refresh still runs and
    // writes into the cache so the NEXT flashlight session opens with
    // the fresher snapshot; we just don't re-render mid-display.
    // Exception: if the visible pool is empty (cold start), let the
    // refresh promote candidates as soon as they land so the user
    // isn't staring at a blank list.
    if !candidateFinderUserHasTyped, !candidateFinderCandidates.isEmpty {
      FlashLog.trace(
        "[candidate_finder] refresh_skip reason=locked_until_first_keystroke "
          + "visible=\(candidateFinderCandidates.count)")
      return
    }
    switch overlay.inputMode {
    case .commandLine:
      guard NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil else {
        return
      }
      candidateFinderCandidates = candidateFinderCandidates(for: candidateFinderScope)
      refreshCommandLine(text: overlay.commandLineText, cursorIndex: overlay.commandLineCursorIndex)
    case .candidateFinder:
      candidateFinderCandidates = candidateFinderCandidates(for: candidateFinderScope)
      refreshCandidateFinder(query: overlay.candidateFinderQuery)
    case .hints, .normal, .modal:
      return
    }
  }

  private func refreshCandidatesAsync(scope: CandidateScope, reason: String) {
    switch scope {
    case .running:
      guard !candidateFinderRunningAppsRefreshInFlight else { return }
      candidateFinderRunningAppsRefreshInFlight = true
    case .all:
      guard !candidateFinderAllAppsRefreshInFlight else { return }
      candidateFinderAllAppsRefreshInFlight = true
    }

    FlashLog.trace("[candidate_finder] refresh_start scope=\(scope) reason=\(reason)")
    candidateFinderCacheQueue.async { [weak self] in
      guard let self else { return }
      let candidates = self.registry.candidates(scope: scope)
      DispatchQueue.main.async {
        switch scope {
        case .running:
          self.candidateFinderRunningAppsCache = candidates
          self.candidateFinderRunningAppsCacheReady = true
          self.candidateFinderRunningAppsRefreshInFlight = false
        case .all:
          self.candidateFinderAllAppsCache = candidates
          self.candidateFinderAllAppsCacheReady = true
          self.candidateFinderAllAppsRefreshInFlight = false
        }
        FlashLog.trace(
          "[candidate_finder] refresh_done scope=\(scope) count=\(candidates.count) reason=\(reason)")
        self.refreshVisibleCandidateFinderResultsFromCache()
      }
    }
  }

  private func candidateFinderCandidates(for scope: CandidateScope) -> [Candidate] {
    // Bangs are NOT in the default pool — they only surface when the
    // user types `!` (see `updateCandidateMatches`'s bang branch). The
    // default flashlight shows apps/tabs/tmux/etc. without bang noise.
    switch scope {
    case .running:
      if !candidateFinderRunningAppsCacheReady {
        refreshCandidatesAsync(scope: .running, reason: "cache_miss")
      }
      return candidateFinderRunningAppsCache
    case .all:
      if !candidateFinderAllAppsCacheReady {
        refreshCandidatesAsync(scope: .all, reason: "cache_miss")
      }
      return candidateFinderAllAppsCacheReady
        ? candidateFinderAllAppsCache : candidateFinderRunningAppsCache
    }
  }

  func refreshCandidateFinder(query: String) {
    updateCandidateMatches(query: query)
    overlay.displayCandidateFinder(query: query, items: candidateFinderDisplayItems())
  }

  /// Translate the `!<token>` range from the candidate-finder query into
  /// the full command buffer (`":flashlight !g foo"`). Returns an
  /// `NSRange` so the panel can drive `attributedStringValue` without
  /// re-parsing.
  private func bangRangeInCommand(
    command: String,
    query: String,
    bangRange: Range<String.Index>
  ) -> NSRange {
    let bangOffset = query.distance(from: query.startIndex, to: bangRange.lowerBound)
    let bangLen = query.distance(from: bangRange.lowerBound, to: bangRange.upperBound)
    let prefixLen = command.count - query.count
    let location = max(0, prefixLen + bangOffset)
    let utf16Prefix = command.index(
      command.startIndex,
      offsetBy: min(location, command.count))
    let utf16End = command.index(
      utf16Prefix,
      offsetBy: min(bangLen, command.distance(from: utf16Prefix, to: command.endIndex)))
    let nsLocation = utf16Prefix.utf16Offset(in: command)
    let nsLength = utf16End.utf16Offset(in: command) - nsLocation
    return NSRange(location: nsLocation, length: max(0, nsLength))
  }

  func refreshCommandLine(text: String, cursorIndex: Int? = nil) {
    let command = Self.commandLineBuffer(from: text)
    overlay.commandLineText = command
    overlay.commandLineCursorIndex = cursorIndex ?? command.count
    if let query = NormalModeDispatcher.commandLineCandidateQuery(command) {
      candidateFinderEmojiMode = NormalModeDispatcher.commandLineEmojiQuery(command) != nil
      clearCommandLineCompletionState()
      if candidateFinderCandidates.isEmpty {
        candidateFinderCandidates = candidateFinderCandidates(for: candidateFinderScope)
        candidateFinderSelectedIndex = 0
      }
      // Bang lock: once the user has typed a space after `!<token>`, the
      // remainder of the query semantically belongs to that bang's
      // dispatch (e.g. `!g rust language` → "search Google for 'rust
      // language'"). Showing candidate rows in that state was confusing
      // — the user was matching against bang names instead of typing
      // the query — so we drop the suggestions and pass the confirmed
      // bang range to the panel so it can underline `!g` and visually
      // acknowledge the lock-in. Backspacing past the space (no
      // confirmed bang anymore) unlocks and the bang list returns.
      let bang = CandidateFinder.parseBangState(query)
      if !candidateFinderEmojiMode, let bang, bang.confirmed {
        candidateFinderMatches = []
        candidateFinderSelectedIndex = 0
        let queryRange = bangRangeInCommand(command: command, query: query, bangRange: bang.bangRange)
        overlay.displayCommandLine(
          command,
          suggestions: nil,
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex,
          underlineRange: queryRange)
        return
      }
      updateCandidateMatches(query: query)
      overlay.displayCommandLine(
        command,
        suggestions: candidateFinderDisplayItems(),
        cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    if let context = commandLineCompletionContext(for: command) {
      clearCandidateFinderState()
      updateCommandLineCompletions(context: context)
      overlay.displayCommandLine(
        command,
        suggestions: commandLineCompletionDisplayItems(),
        emptyText: "no matching command",
        cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    clearCandidateFinderState()
    clearCommandLineCompletionState()
    overlay.displayCommandLine(command, cursorIndex: overlay.commandLineCursorIndex)
  }

  private func commandLineCompletionContext(for command: String)
    -> NormalModeDispatcher.CommandLineCompletionContext?
  {
    let registrations = pluginManager.commandRegistrations(
      forBundleID: currentNonFlashContext()?.bundleIdentifier)
    var subcommands: [String: [String]] = [:]
    var commandsOrdered: [String] = []
    for registration in registrations {
      let key = registration.command.lowercased()
      if subcommands[key] == nil {
        subcommands[key] = []
        commandsOrdered.append(key)
      }
      // `"*"` marks a wildcard command (whole remainder is args, e.g.
      // `:calc 2 + 2`); the verb is still completable, but there is no
      // concrete subcommand to suggest.
      if registration.subcommand == "*" { continue }
      if !subcommands[key]!.contains(where: {
        $0.localizedCaseInsensitiveCompare(registration.subcommand) == .orderedSame
      }) {
        subcommands[key]?.append(registration.subcommand)
      }
    }
    let topics = HelpDocs.allTopics(config: config, showModes: true)
      .flatMap { [$0.name] + $0.aliases }
    return NormalModeDispatcher.commandLineCompletions(
      command,
      pluginCommands: commandsOrdered,
      pluginSubcommands: subcommands,
      helpTopics: topics)
  }

  private func updateCommandLineCompletions(
    context: NormalModeDispatcher.CommandLineCompletionContext
  ) {
    let previousLabel: String? = commandLineCompletionMatches.indices.contains(
      commandLineCompletionSelectedIndex)
      ? commandLineCompletionMatches[commandLineCompletionSelectedIndex].completion.label : nil
    commandLineCompletionPrefix = context.prefix
    commandLineCompletionItems = context.items
    commandLineCompletionQuery = context.query
    let trimmedQuery = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let scored: [CommandLineCompletionMatch] = context.items.compactMap { item in
      // Frecency boost surfaces the user's most-typed commands at the
      // top of the empty `:` prompt without distorting the order once
      // they start typing — fuzzy score dominates from the first
      // character because it's an order of magnitude larger than the
      // capped boost.
      let boost = commandFrecencyBoost(label: item.label)
      if trimmedQuery.isEmpty {
        return CommandLineCompletionMatch(completion: item, score: boost)
      }
      guard
        let score = NormalModeDispatcher.fuzzyScore(
          query: trimmedQuery, candidate: item.label)
      else { return nil }
      return CommandLineCompletionMatch(completion: item, score: score + boost)
    }
    let sorted = scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.completion.label.localizedCaseInsensitiveCompare(rhs.completion.label)
        == .orderedAscending
    }
    commandLineCompletionMatches = sorted
    if sorted.isEmpty {
      commandLineCompletionSelectedIndex = 0
      return
    }
    if let previousLabel,
      let restored = sorted.firstIndex(where: { $0.completion.label == previousLabel })
    {
      commandLineCompletionSelectedIndex = restored
    } else {
      commandLineCompletionSelectedIndex = min(
        max(commandLineCompletionSelectedIndex, 0), sorted.count - 1)
    }
  }

  /// Frecency boost for a command-line completion label. Falls back to
  /// 0 when the store is unavailable (couldn't open the JSON file) or
  /// the label has never been opened.
  private func commandFrecencyBoost(label: String) -> Int {
    guard let frecencyStore else { return 0 }
    return frecencyStore.boost(forKey: FrecencyKey.command(label: label))
  }

  /// Record a frecency open against a command-line verb (`:flashlight`,
  /// `:help`, …). Called from every `submitCommandLine` so the empty-
  /// `:` prompt surfaces the user's actual habits.
  private func recordCommandLineFrecency(rawInput: String) {
    guard let frecencyStore else { return }
    var trimmed = rawInput.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(":") { trimmed.removeFirst() }
    guard let verb = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { return }
    let label = verb.lowercased()
    guard !label.isEmpty else { return }
    frecencyStore.recordOpen(itemKey: FrecencyKey.command(label: label))
  }

  /// Frecency boost for a Candidate. Mirrors the prior SearchService
  /// behaviour: derive the item key from the candidate (bundle id, URL,
  /// or sourcePayload envelope) and look up the cached integer boost.
  /// Used by the in-memory ranker inside `runCandidateFinderSearch`.
  func candidateFrecencyBoost(_ candidate: Candidate) -> Int {
    guard let frecencyStore, let key = FrecencyMapper.itemKey(for: candidate) else {
      return 0
    }
    return frecencyStore.boost(forKey: key)
  }

  private var commandBarSuggestionCount: Int {
    max(1, config.flashlight.suggestionCount)
  }

  func commandLineCompletionDisplayItems(windowSize: Int? = nil) -> [CandidateDisplayItem] {
    guard !commandLineCompletionMatches.isEmpty else { return [] }
    let windowSize = windowSize ?? commandBarSuggestionCount
    let maxStart = max(0, commandLineCompletionMatches.count - windowSize)
    let start = min(
      max(0, commandLineCompletionSelectedIndex - windowSize / 2), maxStart)
    let end = min(commandLineCompletionMatches.count, start + windowSize)
    return commandLineCompletionMatches[start..<end].enumerated().map { offset, match in
      CandidateDisplayItem(
        title: match.completion.label,
        highlightedRanges: commandLineCompletionQuery.isEmpty
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: commandLineCompletionQuery, candidate: match.completion.label),
        isSelected: start + offset == commandLineCompletionSelectedIndex)
    }
  }

  private func clearCommandLineCompletionState() {
    commandLineCompletionPrefix = ""
    commandLineCompletionItems = []
    commandLineCompletionMatches = []
    commandLineCompletionSelectedIndex = 0
    commandLineCompletionQuery = ""
  }

  static func commandLineBuffer(from raw: String) -> String {
    raw.hasPrefix(":") ? raw : ":\(raw)"
  }

  private func updateCandidateMatches(query: String) {
    let t0 = CFAbsoluteTimeGetCurrent()
    // `@<source>` / `--<source>` selectors (e.g. `:flashlight @tmux @slack
    // test`) pin the pool to those sources; they may appear anywhere and
    // several widen the pool (OR). The residual text is the actual search
    // query. Selectors are only honored outside emoji mode and outside
    // bang mode.
    let sourceCompletion = CandidateFinder.sourceCompletionState(
      query: query,
      emojiMode: candidateFinderEmojiMode)
    let bangCompletion = CandidateFinder.bangCompletionState(
      query: query,
      emojiMode: candidateFinderEmojiMode)
    let parsed =
      sourceCompletion == nil
      ? NormalModeDispatcher.candidateFinderSourceFilter(query)
      : NormalModeDispatcher.CandidateFinderQuery(
        sourceFilters: [], attributeFilters: [], text: query)
    let sourceFilters = candidateFinderEmojiMode ? [] : parsed.sourceFilters
    let attributeFilters: [CandidateFinder.CompiledAttributeFilter]
    if candidateFinderEmojiMode {
      attributeFilters = []
    } else {
      attributeFilters = parsed.attributeFilters.map { raw in
        CandidateFinder.CompiledAttributeFilter.parse(field: raw.field, pattern: raw.pattern)
      }
    }
    let trimmed = parsed.text
    candidateFinderCurrentQuery = sourceCompletion?.token ?? trimmed

    let (pool, scoringText) = buildCandidateFinderPool(
      trimmed: trimmed,
      sourceFilters: sourceFilters,
      attributeFilters: attributeFilters)
    let tFiltered = CFAbsoluteTimeGetCurrent()

    // Bump the generation so any scoring job that completes AFTER
    // this keystroke is dropped silently when its callback fires.
    candidateFinderIndexGenerationCounter &+= 1
    let generation = candidateFinderIndexGenerationCounter
    let isEmojiMode = candidateFinderEmojiMode

    if isEmojiMode {
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scoringText)
      let sorted = CandidateFinder.emojiMatches(
        pool: pool,
        normalizedQuery: normalizedQuery,
        limit: Self.instantEmojiResultLimit)
      applyCandidateMatches(sorted)
      return
    }

    if sourceCompletion != nil || bangCompletion != nil || CandidateFinder.parseBang(trimmed) != nil
    {
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scoringText)
      let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
      let scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalizedQuery,
        fuzzyScore: fuzzy,
        allowParallel: false)
      let sorted = CandidateFinder.sortedMatches(scored, precedence: precedenceTable())
      applyCandidateMatches(sorted)
      return
    }

    // Score on the dedicated background queue so the keystroke
    // returns immediately. The caller (refreshCommandLine /
    // refreshCandidateFinder) re-renders its surface with the
    // previous match snapshot; the async callback rerenders again
    // when fresh results land. Generation check drops late results.
    Self.scoringQueue.async { [weak self] in
      guard let self else { return }
      // Drop stale work before any scoring runs. The generation
      // counter is bumped on the main thread, so by the time this
      // closure starts a later keystroke may already supersede it.
      // The old check inside the main-dispatched callback would let
      // the full scoring + sort run before throwing the result away.
      guard generation == self.candidateFinderIndexGenerationCounter else { return }
      let tScoringStart = CFAbsoluteTimeGetCurrent()
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scoringText)
      let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
      var scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalizedQuery,
        fuzzyScore: fuzzy,
        allowParallel: !isEmojiMode)
      let tScored = CFAbsoluteTimeGetCurrent()
      // Apply frecency boost on the same thread before the sort so
      // the comparator sees the final score; reading the store's
      // O(1) snapshot is safe off main. Skip the loop entirely when
      // the store has no entries — the boost is always 0 in that
      // case and `FrecencyMapper.itemKey` does a non-trivial amount
      // of per-candidate work that's pure waste here.
      let store = self.frecencyStore
      if !isEmojiMode, let store, !store.isEmpty {
        for index in scored.indices {
          if let key = FrecencyMapper.itemKey(for: scored[index].candidate) {
            scored[index].score += store.boost(forKey: key)
          }
        }
      }
      let sorted = CandidateFinder.sortedMatches(scored, precedence: self.precedenceTable())
      let tSorted = CFAbsoluteTimeGetCurrent()
      DispatchQueue.main.async {
        guard generation == self.candidateFinderIndexGenerationCounter else { return }
        self.applyCandidateMatches(sorted)
        self.rerenderCandidateFinderSurface(query: query)
        // `<cmd+cr>` on a source-completion row sets this flag so we
        // open the top filtered candidate as soon as the rescoring
        // settles. Consume one-shot so a later keystroke can't
        // accidentally trigger an open.
        if self.pendingFlashlightSubmitAfterSourceLock {
          self.pendingFlashlightSubmitAfterSourceLock = false
          self.openTopCandidateFinderMatchAfterSourceLock()
        }
        if !trimmed.isEmpty {
          let tRendered = CFAbsoluteTimeGetCurrent()
          let top = sorted.prefix(5).map { match in
            "\(match.candidate.source):\(match.candidate.name)=\(match.score)"
          }.joined(separator: "|")
          let dFilter = Int((tFiltered - t0) * 1000)
          let dScore = Int((tScored - tScoringStart) * 1000)
          let dSort = Int((tSorted - tScored) * 1000)
          let dRender = Int((tRendered - tSorted) * 1000)
          let dTotal = Int((tRendered - t0) * 1000)
          FlashLog.trace(
            "[candidate_finder] q=\"\(trimmed)\" pool=\(pool.count) "
              + "matches=\(sorted.count) "
              + "total_ms=\(dTotal) filter_ms=\(dFilter) score_ms=\(dScore) "
              + "sort_ms=\(dSort) render_ms=\(dRender) "
              + "top5=[\(top)]")
        }
      }
    }
  }

  /// Open the top non-completion candidate after the user locked in
  /// a source filter with `<cmd+cr>`. Skips bang + source rows so a
  /// stale completion row at the top doesn't get "opened" as a no-op.
  private func openTopCandidateFinderMatchAfterSourceLock() {
    for match in candidateFinderMatches {
      let kind = match.candidate.kind
      if kind == CandidateFinder.bangKind || kind == CandidateFinder.sourceKind {
        continue
      }
      finishCommandLineInteraction(reason: "command_open_after_source_lock")
      openSourceItem(match.candidate)
      return
    }
  }

  /// Single queue for the per-keystroke fuzzy scoring + sort. Kept
  /// static so it lives across `updateCandidateMatches` calls without
  /// being recreated; `userInitiated` keeps it ahead of background
  /// utility work but never preempts the main thread.
  private static let scoringQueue = DispatchQueue(
    label: "flash.candidate.scoring", qos: .userInitiated)
  /// The emoji picker only renders five rows, but keeping a wider
  /// slice preserves a short arrow-navigation buffer without sorting
  /// or retaining the full emoji pool on every keystroke.
  private static let instantEmojiResultLimit = 64

  /// Build a `PrecedenceTable` from the live config. Called once per
  /// keystroke (the table is cheap to materialise — `[String: Int]`
  /// of ~a dozen entries) so config edits take effect on the next
  /// search without needing a process-level cache.
  private func precedenceTable() -> CandidateFinder.PrecedenceTable {
    CandidateFinder.PrecedenceTable(
      weights: config.flashlight.precedence,
      aliveBonus: config.flashlight.precedenceAliveBonus)
  }

  /// Re-render the active candidate-finder surface (command-line
  /// flashlight prompt OR the dedicated `.candidateFinder` modal) with
  /// the current `candidateFinderMatches`. Called from the async
  /// scoring callback so a late-arriving result replaces the stale
  /// suggestion list without a full `refreshCommandLine` re-parse.
  private func rerenderCandidateFinderSurface(query: String) {
    switch overlay.inputMode {
    case .commandLine:
      // Skip when the user has already left the flashlight surface
      // (mode jumped to normal / hints / modal). The async result is
      // for a surface that no longer exists.
      guard
        NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil
      else { return }
      overlay.displayCommandLine(
        overlay.commandLineText,
        suggestions: candidateFinderDisplayItems(),
        cursorIndex: overlay.commandLineCursorIndex)
    case .candidateFinder:
      overlay.displayCandidateFinder(
        query: query, items: candidateFinderDisplayItems())
    case .hints, .normal, .modal:
      return
    }
  }

  /// Set `candidateFinderMatches` and clamp the selected index.
  /// Centralised so the SearchService completion and the disabled-
  /// mode fallback can't drift on the selection-bounds rules.
  private func applyCandidateMatches(_ matches: [CandidateMatch]) {
    candidateFinderMatches = matches
    if matches.isEmpty {
      candidateFinderSelectedIndex = 0
    } else {
      candidateFinderSelectedIndex = min(
        max(candidateFinderSelectedIndex, 0), matches.count - 1)
    }
  }

  /// Pick the candidate pool and the text we score against. Two cases:
  ///
  ///   * Default mode — the regular pool (apps, tmux, browser tabs, …)
  ///     filtered by emoji-mode kind + any `@source`/`--source`
  ///     selectors, scored on the full query.
  ///   * Bang mode (query starts with `!`) — the pool is **only** the
  ///     registered plugin bangs, scored on the token typed after `!`.
  ///     Nothing else competes for the list so the user can browse the
  ///     bang registry without app rows piling up.
  private func buildCandidateFinderPool(
    trimmed: String,
    sourceFilters: [String],
    attributeFilters: [CandidateFinder.CompiledAttributeFilter]
  ) -> (pool: [Candidate], scoringText: String) {
    if !candidateFinderEmojiMode, let bang = CandidateFinder.parseBang(trimmed) {
      let bangs = CandidateFinder.prepare(
        pluginManager.shebangCandidates(
          forBundleID: currentNonFlashContext()?.bundleIdentifier))
      return (bangs, bang.token)
    }
    if let bang = CandidateFinder.bangCompletionState(
      query: trimmed,
      emojiMode: candidateFinderEmojiMode)
    {
      let bangs = CandidateFinder.prepare(
        pluginManager.shebangCandidates(
          forBundleID: currentNonFlashContext()?.bundleIdentifier))
      return (bangs, bang.token)
    }
    // `@<partial>` completion: when the user is in the middle of
    // typing a source token (no trailing whitespace yet), swap the
    // pool for source-completion rows derived from the candidates
    // actually present. This mirrors the bang-completion surface so
    // `<tab>`/`<cr>` semantics stay identical across both modes.
    if let completion = CandidateFinder.sourceCompletionState(
      query: trimmed,
      emojiMode: candidateFinderEmojiMode)
    {
      let pool = CandidateFinder.prepare(
        knownSourceCompletionCandidates())
      return (pool, completion.token)
    }
    // Cache the kind+sourceFilter+attributeFilter pass — while the
    // user types into flashlight the signature is stable, so the same
    // ~2k-entry filter ran ~2k times on every keystroke. Keyed by the
    // base-pool epoch + emoji mode + filter signature; one-slot cache
    // because consecutive keystrokes always share the same key.
    let signature = poolFilterSignature(
      sourceFilters: sourceFilters, attributeFilters: attributeFilters)
    if let cached = candidateFinderFilteredPoolCache,
      cached.epoch == candidateFinderCandidatesEpoch,
      cached.emojiMode == candidateFinderEmojiMode,
      cached.signature == signature
    {
      return (cached.pool, trimmed)
    }
    let pool = candidateFinderCandidates.filter { candidate in
      let kindMatches =
        candidateFinderEmojiMode
        ? candidate.kind == CandidateFinder.emojiKind
        : candidate.kind != CandidateFinder.emojiKind
          && candidate.kind != CandidateFinder.bangKind
          && candidate.kind != CandidateFinder.sourceKind
      guard kindMatches else { return false }
      if !sourceFilters.isEmpty {
        let any = sourceFilters.contains {
          CandidateFinder.candidateMatchesSourceFilter(candidate, filter: $0)
        }
        guard any else { return false }
      }
      return true
    }
    let attributeFiltered = CandidateFinder.applyAttributeFilters(
      pool, filters: attributeFilters)
    candidateFinderFilteredPoolCache = (
      epoch: candidateFinderCandidatesEpoch,
      emojiMode: candidateFinderEmojiMode,
      signature: signature,
      pool: attributeFiltered)
    return (attributeFiltered, trimmed)
  }

  /// Stable cache key for the current pool-filter inputs. Source
  /// selectors come from a user-typed token list (`@tmux @apps`); the
  /// attribute filters compare field+kind+needle. Joining them into a
  /// short string is cheap enough that the cache key is faster to
  /// build than even one short filter pass.
  private func poolFilterSignature(
    sourceFilters: [String],
    attributeFilters: [CandidateFinder.CompiledAttributeFilter]
  ) -> String {
    var parts: [String] = []
    parts.reserveCapacity(sourceFilters.count + attributeFilters.count)
    for filter in sourceFilters {
      parts.append("s:\(filter)")
    }
    for filter in attributeFilters {
      parts.append("a:\(filter.field):\(filter.kind):\(filter.needle)")
    }
    return parts.joined(separator: "|")
  }

  /// Build one `@<source>` completion row per distinct source label
  /// present in the live candidate pool. Cached by snapshot identity
  /// so the same array gets reused while the user is still typing.
  private func knownSourceCompletionCandidates() -> [Candidate] {
    var seen = Set<String>()
    var out: [Candidate] = []
    for candidate in candidateFinderCandidates {
      let label = candidate.source
      guard !label.isEmpty, !seen.contains(label) else { continue }
      seen.insert(label)
      out.append(CandidateFinder.sourceCompletionCandidate(label))
    }
    // Stable display order: alphabetical by source label. The fuzzy
    // scorer drives the live ranking once the user types a partial.
    out.sort { $0.sourcePayload ?? "" < $1.sourcePayload ?? "" }
    return out
  }

  /// Dispatch a selected bang row: route the live query's remainder to the
  /// owning plugin via `invokeShebang`. Returns false for non-bang
  /// candidates so callers fall through to the normal open path.
  func dispatchBangCandidate(_ candidate: Candidate, query: String) -> Bool {
    guard candidate.kind == CandidateFinder.bangKind,
      let token = candidate.sourcePayload, !token.isEmpty
    else { return false }
    let remainder: String
    if let bang = CandidateFinder.parseBang(query),
      bang.token.lowercased() == token.lowercased()
    {
      remainder = bang.remainder
    } else {
      remainder = ""
    }
    return pluginManager.invokeShebang(
      token: token,
      query: remainder,
      forBundleID: currentNonFlashContext()?.bundleIdentifier
    ) { [weak self] ok, pid, stdout in
      guard ok, let self else { return }
      self.activatePluginCommandTarget(pid)
      guard let stdout, !stdout.isEmpty else { return }
      self.overlay.displayBanner(stdout)
    }
  }

  func candidateFinderDisplayItems(windowSize: Int? = nil) -> [CandidateDisplayItem] {
    guard !candidateFinderMatches.isEmpty else { return [] }
    let windowSize = windowSize ?? commandBarSuggestionCount
    let maxStart = max(0, candidateFinderMatches.count - windowSize)
    let start = min(max(0, candidateFinderSelectedIndex - windowSize / 2), maxStart)
    let end = min(candidateFinderMatches.count, start + windowSize)
    return candidateFinderMatches[start..<end].enumerated().map { offset, match in
      let title =
        match.candidate.displayTitle.isEmpty
        ? candidateFinderDisplayTitle(match.candidate) : match.candidate.displayTitle
      return CandidateDisplayItem(
        title: title,
        highlightedRanges: candidateFinderCurrentQuery.isEmpty
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: candidateFinderCurrentQuery,
            candidate: title),
        isSelected: start + offset == candidateFinderSelectedIndex)
    }
  }

  private func candidateFinderDisplayTitle(_ candidate: Candidate) -> String {
    CandidateFinder.displayTitle(candidate)
  }

  static func candidateFinderDisplayTitle(source: String, title: String) -> String {
    CandidateFinder.displayTitle(source: source, name: title)
  }

  func submitCommandLine(_ rawInput: String) {
    // `#` output-capture modifier (`:#aws whoami`): strip it up front so all
    // downstream parsing sees a clean command line, and remember to route the
    // command's stdout onto the clipboard rather than just a toast.
    let (raw, captureOutput) =
      NormalModeDispatcher.commandLineClipboardModifier(rawInput)
    // Record the verb against the frecency store so the empty-`:`
    // completion list surfaces what the user actually runs. We record
    // before dispatch so even an unknown command (typo or
    // half-finished plugin install) still gets a frequency mark — the
    // user's intent is what matters; the cost of a bad mark is bounded
    // by the same decay all other frecency entries pay.
    recordCommandLineFrecency(rawInput: raw)
    // `:open <args>` is a dumb forward to `/usr/bin/open` — no app-finding
    // smarts (that lives in `:flashlight`). Caught first so it never falls
    // into the candidate-finder or command-spec paths.
    if let argv = NormalModeDispatcher.commandLineOpenForward(raw) {
      finishCommandLineInteraction(reason: "open_forward")
      NormalModeDispatcher.runOpen(argv)
      return
    }
    if NormalModeDispatcher.commandLineCandidateQuery(raw) != nil {
      submitSelectedCommandLineApp()
      return
    }
    // Selected sub-command completions (`:help con` → `:help config`)
    // take precedence over the raw text. Without this, the raw form
    // gets parsed as `:help con` and the user sees "con not found"
    // even though `config` was visibly highlighted. `applySelected…`
    // clears the completion state before recursing, so the recursive
    // call falls through to the normal command / help parser without
    // looping.
    if !commandLineCompletionMatches.isEmpty,
      commandLineCompletionMatchesAreSubCommand,
      applySelectedCommandLineCompletion()
    {
      return
    }
    if let helpTopic = NormalModeDispatcher.commandLineHelpTopic(raw) {
      finishCommandLineInteraction(reason: "help_submit")
      showHelp(topic: helpTopic)
      return
    }
    if let command = NormalModeDispatcher.commandLineCommand(raw) {
      finishCommandLineInteraction(reason: "command_submit")
      performCommandLineCommand(command)
      return
    }
    // Bare `:clipboard` opens the dedicated history modal rather than firing
    // a fire-and-forget plugin command; the host fetches the history and
    // renders the list itself. `:clipboard <arg>` falls through below.
    if let plugin = NormalModeDispatcher.pluginCommandLineInvocation(raw),
      plugin.command.lowercased() == "clipboard", plugin.subcommand.isEmpty, plugin.args.isEmpty
    {
      finishCommandLineInteraction(reason: "clipboard_submit")
      openClipboardModal()
      return
    }
    if let plugin = NormalModeDispatcher.pluginCommandLineInvocation(raw),
      pluginManager.invoke(
        command: plugin.command,
        subcommand: plugin.subcommand,
        args: plugin.args,
        raw: plugin.raw,
        forBundleID: currentNonFlashContext()?.bundleIdentifier,
        onResult: { [weak self] ok, pid, stdout in
          guard ok else { return }
          self?.activatePluginCommandTarget(pid)
          guard let stdout, !stdout.isEmpty else { return }
          if captureOutput {
            NormalModeDispatcher.copy(stdout)
            self?.overlay.displayBanner("Copied: \(stdout)")
          } else {
            self?.overlay.displayBanner(stdout)
          }
        })
    {
      finishCommandLineInteraction(reason: "plugin_command_submit")
      return
    }
    let topLevelEmpty =
      commandLineCompletionPrefix == ":" && commandLineCompletionQuery.isEmpty
    if !commandLineCompletionMatches.isEmpty,
      !topLevelEmpty,
      applySelectedCommandLineCompletion()
    {
      return
    }
    FlashLog.debug("[normal_mode] unknown command \(raw)")
    finishCommandLineInteraction(reason: "command_unknown")
  }

  /// True when the active completion list is for a **sub-command**
  /// (`:help <topic>`, `:plugins <sub>`, `:<plugin> <action>`) rather
  /// than the top-level command list. Top-level completions are
  /// suggestions for the bare verb (`:q<cr>` shouldn't expand to
  /// `:quit` just because `quit` happens to be selected); sub-command
  /// completions are what the user is actively narrowing.
  private var commandLineCompletionMatchesAreSubCommand: Bool {
    let prefix = commandLineCompletionPrefix
    return prefix.count > 1 && prefix.hasSuffix(" ")
  }

  private func performCommandLineCommand(_ command: NormalModeDispatcher.CommandLineCommand) {
    switch command {
    case .quit(let force):
      performMappedCommand(.quitApp(force: force))
    case .save:
      performMappedCommand(.save)
    case .saveAndQuit(let force):
      performMappedCommand(.saveAndQuit(force: force))
    case .print:
      performMappedCommand(.print)
    case .open:
      performMappedCommand(.openDocument)
    case .newWindow:
      performMappedCommand(.newWindow)
    case .newTab:
      performMappedCommand(.tabNew)
    case .close:
      performMappedCommand(.close)
    case .find:
      performMappedCommand(.find)
    case .undo:
      performMappedCommand(.undo)
    case .redo:
      performMappedCommand(.redo)
    case .copy:
      performMappedCommand(.copy)
    case .cut:
      performMappedCommand(.cut)
    case .paste:
      performMappedCommand(.paste)
    case .plugins(let sub):
      runPluginsSubcommand(sub)
    case .mappings:
      showMappings()
    case .help(let topic):
      showHelp(topic: topic)
    }
  }

  private func applySelectedCommandLineCompletion() -> Bool {
    guard !commandLineCompletionMatches.isEmpty else { return false }
    let index = min(
      commandLineCompletionSelectedIndex, commandLineCompletionMatches.count - 1)
    let match = commandLineCompletionMatches[index]
    let completion = match.completion
    let prefix = commandLineCompletionPrefix
    let newBuffer = prefix + completion.insertion
    switch completion.kind {
    case .acceptsArgs:
      refreshCommandLine(text: newBuffer, cursorIndex: newBuffer.count)
      return true
    case .terminal, .pluginSubcommand:
      clearCommandLineCompletionState()
      submitCommandLine(newBuffer)
      return true
    }
  }

  /// Insert the selected completion's **value** (`insertion`) into the
  /// command line without submitting — the `<tab>` half of the
  /// candidate contract. The visible `label` is purely cosmetic; what
  /// lands in the buffer is always the value. Returns false when no
  /// completion list is active so the caller can fall back to selection
  /// movement (the candidate finder keeps its documented tab-to-cycle).
  func applySelectedCommandLineCompletionInPlace() -> Bool {
    guard !commandLineCompletionMatches.isEmpty else { return false }
    let index = min(
      commandLineCompletionSelectedIndex, commandLineCompletionMatches.count - 1)
    let completion = commandLineCompletionMatches[index].completion
    let newBuffer = commandLineCompletionPrefix + completion.insertion
    refreshCommandLine(text: newBuffer, cursorIndex: newBuffer.count)
    return true
  }

  private func submitSelectedCommandLineApp() {
    actOnSelectedCandidateFinderCandidate(submit: false, submitExactBang: true)
  }

  /// Single act-on-selection entry point for the flashlight surface.
  /// `<cr>` and `<tab>` call with `submit=false` (insert-only — for
  /// bangs this puts `!<token> ` in the buffer so the user keeps
  /// typing; for everything else this opens the candidate). `<cmd+cr>`
  /// calls with `submit=true` (for bangs this dispatches with whatever
  /// remainder was typed; for everything else identical to `<cr>`).
  func actOnSelectedCandidateFinderCandidate(submit: Bool) {
    actOnSelectedCandidateFinderCandidate(submit: submit, submitExactBang: false)
  }

  /// `submitExactBang` is the plain-Return path: an exact typed bang
  /// (`!googlemaps`) should dispatch, while a partial selected bang
  /// (`!goo` on the `googlemaps` row) still canonicalizes first.
  private func actOnSelectedCandidateFinderCandidate(submit: Bool, submitExactBang: Bool) {
    let typedBang = CandidateFinder.parseBang(candidateFinderCurrentQuery)
    let isEmpty = candidateFinderMatches.isEmpty

    if isEmpty {
      if let typed = typedBang {
        submitTypedBang(typed: typed)
      } else {
        finishCommandLineInteraction(reason: "command_open_empty")
      }
      return
    }

    let candidate = candidateFinderMatches[min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)]
      .candidate
    if candidate.kind == CandidateFinder.bangKind,
      let token = candidate.sourcePayload
    {
      if submit
        || (submitExactBang
          && CandidateFinder.selectedBangMatchesTypedToken(
            query: candidateFinderCurrentQuery,
            selectedToken: token))
      {
        submitTypedBang(typed: (token: token, remainder: typedBang?.remainder ?? ""))
        return
      }
      // `<cr>`/`<tab>` on a bang row with matches: canonicalize the
      // buffer to `:flashlight !<token> ` so the cursor sits ready for
      // the query. The selection is the authority — we don't preserve
      // any partial token the user typed.
      let buffer = ":flashlight !\(token) "
      refreshCommandLine(text: buffer, cursorIndex: buffer.count)
      return
    }
    if candidate.kind == CandidateFinder.sourceKind,
      let source = candidate.sourcePayload
    {
      // Source-completion row. Rewrite the in-progress `@<partial>`
      // token in the buffer with the canonical `@<source> ` so the
      // existing source-filter parser applies it to the next refresh,
      // and the cursor sits ready for the query.
      //   * `<tab>`/`<cr>` (`submit == false`): canonicalize + stop —
      //     same shape as Tab/CR on a bang row with matches.
      //   * `<cmd+cr>` (`submit == true`): canonicalize, then open
      //     the top filtered candidate once the async rescoring
      //     settles — same shape as Cmd+CR on a bang dispatching the
      //     typed remainder. The `pendingFlashlightSubmitAfterSourceLock`
      //     flag is consumed by the rerender callback in
      //     `updateCandidateMatches`.
      if submit {
        pendingFlashlightSubmitAfterSourceLock = true
      }
      replaceInProgressAtSourceToken(with: source)
      return
    }
    finishCommandLineInteraction(reason: "command_open")
    openSourceItem(candidate)
  }

  /// Rewrite the trailing `@<partial>` token inside the live command
  /// line with `@<source> ` and re-render. Called by Tab/CR/Cmd+CR on
  /// a source-completion row so the user sees the canonical filter
  /// appear without leaving the surface.
  private func replaceInProgressAtSourceToken(with source: String) {
    let command = overlay.commandLineText
    guard let query = NormalModeDispatcher.commandLineCandidateQuery(command),
      let completion = CandidateFinder.parseAtSourceCompletion(query)
    else { return }
    // Map the `query`-relative @ range into the absolute command buffer
    // (the prompt + verb prefix the user can't see in `query`).
    let prefixLen = command.count - query.count
    let queryStart = command.index(command.startIndex, offsetBy: prefixLen)
    let atOffset = query.distance(from: query.startIndex, to: completion.atRange.lowerBound)
    let endOffset = query.distance(from: query.startIndex, to: completion.atRange.upperBound)
    let absoluteStart = command.index(queryStart, offsetBy: atOffset)
    let absoluteEnd = command.index(queryStart, offsetBy: endOffset)
    let replacement = "@\(source) "
    let buffer = command.replacingCharacters(in: absoluteStart..<absoluteEnd, with: replacement)
    let newCursor = command.distance(from: command.startIndex, to: absoluteStart) + replacement.count
    refreshCommandLine(text: buffer, cursorIndex: newCursor)
  }

  /// `<cmd+cr>` in bang mode. Dispatches whatever the user typed via
  /// `PluginManager.invokeShebang`, which checks explicit-token
  /// registrations first then falls back to the catch-all (so
  /// `!google rust` reaches searchengines even though `google` isn't
  /// declared in any plugin's manifest). If a candidate row is
  /// selected AND its token equals the typed token, we still go
  /// through `invokeShebang` — its lookup is the same — so this path
  /// is unified.
  private func submitTypedBang(typed: (token: String, remainder: String)) {
    let dispatched = pluginManager.invokeShebang(
      token: typed.token,
      query: typed.remainder,
      forBundleID: currentNonFlashContext()?.bundleIdentifier
    ) { [weak self] ok, pid, stdout in
      guard ok, let self else { return }
      self.activatePluginCommandTarget(pid)
      guard let stdout, !stdout.isEmpty else { return }
      self.overlay.displayBanner(stdout)
    }
    if !dispatched {
      FlashLog.warn("[normal_mode] no plugin claimed bang !\(typed.token)")
    }
    finishCommandLineInteraction(reason: "command_bang_submit")
  }

  func finishCommandLineInteraction(reason: String) {
    overlay.hide()
    resetCommandLineState()
    transitionMode(to: Self.commandLineExitMode(currentMode: flashMode), reason: reason)
  }

  func resetCommandLineState() {
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    overlay.candidateFinderQuery = ""
    candidateFinderScope = .all
    clearCandidateFinderState()
    clearCommandLineCompletionState()
  }

  func clearCandidateFinderState() {
    overlay.candidateFinderQuery = ""
    candidateFinderCandidates = []
    candidateFinderMatches = []
    candidateFinderSelectedIndex = 0
    candidateFinderCurrentQuery = ""
    candidateFinderEmojiMode = false
  }

  private func quitNormalModeTargetApp(force: Bool = false) {
    guard let context = normalModeContext(),
      let app = NSRunningApplication(processIdentifier: context.processID)
    else {
      FlashLog.debug("[normal_mode] no target app for :quit")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[normal_mode] quit pid=\(context.processID) bundle=\(context.bundleIdentifier) "
        + "force=\(force)"
    )
    if force {
      _ = app.forceTerminate()
    } else {
      _ = app.terminate()
    }
    normalModeTargetPID = nil
    applyModeOverlay()
  }

  private func scrollNormalMode(
    _ kind: NormalModeDispatcher.ScrollKind,
    repeatCount: Int = 1
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for \(kind)")
      applyModeOverlay()
      return
    }
    // gg/G: try a `scrollExtremes` source first (e.g. the tmux plugin
    // runs `tmux send-keys -X history-top` / `-X cancel`, which moves
    // *inside* the live buffer rather than blasting wheel ticks at a
    // pane that's already at the bottom). Falls through to the
    // hermetic Scroller path when no source claims it.
    if kind == .top || kind == .bottom {
      performScrollExtreme(kind, context: context, repeatCount: repeatCount)
      return
    }
    var didScroll = false
    for _ in 0..<normalizedRepeatCount(repeatCount) {
      if NormalModeDispatcher.scroll(
        kind,
        pid: context.processID,
        bundleID: context.bundleIdentifier,
        windowFrame: context.frontWindowFrame)
      {
        didScroll = true
      }
    }
    if didScroll {
      monitor.invalidateAfterUserAction(pid: context.processID, reason: "normal_scroll")
    }
    applyModeOverlay()
  }

  private func performScrollExtreme(
    _ kind: NormalModeDispatcher.ScrollKind,
    context: AppContext,
    repeatCount: Int
  ) {
    let registry: SourceRegistry = self.registry
    let bundleID = context.bundleIdentifier
    let pid = context.processID
    let windowFrame = context.frontWindowFrame
    let normalized = normalizedRepeatCount(repeatCount)
    let monitor: AppMonitor = self.monitor
    let completion: (SourceActionResult) -> Void = { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll_extreme")
        self.applyModeOverlay()
      case .failed:
        // Source claimed but the underlying command failed — don't
        // double-fire with the Scroller wheel fallback (it would just
        // confuse the user with extra motion). Surface and stop.
        FlashLog.debug("[normal_mode] scroll_extreme failed kind=\(kind) bundle=\(bundleID)")
        self.applyModeOverlay()
      case .unhandled:
        self.scrollViaScroller(
          kind, pid: pid, bundleID: bundleID, windowFrame: windowFrame, repeats: normalized)
      }
    }
    if kind == .top {
      registry.scrollTop(in: context, completion: completion)
    } else {
      registry.scrollBottom(in: context, completion: completion)
    }
  }

  private func scrollViaScroller(
    _ kind: NormalModeDispatcher.ScrollKind,
    pid: pid_t,
    bundleID: String,
    windowFrame: CGRect?,
    repeats: Int
  ) {
    // gg/G outside a claiming source: in browsers, `cmd+up` /
    // `cmd+down` is the dependable scroll-to-edge gesture (the
    // huge-wheel-delta path only nudges Firefox a viewport at a time).
    // Everything else still goes through the AX scrollbar / wheel
    // hermetic fallback.
    if BrowserTabSources.allBundleIdentifiers.contains(bundleID),
      kind == .top || kind == .bottom
    {
      let key: CGKeyCode =
        kind == .top ? CGKeyCode(kVK_UpArrow) : CGKeyCode(kVK_DownArrow)
      var didScroll = false
      for _ in 0..<repeats {
        if NormalModeDispatcher.sendKey(virtualKey: key, flags: .maskCommand, to: pid) {
          didScroll = true
        }
      }
      if didScroll {
        monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll_browser_edge")
      }
      applyModeOverlay()
      return
    }
    var didScroll = false
    for _ in 0..<repeats {
      if NormalModeDispatcher.scroll(
        kind, pid: pid, bundleID: bundleID, windowFrame: windowFrame)
      {
        didScroll = true
      }
    }
    if didScroll {
      monitor.invalidateAfterUserAction(pid: pid, reason: "normal_scroll")
    }
    applyModeOverlay()
  }

  private func sendNormalModeKey(
    _ key: CGKeyCode,
    flags: CGEventFlags = [],
    repeatCount: Int = 1,
    suppressInTerminalFor command: URLCommand? = nil
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for key \(key)")
      applyModeOverlay()
      return
    }
    if let command,
      Self.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        command,
        bundleIdentifier: context.bundleIdentifier)
    {
      FlashLog.debug(
        "[normal_mode] suppress terminal shortcut command=\(command.diagnosticDescription) "
          + "bundle=\(context.bundleIdentifier)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)
    for index in 0..<count {
      let delay = DispatchTimeInterval.milliseconds(index * 35)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: context.processID)
      }
    }
    let finalDelay = DispatchTimeInterval.milliseconds((count - 1) * 35 + 35)
    DispatchQueue.main.asyncAfter(deadline: .now() + finalDelay) { [weak self] in
      guard let self else { return }
      self.scheduleNormalModeRecapture()
    }
  }

  /// Insert text into the focused app: stash it on the pasteboard and
  /// synthesize Cmd+V into the app that owned focus when the picker was
  /// invoked (an emoji glyph, a clipboard-history entry, …). The overlay
  /// never takes key focus, so the app's text field is still first
  /// responder once we dismiss.
  func insertText(_ text: String) {
    let pid = normalModeContext()?.processID
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay(captureOverride: true)
    guard !text.isEmpty, let pid else { return }
    NormalModeDispatcher.copy(text)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      NormalModeDispatcher.sendKey(
        virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, to: pid)
      self?.scheduleNormalModeRecapture()
    }
  }

  private func navigateTargetHistory(direction: NavigationDirection, repeatCount: Int) {
    let key: CGKeyCode
    switch direction {
    case .back:
      key = CGKeyCode(kVK_ANSI_LeftBracket)
    case .forward:
      key = CGKeyCode(kVK_ANSI_RightBracket)
    }
    sendNormalModeKey(key, flags: .maskCommand, repeatCount: repeatCount)
  }

  private func sendNormalModeKeySequence(_ keys: [(CGKeyCode, CGEventFlags)]) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for key sequence")
      applyModeOverlay()
      return
    }
    for (key, flags) in keys {
      NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: context.processID)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
      self?.scheduleNormalModeRecapture()
    }
  }

  private func tabSelectInNormalMode(index: Int) {
    let index = normalizedRepeatCount(index)
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for tab_select index=\(index)")
      applyModeOverlay()
      return
    }
    if let key = Self.nativeBrowserTabIndexKey(
      index: index,
      bundleIdentifier: context.bundleIdentifier)
    {
      sendNormalModeKey(key, flags: .maskCommand)
      return
    }
    registry.tabSelect(at: index, in: context) { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        if let pid = result.targetPID {
          self.normalModeTargetPID = pid
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        FlashLog.warn(
          "[normal_mode] tab_select failed in claimed source "
            + "bundle=\(context.bundleIdentifier) index=\(index)")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        guard let key = Self.tabIndexKeyCode(index) else {
          FlashLog.debug("[normal_mode] tab_select unsupported index=\(index)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(key, flags: .maskCommand)
      }
    }
  }

  private func tabNextInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_next",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabNext(in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        guard
          let shortcut = Self.tabTraversalFallbackShortcut(
            direction: .forward,
            bundleIdentifier: context.bundleIdentifier)
        else {
          FlashLog.debug(
            "[normal_mode] tab_next unsupported bundle=\(context.bundleIdentifier)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(shortcut.key, flags: shortcut.flags, repeatCount: count)
      })
  }

  private func tabPrevInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_previous",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabPrev(in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        guard
          let shortcut = Self.tabTraversalFallbackShortcut(
            direction: .back,
            bundleIdentifier: context.bundleIdentifier)
        else {
          FlashLog.debug(
            "[normal_mode] tab_previous unsupported bundle=\(context.bundleIdentifier)")
          self.applyModeOverlay()
          return
        }
        self.sendNormalModeKey(shortcut.key, flags: shortcut.flags, repeatCount: count)
      })
  }

  /// Jump to the last tab. Browsers map ⌘9 to "last tab" by convention
  /// (Chrome, Safari, Firefox), so for those bundles the fast path is a
  /// single synthesized ⌘9. Plugin-backed sources expose this through
  /// the `tab_last` source action (the tmux plugin uses `last-window`).
  private func tabLastInNormalMode() {
    performTabSourceAction(
      name: "tab_last",
      repeatCount: 1,
      action: { registry, context, completion in
        registry.tabLast(in: context, completion: completion)
      },
      fallback: { [weak self] context, _ in
        if BrowserTabSources.allBundleIdentifiers.contains(context.bundleIdentifier) {
          self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_9), flags: .maskCommand)
        } else {
          FlashLog.debug(
            "[normal_mode] tab_last unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
        }
      })
  }

  /// Reorder the focused window's current tab. Tmux runs `swap-window`
  /// across the source action; Firefox honours ⌘⇧Page Up/Down to slide
  /// the active tab inside its strip, so the host falls back to that
  /// chord when the plugin layer doesn't claim the action. Browsers
  /// without a portable shortcut (Safari, Chromium today) get a
  /// `warn`-level log naming the bundle so the user knows the mapping
  /// fired but couldn't reach the app — they can bind their own
  /// shortcut and override `[m`/`]m` in flash.toml.
  private func tabMoveInNormalMode(direction: SourceTabDirection, repeatCount: Int) {
    let actionName = direction == .next ? "tab_move_next" : "tab_move_previous"
    performTabSourceAction(
      name: actionName,
      repeatCount: repeatCount,
      action: { registry, context, completion in
        if direction == .next {
          registry.tabMoveNext(in: context, completion: completion)
        } else {
          registry.tabMovePrev(in: context, completion: completion)
        }
      },
      fallback: { [weak self] context, count in
        guard let self else { return }
        if Self.bundleSupportsFirefoxStyleTabMove(context.bundleIdentifier) {
          let key: CGKeyCode = direction == .next
            ? CGKeyCode(kVK_PageDown) : CGKeyCode(kVK_PageUp)
          self.sendNormalModeKey(
            key, flags: [.maskCommand, .maskShift], repeatCount: count)
          return
        }
        FlashLog.warn(
          "[normal_mode] \(actionName) has no native shortcut on "
            + "bundle=\(context.bundleIdentifier); bind via a tab-mover "
            + "extension or override `[m`/`]m` in flash.toml")
        self.applyModeOverlay()
      })
  }

  /// Bundles whose tab strip honours `⌘⇧Page Up / ⌘⇧Page Down` for
  /// moving the focused tab left / right. Firefox (release +
  /// developer edition) is the canonical example; other Mozilla-based
  /// browsers inherit the same chord.
  private static let firefoxStyleTabMoveBundles: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
  ]

  static func bundleSupportsFirefoxStyleTabMove(_ bundleID: String) -> Bool {
    firefoxStyleTabMoveBundles.contains(bundleID)
  }

  /// Reopen the most recently closed tab. Cross-browser standard is
  /// ⌘⇧T; the plugin source action gets first refusal (tmux returns
  /// `.unhandled` because there's no concept of a closed tab to reopen)
  /// so the keystroke fallback only runs in non-terminal contexts that
  /// actually honour the chord.
  private func tabReopenInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_reopen",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabReopen(in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        if BrowserTabSources.allBundleIdentifiers.contains(context.bundleIdentifier) {
          self?.sendNormalModeKey(
            CGKeyCode(kVK_ANSI_T),
            flags: [.maskCommand, .maskShift],
            repeatCount: count)
        } else {
          FlashLog.debug(
            "[normal_mode] tab_reopen unsupported bundle=\(context.bundleIdentifier)")
          self?.applyModeOverlay()
        }
      })
  }

  private func tabNewInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_new",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabNew(in: context, completion: completion)
      },
      fallback: { [weak self] context, count in
        let key = AppDelegate.tabNewFallbackKey(forBundleIdentifier: context.bundleIdentifier)
        self?.sendNormalModeKey(key, flags: .maskCommand, repeatCount: count)
      })
  }

  private func tabCloseInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_close",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabClose(in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: count)
      })
  }

  /// `window_close` inside a terminal hosting tmux must close the *tmux*
  /// window, not the terminal's OS window — sending ⌘W to e.g. Alacritty
  /// quits the whole terminal, yanking the user out of the app and off
  /// their tmux session. Route through the tmux source action (it picks
  /// the next window in the same session itself) and only fall back to
  /// ⌘W for apps no source claims (browsers, native windows).
  private func windowCloseInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "window_close",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabClose(in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: count)
      })
  }

  /// macOS terminals that have no native tabs (only windows). For these
  /// bundles, tab_new / :tabnew fall back to cmd-N so the gesture still
  /// produces a new workspace. tmux is handled by the tmux plugin's
  /// `tab_new` source action one level up — when an attached tmux client
  /// is present, `new-window` runs and this fallback never fires.
  static let tabNewWindowOnlyBundleIdentifiers: Set<String> = [
    "org.alacritty",
    "io.alacritty",
  ]

  static func tabNewFallbackKey(forBundleIdentifier bundleIdentifier: String) -> CGKeyCode {
    if tabNewWindowOnlyBundleIdentifiers.contains(bundleIdentifier) {
      return CGKeyCode(kVK_ANSI_N)
    }
    return CGKeyCode(kVK_ANSI_T)
  }

  private func performTabSourceAction(
    name: String,
    repeatCount: Int,
    action: @escaping (
      SourceRegistry,
      AppContext,
      @escaping (SourceActionResult) -> Void
    ) -> Void,
    fallback: @escaping (AppContext, Int) -> Void
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for \(name)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)

    func attempt(_ remaining: Int) {
      guard remaining > 0 else {
        scheduleNormalModeRecapture()
        return
      }
      action(registry, context) { [weak self] result in
        guard let self else { return }
        switch result.disposition {
        case .performed:
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          attempt(remaining - 1)
        case .failed:
          // A source claimed the action but couldn't complete it. The
          // keystroke fallback must not fire here — see
          // `SourceActionResult.Disposition.failed`.
          FlashLog.warn(
            "[normal_mode] \(name) failed in claimed source bundle=\(context.bundleIdentifier)")
          self.scheduleNormalModeRecapture()
        case .unhandled:
          fallback(context, remaining)
        }
      }
    }

    attempt(count)
  }

  static func nativeBrowserTabIndexKey(index: Int, bundleIdentifier: String) -> CGKeyCode? {
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    return tabIndexKeyCode(index)
  }

  static func tabTraversalFallbackShortcut(
    direction: NavigationDirection,
    bundleIdentifier: String
  ) -> (key: CGKeyCode, flags: CGEventFlags)? {
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    let key: CGKeyCode =
      direction == .forward
      ? CGKeyCode(kVK_ANSI_RightBracket)
      : CGKeyCode(kVK_ANSI_LeftBracket)
    return (key, [.maskCommand, .maskShift])
  }

  private static func tabIndexKeyCode(_ index: Int) -> CGKeyCode? {
    switch index {
    case 1: return CGKeyCode(kVK_ANSI_1)
    case 2: return CGKeyCode(kVK_ANSI_2)
    case 3: return CGKeyCode(kVK_ANSI_3)
    case 4: return CGKeyCode(kVK_ANSI_4)
    case 5: return CGKeyCode(kVK_ANSI_5)
    case 6: return CGKeyCode(kVK_ANSI_6)
    case 7: return CGKeyCode(kVK_ANSI_7)
    case 8: return CGKeyCode(kVK_ANSI_8)
    case 9: return CGKeyCode(kVK_ANSI_9)
    default: return nil
    }
  }

  static func normalModeCommandKeyShortcutIsUnsafeInTerminal(
    _ command: URLCommand,
    bundleIdentifier: String
  ) -> Bool {
    guard TerminalBundles.identifiers.contains(bundleIdentifier) else { return false }
    switch command {
    case .undo, .redo:
      return true
    default:
      return false
    }
  }

  private func copyFocusedDocumentURL() {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for copyDocumentURL")
      return
    }
    guard let url = registry.documentURL(in: context) else {
      FlashLog.debug(
        "[normal_mode] no AX document URL exposed by \(context.bundleIdentifier)")
      return
    }
    NormalModeDispatcher.copy(url)
  }

  func normalModeContext() -> AppContext? {
    if let context = currentNonFlashContext() {
      normalModeTargetPID = context.processID
      return context
    }
    if let pid = normalModeTargetPID,
      let context = monitor.context(for: pid)
    {
      return context
    }
    return nil
  }

  enum NavigationDirection {
    case back
    case forward
  }

  func recordAppActivation(_ pid: pid_t) {
    recordMovement(.app(pid: pid), source: "app_activation")
    recordAppMRU(pid)
  }

  /// Raise the app a plugin command asked Flash to bring forward (e.g.
  /// the terminal hosting the tmux session a `:tmux window …` mapping
  /// just switched to). Activation fires `didActivateApplication`, which
  /// records the jump into the movement history — so `ctrl-o`/`ctrl-i`
  /// replay tmux jumps the same as any other Flash navigation.
  func activatePluginCommandTarget(_ pid: pid_t?) {
    guard let pid,
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated
    else { return }
    RunningApplicationActivation.activate(app, options: [.activateAllWindows])
    if flashMode == .normal {
      normalModeTargetPID = pid
      suppressEditableFocus(for: pid)
    }
    scheduleNormalModeRecapture()
  }

  private func recordAppMRU(_ pid: pid_t) {
    if appNavigationTargetPID == pid {
      appNavigationTargetPID = nil
      appCurrent = pid
      return
    }
    if let current = appCurrent, current == pid { return }
    if let current = appCurrent {
      if appBackStack.last != current {
        appBackStack.append(current)
      }
    }
    appCurrent = pid
    appForwardStack.removeAll(keepingCapacity: true)
  }

}

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
      if overlay.inputMode == .commandLine || overlay.inputMode == .candidateFinder
        || overlay.inputMode == .modal
      {
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
    transitionMode(to: .insert, reason: reason.logValue, lockInsert: reason.locksInsertMode)
  }

  private func transitionMode(
    to nextMode: FlashMode,
    reason: String,
    lockInsert: Bool = false
  ) {
    let previousMode = flashMode
    insertFocusExitProbeToken &+= 1
    insertEditableFocusRepairToken &+= 1
    insertFocusOwnerPID = nil
    insertEditableFocusExitPID = nil
    insertNavigationExitToken &+= 1
    normalModePendingCommandToken &+= 1
    insertModeLockedUntilExplicitNormal = nextMode == .insert && lockInsert
    contextMenuInteractionRecaptureSuppressedUntil = nil
    cancelPointerInsertHandoff(reason: "mode_transition_\(nextMode)_\(reason)")
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
    }
    applyModeOverlay()
    scheduleNormalModeRecapture()
  }

  private func modeDidEnterInsert(reason: String) {
    let insertTarget = currentNonFlashContext()
    let panelKeyAtEntry = overlay.isKeyWindow
    insertFocusOwnerPID = insertTarget?.processID
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
    if !insertModeLockedUntilExplicitNormal {
      repairSingleStrongEditableFocusIfNeeded(target: insertTarget, reason: reason)
      armEditableFocusExitIfNeeded(target: insertTarget, reason: reason)
    }
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
    // The focused-window-changed and main-window-changed AX notifications are
    // exactly the signal plugins want to react to when they care about *which*
    // window inside an app is on top (e.g. an iTerm/Alacritty plugin watching
    // tmux clients move between attached terminals). The generic
    // `core:ax.changed` fires for any AX mutation, so it's too noisy for that
    // use case; this dedicated event carries the focused window's frame and
    // pid so subscribers can filter on it directly.
    if notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
    {
      var payload: [String: Any] = [
        "pid": Int(pid),
        "bundle_id": context.bundleIdentifier,
      ]
      let frame = context.frontWindowFrame
      payload["front_window_frame"] = [
        "x": Double(frame.origin.x),
        "y": Double(frame.origin.y),
        "width": Double(frame.size.width),
        "height": Double(frame.size.height),
      ]
      pluginManager.emit(
        PluginEvent(
          name: "core:window.focus.changed",
          payload: payload,
          bundleID: context.bundleIdentifier,
          configPath: nil,
          focused: true,
          frontWindowFrame: context.frontWindowFrame,
          pid: pid))
    }
    beginTrackedWindowGeometryChange(reason: notification, frame: context.frontWindowFrame)
  }

  func modeWillBeginWindowGeometryChange(reason: String) {
    windowGeometryChangeInProgress = true
    FlashLog.trace("[mode] window_geometry_begin mode=\(flashMode) reason=\(reason)")
    switch flashMode {
    case .insert:
      overlay.setActiveWindowBorder(around: nil)
    case .normal:
      break
    }
  }

  func modeDidEndWindowGeometryChange(reason: String) {
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

  static func normalModeMayEnterInsert(reason: InsertModeTransitionReason) -> Bool {
    // `.explicitCommand` joins the user-driven set because mapped-key
    // actions like `/` (app_find) and `t` (tab_new) follow a sendKey →
    // enterInsertMode pattern: the user just pressed a normal-mode key
    // and the intent is "open something and start typing". Holding the
    // gate against `.explicitCommand` left those mappings stuck in
    // NORMAL after the side-effect fired, so typing went to the empty
    // search bar / new tab via the system, then nothing.
    reason == .hintCommit || reason == .normalModeInput || reason == .lockedNormalModeInput
      || reason == .pointerClick || reason == .explicitCommand
  }

  func focusedInputMayHaveChanged(pid: pid_t) {
    guard modeBadgeEnabled, flashMode == .insert, !insertModeLockedUntilExplicitNormal else {
      return
    }
    let focusedPID = currentNonFlashContext()?.processID
    if Self.insertModeShouldExitAfterFocusedAppChange(
      mode: flashMode,
      modeBadgeEnabled: modeBadgeEnabled,
      overlayInputMode: overlay.inputMode,
      hasHints: !currentHints.isEmpty,
      activationInFlight: activationInFlight,
      insertFocusOwnerPID: insertFocusOwnerPID,
      focusedPID: focusedPID,
      insertModeLocked: insertModeLockedUntilExplicitNormal)
    {
      FlashLog.debug(
        "[mode] insert_app_unfocused owner=\(insertFocusOwnerPID.map { String($0) } ?? "nil") "
          + "focused=\(focusedPID.map { String($0) } ?? "nil") event=\(pid)")
      enterNormalMode()
      return
    }
    guard
      Self.insertModeShouldExitAfterFocusedElementChange(
        mode: flashMode,
        modeBadgeEnabled: modeBadgeEnabled,
        overlayInputMode: overlay.inputMode,
        hasHints: !currentHints.isEmpty,
        activationInFlight: activationInFlight,
        focusedPID: focusedPID,
        eventPID: pid,
        editableFocusExitPID: insertEditableFocusExitPID,
        focusedElementIsEditable: false,
        insertModeLocked: insertModeLockedUntilExplicitNormal)
    else { return }

    insertFocusExitProbeToken &+= 1
    let token = insertFocusExitProbeToken
    monitor.focusedInputSnapshot(pid: pid) { [weak self] snapshot in
      guard let self, self.insertFocusExitProbeToken == token, let snapshot else { return }
      self.completeFocusedInputExitIfNeeded(pid: pid, token: token, snapshot: snapshot)
    }
  }

  private func completeFocusedInputExitIfNeeded(
    pid: pid_t,
    token: UInt64,
    snapshot: InputFocusSnapshot,
    attempt: Int = 0
  ) {
    let focusedPID = currentNonFlashContext()?.processID
    let decision = InsertModeFocusMachine.insertFocusChangeDecision(
      focusedPID: focusedPID,
      eventPID: pid,
      armedEditablePID: insertEditableFocusExitPID,
      snapshot: snapshot,
      pointerPressed: Self.insertFocusExitShouldWaitForPointerRelease(),
      attempt: attempt)
    switch decision {
    case .stay:
      return
    case .waitForPointerRelease:
      // Waiting for the mouse button to come up is a distinct loop from the
      // transient-resample budget, so it does not consume an attempt.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
        self?.completeFocusedInputExitAfterPointerRelease(pid: pid, token: token, attempt: attempt)
      }
      return
    case .resampleAfter(let milliseconds):
      FlashLog.trace(
        "[mode] insert_focus_transient pid=\(pid) role=\(snapshot.role ?? "nil") "
          + "surface=\(snapshot.surface) attempt=\(attempt)")
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
        self?.completeFocusedInputExitAfterPointerRelease(
          pid: pid, token: token, attempt: attempt + 1)
      }
    case .exitToNormal:
      FlashLog.debug(
        "[mode] insert_focus_lost pid=\(pid) role=\(snapshot.role ?? "nil") "
          + "surface=\(snapshot.surface)")
      enterNormalMode()
    }
  }

  private func completeFocusedInputExitAfterPointerRelease(
    pid: pid_t,
    token: UInt64,
    attempt: Int = 0
  ) {
    guard insertFocusExitProbeToken == token, flashMode == .insert else { return }
    if Self.insertFocusExitShouldWaitForPointerRelease() {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
        self?.completeFocusedInputExitAfterPointerRelease(pid: pid, token: token, attempt: attempt)
      }
      return
    }
    monitor.focusedInputSnapshot(pid: pid) { [weak self] snapshot in
      guard let self, self.insertFocusExitProbeToken == token, let snapshot else { return }
      self.completeFocusedInputExitIfNeeded(
        pid: pid, token: token, snapshot: snapshot, attempt: attempt)
    }
  }

  static func insertModeShouldExitAfterFocusedAppChange(
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    insertFocusOwnerPID: pid_t?,
    focusedPID: pid_t?,
    insertModeLocked: Bool = false
  ) -> Bool {
    guard !insertModeLocked else { return false }
    guard let insertFocusOwnerPID, let focusedPID else { return false }
    return mode == .insert
      && modeBadgeEnabled
      && overlayInputMode == .hints
      && !hasHints
      && !activationInFlight
      && focusedPID != insertFocusOwnerPID
  }

  static func insertModeShouldExitAfterFocusedElementChange(
    mode: FlashMode,
    modeBadgeEnabled: Bool,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    focusedPID: pid_t?,
    eventPID: pid_t,
    editableFocusExitPID: pid_t?,
    focusedElementIsEditable: Bool,
    insertModeLocked: Bool = false
  ) -> Bool {
    !insertModeLocked
      && mode == .insert
      && modeBadgeEnabled
      && overlayInputMode == .hints
      && !hasHints
      && !activationInFlight
      && focusedPID == eventPID
      && focusedPID == editableFocusExitPID
      && !focusedElementIsEditable
  }

  private func armEditableFocusExitIfNeeded(target: AppContext?, reason: String) {
    guard modeBadgeEnabled, let target else { return }
    insertFocusExitProbeToken &+= 1
    let token = insertFocusExitProbeToken
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.insertEditableFocusArmDelayMs)
    ) { [weak self] in
      guard let self, self.insertFocusExitProbeToken == token, self.flashMode == .insert else {
        return
      }
      guard self.currentNonFlashContext()?.processID == target.processID else { return }
      self.monitor.focusedInputSnapshot(pid: target.processID) { [weak self] snapshot in
        guard let self, self.insertFocusExitProbeToken == token, self.flashMode == .insert else {
          return
        }
        guard let snapshot, InsertModeFocusMachine.shouldArmGenericExit(snapshot: snapshot) else {
          FlashLog.trace(
            "[mode] editable_focus_exit_unarmed pid=\(target.processID) reason=\(reason)")
          return
        }
        self.insertEditableFocusExitPID = target.processID
        FlashLog.trace(
          "[mode] editable_focus_exit_armed pid=\(target.processID) reason=\(reason)")
      }
    }
  }

  static let insertEditableFocusArmDelayMs = 120
  static let insertEditableFocusRepairDelaysMs = [40, 120, 250]

  private func repairSingleStrongEditableFocusIfNeeded(
    target: AppContext?,
    reason: String,
    attempt: Int = 0,
    token: UInt64? = nil
  ) {
    guard modeBadgeEnabled, let target, !insertModeLockedUntilExplicitNormal else { return }
    let repairToken: UInt64
    if let token {
      repairToken = token
    } else {
      insertEditableFocusRepairToken &+= 1
      repairToken = insertEditableFocusRepairToken
    }
    guard Self.insertEditableFocusRepairDelaysMs.indices.contains(attempt) else { return }
    let delay = Self.insertEditableFocusRepairDelaysMs[attempt]
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
      guard let self else { return }
      guard self.insertEditableFocusRepairToken == repairToken else { return }
      guard self.flashMode == .insert, self.modeBadgeEnabled else { return }
      guard !self.insertModeLockedUntilExplicitNormal else { return }
      guard self.overlay.inputMode == .hints, self.currentHints.isEmpty, !self.activationInFlight
      else { return }
      guard self.currentNonFlashContext()?.processID == target.processID else { return }
      self.monitor.repairSingleStrongEditableFocus(pid: target.processID) { [weak self] result in
        guard let self else { return }
        guard self.insertEditableFocusRepairToken == repairToken else { return }
        guard self.flashMode == .insert, self.currentNonFlashContext()?.processID == target.processID
        else { return }
        switch result {
        case .alreadyEditable:
          FlashLog.trace(
            "[mode] editable_focus_repair_skip reason=already_editable pid=\(target.processID)")
        case .repaired:
          FlashLog.debug(
            "[mode] editable_focus_repaired pid=\(target.processID) result=\(result)")
          self.armEditableFocusExitIfNeeded(target: target, reason: "focus_repair_\(reason)")
        case .ambiguous:
          FlashLog.trace(
            "[mode] editable_focus_repair_skip pid=\(target.processID) result=\(result)")
        case .noFocusedWindow, .noCandidate, .focusFailed:
          let nextAttempt = attempt + 1
          if Self.insertEditableFocusRepairDelaysMs.indices.contains(nextAttempt) {
            FlashLog.trace(
              "[mode] editable_focus_repair_retry pid=\(target.processID) attempt=\(attempt) "
                + "result=\(result)")
            self.repairSingleStrongEditableFocusIfNeeded(
              target: target,
              reason: reason,
              attempt: nextAttempt,
              token: repairToken)
          } else {
            FlashLog.trace(
              "[mode] editable_focus_repair_skip pid=\(target.processID) result=\(result)")
          }
        }
      }
    }
  }

  static func insertFocusExitShouldWaitForPointerRelease(
    pressedMouseButtons: Int = NSEvent.pressedMouseButtons
  ) -> Bool {
    pressedMouseButtons != 0
  }

  func armBrowserTabNavigationExit(
    pid: pid_t,
    bundleIdentifier: String,
    initialURL: String?
  ) {
    guard !insertModeLockedUntilExplicitNormal else { return }
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier), pid > 0 else {
      return
    }
    insertNavigationExitToken &+= 1
    let token = insertNavigationExitToken
    FlashLog.trace(
      "[mode] arm_navigation_exit pid=\(pid) bundle=\(bundleIdentifier) "
        + "initial=\(initialURL ?? "nil")")
    pollBrowserTabNavigationExit(
      pid: pid,
      token: token,
      initialURL: initialURL,
      remainingAttempts: Self.insertNavigationExitPollAttempts)
  }

  private func pollBrowserTabNavigationExit(
    pid: pid_t,
    token: UInt64,
    initialURL: String?,
    remainingAttempts: Int
  ) {
    guard insertNavigationExitToken == token, flashMode == .insert,
      !insertModeLockedUntilExplicitNormal, remainingAttempts > 0
    else {
      return
    }
    monitor.focusedDocumentURL(pid: pid) { [weak self] url in
      guard let self, self.insertNavigationExitToken == token, self.flashMode == .insert,
        !self.insertModeLockedUntilExplicitNormal
      else {
        return
      }
      if Self.insertNavigationExitShouldExit(currentURL: url, initialURL: initialURL) {
        FlashLog.debug("[mode] insert_navigation_committed pid=\(pid) url=\(url ?? "nil")")
        self.enterNormalMode()
        return
      }
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(Self.insertNavigationExitPollIntervalMs)
      ) { [weak self] in
        self?.pollBrowserTabNavigationExit(
          pid: pid,
          token: token,
          initialURL: initialURL,
          remainingAttempts: remainingAttempts - 1)
      }
    }
  }

  static let insertNavigationExitPollIntervalMs = 150
  static let insertNavigationExitPollAttempts = 200

  static func insertNavigationExitShouldExit(
    currentURL: String?,
    initialURL: String?
  ) -> Bool {
    guard let current = currentURL?.trimmed, !current.isEmpty else { return false }
    if let initial = initialURL?.trimmed, !initial.isEmpty, current == initial {
      return false
    }
    guard let url = URL(string: current), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return scheme == "http" || scheme == "https"
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
    NormalModePointerPolicy.pointerScrollShouldBeSuppressed(mode: mode, hasHints: hasHints)
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
      visible: statusBarVisible,
      hasHints: !currentHints.isEmpty,
      activationInFlight: activationInFlight,
      captureOverride: captureOverride)
    FlashLog.trace(
      "[mode] overlay mode=\(flashMode) capture=\(snapshot.captureInput) "
        + "override=\(String(describing: captureOverride)) "
        + "visible=\(statusBarVisible) hints=\(currentHints.count) in_flight=\(activationInFlight)")
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
    if Self.contextMenuInteractionRecaptureSuppressionIsActive(
      until: contextMenuInteractionRecaptureSuppressedUntil)
    {
      FlashLog.trace("[mode] recapture_skip reason=context_menu_interaction")
      return
    }
    if Self.pointerInsertHandoffRecaptureSuppressionIsActive(
      until: pointerInsertHandoffRecaptureSuppressedUntil)
    {
      FlashLog.trace("[mode] recapture_skip reason=pointer_insert_handoff_pending")
      return
    }
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

  func noteMenuBarInteraction(reason: String, now: Date = Date()) {
    menuBarInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.menuBarInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    FlashLog.trace("[mode] menu_bar_interaction reason=\(reason) recapture_suppressed=true")
  }

  func noteContextMenuInteraction(reason: String, now: Date = Date()) {
    contextMenuInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.contextMenuInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    FlashLog.trace("[mode] context_menu_interaction reason=\(reason) recapture_suppressed=true")
  }

  @discardableResult
  func notePointerInsertHandoff(reason: String, now: Date = Date()) -> UInt64 {
    pointerInsertHandoffToken &+= 1
    pointerInsertHandoffRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.pointerInsertHandoffRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    FlashLog.trace(
      "[mode] pointer_insert_handoff reason=\(reason) token=\(pointerInsertHandoffToken) "
        + "recapture_suppressed=true")
    return pointerInsertHandoffToken
  }

  func clearPointerInsertHandoff(reason: String, token: UInt64? = nil) {
    if let token, token != pointerInsertHandoffToken {
      FlashLog.trace(
        "[mode] pointer_insert_handoff_clear_skip reason=\(reason) token=\(token) "
          + "current=\(pointerInsertHandoffToken)")
      return
    }
    if pointerInsertHandoffRecaptureSuppressedUntil != nil {
      FlashLog.trace("[mode] pointer_insert_handoff_clear reason=\(reason)")
    }
    pointerInsertHandoffRecaptureSuppressedUntil = nil
    pointerInsertHandoffToken &+= 1
  }

  func cancelPointerInsertHandoff(reason: String) {
    let hadSuppression = pointerInsertHandoffRecaptureSuppressedUntil != nil
    pointerInsertHandoffRecaptureSuppressedUntil = nil
    pointerInsertHandoffToken &+= 1
    if hadSuppression {
      normalModeRecaptureToken &+= 1
      FlashLog.trace("[mode] pointer_insert_handoff_cancel reason=\(reason)")
    }
  }

  func pointerInsertHandoffIsCurrent(_ token: UInt64?, now: Date = Date()) -> Bool {
    Self.pointerInsertHandoffIsCurrent(
      token: token,
      currentToken: pointerInsertHandoffToken,
      pointerInsertHandoffRecaptureSuppressedUntil:
        pointerInsertHandoffRecaptureSuppressedUntil,
      now: now)
  }

  static func pointerInsertHandoffIsCurrent(
    token: UInt64?,
    currentToken: UInt64,
    pointerInsertHandoffRecaptureSuppressedUntil: Date?,
    now: Date
  ) -> Bool {
    guard let token else { return true }
    guard token == currentToken else { return false }
    return pointerInsertHandoffRecaptureSuppressionIsActive(
      until: pointerInsertHandoffRecaptureSuppressedUntil,
      now: now)
  }

  func shouldScheduleNormalModeRecaptureAfterWorkspaceActivation(now: Date = Date()) -> Bool {
    let shouldRecapture = Self.workspaceActivationShouldScheduleNormalModeRecapture(
      mode: flashMode,
      menuBarInteractionRecaptureSuppressedUntil: menuBarInteractionRecaptureSuppressedUntil,
      contextMenuInteractionRecaptureSuppressedUntil:
        contextMenuInteractionRecaptureSuppressedUntil,
      pointerInsertHandoffRecaptureSuppressedUntil:
        pointerInsertHandoffRecaptureSuppressedUntil,
      now: now)
    if !shouldRecapture,
      Self.menuBarInteractionRecaptureSuppressionIsActive(
        until: menuBarInteractionRecaptureSuppressedUntil,
        now: now)
    {
      FlashLog.trace("[mode] recapture_skip reason=recent_menu_bar_interaction")
    }
    if !shouldRecapture,
      Self.contextMenuInteractionRecaptureSuppressionIsActive(
        until: contextMenuInteractionRecaptureSuppressedUntil,
        now: now)
    {
      FlashLog.trace("[mode] recapture_skip reason=context_menu_interaction")
    }
    if !shouldRecapture,
      Self.pointerInsertHandoffRecaptureSuppressionIsActive(
        until: pointerInsertHandoffRecaptureSuppressedUntil,
        now: now)
    {
      FlashLog.trace("[mode] recapture_skip reason=pointer_insert_handoff_pending")
    }
    if menuBarInteractionRecaptureSuppressedUntil.map({ $0 <= now }) == true {
      menuBarInteractionRecaptureSuppressedUntil = nil
    }
    if contextMenuInteractionRecaptureSuppressedUntil.map({ $0 <= now }) == true {
      contextMenuInteractionRecaptureSuppressedUntil = nil
    }
    if pointerInsertHandoffRecaptureSuppressedUntil.map({ $0 <= now }) == true {
      pointerInsertHandoffRecaptureSuppressedUntil = nil
    }
    return shouldRecapture
  }

  static func workspaceActivationShouldScheduleNormalModeRecapture(
    mode: FlashMode,
    menuBarInteractionRecaptureSuppressedUntil: Date?,
    contextMenuInteractionRecaptureSuppressedUntil: Date? = nil,
    pointerInsertHandoffRecaptureSuppressedUntil: Date? = nil,
    now: Date
  ) -> Bool {
    mode == .normal
      && !menuBarInteractionRecaptureSuppressionIsActive(
        until: menuBarInteractionRecaptureSuppressedUntil,
        now: now)
      && !contextMenuInteractionRecaptureSuppressionIsActive(
        until: contextMenuInteractionRecaptureSuppressedUntil,
        now: now)
      && !pointerInsertHandoffRecaptureSuppressionIsActive(
        until: pointerInsertHandoffRecaptureSuppressedUntil,
        now: now)
  }

  static func menuBarInteractionRecaptureSuppressionIsActive(
    until: Date?,
    now: Date
  ) -> Bool {
    guard let until else { return false }
    return now < until
  }

  static func contextMenuInteractionRecaptureSuppressionIsActive(
    until: Date?,
    now: Date = Date()
  ) -> Bool {
    guard let until else { return false }
    return now < until
  }

  static func menuBarPointerShouldReleaseNormalCapture(
    mode: FlashMode,
    action: JumpAction
  ) -> Bool {
    false
  }

  static func appPointerShouldReleaseNormalCapture(
    mode: FlashMode,
    wasCommandLine: Bool,
    action: JumpAction
  ) -> Bool {
    NormalModePointerPolicy.appClickDecision(
      mode: mode,
      wasCommandLine: wasCommandLine,
      hasHints: false,
      action: action
    ).releaseCapture
  }

  static func appPointerShouldSuspendForContextMenu(
    mode: FlashMode,
    wasCommandLine: Bool,
    action: JumpAction
  ) -> Bool {
    NormalModePointerPolicy.appClickDecision(
      mode: mode,
      wasCommandLine: wasCommandLine,
      hasHints: false,
      action: action
    ).suspendForNativeSurface
  }

  static func appPointerShouldProbeForInsert(
    mode: FlashMode,
    wasCommandLine: Bool,
    action: JumpAction
  ) -> Bool {
    NormalModePointerPolicy.appClickDecision(
      mode: mode,
      wasCommandLine: wasCommandLine,
      hasHints: false,
      action: action
    ).probeForInsert
  }

  static func pointerActionMayEnterInsert(_ action: JumpAction) -> Bool {
    NormalModePointerPolicy.pointerActionMayEnterInsert(action)
  }

  private func verifyNormalModeCapture(reason: String) {
    normalModeCaptureVerificationToken &+= 1
    let token = normalModeCaptureVerificationToken
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
      guard let self, self.normalModeCaptureVerificationToken == token else { return }
      guard self.shouldCaptureNormalModeInput else { return }
      guard !self.overlay.keyboardCaptureIsActive else { return }
      // On macOS Tahoe (26) the system can refuse to grant key window to
      // an accessory app even after `NSApp.activate()` — Firefox holds
      // activation and won't yield. The original code escalated to
      // another `scheduleNormalModeRecapture`, which kicked off nine
      // more retries, each landing back here when they failed and
      // cascading into a tight loop that pegged the main runloop. The
      // owning `scheduleNormalModeRecapture` already retries on a
      // 0/10/30/60/120/250/500/900/1400 ms ramp; if every retry on that
      // ramp lost the race we accept the loss and wait for the next
      // explicit `enter_normal_mode` press. Stops the spin without
      // hiding the diagnostic.
      FlashLog.debug(
        "[mode] capture_inactive reason=\(reason) key=\(self.overlay.isKeyWindow) "
          + "first_responder=\(String(describing: self.overlay.firstResponder))")
    }
  }

  func scheduleNormalModeRecaptureAfterPointerFocusLoss() {
    if Self.contextMenuInteractionRecaptureSuppressionIsActive(
      until: contextMenuInteractionRecaptureSuppressedUntil)
    {
      FlashLog.trace("[mode] pointer_recapture_skip reason=context_menu_interaction")
      return
    }
    if Self.pointerInsertHandoffRecaptureSuppressionIsActive(
      until: pointerInsertHandoffRecaptureSuppressedUntil)
    {
      FlashLog.trace("[mode] pointer_recapture_skip reason=pointer_insert_handoff_pending")
      return
    }
    if Self.pointIsInMenuBar(NSEvent.mouseLocation) {
      // The user clicked the menu bar (system menu, app menu, or status
      // item). Recapturing key window here races the menu/status popup's
      // open and can close it immediately.
      noteMenuBarInteraction(reason: "pointer_focus_loss")
      FlashLog.trace("[mode] pointer_recapture_skip target=menu_bar")
      return
    }
    FlashLog.trace(
      "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
        + "reason=normal_mode_focus_contract")
    scheduleNormalModeRecapture()
  }

  static let normalModeRecaptureDelaysMs = [0, 10, 30, 60, 120, 250, 500, 900, 1_400]
  static let menuBarInteractionRecaptureSuppressionMs = 1_500
  static let contextMenuInteractionRecaptureSuppressionMs = 1_500
  static let pointerInsertHandoffRecaptureSuppressionMs = 1_500
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

  static func pointerInsertHandoffRecaptureSuppressionIsActive(
    until: Date?,
    now: Date = Date()
  ) -> Bool {
    guard let until else { return false }
    return now < until
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
    case .lockedInsertMode:
      enterInsertMode(reason: .lockedNormalModeInput)
    case .normalMode:
      enterNormalMode()
    case .commandMode:
      enterCommandLineMode()
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
    case .reload(let force):
      reloadInNormalMode(force: force, repeatCount: repeatCount)
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
    case .archive:
      archiveInNormalMode(repeatCount: repeatCount)
    case .resourceNext:
      resourceNavigationInNormalMode(direction: .next, repeatCount: repeatCount)
    case .resourcePrevious:
      resourceNavigationInNormalMode(direction: .previous, repeatCount: repeatCount)
    case .close:
      windowCloseInNormalMode(repeatCount: repeatCount)
    case .tabClose:
      tabCloseInNormalMode(repeatCount: repeatCount)
    case .find:
      // ⌘F opens the find bar in the focused app, then Flash drops to insert
      // so the user can start typing the query immediately. The `/` chord
      // is the user's explicit intent signal, so this still satisfies the
      // audit-rule requirement that mode flips trace to a user-action path.
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
      enterInsertMode(reason: .explicitCommand)
    case .candidateFinder(let all):
      enterCommandLineMode(initialText: "flashlight ", candidateFinderScope: all ? .all : .running)
    case .enterCommand(let input, let restoreMode):
      enterCommandLineMode(
        initialText: input,
        candidateFinderScope: .all,
        restoreMode: restoreMode)
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
    case .quitApp(let force):
      quitNormalModeTargetApp(force: force)
    case .saveAndQuit(let force):
      sendNormalModeKey(CGKeyCode(kVK_ANSI_S), flags: .maskCommand, repeatCount: repeatCount)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
        self?.performMappedCommand(.quitApp(force: force))
      }
    case .tabNew:
      let tabNewContext = normalModeContext()
      let initialURL = tabNewContext.flatMap { registry.documentURL(in: $0) }
      tabNewInNormalMode(repeatCount: repeatCount)
      // `t` is the user's explicit "open something fresh and start typing"
      // intent: switching to insert lets them type into the new tab/window
      // without an extra `i`. Matches the unified contract on `/`.
      enterInsertMode(reason: .explicitCommand)
      if let tabNewContext {
        armBrowserTabNavigationExit(
          pid: tabNewContext.processID,
          bundleIdentifier: tabNewContext.bundleIdentifier,
          initialURL: initialURL)
      }
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showPlugins:
      showPlugins()
    case .showAlert, .dismissAlert, .dismissHints, .quit, .openApp, .pluginCommand, .moveWindow,
      .pluginVerb:
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

  func normalizedRepeatCount(_ repeatCount: Int) -> Int {
    min(max(repeatCount, 1), 999)
  }

  func enterCommandLineMode(
    initialText: String = "",
    candidateFinderScope: CandidateScope? = nil,
    restoreMode: Bool = false
  ) {
    guard
      Self.commandLineEntryIsAllowed(
        mode: flashMode,
        hasHints: !currentHints.isEmpty,
        activationInFlight: activationInFlight)
    else { return }
    // Snapshot the entry mode *before* `transitionMode` runs anywhere
    // below so `finishCommandLineInteraction` can put the user back where
    // they were. Verbs that don't ask for this clear the slot so a stale
    // value from a prior open doesn't leak.
    commandLineRestoreModeTarget = restoreMode ? flashMode : nil
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    closeModalStateForModeExit(reason: "enter_command_mode")
    clearTransientHintState(reason: "enter_command_mode")
    resetCommandLineState()
    if let candidateFinderScope {
      self.candidateFinderScope = candidateFinderScope
      openCandidateFinderSession(scope: candidateFinderScope)
    } else {
      self.candidateFinderScope = .all
      clearCandidateFinderState()
    }
    overlay.setActiveWindowBorder(around: nil)
    let command = Self.commandLineBuffer(from: initialText)
    notifyPluginsAfterCandidateFinderSnapshot(scope: self.candidateFinderScope)
    prewarmCandidateFinderCaches(reason: "command_line_open")
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
      HelpDocs.render(
        topic: topic,
        config: config,
        showModes: modeBadgeEnabled,
        pluginTopics: pluginManager.pluginHelpTopics())
    }
  }

  func showPlugins() {
    presentModal(reason: "enter_plugins") { [self] in
      pluginManager.statusText()
    }
  }

  private func runPluginsSubcommand(_ sub: NormalModeDispatcher.PluginsSubcommand) {
    switch sub {
    case .modal:
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
      presentModal(reason: "plugins_reload") { "# Plugins reload\n\n\(summary)" }
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
      in: pluginSelectorContext()
    ) { [weak self] ok, _, stdout, _ in
      guard let self else { return }
      let entries = (ok ? stdout : nil).flatMap(Self.decodeClipboardModalEntries) ?? []
      self.clipboardModalEntries = entries
      guard !entries.isEmpty else {
        self.presentModal(reason: "clipboard_empty") { "# Clipboard\n\nNo history yet." }
        return
      }
      self.presentSelectableModal(reason: "clipboard", lines: entries.map(\.preview))
    }
    if !dispatched {
      clipboardModalEntries = []
      presentModal(reason: "clipboard_unavailable") { "# Clipboard\n\nPlugin unavailable." }
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
    candidateFinderScope = scope
    openCandidateFinderSession(scope: scope)
    overlay.setActiveWindowBorder(around: nil)
    notifyPluginsAfterCandidateFinderSnapshot(scope: scope)
    prewarmCandidateFinderCaches(reason: "candidate_finder_open")
    overlay.displayCandidateFinder(query: "", items: [])
  }

  func prewarmCandidateFinderCaches(reason: String) {
    refreshCandidatesAsync(scope: .running, reason: reason)
    refreshCandidatesAsync(scope: .all, reason: reason)
  }

  /// Open a flashlight session by freezing one candidate snapshot. This is the
  /// only time the visible pool is composed for the session: plugin/browser/tmux
  /// rows must come from already-warm in-memory `candidates(...)` snapshots, not
  /// session-time `queryCandidates` RPCs. Later plugin snapshot updates can warm
  /// the next session, but they must not mutate this one.
  func openCandidateFinderSession(scope: CandidateScope) {
    candidateFinderPrecedenceTable = buildCandidateFinderPrecedenceTable()
    candidateFinderCandidates = candidateFinderCandidates(for: scope)
    candidateFinderSelectedIndex = 0
    FlashLog.trace(
      "[candidate_finder] session_snapshot scope=\(scope) count=\(candidateFinderCandidates.count)")
  }

  private func notifyPluginsAfterCandidateFinderSnapshot(scope: CandidateScope) {
    pluginManager.emit(
      PluginEvent(
        name: "core:flashlight.opened",
        payload: ["scope": scope == .running ? "running" : "all"],
        bundleID: nil,
        configPath: nil,
        focused: nil))
  }

  func invalidateCandidateFinderCaches(reason: String, refreshApps: Bool) {
    FlashLog.trace("[candidate_finder] refresh_cache reason=\(reason) refresh_apps=\(refreshApps)")
    if refreshApps {
      registry.refreshRunningApplications()
    }
    prewarmCandidateFinderCaches(reason: reason)
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
      let candidates = self.registry.coreAppCandidates(scope: scope)
      DispatchQueue.main.async {
        switch scope {
        case .running:
          self.candidateFinderRunningAppsRefreshInFlight = false
        case .all:
          self.candidateFinderAllAppsRefreshInFlight = false
        }
        FlashLog.trace(
          "[candidate_finder] refresh_done scope=\(scope) count=\(candidates.count) reason=\(reason)"
        )
      }
    }
  }

  private func candidateFinderCandidates(for scope: CandidateScope) -> [Candidate] {
    // Bangs are NOT in the default pool — they only surface when the
    // user types `!` (see `updateCandidateMatches`'s bang branch). The
    // base snapshot is still over every current source: apps from the warmed
    // `ApplicationSource` cache, and plugin/browser/tmux rows from each
    // source's in-memory candidates snapshot. Query-time filtering narrows the
    // default flashlight to the navigation families, or to whichever
    // `@source` the user explicitly names. Do not call `queryCandidates`
    // here — any RPC or live refresh would either delay first paint or mutate
    // the list after it is visible.
    let candidates = registry.candidates(scope: scope)
    FlashLog.trace(
      "[candidate_finder] snapshot_sync scope=\(scope) count=\(candidates.count)")
    return candidates
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
      clearCommandLineCompletionState()
      if candidateFinderCandidates.isEmpty {
        candidateFinderPrecedenceTable = buildCandidateFinderPrecedenceTable()
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
      if let bang, bang.confirmed {
        candidateFinderMatches = []
        candidateFinderSelectedIndex = 0
        let queryRange = bangRangeInCommand(
          command: command, query: query, bangRange: bang.bangRange)
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
      in: pluginSelectorContext())
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
    let topics = HelpDocs.allTopics(
      config: config,
      showModes: true,
      pluginTopics: pluginManager.pluginHelpTopics()
    )
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
    let previousLabel: String? =
      commandLineCompletionMatches.indices.contains(
        commandLineCompletionSelectedIndex)
      ? commandLineCompletionMatches[commandLineCompletionSelectedIndex].completion.label : nil
    commandLineCompletionPrefix = context.prefix
    commandLineCompletionItems = context.items
    commandLineCompletionQuery = context.query
    let trimmedQuery = context.query.trimmed
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
    // `@<source>` narrows the pool to a single source; the residual text after
    // the `@source ` token is the actual fuzzy query.
    let sourceCompletion = CandidateFinder.sourceCompletionState(query: query)
    let bangCompletion = CandidateFinder.bangCompletionState(query: query)
    let parsed =
      sourceCompletion == nil
      ? NormalModeDispatcher.candidateFinderSourceFilter(query)
      : NormalModeDispatcher.CandidateFinderQuery(sourceFilter: nil, text: query)
    let trimmed = parsed.text
    candidateFinderCurrentQuery = sourceCompletion?.token ?? trimmed

    let (pool, scoringText) = buildCandidateFinderPool(
      trimmed: trimmed,
      sourceFilter: parsed.sourceFilter)
    let tFiltered = CFAbsoluteTimeGetCurrent()

    // Bump the generation so any scoring job that completes AFTER
    // this keystroke is dropped silently when its callback fires.
    candidateFinderIndexGenerationCounter &+= 1
    let generation = candidateFinderIndexGenerationCounter

    if sourceCompletion != nil || bangCompletion != nil || CandidateFinder.parseBang(trimmed) != nil
    {
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(scoringText)
      let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
      let scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalizedQuery,
        fuzzyScore: fuzzy,
        allowParallel: false)
      let sorted = CandidateFinder.sortedMatches(
        scored, precedence: precedenceTable(), normalizedQuery: normalizedQuery)
      // Bang / source-completion pools are disjoint from the main flashlight
      // pool, so a saved incremental cache from a previous keystroke must
      // not survive into the next plain-query keystroke.
      candidateFinderIncrementalCache = nil
      applyCandidateMatches(sorted)
      return
    }

    if scoringText.trimmed.isEmpty {
      let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
      let scored = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: "",
        fuzzyScore: fuzzy,
        allowParallel: false)
      let sorted = CandidateFinder.sortedMatches(scored, precedence: precedenceTable())
      // Empty query returns the whole filtered pool — a useful starting
      // point but not a fuzzy-narrowed set, so leave the incremental
      // cache empty and let the first real keystroke seed it from the
      // full pool.
      candidateFinderIncrementalCache = nil
      applyCandidateMatches(sorted)
      return
    }

    // Score on the main thread so the keystroke and its fresh result
    // land in the same frame. The fuzzy ranker uses the precomputed
    // scoring masks + normalized fields stashed by `CandidateFinder
    // .prepare`, so a 3000-candidate pool typically scores + sorts in
    // ~1–2ms — well under the 16ms frame budget. The earlier
    // background-queue + async-callback design was visibly choppy: the
    // keystroke painted with the previous match snapshot, then the
    // sorted result replaced it a frame later, which felt like a
    // perceptible delay even when the work itself was sub-millisecond.
    // The heaviest pools (full installed-app + plugin candidate
    // counts) stay below ~5k so the synchronous path stays cheap.
    let tScoringStart = CFAbsoluteTimeGetCurrent()
    // Rewrite standalone emoticons (`:)`, `:-(`, `;)`, …) to the emoji
    // shortcodes the `emojis` plugin indexes before normalization strips
    // their punctuation — otherwise `@emojis.glyphs :)` collapses to an
    // empty query and lists every glyph unranked.
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(
      NormalModeDispatcher.expandEmoticons(scoringText))
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let signature = parsed.sourceFilter ?? ""
    // Incremental narrowing: if the new query extends the previous one
    // and neither the pool nor the attribute filters have changed since
    // the previous keystroke, no candidate that failed the shorter
    // query can possibly pass the longer one. Re-score only the
    // previous match set; the candidate space contracts on every
    // keystroke and scoring gets monotonically cheaper.
    let scoringPool: [Candidate]
    let isIncremental: Bool
    if let cache = candidateFinderIncrementalCache,
      cache.epoch == candidateFinderCandidatesEpoch,
      cache.signature == signature,
      !cache.normalizedQuery.isEmpty,
      normalizedQuery.count > cache.normalizedQuery.count,
      normalizedQuery.hasPrefix(cache.normalizedQuery)
    {
      scoringPool = cache.matches.map(\.candidate)
      isIncremental = true
    } else {
      scoringPool = pool
      isIncremental = false
    }
    var scored = CandidateFinder.scoreMatches(
      pool: scoringPool,
      normalizedQuery: normalizedQuery,
      fuzzyScore: fuzzy,
      allowParallel: true)
    let tScored = CFAbsoluteTimeGetCurrent()
    // Apply frecency boost before the sort so the comparator sees the
    // final score. Skip the loop entirely when the store has no
    // entries — the boost is always 0 in that case and
    // `FrecencyMapper.itemKey` does a non-trivial amount of per-candidate
    // work that's pure waste here.
    let store = self.frecencyStore
    if let store, !store.isEmpty {
      for index in scored.indices {
        if let key = FrecencyMapper.itemKey(for: scored[index].candidate) {
          scored[index].score += store.boost(forKey: key)
        }
      }
    }
    // Top-K bounded sort. The display window is `commandBarSuggestionCount`
    // (default 10), with arrow-key scrolling allowed inside the bounded
    // set, so a 3x buffer keeps the result list scroll-friendly without
    // paying for a full O(N log N) sort of every match. Keep the
    // incremental cache unbounded, though: a row that misses the display
    // top-K for "t" can become the best match for "tmux".
    let sortLimit = max(commandBarSuggestionCount * 3, 30)
    let ranked = CandidateFinder.displayAndIncrementalMatches(
      scored, precedence: precedenceTable(), limit: sortLimit, normalizedQuery: normalizedQuery)
    let sorted = ranked.display
    let tSorted = CFAbsoluteTimeGetCurrent()
    // Re-check the generation — a re-entrant call (e.g. caches landing
    // mid-update) could have already superseded us.
    guard generation == self.candidateFinderIndexGenerationCounter else { return }
    candidateFinderIncrementalCache = (
      normalizedQuery: normalizedQuery,
      matches: ranked.incremental,
      epoch: candidateFinderCandidatesEpoch,
      signature: signature
    )
    applyCandidateMatches(sorted)
    if !trimmed.isEmpty {
      let tRendered = CFAbsoluteTimeGetCurrent()
      let top = sorted.prefix(5).map { match in
        "\(match.candidate.source):\(match.candidate.title)=\(match.score)"
      }.joined(separator: "|")
      let dFilter = Int((tFiltered - t0) * 1000)
      let dScore = Int((tScored - tScoringStart) * 1000)
      let dSort = Int((tSorted - tScored) * 1000)
      let dRender = Int((tRendered - tSorted) * 1000)
      let dTotal = Int((tRendered - t0) * 1000)
      FlashLog.trace(
        "[candidate_finder] q=\"\(trimmed)\" pool=\(pool.count) "
          + "scored=\(scoringPool.count) inc=\(isIncremental) "
          + "matches=\(sorted.count) "
          + "total_ms=\(dTotal) filter_ms=\(dFilter) score_ms=\(dScore) "
          + "sort_ms=\(dSort) render_ms=\(dRender) "
          + "top5=[\(top)]")
    }
  }

  /// Build a `PrecedenceTable` from the live source descriptors and config
  /// overrides. Frozen once with the candidate snapshot so query-time sorting
  /// uses a prepared table.
  private func buildCandidateFinderPrecedenceTable() -> CandidateFinder.PrecedenceTable {
    CandidateFinder.PrecedenceTable(
      sources: registry.registeredCandidateSourceDescriptors(),
      overrides: config.flashlight.precedence,
      aliveBonus: config.flashlight.precedenceAliveBonus)
  }

  private func precedenceTable() -> CandidateFinder.PrecedenceTable {
    candidateFinderPrecedenceTable
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

  /// Pick the candidate pool and the text we score against. Three cases:
  ///
  ///   * Bang mode (query starts with `!`) — the pool is the bang registry, or
  ///     the candidate source declared by the bang once it's confirmed (e.g.
  ///     `!kill ` shows the processes plugin's process list).
  ///   * `@<source>` mode — the pool is narrowed to that one source. With an
  ///     empty residual the user sees every candidate from that source (e.g.
  ///     `@emojis.glyphs ` lists every emoji).
  ///   * Default — the regular pool scored on the full query, restricted to
  ///     tmux windows/tabs, browser tabs, apps, and Slack channels. Synthetic
  ///     bang / source-completion rows are always excluded; all other source
  ///     families are excluded unless the user opts in via `@<source>`.
  private func buildCandidateFinderPool(
    trimmed: String,
    sourceFilter: String?
  ) -> (pool: [Candidate], scoringText: String) {
    if let bang = CandidateFinder.parseBangState(trimmed),
      bang.confirmed,
      let candidateSource = pluginManager.shebangCandidateSource(
        token: bang.token,
        in: pluginSelectorContext())
    {
      // Confirmed bang bound to a candidate source: swap the pool to that
      // source's live candidates. Selection routes back through the bang.
      let scoped = candidateFinderCandidates.filter { candidate in
        guard Self.candidateCanRenderInCommandBar(candidate) else { return false }
        return CandidateFinder.candidateMatchesSourceFilter(candidate, filter: candidateSource)
      }
      return (scoped, bang.remainder)
    }
    if let bang = CandidateFinder.parseBang(trimmed) {
      let bangs = CandidateFinder.prepare(
        pluginManager.shebangCandidates(
          in: pluginSelectorContext()))
      return (bangs, bang.token)
    }
    if let bang = CandidateFinder.bangCompletionState(query: trimmed) {
      let bangs = CandidateFinder.prepare(
        pluginManager.shebangCandidates(
          in: pluginSelectorContext()))
      return (bangs, bang.token)
    }
    // `@<partial>` completion: when the user is in the middle of
    // typing a source token (no trailing whitespace yet), swap the
    // pool for source-completion rows derived from the candidates
    // actually present. This mirrors the bang-completion surface so
    // `<tab>`/`<cr>` semantics stay identical across both modes.
    if let completion = CandidateFinder.sourceCompletionState(query: trimmed) {
      let pool = CandidateFinder.prepare(
        knownSourceCompletionCandidates())
      return (pool, completion.token)
    }
    // Cache the kind+source-narrow pass — while the user types into
    // flashlight the signature is stable, so the same ~2k-entry filter
    // ran ~2k times on every keystroke. Keyed by the base-pool epoch +
    // filter signature; one-slot cache because consecutive keystrokes
    // always share the same key.
    let signature = sourceFilter ?? ""
    if let cached = candidateFinderFilteredPoolCache,
      cached.epoch == candidateFinderCandidatesEpoch,
      cached.signature == signature
    {
      return (cached.pool, trimmed)
    }
    // `@<source>` opts in to whatever source the user names. Without an
    // explicit source filter, keep the default flashlight focused on navigation
    // destinations only: tmux windows/tabs, browser tabs, apps, and Slack
    // channels.
    let userOptedIntoSource = sourceFilter != nil
    let pool = candidateFinderCandidates.filter { candidate in
      guard candidate.kind != CandidateFinder.bangKind,
        candidate.kind != CandidateFinder.sourceKind
      else { return false }
      guard Self.candidateCanRenderInCommandBar(candidate) else { return false }
      if !userOptedIntoSource,
        !CandidateFinder.isDefaultFlashlightCandidate(candidate, precedence: precedenceTable())
      {
        return false
      }
      if let sourceFilter,
        !CandidateFinder.candidateMatchesSourceFilter(candidate, filter: sourceFilter)
      {
        return false
      }
      return true
    }
    candidateFinderFilteredPoolCache = (
      epoch: candidateFinderCandidatesEpoch,
      signature: signature,
      pool: pool
    )
    return (pool, trimmed)
  }

  static func candidateCanRenderInCommandBar(_ candidate: Candidate) -> Bool {
    CandidateEmojiSupport.candidateCanRenderInCommandBar(candidate)
  }

  /// Build one `@<source>` completion row per registered candidate source.
  /// This uses the source declarations, not the currently visible candidate
  /// pool, so `@firefox.tabs` can be offered before the Firefox plugin has
  /// produced a tab snapshot for this flashlight session.
  private func knownSourceCompletionCandidates() -> [Candidate] {
    registry.registeredCandidateSourceLabels().map(CandidateFinder.sourceCompletionCandidate)
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
      in: pluginSelectorContext()
    ) { [weak self] ok, pid, stdout, navigationURL in
      guard ok, let self else { return }
      self.activatePluginCommandTarget(pid, navigationURL: navigationURL)
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
        in: pluginSelectorContext(),
        onResult: { [weak self] ok, pid, stdout, navigationURL in
          guard ok else { return }
          self?.activatePluginCommandTarget(pid, navigationURL: navigationURL)
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
      handleURLCommand(.pluginVerb(name: "app_save", args: [:]))
    case .saveAndQuit(let force):
      performMappedCommand(.saveAndQuit(force: force))
    case .print:
      handleURLCommand(.pluginVerb(name: "app_print", args: [:]))
    case .open:
      handleURLCommand(.pluginVerb(name: "document_open", args: [:]))
    case .newWindow:
      handleURLCommand(.pluginVerb(name: "window_new", args: [:]))
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
      sendNormalModeKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    case .cut:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_X), flags: .maskCommand)
    case .paste:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
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
    actOnSelectedCandidateFinderCandidate(submit: false, allowFinisher: true)
  }

  /// Single act-on-selection entry point for the flashlight surface.
  /// `<cr>` and `<tab>` call with `submit=false` (insert-first).
  /// Return passes `allowFinisher=true`, so source-owned finishers and
  /// exact primary-title matches can open. Tab passes `allowFinisher=false`
  /// but `submitFinalDestinations=true`, so app, browser-tab, and
  /// tmux-window rows behave like an explicit Command-Return while
  /// partial/source rows still rewrite the buffer. `<cmd+cr>` calls with
  /// `submit=true`, the explicit force-submit path for real candidates.
  /// Synthetic source-filter rows are always insert-only.
  func actOnSelectedCandidateFinderCandidate(
    submit: Bool,
    allowFinisher: Bool = true,
    submitFinalDestinations: Bool = false
  ) {
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

    let candidate = candidateFinderMatches[
      min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)
    ]
    .candidate
    if candidate.kind == CandidateFinder.bangKind,
      let token = candidate.sourcePayload
    {
      if submit {
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
      // and the cursor sits ready for the query. Source rows are
      // synthetic completions, not resolvable candidates, so Return,
      // Tab, and Command-Return all stop at insertion.
      replaceInProgressAtSourceToken(with: source)
      return
    }
    if CandidateFinder.selectionSubmits(
      candidate,
      query: candidateFinderCurrentQuery,
      submit: submit,
      allowFinisher: allowFinisher,
      submitFinalDestinations: submitFinalDestinations)
    {
      finishCommandLineInteraction(reason: "command_open")
      openSourceItem(candidate)
      return
    }
    replaceCommandLineCandidateQuery(with: CandidateFinder.commandInsertionText(candidate))
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
    let newCursor =
      command.distance(from: command.startIndex, to: absoluteStart) + replacement.count
    refreshCommandLine(text: buffer, cursorIndex: newCursor)
  }

  /// Replace the live `:flashlight` / `:emojis` query with the
  /// selected candidate's canonical insertion text while keeping the
  /// command verb intact. Return reaches this path for non-finishers;
  /// Tab reaches it for non-final destinations. Command-Return is the
  /// explicit submit.
  private func replaceCommandLineCandidateQuery(with insertion: String) {
    let command = overlay.commandLineText
    guard let query = NormalModeDispatcher.commandLineCandidateQuery(command) else { return }
    let prefixLen = command.count - query.count
    let queryStart = command.index(command.startIndex, offsetBy: prefixLen)
    let buffer = String(command[..<queryStart]) + insertion
    refreshCommandLine(text: buffer, cursorIndex: buffer.count)
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
      in: pluginSelectorContext()
    ) { [weak self] ok, pid, stdout, navigationURL in
      guard ok, let self else { return }
      self.activatePluginCommandTarget(pid, navigationURL: navigationURL)
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
    // Restore the snapshot the entry verb armed (`restore_mode=1`) if any;
    // otherwise fall through to the default exit target. Clear the slot in
    // either case so the next open starts fresh.
    let target =
      commandLineRestoreModeTarget
      ?? Self.commandLineExitMode(currentMode: flashMode)
    commandLineRestoreModeTarget = nil
    transitionMode(to: target, reason: reason)
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
    candidateFinderPrecedenceTable = .default
    candidateFinderIncrementalCache = nil
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

  func sendNormalModeKey(
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
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        // Note the synthesized chord so a `postToPid` event that loops back
        // through the Carbon dispatcher can't re-trigger our own hotkey for
        // the same combo (e.g. the `⌘⇧]` Messages tab-traversal fallback).
        self?.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
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
      mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
      NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: context.processID)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
      self?.scheduleNormalModeRecapture()
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
  func activatePluginCommandTarget(_ pid: pid_t?, navigationURL: URL? = nil) {
    if let navigationURL {
      recordMovement(.route(navigationURL, pid: pid), source: "plugin_command")
    }
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

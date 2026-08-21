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

private struct NormalModeKeyDispatchTarget {
  let processID: pid_t
  let bundleIdentifier: String
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
    dispatchMode(.enterNormal(targetPID: nil))
  }

  func enterInsertMode(
    reason: InsertModeTransitionReason = .explicitCommand,
    targetPID: pid_t? = nil
  ) {
    let pid = Self.insertEntryTargetPID(
      explicitTargetPID: targetPID,
      currentMode: flashMode,
      normalModeTargetPID: normalModeTargetPID)
    FlashLog.trace(
      "[mode] enter_insert reason=\(reason.logValue) from=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight)")
    dispatchMode(.enterInsert(reason: reason, targetPID: pid))
  }

  /// The single mutation entry point for the mode: feed the event through the
  /// pure reducer, then perform the effects it returns.
  func dispatchMode(_ event: ModeEvent) {
    modeStore.dispatch(event)
  }

  /// Performs the effects the reducer emitted. The reducer DECIDES the
  /// transition and what to sync; this just does the AppKit work, reusing the
  /// existing routines. No decisions live here.
  func applyModeEffects(_ effects: [ModeEffect], previous _: Mode, next: Mode) {
    for effect in effects {
      switch effect {
      case .setMappingScope(let scope):
        mappings.apply(scope: scope)
      case .clearTransientHintState:
        // Reads the still-current overlay surface to tear down a command /
        // modal we are leaving, then clears hint + input state.
        closeModalStateForModeExit(reason: "mode_enter")
        resetModeInputState()
        clearTransientHintState(reason: "mode_enter")
      case .renderSurface:
        applyEnterBookkeeping(next)
        applyModeOverlay()
      case .scheduleRecapture:
        scheduleNormalModeRecapture()
      case .activateFocusedApp(let pid):
        activateInsertTargetApp(pid)
      case .hideOverlayIfIdle:
        if currentHints.isEmpty { overlay.hide() }
      }
    }
  }

  /// Per-base-mode bookkeeping that must run before the surface is rendered.
  private func applyEnterBookkeeping(_ next: Mode) {
    // Any base-mode transition ends a transient native-surface suspension; clear
    // it before the surface renders so capture isn't pinned off afterward.
    nativeSurfaceSuspended = false
    switch next {
    case .normal:
      if let context = normalModeContext() {
        normalModeTargetPID = context.processID
        suppressEditableFocus(for: context.processID)
      }
    case .insert, .disabled:
      normalModeTargetPID = nil
    case .command:
      break
    }
  }

  /// Re-activate the focused app on INSERT entry so its window reclaims key
  /// status from the panel (the Messages "first keystroke dropped" fix).
  private func activateInsertTargetApp(_ pid: pid_t?) {
    let target = pid.flatMap { monitor.context(for: $0) } ?? currentNonFlashContext()
    guard let target,
      let app = NSRunningApplication(processIdentifier: target.processID),
      !app.isTerminated
    else { return }
    RunningApplicationActivation.activate(app, options: [])
  }

  /// Map a projected mode label to the user-configured string.
  func modeLabelText(_ label: ModeLabel) -> String {
    switch label {
    case .insert: return config.mode.labels.insert
    case .normal: return config.mode.labels.normal
    case .command: return config.mode.labels.command
    }
  }

  func invalidateActivation(reason: String) {
    if activationInFlight || activationInFlightGeneration != nil {
      FlashLog.trace(
        "[activation] invalidate reason=\(reason) gen=\(activationGen) "
          + "in_flight_gen=\(String(describing: activationInFlightGeneration))")
    }
    activationLifecycle.invalidate()
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
    clearHintSessionState()
    pendingAction = .leftClick
    if hadActivation {
      invalidateActivation(reason: reason)
    }
  }

  func refreshCurrentModeSideEffects(reason: String) {
    // Both modes paint the active-window border (thin green normal / blue insert).
    updateActiveWindowBorder(reason: reason)
  }

  func activeWindowMayHaveChanged(
    pid: pid_t,
    notification: String,
    observedWindow: AXUIElement?
  ) {
    guard let context = currentNonFlashContext(), context.processID == pid else { return }
    if let observedWindow,
      notification == kAXWindowMovedNotification as String
        || notification == kAXWindowResizedNotification as String
        || notification == kAXUIElementDestroyedNotification as String
    {
      windowLayoutManager.observedWindowFrameChange(
        pid: pid,
        window: observedWindow,
        frame: context.frontWindowFrame,
        notification: notification,
        statusBarReservesSpace: statusBarVisible)
    }
    // A browser tab switch / navigation surfaces here (title/window AX changes)
    // without an app-focus change — re-resolve URL-scoped plugin mappings.
    scheduleURLContextMappingRefresh(pid: pid)
    if pluginManager.hasListener(for: "core:ax.changed") {
      pluginManager.emit(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["notification": notification, "pid": Int(pid)],
          bundleID: context.bundleIdentifier,
          configPath: nil,
          focused: true))
    }
    // The focused-window-changed and main-window-changed AX notifications are
    // exactly the signal plugins want to react to when they care about *which*
    // window inside an app is on top (e.g. an iTerm/Alacritty plugin watching
    // tmux clients move between attached terminals). The generic
    // `core:ax.changed` fires for any AX mutation, so it's too noisy for that
    // use case; this dedicated event carries the focused window's frame and
    // pid so subscribers can filter on it directly.
    let isFocusChange =
      notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
    if isFocusChange {
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
    if isFocusChange {
      // A window FOCUS change (switching windows/apps) is not a move — redraw
      // the insert border at the newly-focused window in place. Routing focus
      // changes through the move/resize "hide during change" path is what made
      // the border flicker off (appear-then-vanish) on every app switch and on
      // insert entry.
      scheduleAmbientLocationRecord(pid: pid, reason: "window_focus")
    }
    // Window AX notifications are delivered after the operation. Resolve the
    // authoritative WindowServer frame now and replace (or clear) the stroke in
    // one transaction; delaying behind a quiet period leaves a stale border.
    updateActiveWindowBorder(reason: notification)
    scheduleActiveWindowBorderReconciliation(
      delaysMs: [Self.activeWindowBorderEventSettleDelayMs], reason: notification)
  }

  private func resetModeInputState() {
    cancelCandidateFinderSessionWork()
    overlay.normalModePending = ""
    overlay.normalModeRepeatAnchor = nil
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
    // `.normalModePassthrough` is user-driven too: it is scheduled only when
    // the user presses an unmapped configured key or modifier chord in NORMAL.
    reason == .hintCommit || reason == .normalModeInput || reason == .lockedNormalModeInput
      || reason == .pointerClick || reason == .explicitCommand
      || reason == .normalModePassthrough
  }

  func focusedInputMayHaveChanged(pid: pid_t) {
    // Mode is no longer driven by focus changes — the only way to leave INSERT
    // is an explicit keyboard request (`enterNormalMode`); focus-following
    // auto-exit was removed. But URL-scoped plugin mappings (e.g. Gmail's `o`)
    // must follow the focused document, which can change with no app-focus
    // change (browser tab switch / in-page navigation), so re-resolve them here.
    scheduleURLContextMappingRefresh(pid: pid)
  }

  /// Re-resolve URL-scoped plugin mappings for `pid` (e.g. Gmail's `o`, which
  /// only applies on `mail.google.com`). The effective set is recomputed on
  /// app-focus change, but a tab switch or in-page navigation keeps the same
  /// app focused while the document URL — and thus the applicable mappings —
  /// changes. Debounced so a burst of AX notifications collapses to a single
  /// `documentURL` probe + remap; a no-op unless a URL-selector plugin is loaded.
  func scheduleURLContextMappingRefresh(pid: pid_t) {
    guard pluginManager.needsURLSelectorContext(),
      let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    else { return }
    urlContextMappingRefreshWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      else { return }
      self.refreshEffectiveMappings(for: bundleID, includeURL: true)
    }
    urlContextMappingRefreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
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

  static func insertModeMayArmEditableFocusExit(
    bundleIdentifier: String?,
    insertModeLocked: Bool
  ) -> Bool {
    guard !insertModeLocked, let bundleIdentifier else { return false }
    return !TerminalBundles.identifiers.contains(bundleIdentifier)
  }

  static func insertModeMayRepairEditableFocus(
    reason: InsertModeTransitionReason?,
    bundleIdentifier: String?,
    insertModeLocked: Bool
  ) -> Bool {
    guard
      insertModeMayArmEditableFocusExit(
        bundleIdentifier: bundleIdentifier,
        insertModeLocked: insertModeLocked)
    else { return false }
    return reason == .hintCommit || reason == .pointerClick
  }

  static func insertEntryTargetPID(
    explicitTargetPID: pid_t?,
    currentMode: FlashMode,
    normalModeTargetPID: pid_t?
  ) -> pid_t? {
    explicitTargetPID ?? (currentMode == .normal ? normalModeTargetPID : nil)
  }

  static func insertFocusExitShouldWaitForPointerRelease(
    pressedMouseButtons: Int = NSEvent.pressedMouseButtons
  ) -> Bool {
    pressedMouseButtons != 0
  }

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
  /// into insert mode or re-key normal capture. (Hints visible → still
  /// cancel: the user is scrolling away from the picker.)
  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    NormalModePointerPolicy.pointerScrollShouldPassThrough(mode: mode, hasHints: hasHints)
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
      // stale border via `updateActiveWindowBorder`'s built-in
      // hide branch.
      refreshActiveWindowBorder: true)
  }

  func applyModeOverlay(captureOverride: Bool? = nil) {
    let mode = modeStore.mode
    // A pointer-mode session behaves exactly like a hint set being up: the
    // transient overlay owns input (`.hints`) and NORMAL's own capture is off.
    let hasHints = !currentHints.isEmpty || hintSession.pointerModeActive
    let inFlight = activationInFlight
    let suspended = nativeSurfaceSuspended
      || Self.aboutWindowShouldOwnNativeKeyboard(
        visible: aboutWindowVisible,
        hasTransientInput: hasHints,
        activationInFlight: inFlight)
    let inputMode = mode.overlayInputMode(
      hasHints: hasHints, activationInFlight: inFlight, nativeSurfaceSuspended: suspended)
    // A native-surface suspension forces capture off even when a caller passes
    // `captureOverride: true` (e.g. a recapture attempt that raced a menu open).
    let capture =
      (captureOverride ?? mode.ownsKeyboard(hasHints: hasHints, activationInFlight: inFlight))
      && !suspended
    let text = modeLabelText(mode.label)
    FlashLog.trace(
      "[mode] overlay mode=\(mode) input=\(inputMode) capture=\(capture) "
        + "override=\(String(describing: captureOverride)) suspended=\(suspended) "
        + "visible=\(statusBarVisible) hints=\(currentHints.count) in_flight=\(inFlight)")
    statusBarController?.updateModeLabel(text)
    overlay.inputMode = inputMode
    updateActiveWindowBorder(reason: "apply_mode_overlay")
    overlay.setModeBadge(
      text: text,
      visible: mode.badgeVisibleIntrinsic && statusBarVisible,
      captureInput: capture,
      style: mode.badgeStyle)
  }

  static func commandSurfaceModeLabel(labels: Config.Mode.Labels) -> String {
    labels.command
  }

  func suppressEditableFocus(for pid: pid_t) {
    guard pid > 0 else { return }
  }

  func scheduleNormalModeRecapture(delaysMs: [Int] = AppDelegate.normalModeRecaptureDelaysMs) {
    guard !aboutWindowVisible else {
      FlashLog.trace("[mode] recapture_skip reason=about_window")
      return
    }
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
    // Reaching here means no suppression is active — any native surface (context
    // menu) has dismissed — so clear the suspend flag before re-establishing
    // capture, otherwise the projection keeps capture pinned off.
    nativeSurfaceSuspended = false
    // Flip `overlay.inputMode` to `.normal` synchronously before
    // scheduling the retries. The 0 ms entry below is still a
    // `DispatchQueue.main.asyncAfter` — it doesn't run until the next
    // runloop turn — so set the routing mode before any later recapture
    // attempt can see stale `.hints` state left over from `commit()`'s
    // pre-dispatch `applyModeOverlay(captureOverride: false)`.
    if shouldCaptureNormalModeInput {
      applyModeOverlay(captureOverride: true)
    }
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    cancelNormalModeCaptureRecovery(reason: "new_recapture")
    let delays = delaysMs.isEmpty ? [0] : delaysMs
    FlashLog.trace(
      "[mode] schedule_recapture token=\(token) delays="
        + delays.map(String.init).joined(separator: ","))
    for delayMs in delays {
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

  func aboutWindowVisibilityDidChange(_ visible: Bool) {
    guard aboutWindowVisible != visible else { return }
    aboutWindowVisible = visible
    normalModeRecaptureToken &+= 1
    cancelNormalModeCaptureRecovery(reason: "about_window")
    applyModeOverlay()
    if !visible, flashMode == .normal {
      scheduleNormalModeRecapture()
    }
  }

  static func aboutWindowShouldOwnNativeKeyboard(
    visible: Bool,
    hasTransientInput: Bool,
    activationInFlight: Bool
  ) -> Bool {
    visible && !hasTransientInput && !activationInFlight
  }

  func noteMenuBarInteraction(reason: String, now: Date = Date()) {
    menuBarInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.menuBarInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    cancelNormalModeCaptureRecovery(reason: "menu_bar_interaction")
    FlashLog.trace("[mode] menu_bar_interaction reason=\(reason) recapture_suppressed=true")
  }

  func noteContextMenuInteraction(reason: String, now: Date = Date()) {
    contextMenuInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.contextMenuInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    cancelNormalModeCaptureRecovery(reason: "context_menu_interaction")
    FlashLog.trace("[mode] context_menu_interaction reason=\(reason) recapture_suppressed=true")
  }

  @discardableResult
  func notePointerInsertHandoff(reason: String, now: Date = Date()) -> UInt64 {
    pointerInsertHandoffToken &+= 1
    pointerInsertHandoffRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.pointerInsertHandoffRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    cancelNormalModeCaptureRecovery(reason: "pointer_insert_handoff")
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
    recaptureSuppression.pruneExpired(now: now)
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
    RecaptureSuppression.active(until, now: now)
  }

  static func contextMenuInteractionRecaptureSuppressionIsActive(
    until: Date?,
    now: Date = Date()
  ) -> Bool {
    RecaptureSuppression.active(until, now: now)
  }

  static func pointerActionMayEnterInsert(_ action: JumpAction) -> Bool {
    NormalModePointerPolicy.pointerActionMayEnterInsert(action)
  }

  private func cancelNormalModeCaptureRecovery(reason: String) {
    guard normalModeCaptureRecoveryRecaptureToken != nil else { return }
    normalModeCaptureRecoveryToken &+= 1
    normalModeCaptureRecoveryRecaptureToken = nil
    FlashLog.trace("[mode] capture_recovery_cancel reason=\(reason)")
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
    if let click = Self.pointerFocusLossClick(
      pressedMouseButtons: NSEvent.pressedMouseButtons,
      currentEventType: NSApp.currentEvent?.type,
      location: NSEvent.mouseLocation)
    {
      cancelPointerInsertHandoff(reason: "pointer_focus_loss")
      FlashLog.trace(
        "[mode] pointer_focus_loss_handoff action=\(click.action) "
          + "buttons=\(NSEvent.pressedMouseButtons)")
      let decision = NormalModePointerPolicy.appClickDecision(
        mode: flashMode,
        wasCommandLine: overlay.inputMode == .commandLine,
        hasHints: false,
        action: click.action)
      handleAppPointerDecision(decision, click: click)
      return
    }
    if Self.pointerFocusLossShouldDeferRecaptureForPointerMonitor(
      inputMode: overlay.inputMode,
      modeBadgeVisible: overlay.modeBadgeVisible,
      modeBadgeCapturesInput: overlay.modeBadgeCapturesInput)
    {
      deferNormalModeRecaptureAfterPointerFocusLoss(reason: "await_pointer_monitor")
      return
    }
    FlashLog.trace(
      "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
        + "reason=normal_mode_focus_contract")
    scheduleNormalModeRecapture()
  }

  private func deferNormalModeRecaptureAfterPointerFocusLoss(reason: String) {
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    FlashLog.trace(
      "[mode] pointer_recapture_defer target=\(Self.pointerFocusLossTarget()) "
        + "reason=\(reason) token=\(token)")
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.pointerFocusLossRecaptureDeferralMs)
    ) { [weak self] in
      guard let self else { return }
      guard self.normalModeRecaptureToken == token else {
        FlashLog.trace("[mode] pointer_recapture_defer_skip token=\(token) reason=stale")
        return
      }
      guard self.flashMode == .normal else {
        FlashLog.trace(
          "[mode] pointer_recapture_defer_skip token=\(token) reason=mode "
            + "mode=\(self.flashMode)")
        return
      }
      guard
        !Self.contextMenuInteractionRecaptureSuppressionIsActive(
          until: self.contextMenuInteractionRecaptureSuppressedUntil)
      else {
        FlashLog.trace(
          "[mode] pointer_recapture_defer_skip token=\(token) reason=context_menu_interaction")
        return
      }
      guard
        !Self.pointerInsertHandoffRecaptureSuppressionIsActive(
          until: self.pointerInsertHandoffRecaptureSuppressedUntil)
      else {
        FlashLog.trace(
          "[mode] pointer_recapture_defer_skip token=\(token) "
            + "reason=pointer_insert_handoff_pending")
        return
      }
      if Self.pointIsInMenuBar(NSEvent.mouseLocation) {
        self.noteMenuBarInteraction(reason: "pointer_focus_loss_deferred")
        FlashLog.trace("[mode] pointer_recapture_defer_skip token=\(token) target=menu_bar")
        return
      }
      FlashLog.trace(
        "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
          + "reason=normal_mode_focus_contract_deferred")
      self.scheduleNormalModeRecapture()
    }
  }

  static let normalModeRecaptureDelaysMs = [0, 10, 30, 60, 120, 250, 500, 900, 1_400]
  static let normalModeFocusChangingRecaptureDelaysMs = [
    0, 1, 4, 8, 16, 30, 60, 120, 250, 500, 900, 1_400,
  ]
  static var normalModeKeyTargetActivationDelayMs: Int { FlashTunables.sendKeyIntervalMs }

  private static let normalModeKeyModifierMask: CGEventFlags = [
    .maskCommand, .maskControl, .maskAlternate, .maskShift,
  ]
  static let normalModeCaptureRecoveryDelaysMs = [250, 750, 1_500, 3_000]
  static let menuBarInteractionRecaptureSuppressionMs = 1_500
  static let contextMenuInteractionRecaptureSuppressionMs = 1_500
  static let pointerInsertHandoffRecaptureSuppressionMs = 1_500
  // Brief: just long enough for the pointer monitor to turn a click into INSERT
  // before we reclaim key. Any longer and an app that spontaneously steals
  // focus would sit on it while the badge still reads NORMAL — the exact
  // "shown but not capturing" inconsistency we want to make impossible.
  static let pointerFocusLossRecaptureDeferralMs = 120
  static let activeWindowBorderEventSettleDelayMs = 80
  static let activeWindowBorderRecoveryDelaysMs = [80, 250, 750]
  static let activeWindowBorderFrameTolerance: CGFloat = 1

  private static func pointerFocusLossTarget() -> String {
    pointIsInMenuBar(NSEvent.mouseLocation) ? "menu_bar" : "window_or_popup"
  }

  static func pointerFocusLossClick(
    pressedMouseButtons: Int,
    currentEventType: NSEvent.EventType? = nil,
    location: CGPoint
  ) -> OverlayPointerClick? {
    if currentEventType == .rightMouseDown {
      return OverlayPointerClick(action: .rightClick, location: location, modifiers: .all)
    }
    if currentEventType == .leftMouseDown || currentEventType == .otherMouseDown {
      return OverlayPointerClick(action: .leftClick, location: location, modifiers: .all)
    }
    guard pressedMouseButtons != 0 else { return nil }
    let action: JumpAction = (pressedMouseButtons & (1 << 1)) != 0 ? .rightClick : .leftClick
    return OverlayPointerClick(action: action, location: location, modifiers: .all)
  }

  static func pointerFocusLossShouldDeferRecaptureForPointerMonitor(
    inputMode: OverlayInputMode,
    modeBadgeVisible: Bool,
    modeBadgeCapturesInput: Bool
  ) -> Bool {
    OverlayPanel.pointerIntentMonitorShouldRun(
      inputMode: inputMode,
      modeBadgeVisible: modeBadgeVisible,
      modeBadgeCapturesInput: modeBadgeCapturesInput)
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
    RecaptureSuppression.active(until, now: now)
  }

  static func normalModeCaptureRecoveryShouldRetry(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    keyboardCaptureIsActive: Bool,
    menuBarInteractionRecaptureSuppressedUntil: Date?,
    contextMenuInteractionRecaptureSuppressedUntil: Date?,
    pointerInsertHandoffRecaptureSuppressedUntil: Date?,
    now: Date = Date()
  ) -> Bool {
    guard mode == .normal, !hasHints, !activationInFlight, !keyboardCaptureIsActive else {
      return false
    }
    switch overlayInputMode {
    case .commandLine, .candidateFinder:
      return false
    case .hints, .normal:
      break
    }
    return !menuBarInteractionRecaptureSuppressionIsActive(
      until: menuBarInteractionRecaptureSuppressedUntil,
      now: now)
      && !contextMenuInteractionRecaptureSuppressionIsActive(
        until: contextMenuInteractionRecaptureSuppressedUntil,
        now: now)
      && !pointerInsertHandoffRecaptureSuppressionIsActive(
        until: pointerInsertHandoffRecaptureSuppressedUntil,
        now: now)
  }

  var shouldCaptureNormalModeInput: Bool {
    return Self.normalModeShouldOwnKeyboardInput(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: !currentHints.isEmpty,
      activationInFlight: activationInFlight)
  }

  @discardableResult
  func guardNormalModeInputAfterActionDispatch(force: Bool = false) -> Bool {
    guard shouldCaptureNormalModeInput else { return false }
    // If the panel already owns the key window AND is routing as normal, the
    // command didn't disturb focus (the common case for scroll/tab/vim
    // sequences and back-to-back chords). Capture is already intact, so skip
    // the re-render + recapture ramp: re-asserting on every keystroke runs an
    // `orderOut`+re-key cycle that can momentarily drop a rapid follow-up key
    // to the focused app ("fires late / lands in the wrong window"). Only
    // re-assert when key was actually lost (e.g. the command activated another
    // app) or the input routing is stale.
    if !force, overlay.keyboardCaptureIsActive, overlay.inputMode == .normal { return false }
    applyModeOverlay(captureOverride: true)
    return true
  }

  static func normalModeShouldRecaptureAfterActionDispatch(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool
  ) -> Bool {
    normalModeShouldOwnKeyboardInput(
      mode: mode,
      overlayInputMode: overlayInputMode,
      hasHints: hasHints,
      activationInFlight: activationInFlight)
  }

  static func normalModeShouldOwnKeyboardInput(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool
  ) -> Bool {
    guard mode == .normal, !hasHints, !activationInFlight else { return false }
    switch overlayInputMode {
    case .hints, .normal:
      return true
    case .commandLine, .candidateFinder:
      return false
    }
  }

  func hasNormalModeBinding(_ cfg: Config) -> Bool {
    cfg.mode.containsAdvancedModeMapping
  }

  func dispatchNativeMappingAction(_ action: MappingCommand) {
    let wasNormal = flashMode == .normal
    if wasNormal {
      overlay.normalModePending = ""
      overlay.normalModeRepeatAnchor = nil
      normalModePendingCommandToken &+= 1
    }
    performMappingCommand(action)
    guard wasNormal else { return }
    let focusChanging = Self.normalModeActionMayChangeKeyboardFocus(action)
    if guardNormalModeInputAfterActionDispatch(force: focusChanging) {
      scheduleNormalModeRecapture(
        delaysMs: focusChanging
          ? Self.normalModeFocusChangingRecaptureDelaysMs
          : Self.normalModeRecaptureDelaysMs)
    }
  }

  static func normalModeActionMayChangeKeyboardFocus(_ action: MappingCommand) -> Bool {
    switch action {
    case .shellCommand:
      return true
    case .flashCommand(let command):
      return normalModeCommandMayChangeKeyboardFocus(command)
    }
  }

  static func normalModeCommandMayChangeKeyboardFocus(_ command: URLCommand) -> Bool {
    switch command {
    case .openApp, .pluginCommand, .pluginVerb, .appPrev, .appNext, .showAbout,
      .movementBack, .movementForward, .quitApp, .saveAndQuit:
      return true
    case .sendKey(_, _, let flagsRawValue):
      return normalModeKeyDispatchNeedsTargetActivation(
        flags: CGEventFlags(rawValue: flagsRawValue))
    case .sendKeys(_, _, let flagsRawValues):
      return flagsRawValues.contains {
        normalModeKeyDispatchNeedsTargetActivation(flags: CGEventFlags(rawValue: $0))
      }
    default:
      return false
    }
  }

  static func normalModeKeyDispatchNeedsTargetActivation(flags: CGEventFlags) -> Bool {
    flags.intersection(normalModeKeyModifierMask).isEmpty
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
    case .sendKeys(_, let keyCodes, let flagsRawValues):
      let sequence = zip(keyCodes, flagsRawValues).map {
        (key: $0.0, flags: CGEventFlags(rawValue: $0.1))
      }
      sendNormalModeKeySequence(sequence, repeatCount: repeatCount)
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
    case .mouseTargetScreen(let command):
      activateScreenScopeHints(command)
    case .mouseGrid(let command):
      activateMouseGrid(command, contextOverride: normalModeContext())
    case .mouseRepeat:
      performMouseRepeat(repeatCount: repeatCount)
    case .mousePointer:
      enterPointerMode()
    case .focusInput:
      focusTextInputInNormalMode(index: repeatCount)
    case .scrollTarget:
      activateScrollTargetHints()
    case .mouseDock:
      activateDockHints()
    case .mouseStatusBar:
      activateStatusItemHints()
    case .copyURL:
      copyFocusedDocumentURL()
      applyModeOverlay()
    case .yankSelection(let register):
      yankSelection(into: register)
    case .paste(let register):
      pasteRegister(register, repeatCount: repeatCount)
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
    case .paneNext:
      paneNavigateInNormalMode(direction: .next, repeatCount: repeatCount)
    case .panePrev:
      paneNavigateInNormalMode(direction: .previous, repeatCount: repeatCount)
    case .paneSplitVertical:
      paneSplitInNormalMode(vertical: true, repeatCount: repeatCount)
    case .paneSplitHorizontal:
      paneSplitInNormalMode(vertical: false, repeatCount: repeatCount)
    case .paneClose:
      paneCloseInNormalMode(repeatCount: repeatCount)
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
      tabNewInNormalMode(repeatCount: repeatCount)
      // `t` is the user's explicit "open something fresh and start typing"
      // intent: switch to insert so they can type into the new tab/window.
      enterInsertMode(reason: .explicitCommand)
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showPlugins:
      openDebugDashboard(tab: "plugins")
    case .showAbout:
      handleURLCommand(command)
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
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.normalModeRepeatAnchor = nil
    closeModalStateForModeExit(reason: "enter_command_mode")
    clearTransientHintState(reason: "enter_command_mode")
    resetCommandLineState()
    if let candidateFinderScope {
      self.candidateFinderScope = candidateFinderScope
    } else {
      self.candidateFinderScope = .all
      clearCandidateFinderState()
    }
    overlay.setActiveWindowBorder(around: nil)
    let command = Self.commandLineBuffer(from: initialText)
    // The flashlight is just the command line pre-filled with `:flashlight ` —
    // render it on the native command-line surface (native editing + a blinking
    // caret + arrow/Ctrl-N-P candidate navigation) instead of the bespoke
    // `.finder` surface that drew a static `|`. The candidate scope is tracked
    // separately via `self.candidateFinderScope` / `openCandidateFinderSession`,
    // so the suggestion pool is unaffected.
    let scope: CommandScope = .commandLine
    dispatchMode(.openCommand(scope: scope, restoreMode: restoreMode))
    if let candidateFinderScope {
      openCandidateFinderSession(scope: candidateFinderScope)
      if let query = NormalModeDispatcher.commandLineCandidateQuery(command) {
        prefetchNonLocationSources(forCandidateQuery: query)
      }
    }
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

  /// `:help [topic]` — docs live in the HTTP dashboard's Docs tab, so open the
  /// browser there (deep-linked to the topic when one is named).
  func showHelp(topic: String? = nil) {
    openDebugDashboard(tab: "docs", topic: topic)
  }

  /// Open the HTTP debug inspector dashboard in the default browser on `tab`
  /// (`logs` / `plugins` / `commands` / `state` / `docs`), optionally deep-linked
  /// to a `topic` (Docs). Backs `:logs`, `:plugins`, `:commands`, `:help`. The
  /// inspector is loopback-only and on by default; we still start it on demand if
  /// it was disabled, and open the page once the listener has a bound port.
  func openDebugDashboard(tab: String, topic: String? = nil) {
    finishCommandLineInteraction(reason: "debug_dashboard")
    if debugServer == nil {
      let server = DebugServer(
        host: config.debug.httpInspectorHost,
        port: config.debug.httpInspectorPort,
        stateProvider: { [weak self] in self?.debugStateJSON() ?? [:] })
      debugServer = server
      server.start()
    }
    openDebugDashboardWhenReady(tab: tab, topic: topic, attempt: 0)
  }

  private func openDebugDashboardWhenReady(tab: String, topic: String?, attempt: Int) {
    guard let server = debugServer else { return }
    if let port = server.listeningPort {
      let host =
        (server.host == "0.0.0.0" || server.host.isEmpty) ? "127.0.0.1" : server.host
      let fragment =
        topic.flatMap { $0.isEmpty ? nil : $0 }
        .map { "\(tab)/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)" }
        ?? tab
      if let url = URL(string: "http://\(host):\(port)/#\(fragment)") {
        NSWorkspace.shared.open(url)
        FlashLog.info("[debug] opened inspector dashboard at \(url.absoluteString)")
      }
      return
    }
    guard attempt < 30 else {
      FlashLog.warn("[debug] inspector did not start in time")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      self?.openDebugDashboardWhenReady(tab: tab, topic: topic, attempt: attempt + 1)
    }
  }

  private func runPluginsSubcommand(_ sub: NormalModeDispatcher.PluginsSubcommand) {
    switch sub {
    case .modal:
      openDebugDashboard(tab: "plugins")
    case .reload:
      let ids = pluginManager.reloadAll()
      FlashLog.info("[plugins] reload command ids=\(ids.joined(separator: ","))")
      // The plugins tab shows live runtime state, so the reload's progress and
      // result land there instead of a one-shot modal.
      openDebugDashboard(tab: "plugins")
    }
  }

  /// `:mappings` — the resolved mapping table now lives in the dashboard's
  /// Mappings tab (fed by `debugStateJSON`).
  private func showMappings() {
    openDebugDashboard(tab: "mappings")
  }

  /// `:clipboard` — history now lives in the HTTP dashboard's Clipboard tab.
  /// Refresh the host cache from the plugin, then open the browser there. The
  /// history travels over the plugin command RPC (keeping this surface
  /// decoupled from the flashlight candidate pool).
  func openClipboardDashboard() {
    refreshClipboardDashboardCache()
    openDebugDashboard(tab: "clipboard")
  }

  /// Pull the full clipboard history from the plugin into `clipboardEntries`
  /// (the dashboard payload) and rebroadcast state so an open inspector updates
  /// live. Driven by `:clipboard` and by each pasteboard change.
  func refreshClipboardDashboardCache() {
    _ = pluginManager.invoke(
      command: "clipboard", subcommand: "", args: [], raw: ":clipboard",
      in: pluginSelectorContext()
    ) { [weak self] ok, _, stdout, _ in
      let entries = (ok ? stdout : nil).flatMap(Self.decodeClipboardModalEntries) ?? []
      DispatchQueue.main.async {
        guard let self else { return }
        self.clipboardEntries = entries
        self.debugServer?.broadcastState()
      }
    }
  }

  static func decodeClipboardModalEntries(_ json: String) -> [ClipboardModalEntry]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([ClipboardModalEntry].self, from: data)
  }

  static var candidateFinderFirstPaintBudgetMs: Int { 150 }
  static var candidateFinderSlowReplyWarningMs: Int { 100 }

  /// Open a flashlight session behind a short, session-local fan-in barrier.
  /// The command prompt paints immediately with no rows. Built-in applications
  /// and every eligible plugin's in-memory location catalog are then frozen into
  /// one deterministic snapshot and revealed exactly once. Nothing is retained
  /// in the host after the session closes.
  func openCandidateFinderSession(scope: CandidateScope) {
    let startedNs = DispatchTime.now().uptimeNanoseconds
    candidateFinderPrecedenceTable = buildCandidateFinderPrecedenceTable()
    candidateFinderScope = scope
    candidateFinderSessionGeneration &+= 1
    invalidateCandidateQueryEvaluation()
    let generation = candidateFinderSessionGeneration
    candidateFinderFetchedNonLocationSourceIDs.removeAll()
    candidateFinderDeferredNonLocationSnapshots.removeAll()
    candidateFinderInitialDeadlineWork?.cancel()
    candidateFinderInitialDeadlineWork = nil
    candidateFinderInitialSnapshotReady = false
    candidateFinderSubmissionDeferral.cancel()
    candidateFinderCandidates = []
    candidateFinderMatches = []
    candidateFinderSelectedIndex = 0

    // Built-in candidate sources join the barrier too: core.apps may still be
    // waiting on its asynchronous resident-startup index, so it is gathered as
    // a regular expected source instead of being frozen as a partial seed.
    var sourcesByID: [String: FlashSource] = [:]
    for source in registry.initialCandidateSnapshotSources() {
      sourcesByID[source.identifier] = source
    }
    let sources = sourcesByID.values.sorted { $0.identifier < $1.identifier }
    candidateFinderInitialBarrier = CandidateSnapshotBarrier(
      generation: generation,
      startedNs: startedNs,
      expectedSourceIDs: sources.map(\.identifier))

    let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
    FlashLog.trace(
      "[candidate_finder] snapshot_begin generation=\(generation) scope=\(scope) "
        + "sources=\(sources.count) seed_ms=\(elapsedMs)")

    // Let `enterCommandLineMode` render/focus the native text field first.
    // Snapshots start on the next main turn, so even a future synchronous source
    // cannot publish rows before the prompt has appeared.
    DispatchQueue.main.async { [weak self] in
      self?.startInitialCandidateSnapshots(
        sources,
        scope: scope,
        generation: generation)
    }
  }

  private func startInitialCandidateSnapshots(
    _ sources: [FlashSource],
    scope: CandidateScope,
    generation: UInt64
  ) {
    guard generation == candidateFinderSessionGeneration,
      let barrier = candidateFinderInitialBarrier,
      barrier.generation == generation
    else { return }

    let elapsedMs = Int(
      (DispatchTime.now().uptimeNanoseconds &- barrier.startedNs) / 1_000_000)
    let remainingMs = max(0, Self.candidateFinderFirstPaintBudgetMs - elapsedMs)
    if remainingMs == 0 {
      finalizeInitialCandidateSnapshot(
        generation: generation, reason: .firstPaintBudget)
      return
    }

    let deadline = DispatchWorkItem { [weak self] in
      self?.finalizeInitialCandidateSnapshot(
        generation: generation, reason: .firstPaintBudget)
    }
    candidateFinderInitialDeadlineWork = deadline
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(remainingMs),
      execute: deadline)

    guard !sources.isEmpty else {
      finalizeInitialCandidateSnapshot(
        generation: generation, reason: .allSourcesSettled)
      return
    }

    let env = registry.snapshotEnvironment
    for source in sources {
      let snapshotStartedNs = DispatchTime.now().uptimeNanoseconds
      source.snapshotCandidates(in: env, scope: scope) { [weak self] candidates in
        self?.recordInitialCandidateReply(
          candidates,
          sourceID: source.identifier,
          generation: generation,
          snapshotStartedNs: snapshotStartedNs)
      }
    }
  }

  private func recordInitialCandidateReply(
    _ candidates: [Candidate],
    sourceID: String,
    generation: UInt64,
    snapshotStartedNs: UInt64
  ) {
    let nowNs = DispatchTime.now().uptimeNanoseconds
    let latencyMs = Int((nowNs &- snapshotStartedNs) / 1_000_000)
    guard generation == candidateFinderSessionGeneration else {
      FlashLog.trace(
        "[candidate_finder] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=stale_session ms=\(latencyMs)")
      return
    }
    guard var barrier = candidateFinderInitialBarrier,
      barrier.generation == generation
    else {
      if candidateFinderInitialSnapshotReady {
        FlashLog.warn(
          "[candidate_finder] snapshot_reply_late source=\(sourceID) "
            + "generation=\(generation) ms=\(latencyMs) count=\(candidates.count) ignored=true")
      }
      return
    }

    let result = barrier.record(
      sourceID: sourceID,
      candidates: candidates,
      latencyMs: latencyMs)
    candidateFinderInitialBarrier = barrier
    switch result {
    case .accepted:
      FlashLog.trace(
        "[candidate_finder] snapshot_reply source=\(sourceID) generation=\(generation) "
          + "ms=\(latencyMs) count=\(candidates.count) "
          + "settled=\(barrier.settledSourceCount)/\(barrier.expectedSourceCount)")
      if latencyMs >= Self.candidateFinderSlowReplyWarningMs {
        FlashLog.warn(
          "[candidate_finder] snapshot_reply_slow source=\(sourceID) "
            + "generation=\(generation) ms=\(latencyMs) "
            + "budget_ms=\(Self.candidateFinderFirstPaintBudgetMs)")
      }
      if barrier.isSettled {
        finalizeInitialCandidateSnapshot(
          generation: generation, reason: .allSourcesSettled)
      }
    case .duplicate:
      FlashLog.warn(
        "[candidate_finder] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=duplicate")
    case .unknownSource:
      FlashLog.warn(
        "[candidate_finder] snapshot_reply_ignored source=\(sourceID) "
          + "generation=\(generation) reason=unknown_source")
    case .finalized:
      FlashLog.warn(
        "[candidate_finder] snapshot_reply_late source=\(sourceID) "
          + "generation=\(generation) ms=\(latencyMs) count=\(candidates.count) ignored=true")
    }
  }

  private func finalizeInitialCandidateSnapshot(
    generation: UInt64,
    reason: CandidateSnapshotBarrier.FinalizationReason
  ) {
    guard generation == candidateFinderSessionGeneration,
      var barrier = candidateFinderInitialBarrier,
      barrier.generation == generation,
      let snapshot = barrier.finalize(reason: reason)
    else { return }

    candidateFinderInitialDeadlineWork?.cancel()
    candidateFinderInitialDeadlineWork = nil
    // Keep the finalized barrier installed while the raw snapshot is prepared
    // off-main. `refreshCommandLine` continues to show a live empty prompt and
    // late opt-in replies are buffered rather than overwriting this first
    // deterministic publication.
    candidateFinderInitialBarrier = barrier
    if !snapshot.missingSourceIDs.isEmpty {
      FlashLog.warn(
        "[candidate_finder] snapshot_budget_missed generation=\(generation) "
          + "budget_ms=\(Self.candidateFinderFirstPaintBudgetMs) "
          + "missing=\(snapshot.missingSourceIDs.joined(separator: ","))")
    }

    let startedNs = barrier.startedNs
    let expectedSourceCount = barrier.expectedSourceCount
    let settledSourceCount = snapshot.replies.count
    let latencies = snapshot.sourceLatencies.isEmpty ? "none" : snapshot.sourceLatencies
    candidateFinderPreparationQueue.async { [weak self] in
      var frozen: [Candidate] = []
      for reply in snapshot.replies {
        frozen.append(contentsOf: CandidateFinder.prepare(reply.candidates))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self,
          generation == self.candidateFinderSessionGeneration,
          self.candidateFinderInitialBarrier?.generation == generation
        else { return }

        self.candidateFinderCandidates = frozen
        self.candidateFinderSelectedIndex = 0
        self.candidateFinderInitialBarrier = nil
        self.candidateFinderInitialSnapshotReady = true
        self.publishDeferredNonLocationSnapshots(generation: generation)

        let elapsedMs = Int(
          (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        FlashLog.info(
          "[candidate_finder] snapshot_ready generation=\(generation) reason=\(reason.rawValue) "
            + "count=\(self.candidateFinderCandidates.count) "
            + "settled=\(settledSourceCount)/\(expectedSourceCount) "
            + "ms=\(elapsedMs) source_ms=\(latencies)")
        self.rerenderActiveCandidateFinderSurface()
      }
    }
  }

  /// Lazily pull non-location candidate stores when the user opts into them.
  /// A confirmed `@source` fetches only providers that declare a matching
  /// source label; bang completion still asks for all providers because some
  /// bang rows (the DuckDuckGo registry) are catalog-driven. Providers are
  /// tracked individually so switching explicit sources later in the same
  /// session still works without repeating prior snapshots.
  func fetchNonLocationSourcesIfNeeded(matching sourceFilter: String? = nil) {
    let sources = registry.nonLocationCandidateSources(matching: sourceFilter)
    let pending = sources.filter { source in
      candidateFinderFetchedNonLocationSourceIDs.insert(source.identifier).inserted
    }
    guard !pending.isEmpty else { return }
    fanOutCandidateSnapshots(
      pending,
      generation: candidateFinderSessionGeneration)
  }

  /// Start only the warm non-location snapshots implied by the current query.
  /// This can run while the initial location barrier is still preparing, which
  /// overlaps plugin decoding with first-paint work. Partial `@source`
  /// completion remains manifest-only and performs no catalog request.
  private func prefetchNonLocationSources(forCandidateQuery query: String) {
    let sourceCompletion = CandidateFinder.sourceCompletionState(query: query)
    let bangCompletion = CandidateFinder.bangCompletionState(query: query)
    let parsed =
      sourceCompletion == nil
      ? NormalModeDispatcher.candidateFinderSourceFilter(query)
      : NormalModeDispatcher.CandidateFinderQuery(sourceFilter: nil, text: query)
    let parsedBang = CandidateFinder.parseBang(parsed.text)
    if let sourceFilter = parsed.sourceFilter {
      fetchNonLocationSourcesIfNeeded(matching: sourceFilter)
    } else if bangCompletion != nil || parsedBang != nil {
      fetchNonLocationSourcesIfNeeded()
    }
  }

  /// A plugin declared its warm catalog stale (`sources.invalidated`). With
  /// no flashlight session open this is a no-op — the next open pulls fresh
  /// stores anyway. With one open, re-pull just that plugin's catalog and
  /// merge it through the per-source pool swap; live plugins instead get
  /// their (filter, text) dedup key cleared so the next keystroke refires.
  func handlePluginSourcesInvalidated(_ pluginID: String) {
    switch overlay.inputMode {
    case .commandLine, .candidateFinder: break
    default: return
    }
    let sourceID = "plugin:\(pluginID)"
    guard let source = pluginManager.sources.first(where: { $0.identifier == sourceID }) else {
      return
    }
    if SourceRegistry.isLiveCandidateSource(source) {
      candidateFinderLiveQueryKey = nil
      return
    }
    // Only re-pull catalogs this session already surfaced: an initial
    // (location) source, or a non-location one the user opted into.
    let alreadySurfaced =
      candidateFinderFetchedNonLocationSourceIDs.contains(sourceID)
      || registry.initialCandidateSnapshotSources().contains { $0.identifier == sourceID }
    guard alreadySurfaced else { return }
    FlashLog.trace("[candidate_finder] invalidated_repull source=\(sourceID)")
    fanOutCandidateSnapshots([source], generation: candidateFinderSessionGeneration)
  }

  /// Fire per-keystroke `sources.query` pulls at live plugin sources when —
  /// and only when — the query is explicitly scoped to them: an `@source`
  /// filter, or a confirmed bang bound to a `candidate_source`. The default
  /// pool and the first-paint barrier never see live sources. Late replies
  /// drop via the session generation; an unchanged (filter, text) pair does
  /// not refire, so a merge-triggered re-render can't loop.
  private func beginLiveSourceQueriesIfNeeded(forCandidateQuery query: String) {
    guard CandidateFinder.sourceCompletionState(query: query) == nil else { return }
    let parsed = NormalModeDispatcher.candidateFinderSourceFilter(query)
    let filter: String
    let text: String
    if let sourceFilter = parsed.sourceFilter {
      filter = sourceFilter
      text = parsed.text.trimmed
    } else if let bang = CandidateFinder.parseBangState(parsed.text.trimmed),
      bang.confirmed,
      let candidateSource = pluginManager.shebangCandidateSource(
        token: bang.token,
        in: pluginSelectorContext())
    {
      filter = candidateSource
      text = bang.remainder
    } else {
      return
    }
    let sources = registry.liveCandidateSources(matching: filter)
    guard !sources.isEmpty else { return }
    let generation = candidateFinderSessionGeneration
    let key = "\(generation)\u{1F}\(filter)\u{1F}\(text)"
    guard key != candidateFinderLiveQueryKey else { return }
    candidateFinderLiveQueryKey = key
    let env = registry.snapshotEnvironment
    for source in sources {
      source.liveCandidates(matching: text, in: env, scope: candidateFinderScope) {
        [weak self] candidates in
        self?.mergeCandidateSnapshotResults(candidates, from: source, generation: generation)
      }
    }
  }

  /// Fan user-requested non-location snapshots out in parallel. Initial location
  /// sources use the one-publish barrier above; this merge path is only reached
  /// after an explicit `@source` / `!` opt-in.
  private func fanOutCandidateSnapshots(
    _ sources: [FlashSource],
    generation: UInt64
  ) {
    let env = registry.snapshotEnvironment
    for source in sources {
      source.snapshotCandidates(in: env, scope: candidateFinderScope) {
        [weak self] candidates in
        self?.mergeCandidateSnapshotResults(candidates, from: source, generation: generation)
      }
    }
  }

  /// Merge one explicitly requested non-location source into the frozen initial
  /// pool, then re-render at the current query. Late replies from a closed or
  /// superseded session are dropped via the generation and surface guards.
  private func mergeCandidateSnapshotResults(
    _ candidates: [Candidate],
    from source: FlashSource,
    generation: UInt64
  ) {
    let sourceID = source.identifier
    candidateFinderPreparationQueue.async { [weak self] in
      let prepared = CandidateFinder.prepare(candidates)
      DispatchQueue.main.async { [weak self] in
        self?.receivePreparedCandidateSnapshot(
          prepared,
          sourceID: sourceID,
          generation: generation)
      }
    }
  }

  private func receivePreparedCandidateSnapshot(
    _ candidates: [Candidate],
    sourceID: String,
    generation: UInt64
  ) {
    guard generation == candidateFinderSessionGeneration else { return }
    switch overlay.inputMode {
    case .commandLine, .candidateFinder: break
    default: return
    }
    if candidateFinderInitialBarrier != nil {
      candidateFinderDeferredNonLocationSnapshots[sourceID] = candidates
      FlashLog.trace(
        "[candidate_finder] merge_deferred source=\(sourceID) count=\(candidates.count)")
      return
    }
    publishPreparedCandidateSnapshot(candidates, sourceID: sourceID)
    scheduleCoalescedCandidateFinderRerender()
  }

  private func publishPreparedCandidateSnapshot(_ candidates: [Candidate], sourceID: String) {
    let ownedPrefix = sourceID + "."
    var pool = candidateFinderCandidates.filter { candidate in
      candidate.sourceID != sourceID && !candidate.sourceID.hasPrefix(ownedPrefix)
    }
    pool.append(contentsOf: candidates)
    candidateFinderCandidates = pool
    FlashLog.trace(
      "[candidate_finder] merge source=\(sourceID) count=\(candidates.count) "
        + "pool=\(candidateFinderCandidates.count)")
  }

  private func publishDeferredNonLocationSnapshots(generation: UInt64) {
    guard generation == candidateFinderSessionGeneration else { return }
    let deferred = candidateFinderDeferredNonLocationSnapshots
    candidateFinderDeferredNonLocationSnapshots.removeAll()
    for sourceID in deferred.keys.sorted() {
      guard let candidates = deferred[sourceID] else { continue }
      publishPreparedCandidateSnapshot(candidates, sourceID: sourceID)
    }
  }

  /// Re-render once per runloop turn no matter how many opt-in sources merged.
  private func scheduleCoalescedCandidateFinderRerender() {
    guard !candidateFinderMergeRerenderScheduled else { return }
    candidateFinderMergeRerenderScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.candidateFinderMergeRerenderScheduled = false
      self.rerenderActiveCandidateFinderSurface()
    }
  }

  /// Re-score and repaint whichever flashlight surface is open after the pool
  /// changed mid-session. Both refresh paths fully replace the rendered rows, so
  /// inserting late candidates is safe; the user's typed query and selection are
  /// preserved by the existing scoring path.
  private func rerenderActiveCandidateFinderSurface() {
    switch overlay.inputMode {
    case .commandLine:
      refreshCommandLine(
        text: overlay.commandLineText, cursorIndex: overlay.commandLineCursorIndex)
    case .candidateFinder:
      refreshCandidateFinder(query: overlay.candidateFinderQuery)
    default:
      break
    }
    if candidateFinderQueryEvaluationSettledGeneration
      == candidateFinderQueryEvaluationInFlightGeneration
    {
      candidateFinderQueryEvaluationSettledGeneration = nil
      candidateFinderQueryEvaluationInFlightGeneration = nil
    }
    replayDeferredCandidateSubmissionIfReady()
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
      if candidateFinderCandidates.isEmpty,
        candidateFinderInitialBarrier == nil,
        !candidateFinderInitialSnapshotReady
      {
        // Cold command line (typed without a mapped flashlight entry): begin
        // the same one-publish initial gather as an explicit open.
        openCandidateFinderSession(scope: candidateFinderScope)
      }
      if candidateFinderInitialBarrier != nil {
        prefetchNonLocationSources(forCandidateQuery: query)
        // Keep the native text field live while the initial catalogs fan in,
        // but do not paint an apps-only list or a false "no matching app"
        // result. Finalization re-scores the latest text and reveals rows once.
        candidateFinderCurrentQuery = query
        candidateFinderMatches = []
        candidateFinderSelectedIndex = 0
        overlay.displayCommandLine(
          command,
          suggestions: nil,
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex)
        return
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
        // The locked-in query now belongs to the bang's dispatch, so keep
        // `candidateFinderCurrentQuery` current — submit re-parses it for the
        // remainder. This branch returns before `updateCandidateMatches` (which
        // normally sets it), so without this it stays stuck at the value from
        // before the confirming space: `!g weather paris` then searched nothing
        // and `weather !g paris` searched only "weather".
        invalidateCandidateQueryEvaluation()
        candidateFinderCurrentQuery = query
        candidateFinderMatches = []
        candidateFinderSelectedIndex = 0
        let queryRange = bangRangeInCommand(
          command: command, query: query, bangRange: bang.bangRange)
        overlay.displayCommandLine(
          command,
          suggestions: nil,
          emptyText: "",
          cursorIndex: overlay.commandLineCursorIndex,
          underlineRange: queryRange,
          underlineInvalid: !confirmedBangIsKnown(bang.token))
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
      if registration.subcommand.isEmpty || registration.subcommand == "*" { continue }
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
      // Vim abbreviation precedence: a candidate the query can actually
      // invoke (`:q` → `quit`) ranks above one it can't yet (`qall` needs
      // `:qa`), regardless of fuzzy score or frecency. Without this, the
      // equal-scoring `qall` / `quit` pair falls to the alphabetical
      // tiebreaker and `qall` wins — surfacing the wrong command for `:q`.
      if !trimmedQuery.isEmpty {
        let lhsInvokable = NormalModeDispatcher.isInvokableAbbreviation(
          query: trimmedQuery, label: lhs.completion.label)
        let rhsInvokable = NormalModeDispatcher.isInvokableAbbreviation(
          query: trimmedQuery, label: rhs.completion.label)
        if lhsInvokable != rhsInvokable { return lhsInvokable }
      }
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

  private var commandBarSuggestionCount: Int {
    max(1, config.flashlight.suggestionCount)
  }

  func commandLineCompletionDisplayItems() -> [CandidateDisplayItem] {
    guard !commandLineCompletionMatches.isEmpty else { return [] }
    // Same windowed slice as the flashlight finder. This list used to show
    // every match at once ("reveal the whole catalogue"), but the plugin
    // command set has outgrown the band between the centered prompt and the
    // screen bottom — an unwindowed list drew up across the prompt itself.
    // Arrow keys scroll the window over the full match set.
    let window = CandidateFinder.displayWindow(
      count: commandLineCompletionMatches.count,
      selectedIndex: commandLineCompletionSelectedIndex,
      windowSize: commandBarSuggestionCount)
    return commandLineCompletionMatches[window].enumerated().map { offset, match in
      CandidateDisplayItem(
        title: match.completion.label,
        highlightedRanges: commandLineCompletionQuery.isEmpty
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: commandLineCompletionQuery, candidate: match.completion.label),
        isSelected: window.lowerBound + offset == commandLineCompletionSelectedIndex)
    }
  }

  private func clearCommandLineCompletionState() {
    commandLineCompletionPrefix = ""
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
    let calculatorOnly = trimmed.first == "="
    if calculatorOnly {
      candidateFinderIncrementalCache = nil
      beginCandidateQueryEvaluationIfNeeded(text: trimmed)
      // A leading `=` is an exclusive evaluator marker. Do not score or show
      // the ordinary catalog while its owning calculator answers settle.
      applyCandidateMatches([])
      return
    }
    let parsedBang = CandidateFinder.parseBang(trimmed)
    let usesTransientCompletionPool =
      sourceCompletion != nil
      || bangCompletion != nil
      || parsedBang != nil

    // Non-location sources (emojis, bangs, notes, …) aren't pulled on open; the
    // moment the user confirms an `@source` or types a `!`bang, fetch the warm
    // stores needed for that intent. Source-completion rows come from manifest
    // declarations, so partial `@em...` input performs no catalog snapshots.
    prefetchNonLocationSources(forCandidateQuery: query)
    beginLiveSourceQueriesIfNeeded(forCandidateQuery: query)

    let (pool, scoringText) = buildCandidateFinderPool(
      trimmed: trimmed,
      rawQuery: query,
      sourceFilter: parsed.sourceFilter)
    let tFiltered = CFAbsoluteTimeGetCurrent()

    // Bump the generation so any scoring job that completes AFTER
    // this keystroke is dropped silently when its callback fires.
    candidateFinderIndexGenerationCounter &+= 1
    let generation = candidateFinderIndexGenerationCounter

    if usesTransientCompletionPool {
      invalidateCandidateQueryEvaluation()
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
      invalidateCandidateQueryEvaluation()
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

    // Bare input is additive: every registered evaluator gets the same exact
    // text. A confirmed `@source` remains catalog-only, but still uses the
    // large-pool ranker below (parallel scoring, incremental narrowing, and a
    // bounded display sort). Evaluator rows live in a fixed answer lane and
    // never enter this fuzzy scorer or its incremental cache.
    if parsed.sourceFilter == nil {
      beginCandidateQueryEvaluationIfNeeded(text: scoringText.trimmed)
    } else {
      invalidateCandidateQueryEvaluation()
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
      let dFilter = Int((tFiltered - t0) * 1000)
      let dScore = Int((tScored - tScoringStart) * 1000)
      let dSort = Int((tSorted - tScored) * 1000)
      let dRender = Int((tRendered - tSorted) * 1000)
      let dTotal = Int((tRendered - t0) * 1000)
      FlashLog.trace(
        "[candidate_finder] pool=\(pool.count) scored=\(scoringPool.count) inc=\(isIncremental) "
          + "matches=\(sorted.count) "
          + "total_ms=\(dTotal) filter_ms=\(dFilter) score_ms=\(dScore) "
          + "sort_ms=\(dSort) render_ms=\(dRender)")
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
    let answerKeys = Set(
      candidateFinderQueryAnswers.map {
        "\($0.sourceID)\u{0}\($0.title)"
      })
    let catalogMatches = matches.filter {
      !answerKeys.contains("\($0.candidate.sourceID)\u{0}\($0.candidate.title)")
    }
    let answers = candidateFinderQueryAnswers.enumerated().map { index, candidate in
      CandidateMatch(candidate: candidate, score: Int.max - index)
    }
    candidateFinderMatches = answers + catalogMatches
    if candidateFinderMatches.isEmpty {
      candidateFinderSelectedIndex = 0
    } else {
      candidateFinderSelectedIndex = min(
        max(candidateFinderSelectedIndex, 0), candidateFinderMatches.count - 1)
    }
  }

  /// Launch one evaluator fan-out per canonical bare query. The session and
  /// per-query generations jointly reject results from closed surfaces and
  /// superseded keystrokes. `SourceRegistry` itself completes only once, so a
  /// multi-plugin response produces a single repaint.
  private func beginCandidateQueryEvaluationIfNeeded(text: String) {
    let exactText = text.trimmed
    guard !exactText.isEmpty, exactText != candidateFinderQueryEvaluationText else {
      return
    }
    candidateFinderQueryEvaluationGeneration &+= 1
    let evaluationGeneration = candidateFinderQueryEvaluationGeneration
    let sessionGeneration = candidateFinderSessionGeneration
    candidateFinderQueryEvaluationText = exactText
    candidateFinderQueryAnswers = []
    candidateFinderQueryEvaluationInFlightGeneration = evaluationGeneration
    candidateFinderQueryEvaluationSettledGeneration = nil

    registry.evaluateQuery(
      QueryEvaluationRequest(
        surface: .flashlight,
        scope: candidateFinderScope,
        text: exactText,
        exclusivePrefix: exactText.first == "=" ? "=" : nil)
    ) { [weak self] candidates in
      guard let self,
        sessionGeneration == self.candidateFinderSessionGeneration,
        evaluationGeneration == self.candidateFinderQueryEvaluationGeneration,
        exactText == self.candidateFinderQueryEvaluationText
      else { return }
      switch self.overlay.inputMode {
      case .commandLine, .candidateFinder: break
      default: return
      }
      self.candidateFinderQueryAnswers = candidates
      if !candidates.isEmpty {
        self.candidateFinderSelectedIndex = 0
      }
      if !candidates.isEmpty || self.candidateFinderSubmissionDeferral.hasPendingAction {
        // Do not open the submission gate until the coalesced render has put
        // these answers into `candidateFinderMatches`.
        self.candidateFinderQueryEvaluationSettledGeneration = evaluationGeneration
        self.scheduleCoalescedCandidateFinderRerender()
      } else {
        // No answer lane changed and nobody is waiting to submit, so the fuzzy
        // rows already on screen are final for this exact query.
        self.candidateFinderQueryEvaluationInFlightGeneration = nil
      }
    }
  }

  private func invalidateCandidateQueryEvaluation() {
    candidateFinderQueryEvaluationGeneration &+= 1
    candidateFinderQueryEvaluationInFlightGeneration = nil
    candidateFinderQueryEvaluationSettledGeneration = nil
    candidateFinderQueryEvaluationText = ""
    candidateFinderQueryAnswers = []
  }

  /// The bang-list pool: static manifest-declared shebangs plus the dynamic
  /// bang-kind rows from candidate sources (e.g. searchengines' DDG bangs),
  /// which land in the session pool once the non-location sources are pulled on
  /// the first `@source`/`!` keystroke.
  private func bangListCandidates() -> [Candidate] {
    pluginManager.shebangCandidates(in: pluginSelectorContext())
      + candidateFinderCandidates.filter { $0.kind == CandidateFinder.bangKind }
  }

  /// Dispatch a named `#[range=user|<name>]` status-bar click through the
  /// `[statusbar.click]` action map — tmux's status-line mouse model: the
  /// span names the action, the binding lives in config. URLs open
  /// activating; action arrays run through the mapping-command dispatcher
  /// (same power as a keybinding, e.g. ["flash", "plugin_command", …]).
  func performStatusBarClickAction(named name: String) {
    guard let action = config.statusBar.clickActions[name] else {
      FlashLog.warn(
        "[statusbar] click range \"\(name)\" has no [statusbar.click] action configured")
      overlay.displayBanner("no [statusbar.click] action for \"\(name)\"")
      return
    }
    FlashLog.debug("[statusbar] click_action name=\(name)")
    switch action {
    case .url(let raw):
      guard let url = URL(string: raw) else { return }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    case .command(let command):
      performMappingCommand(command)
    }
  }

  /// True when a confirmed `!token` is actually routable: an exact shebang
  /// registration, or a bang its wildcard owner has published to the pool
  /// (searchengines' curated table rows). A wildcard registration alone
  /// doesn't count — the owner would just reject the token at dispatch.
  /// Drives the lock-in underline color: purple for routable, red for a
  /// token nothing will answer.
  private func confirmedBangIsKnown(_ token: String) -> Bool {
    let lc = token.lowercased()
    return bangListCandidates().contains {
      $0.sourcePayload?.lowercased() == lc
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
  ///     location entities. Synthetic
  ///     bang / source-completion rows are always excluded; all other sources
  ///     are excluded unless the user opts in via `@<source>`.
  private func buildCandidateFinderPool(
    trimmed: String,
    rawQuery: String,
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
      let bangs = CandidateFinder.prepare(bangListCandidates())
      return (bangs, bang.token)
    }
    // Use the *raw* (untrimmed) query so a trailing space after a bare sigil
    // dismisses the suggestions: `!` shows bang candidates, `! ` does not.
    if let bang = CandidateFinder.bangCompletionState(query: rawQuery) {
      let bangs = CandidateFinder.prepare(bangListCandidates())
      return (bangs, bang.token)
    }
    // `@<partial>` completion: when the user is in the middle of
    // typing a source token (no trailing whitespace yet), swap the
    // pool for source-completion rows derived from the candidates
    // actually present. This mirrors the bang-completion surface so
    // `<tab>`/`<cr>` semantics stay identical across both modes.
    if let completion = CandidateFinder.sourceCompletionState(query: rawQuery) {
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
    let basePool: [Candidate]
    if let cached = candidateFinderFilteredPoolCache,
      cached.epoch == candidateFinderCandidatesEpoch,
      cached.signature == signature
    {
      basePool = cached.pool
    } else {
      // `@<source>` opts in to whatever source the user names. Without an
      // explicit source filter, keep the default flashlight focused on locations.
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
      basePool = pool
    }
    return (basePool, trimmed)
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
      guard let self else { return }
      guard ok else {
        // A failed bang (unknown token, blocked open, plugin error) must
        // say so — a submit that does visibly nothing reads as Flash
        // being broken.
        self.overlay.displayBanner("!\(token) failed")
        return
      }
      self.activatePluginCommandTarget(pid, navigationURL: navigationURL)
      guard let stdout, !stdout.isEmpty else { return }
      self.overlay.displayBanner(stdout)
    }
  }

  func candidateFinderDisplayItems(windowSize: Int? = nil) -> [CandidateDisplayItem] {
    guard !candidateFinderMatches.isEmpty else { return [] }
    let window = CandidateFinder.displayWindow(
      count: candidateFinderMatches.count,
      selectedIndex: candidateFinderSelectedIndex,
      windowSize: windowSize ?? commandBarSuggestionCount)
    return candidateFinderMatches[window].enumerated().map { offset, match in
      let title =
        match.candidate.displayTitle.isEmpty
        ? candidateFinderDisplayTitle(match.candidate) : match.candidate.displayTitle
      return CandidateDisplayItem(
        title: title,
        highlightedRanges: candidateFinderCurrentQuery.isEmpty || match.candidate.effect != nil
          ? []
          : NormalModeDispatcher.fuzzyHighlightRanges(
            query: candidateFinderCurrentQuery,
            candidate: title),
        isSelected: window.lowerBound + offset == candidateFinderSelectedIndex)
    }
  }

  private func candidateFinderDisplayTitle(_ candidate: Candidate) -> String {
    CandidateFinder.displayTitle(candidate)
  }

  static func candidateFinderDisplayTitle(source: String, title: String) -> String {
    CandidateFinder.displayTitle(source: source, name: title)
  }

  /// Append a submitted command to the recall history (most-recent last),
  /// dropping a consecutive duplicate and bounding the size. Records every
  /// submission, success or not. Resets the recall cursor so the next up/down
  /// starts from the newest entry.
  func recordCommandLineHistory(_ rawInput: String) {
    let entry = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    commandLineHistoryCursor = nil
    commandLineHistoryStash = ""
    guard !entry.isEmpty else { return }
    if commandLineHistory.last != entry {
      commandLineHistory.append(entry)
      let cap = 200
      if commandLineHistory.count > cap {
        commandLineHistory.removeFirst(commandLineHistory.count - cap)
      }
    }
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
    recordCommandLineHistory(rawInput)
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
    // Bare `:clipboard` opens the dashboard's Clipboard tab rather than firing
    // a fire-and-forget plugin command; the host caches the history and the web
    // UI renders it. `:clipboard <arg>` falls through below.
    if let plugin = NormalModeDispatcher.pluginCommandLineInvocation(raw),
      plugin.command.lowercased() == "clipboard", plugin.subcommand.isEmpty, plugin.args.isEmpty
    {
      finishCommandLineInteraction(reason: "clipboard_submit")
      openClipboardDashboard()
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
    case .closeWindow:
      closeFocusedWindowInNormalMode()
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
    case .logs:
      openDebugDashboard(tab: "logs")
    case .commands:
      openDebugDashboard(tab: "commands")
    case .about:
      handleURLCommand(.showAbout)
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
  /// but `submitFinalDestinations=true`, so location rows behave like an
  /// explicit Command-Return while partial/source rows still rewrite the
  /// buffer. `<cmd+cr>` calls with `submit=true`, the explicit force-submit
  /// path for real candidates.
  /// Synthetic source-filter rows are always insert-only.
  func actOnSelectedCandidateFinderCandidate(
    submit: Bool,
    allowFinisher: Bool = true,
    submitFinalDestinations: Bool = false
  ) {
    let initialSnapshotPending = candidateFinderInitialBarrier != nil
    let evaluationInFlight = candidateFinderQueryEvaluationInFlightGeneration
    if initialSnapshotPending || evaluationInFlight != nil {
      candidateFinderSubmissionDeferral.deferAction(
        CandidateSubmissionDeferral.Action(
          submit: submit,
          allowFinisher: allowFinisher,
          submitFinalDestinations: submitFinalDestinations),
        sessionGeneration: candidateFinderSessionGeneration,
        query: activeCandidateFinderInputText(),
        evaluationGeneration: initialSnapshotPending ? nil : evaluationInFlight)
      FlashLog.trace(
        "[candidate_finder] action_deferred session=\(candidateFinderSessionGeneration) "
          + "query_generation=\(evaluationInFlight.map(String.init) ?? "initial")")
      return
    }
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
      let remainder = typedBang?.remainder ?? ""
      // Dispatch the search when force-submitted (`<cmd+cr>`) OR on plain `<cr>`
      // (allowFinisher) once a query is already typed — `!g paris weather`, or a
      // bang anywhere like `paris weather !g`, searches immediately. Only fall
      // back to canonicalizing `:flashlight !<token> ` when there's no query yet
      // (so "type `!g`, then the query" keeps working) or on `<tab>`.
      if submit || (allowFinisher && !remainder.isEmpty) {
        submitTypedBang(typed: (token: token, remainder: remainder))
        return
      }
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

  /// Replay a held selection only when both asynchronous first-row boundaries
  /// have settled for the same session, exact query, and evaluator generation.
  /// A user edit, cancel, or superseding evaluation discards the action.
  private func replayDeferredCandidateSubmissionIfReady() {
    let resolution = candidateFinderSubmissionDeferral.resolve(
      sessionGeneration: candidateFinderSessionGeneration,
      query: activeCandidateFinderInputText(),
      currentEvaluationGeneration: candidateFinderQueryEvaluationGeneration,
      initialSnapshotPending: candidateFinderInitialBarrier != nil,
      evaluationInFlightGeneration: candidateFinderQueryEvaluationInFlightGeneration)
    switch resolution {
    case .none, .waiting:
      return
    case .discarded:
      FlashLog.trace(
        "[candidate_finder] deferred_action_discarded session=\(candidateFinderSessionGeneration)")
    case .replay(let action):
      FlashLog.trace(
        "[candidate_finder] deferred_action_replay session=\(candidateFinderSessionGeneration)")
      actOnSelectedCandidateFinderCandidate(
        submit: action.submit,
        allowFinisher: action.allowFinisher,
        submitFinalDestinations: action.submitFinalDestinations)
    }
  }

  /// Exact user-visible candidate query, before `@source`/bang parsing rewrites
  /// `candidateFinderCurrentQuery` for scoring. Using this for deferral identity
  /// preserves initial-barrier submission for explicit selectors and makes any
  /// intervening edit invalidate the held action.
  private func activeCandidateFinderInputText() -> String {
    switch overlay.inputMode {
    case .commandLine:
      return NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText)
        ?? candidateFinderCurrentQuery
    case .candidateFinder:
      return overlay.candidateFinderQuery
    default:
      return candidateFinderCurrentQuery
    }
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
    // Drop the field editor explicitly so a cancel (Escape) closes the bar the
    // same way a submit does — a submit's app activation resigns our key window,
    // which the OS uses to tear the editor down; a cancel has no such trigger, so
    // without this the reused editor stayed associated and the next open showed
    // no caret.
    overlay.resignCommandTextFieldFocus()
    // The reducer pops the surface's recorded `restoreTo`; the resulting
    // base-mode entry effects tear down the command-line overlay.
    dispatchMode(.closeCommand(reason: reason))
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
    cancelCandidateFinderSessionWork()
    overlay.candidateFinderQuery = ""
    candidateFinderCandidates = []
    candidateFinderMatches = []
    candidateFinderSelectedIndex = 0
    candidateFinderCurrentQuery = ""
    candidateFinderPrecedenceTable = .default
    candidateFinderIncrementalCache = nil
  }

  private func cancelCandidateFinderSessionWork() {
    // Bump the generation and cancel the UI deadline so in-flight plugin
    // replies cannot publish into a closed or superseded session.
    candidateFinderSessionGeneration &+= 1
    invalidateCandidateQueryEvaluation()
    candidateFinderInitialDeadlineWork?.cancel()
    candidateFinderInitialDeadlineWork = nil
    candidateFinderInitialBarrier = nil
    candidateFinderInitialSnapshotReady = false
    candidateFinderSubmissionDeferral.cancel()
    candidateFinderFetchedNonLocationSourceIDs.removeAll()
    candidateFinderDeferredNonLocationSnapshots.removeAll()
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

  /// `:q` — close the focused app's focused OS window (its red close button),
  /// leaving the app and its other windows running. Distinct from `x`/`tab_close`
  /// (a tab / tmux window) and `:qa` (quits the whole app). Falls back to ⌘W when
  /// the window has no AX close button (borderless/custom windows).
  private func closeFocusedWindowInNormalMode() {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for :q (close window)")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[normal_mode] close window pid=\(context.processID) bundle=\(context.bundleIdentifier)")
    if !NormalModeDispatcher.closeFocusedWindow(pid: context.processID) {
      sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand)
    }
    applyModeOverlay()
  }

  func sendNormalModeKey(
    _ key: CGKeyCode,
    flags: CGEventFlags = [],
    repeatCount: Int = 1,
    suppressInTerminalFor command: URLCommand? = nil
  ) {
    guard let target = normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal_mode] no target app for key \(key)")
      applyModeOverlay()
      return
    }
    if let command,
      Self.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        command,
        bundleIdentifier: target.bundleIdentifier)
    {
      FlashLog.debug(
        "[normal_mode] suppress terminal shortcut command=\(command.diagnosticDescription) "
          + "bundle=\(target.bundleIdentifier)")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)
    let activationDelayMs =
      activateNormalModeKeyTargetIfNeeded(
        target.processID, flags: flags)
      ? Self.normalModeKeyTargetActivationDelayMs : 0
    for index in 0..<count {
      let delay = DispatchTimeInterval.milliseconds(activationDelayMs + index * 35)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        // Note the synthesized chord so a `postToPid` event that loops back
        // through the Carbon dispatcher can't re-trigger our own hotkey for
        // the same combo (e.g. the `⌘⇧]` Messages tab-traversal fallback).
        self?.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
        NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: target.processID)
      }
    }
    let finalDelay = DispatchTimeInterval.milliseconds(activationDelayMs + (count - 1) * 35 + 35)
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
  func insertText(_ text: String, viaClipboard: Bool = true) {
    let pid = normalModeContext()?.processID
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay(captureOverride: true)
    guard !text.isEmpty, let pid else { return }
    if viaClipboard { NormalModeDispatcher.copy(text) }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      if viaClipboard {
        NormalModeDispatcher.sendKey(
          virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, to: pid)
      } else {
        // Emoji (and other short glyphs): type the Unicode directly so inserting
        // it doesn't clobber the user's clipboard.
        NormalModeDispatcher.insertUnicode(text, to: pid)
      }
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

  private func sendNormalModeKeySequence(
    _ keys: [(CGKeyCode, CGEventFlags)],
    repeatCount: Int = 1
  ) {
    guard let target = normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal_mode] no target app for key sequence")
      applyModeOverlay()
      return
    }
    guard !keys.isEmpty else {
      scheduleNormalModeRecapture()
      return
    }
    let count = normalizedRepeatCount(repeatCount)
    var offsetMs =
      activateNormalModeKeyTargetIfNeeded(target.processID, keys: keys)
      ? Self.normalModeKeyTargetActivationDelayMs : 0
    for _ in 0..<count {
      for (key, flags) in keys {
        let delay = DispatchTimeInterval.milliseconds(offsetMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
          NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: target.processID)
        }
        offsetMs += 35
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs + 30)) { [weak self] in
      self?.scheduleNormalModeRecapture()
    }
  }

  @discardableResult
  private func activateNormalModeKeyTargetIfNeeded(
    _ processID: pid_t,
    flags: CGEventFlags
  ) -> Bool {
    guard Self.normalModeKeyDispatchNeedsTargetActivation(flags: flags) else { return false }
    return activateNormalModeKeyTarget(processID)
  }

  @discardableResult
  private func activateNormalModeKeyTargetIfNeeded(
    _ processID: pid_t,
    keys: [(CGKeyCode, CGEventFlags)]
  ) -> Bool {
    guard keys.contains(where: { Self.normalModeKeyDispatchNeedsTargetActivation(flags: $0.1) })
    else { return false }
    return activateNormalModeKeyTarget(processID)
  }

  @discardableResult
  private func activateNormalModeKeyTarget(_ processID: pid_t) -> Bool {
    guard processID != ProcessInfo.processInfo.processIdentifier else { return false }
    guard
      let app = NSRunningApplication(processIdentifier: processID),
      !app.isTerminated
    else { return false }
    RunningApplicationActivation.activate(app, options: [])
    return true
  }

  private func normalModeKeyDispatchTarget() -> NormalModeKeyDispatchTarget? {
    let hasVisibleNonOverlayKeyWindow = NSApp.keyWindow.map {
      $0 !== overlay && $0.isVisible
    } ?? false
    if Self.normalModeKeyDispatchUsesCurrentProcess(
      applicationIsActive: NSApp.isActive,
      hasVisibleNonOverlayKeyWindow: hasVisibleNonOverlayKeyWindow)
    {
      return NormalModeKeyDispatchTarget(
        processID: ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.flash.app")
    }
    guard let context = normalModeContext() else { return nil }
    return NormalModeKeyDispatchTarget(
      processID: context.processID,
      bundleIdentifier: context.bundleIdentifier)
  }

  static func normalModeKeyDispatchUsesCurrentProcess(
    applicationIsActive: Bool,
    hasVisibleNonOverlayKeyWindow: Bool
  ) -> Bool {
    applicationIsActive && hasVisibleNonOverlayKeyWindow
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

  /// `y` — copy the focused app's current selection into `register`. Reads the
  /// selection off the AX tree when the app exposes it (no clipboard churn);
  /// otherwise synthesizes ⌘C and stores whatever lands on the pasteboard.
  private func yankSelection(into register: String?) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for yank_selection")
      applyModeOverlay()
      return
    }
    let pid = context.processID
    if let text = NormalModeDispatcher.selectedText(pid: pid) {
      registers.write(text, register: register)
      FlashLog.debug(
        "[normal_mode] yank ax len=\(text.count) register=\(register ?? "*clipboard*")")
      applyModeOverlay()
      return
    }
    // No AX selection exposed (web content, terminals): fall back to ⌘C and
    // read the pasteboard once its change-count ticks.
    let beforeChange = NSPasteboard.general.changeCount
    mappings.noteSyntheticKey(virtualKey: UInt32(kVK_ANSI_C), flags: .maskCommand)
    NormalModeDispatcher.sendKey(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand, to: pid)
    pollPasteboard(after: beforeChange, attempts: 20) { [weak self] text in
      guard let self else { return }
      if let text, !text.isEmpty {
        self.registers.write(text, register: register)
        FlashLog.debug(
          "[normal_mode] yank clipboard len=\(text.count) register=\(register ?? "*clipboard*")")
      } else {
        FlashLog.debug("[normal_mode] yank ⌘C produced no selection")
      }
      self.scheduleNormalModeRecapture()
    }
  }

  /// `p` — paste `register`'s contents into the focused app by typing them, so
  /// pasting a named register never disturbs the clipboard. `repeatCount`
  /// pastes the contents that many times (`3p`).
  private func pasteRegister(_ register: String?, repeatCount: Int) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for paste")
      applyModeOverlay()
      return
    }
    guard let text = registers.read(register: register), !text.isEmpty else {
      FlashLog.debug("[normal_mode] paste register=\(register ?? "*clipboard*") empty")
      applyModeOverlay()
      return
    }
    let payload = String(repeating: text, count: normalizedRepeatCount(repeatCount))
    NormalModeDispatcher.insertUnicode(payload, to: context.processID)
    scheduleNormalModeRecapture()
  }

  /// Poll the general pasteboard until its change-count moves past `change`
  /// (our synthesized ⌘C landed) or `attempts` run out, then hand the string
  /// to `completion`. Stays on the main queue so it composes with the rest of
  /// normal-mode dispatch.
  private func pollPasteboard(
    after change: Int,
    attempts: Int,
    completion: @escaping (String?) -> Void
  ) {
    guard attempts > 0 else {
      completion(nil)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
      let pasteboard = NSPasteboard.general
      if pasteboard.changeCount != change {
        completion(pasteboard.string(forType: .string))
      } else {
        self?.pollPasteboard(after: change, attempts: attempts - 1, completion: completion)
      }
    }
  }

  private func copyFocusedDocumentURL() {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for copyDocumentURL")
      return
    }
    // Resolve the URL on the AX queue, not main: `registry.documentURL` walks the
    // AX tree with blocking IPCs (up to a few thousand nodes on a miss) and the
    // main run loop hosts the keyboard-capture tap, so a wedged app would stall
    // input for a whole `url_copy` keystroke. `url_copy` has no latency contract;
    // keep the walk off main (mirroring how discovery runs the provider chain on
    // `axQueue`) and write the pasteboard back on main.
    let registry: SourceRegistry = self.registry
    monitor.axQueue.async {
      guard let url = registry.documentURL(in: context) else {
        FlashLog.debug(
          "[normal_mode] no AX document URL exposed by \(context.bundleIdentifier)")
        return
      }
      DispatchQueue.main.async {
        NormalModeDispatcher.copy(url)
      }
    }
  }

  func normalModeContext() -> AppContext? {
    if Self.normalModeShouldPreferCapturedContext(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: !currentHints.isEmpty,
      activationInFlight: activationInFlight,
      normalModeTargetPID: normalModeTargetPID),
      let pid = normalModeTargetPID,
      let context = monitor.context(for: pid)
    {
      return context
    }
    if let context = currentDirectNonFlashContext() {
      normalModeTargetPID = context.processID
      return context
    }
    if let pid = normalModeTargetPID,
      let context = monitor.context(for: pid)
    {
      return context
    }
    if let context = currentNonFlashContext() {
      normalModeTargetPID = context.processID
      return context
    }
    return nil
  }

  static func normalModeShouldPreferCapturedContext(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    normalModeTargetPID: pid_t?
  ) -> Bool {
    mode == .normal
      && overlayInputMode == .normal
      && !hasHints
      && !activationInFlight
      && normalModeTargetPID != nil
  }

  enum NavigationDirection {
    case back
    case forward
  }

  func recordAppActivation(_ pid: pid_t) {
    recordAppMRU(pid)
    scheduleAmbientLocationRecord(pid: pid, reason: "app_activation")
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
    var ordered = appBackStack
    if let current = appCurrent {
      ordered.append(current)
    }
    ordered.append(contentsOf: appForwardStack.reversed())
    ordered.removeAll { $0 == pid }
    ordered.append(pid)
    appBackStack = Array(ordered.dropLast())
    appCurrent = pid
    appForwardStack.removeAll(keepingCapacity: true)
  }

}

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
      "[mode] enter_normal from=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight)")
    returnActivationIfClosingCommandBar(reason: "enter_normal")
    dispatchMode(.enterNormal(targetPID: terminalReturnApplicationPID))
  }

  func leaveMode() {
    if modeStore.mode.isTerminal {
      suppressDismissedTerminalHover()
      dismissTerminal()
      return
    }
    if overlay.statusPopupController.isVisible { dismissTerminal() }
    returnActivationIfClosingCommandBar(reason: "leave_mode")
    overlay.resignCommandTextFieldFocus()
    dispatchMode(
      .leaveMode(
        hasHints: hintSession.isActive || activationInFlight,
        targetPID: terminalReturnApplicationPID))
  }

  /// A mode mapping that closes the open command bar is a cancel: nothing ran,
  /// so activation goes back to the app the bar covered.
  private func returnActivationIfClosingCommandBar(reason: String) {
    guard overlay.inputMode == .commandLine else { return }
    returnActivationToCoveredApp(reason: reason)
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
      "[mode] enter_insert reason=\(reason.logValue) from=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight)")
    dispatchMode(.enterInsert(targetPID: pid))
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
    MainThreadWatchdog.note("mode_effects")
    for effect in effects {
      switch effect {
      case .prepareKeyboardCapture:
        startKeyboardCaptureTap()
      case .prepareModeEntry:
        applyEnterBookkeeping(next)
      case .hideTerminalPopup:
        terminalInputMappings?.flush()
        overlay.statusPopupController.dismiss()
      case .setMappingScope(let scope):
        mappings.apply(scope: scope)
      case .clearTransientHintState:
        // Reads the still-current overlay surface to tear down a command /
        // modal we are leaving, then clears hint + input state.
        closeModalStateForModeExit(reason: "mode_enter")
        resetModeInputState()
        clearTransientHintState(reason: "mode_enter")
      case .renderSurface:
        applyModeOverlay()
      case .scheduleRecapture:
        scheduleNormalModeRecapture()
      case .activateFocusedApp(let pid):
        activateInsertTargetApp(pid)
      case .hideOverlayIfIdle:
        if hintSession.hints.isEmpty { overlay.hide() }
      }
    }
    refreshOverlayInputRouting()
  }

  /// Per-base-mode bookkeeping that must run before the surface is rendered.
  private func applyEnterBookkeeping(_ next: Mode) {
    // Any base-mode transition ends a transient native-surface suspension; clear
    // it before the surface renders so capture isn't pinned off afterward.
    nativeSurfaceSuspended = false
    switch next {
    case .normal:
      // Identity only: the target pid needs no WindowServer geometry.
      if let context = normalModeDispatchContext() {
        normalModeTargetPID = context.processID
      }
    case .insert, .disabled:
      normalModeTargetPID = nil
    case .command, .terminal:
      break
    }
  }

  /// Re-activate the focused app on INSERT entry so its window reclaims key
  /// status from the panel (the Messages "first keystroke dropped" fix).
  private func activateInsertTargetApp(_ pid: pid_t?) {
    // Identity only: activation needs the app, never its window frame, so this
    // never takes a WindowServer snapshot on the mode-transition path.
    guard
      let app = pid.flatMap({ NSRunningApplication(processIdentifier: $0) })
        ?? currentNonFlashRunningApplication(),
      !app.isTerminated
    else { return }
    RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
  }

  /// The frontmost non-Flash application by identity alone (no geometry):
  /// the workspace frontmost app unless that is Flash itself, in which case
  /// the last observed focused app.
  func currentNonFlashRunningApplication() -> NSRunningApplication? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.bundleIdentifier != flashBundleIdentifier
    {
      return frontmost
    }
    guard let observedFocusedAppPID else { return nil }
    return NSRunningApplication(processIdentifier: observedFocusedAppPID)
  }

  /// Map a projected mode label to the user-configured string.
  func modeLabelText(_ label: ModeLabel) -> String {
    switch label {
    case .insert: return config.mode.labels.insert
    case .normal: return config.mode.labels.normal
    case .command: return config.mode.labels.command
    case .terminal: return config.mode.labels.terminal
    }
  }

  func invalidateActivation(reason: String) {
    if activationInFlight {
      FlashLog.trace(
        "[activation] invalidate reason=\(reason) gen=\(activationGen) "
          + "in_flight_gen=\(String(describing: activationLifecycle.phase))")
    }
    activationLifecycle.invalidate()
  }

  func clearTransientHintState(reason: String) {
    let hadHints = hintSession.isActive
    let hadActivation = activationInFlight
    if hadHints || hadActivation {
      FlashLog.trace(
        "[mode] clear_hints reason=\(reason) hints=\(hintSession.hints.count) "
          + "in_flight=\(activationInFlight)")
    }
    if hadHints {
      overlay.hide()
    }
    clearHintSessionState()
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
    // Identity only — resolving the window context would scan every on-screen
    // window on the main thread, once per event of a drag.
    guard let app = currentNonFlashRunningApplication(), app.processIdentifier == pid else {
      return
    }
    if AppMonitor.isWindowGeometryNotification(notification), let observedWindow {
      observedWindowGeometryDidChange(
        pid: pid, window: observedWindow, notification: notification,
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: config.statusBar.monitor)
      if pluginManager.hasListener(for: "core:ax.changed") {
        pluginManager.emit(
          PluginEvent(
            name: "core:ax.changed",
            payload: ["notification": notification, "pid": Int(pid)],
            bundleID: app.bundleIdentifier))
      }
      return
    }
    let isFocusChange =
      notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
    if isFocusChange {
      scheduleAmbientLocationRecord(pid: pid, reason: "window_focus")
    }
    // The stroke goes first and depends on nothing below. Window AX
    // notifications are delivered after the operation: resolve the
    // authoritative WindowServer frame now and replace (or clear) the stroke
    // in one transaction. It used to wait behind the window-list context
    // match below, and a closed or minimized window leaves its app active
    // with some other app's window on top, so that match dropped the event
    // and the stroke stayed on a window that was gone.
    updateActiveWindowBorder(reason: notification)
    scheduleActiveWindowBorderReconciliation(
      delaysMs: Self.activeWindowBorderEventSettleDelaysMs, reason: notification)

    let destroyedWindow =
      notification == kAXUIElementDestroyedNotification as String ? observedWindow : nil
    let emitsAXChanged = pluginManager.hasListener(for: "core:ax.changed")
    let emitsFocusChange =
      isFocusChange && pluginManager.hasListener(for: "core:window.focus.changed")
    guard destroyedWindow != nil || emitsAXChanged || emitsFocusChange,
      let context = currentNonFlashContext(), context.processID == pid
    else { return }
    if let observedWindow = destroyedWindow {
      windowLayoutManager.observedWindowFrameChange(
        pid: pid,
        window: observedWindow,
        frame: context.frontWindowFrame,
        notification: notification,
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: config.statusBar.monitor)
    }
    if emitsAXChanged {
      pluginManager.emit(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["notification": notification, "pid": Int(pid)],
          bundleID: context.bundleIdentifier))
    }
    // The focused-window-changed and main-window-changed AX notifications are
    // exactly the signal plugins want to react to when they care about *which*
    // window inside an app is on top (e.g. an iTerm/Alacritty plugin watching
    // tmux clients move between attached terminals). The generic
    // `core:ax.changed` fires for any AX mutation, so it's too noisy for that
    // use case; this dedicated event carries the focused window's frame and
    // pid so subscribers can filter on it directly.
    if emitsFocusChange {
      let frame = context.frontWindowFrame
      pluginManager.emit(
        PluginEvent(
          name: "core:window.focus.changed",
          payload: [
            "pid": Int(pid),
            "bundle_id": context.bundleIdentifier,
            "front_window_frame": [
              "x": Double(frame.origin.x),
              "y": Double(frame.origin.y),
              "width": Double(frame.size.width),
              "height": Double(frame.size.height),
            ],
          ],
          bundleID: context.bundleIdentifier,
          frontWindowFrame: frame,
          pid: pid))
    }
  }

  private func resetModeInputState() {
    cancelCandidateFinderSessionWork()
    overlay.normalModePending = ""
    overlay.normalModeRepeatAnchor = nil
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    finder.candidates = []
    finder.matches = []
    finder.selectedIndex = 0
    finder.currentQuery = ""
    hintSession.prefix = ""
  }

  private func closeModalStateForModeExit(reason: String) {
    switch overlay.inputMode {
    case .commandLine:
      FlashLog.trace("[mode] close_modal input=command_line reason=\(reason)")
      overlay.resignCommandTextFieldFocus()
      resetCommandLineState()
      overlay.hide()
    case .passive, .hints, .normal:
      break
    }
  }

  static func insertEntryTargetPID(
    explicitTargetPID: pid_t?,
    currentMode: FlashMode,
    normalModeTargetPID: pid_t?
  ) -> pid_t? {
    explicitTargetPID ?? (currentMode == .normal ? normalModeTargetPID : nil)
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

  /// Whether a native surface (a context menu, the About window) owns the
  /// keyboard, so Flash must not capture it.
  var nativeKeyboardOwnerActive: Bool {
    nativeSurfaceSuspended
      || Self.aboutWindowShouldOwnNativeKeyboard(
        visible: aboutWindowVisible,
        hasTransientInput: hintSession.isActive,
        activationInFlight: activationInFlight)
  }

  /// The overlay's key routing, a pure projection of the mode, the hint
  /// session, the activation walk and native keyboard owners.
  var projectedOverlayInputMode: OverlayInputMode {
    modeStore.mode.overlayInputMode(
      hasHints: hintSession.isActive, activationInFlight: activationInFlight,
      nativeSurfaceSuspended: nativeKeyboardOwnerActive)
  }

  /// Re-derive the overlay's key routing. Called whenever one of its inputs
  /// changes — a mode transition, the hint session or activation walk
  /// starting or ending, a native surface taking or releasing the keyboard —
  /// so routing can never outlive the state it was derived from. In INSERT a
  /// stale `.hints` would swallow every key.
  func refreshOverlayInputRouting() {
    guard let overlay else { return }
    let routed = projectedOverlayInputMode
    guard overlay.inputMode != routed else { return }
    FlashLog.trace("[mode] input_route from=\(overlay.inputMode) to=\(routed)")
    overlay.inputMode = routed
  }

  func applyModeOverlay(captureOverride: Bool? = nil) {
    MainThreadWatchdog.note("mode_overlay")
    let mode = modeStore.mode
    // A pointer-mode session behaves exactly like a hint set being up: the
    // transient overlay owns input (`.hints`) and NORMAL's own capture is off.
    let hasHints = hintSession.isActive
    let inFlight = activationInFlight
    let suspended = nativeKeyboardOwnerActive
    let inputMode = projectedOverlayInputMode
    // A native-surface suspension forces capture off even when a caller passes
    // `captureOverride: true` (e.g. a recapture attempt that raced a menu open).
    let capture =
      (captureOverride ?? mode.ownsKeyboard(hasHints: hasHints, activationInFlight: inFlight))
      && !suspended
    let text = modeLabelText(mode.label)
    FlashLog.trace(
      "[mode] overlay mode=\(mode) input=\(inputMode) capture=\(capture) "
        + "override=\(String(describing: captureOverride)) suspended=\(suspended) "
        + "visible=\(statusBarVisible) hints=\(hintSession.hints.count) in_flight=\(inFlight)")
    statusBarController?.updateModeLabel(text)
    overlay.inputMode = inputMode
    // Command entry paints its text and suggestions immediately after the mode
    // transition. Record the surface but don't lay out an empty command surface
    // here only to replace it in the same turn; `displayCommandLine` performs
    // the one complete first paint.
    var entersCommand = false
    if case .command = mode { entersCommand = !overlay.commandPromptVisible }
    // The surface first: the border's colour is derived from its style.
    overlay.setModeSurface(
      ModeSurface(
        label: text, style: mode.badgeStyle, barVisible: statusBarVisible,
        capturesInput: capture),
      render: !entersCommand)
    updateActiveWindowBorder(reason: "apply_mode_overlay")
  }

  static func commandSurfaceModeLabel(labels: Config.Mode.Labels) -> String {
    labels.command
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
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    cancelNormalModeCaptureRecovery(reason: "new_recapture")
    guard shouldCaptureNormalModeInput else {
      FlashLog.trace("[mode] recapture_skip token=\(token) reason=state")
      return
    }
    // Re-derive routing (`.normal` here) synchronously before scheduling the
    // retries. The 0 ms entry below is still a `DispatchQueue.main.asyncAfter`
    // — it doesn't run until the next runloop turn — so routing is current
    // before any later recapture attempt looks at it.
    refreshOverlayInputRouting()
    overlay.recaptureNormalModeKeyboardInput()
    // The session tap owns capture independently of panel focus. Once routing is
    // `.normal`, retrying on nine future run-loop turns cannot improve anything;
    // retain the recovery ladder only for the no-Accessibility key-window path.
    if overlay.keyboardCaptureActive {
      FlashLog.trace("[mode] recapture_complete token=\(token) via=tap")
      return
    }
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
              + "mode=\(self.flashMode) hints=\(self.hintSession.hints.count) "
              + "in_flight=\(self.activationInFlight) input=\(self.overlay.inputMode)")
          return
        }
        FlashLog.trace("[mode] recapture_apply token=\(token) delay=\(delayMs)")
        self.refreshOverlayInputRouting()
        self.overlay.recaptureNormalModeKeyboardInput()
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
    if Self.pointerFocusLossShouldDeferRecaptureForPointerMonitor(inputMode: overlay.inputMode) {
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
  /// Follow-up reads after a window AX event. The event arrives while a closing
  /// window is still fading out of the window list, which drops it 35–45 ms
  /// after the close; the second read catches a slower app.
  static let activeWindowBorderEventSettleDelaysMs = [45, 150]
  /// Follow-up reads after an activation or display change. A launching app's
  /// first window is picked up by its focused-window resolution instead.
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
    inputMode: OverlayInputMode
  ) -> Bool {
    OverlayPanel.pointerIntentMonitorShouldRun(inputMode: inputMode)
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
    case .commandLine:
      return false
    case .passive, .hints, .normal:
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
      hasHints: hintSession.isActive,
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
    case .passive, .hints, .normal:
      return true
    case .commandLine:
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
    case .normalMode:
      enterNormalMode()
    case .leaveMode:
      leaveMode()
    case .terminalShow(let name):
      showTerminal(named: name)
    case .terminalDismiss:
      dismissTerminal()
    case .terminalRestart(let name):
      restartStatusTerminal(named: name)
    case .terminalQuit(let name):
      quitStatusTerminal(named: name)
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
        repeatCount: repeatCount)
    case .redo:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_Z),
        flags: [.maskCommand, .maskShift],
        repeatCount: repeatCount)
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
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
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
      tabFirstInNormalMode()
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
        hasHints: hintSession.isActive,
        activationInFlight: activationInFlight)
    else { return }
    let invocationTargetPID = finder.invocationTargetPID ?? normalModeDispatchContext()?.processID
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
    finder.invocationTargetPID = invocationTargetPID
    if let candidateFinderScope {
      self.finder.scope = candidateFinderScope
    } else {
      self.finder.scope = .all
      clearCandidateFinderState()
    }
    let command = Self.commandLineBuffer(from: initialText)
    // The flashlight is just the command line pre-filled with `:flashlight ` on
    // the native command-line surface (native editing, a blinking caret,
    // arrow/Ctrl-N-P candidate navigation). The candidate scope is tracked
    // separately via `self.finder.scope` / `openCandidateFinderSession`.
    dispatchMode(.openCommand(restoreMode: restoreMode))
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
        NSWorkspace.shared.open(
          url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
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

  func runPluginsSubcommand(_ sub: NormalModeDispatcher.PluginsSubcommand) {
    switch sub {
    case .modal:
      openDebugDashboard(tab: "plugins")
    case .reload:
      let ids = pluginManager.reloadAll()
      FlashLog.info("[plugins] reload command ids=\(ids.joined(separator: ","))")
      // The plugins tab shows live runtime state, so the reload's progress and
      // result land there instead of a one-shot modal.
      openDebugDashboard(tab: "plugins")
    case .doctor:
      let statuses = pluginManager.pluginStatuses()
      // Off-main: the profile compile check execs sandbox-exec per
      // sandboxed plugin (~2s across the bundled set).
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let report = PluginDoctor.run(statuses: statuses)
        for line in report.lines {
          FlashLog.info("[doctor] \(line)")
        }
        let summary =
          report.issues == 0
          ? "plugins doctor: \(statuses.count) ok"
          : "plugins doctor: \(report.issues) issue(s) — see flash.log"
        DispatchQueue.main.async {
          self?.overlay.displayBanner(summary, durationMs: 4000)
        }
      }
    }
  }

  /// `:mappings` — the resolved mapping table now lives in the dashboard's
  /// Mappings tab (fed by `debugStateJSON`).
  func showMappings() {
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

  func quitNormalModeTargetApp(force: Bool = false) {
    guard let context = normalModeDispatchContext(),
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
  func closeFocusedWindowInNormalMode() {
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for :q (close window)")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[normal_mode] close window pid=\(context.processID) bundle=\(context.bundleIdentifier)")
    let pid = context.processID
    Self.normalModeAXActionQueue.async { [weak self] in
      let closed = NormalModeDispatcher.closeFocusedWindow(pid: pid)
      DispatchQueue.main.async {
        guard let self else { return }
        if !closed {
          self.sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand)
        }
        self.applyModeOverlay()
      }
    }
  }

  /// Quick AX reads and presses for NORMAL verbs (`y`, `:q`). They are IPC
  /// into the target app, so never on the main run loop; a queue of their own
  /// keeps them from waiting behind a hint walk on `axQueue`.
  static let normalModeAXActionQueue = DispatchQueue(
    label: "flash.normal.ax_action", qos: .userInteractive)

  func sendNormalModeKey(
    _ key: CGKeyCode,
    flags: CGEventFlags = [],
    repeatCount: Int = 1
  ) {
    guard let target = normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal_mode] no target app for key \(key)")
      applyModeOverlay()
      return
    }
    if Self.normalModeCommandKeyShortcutIsUnsafeInTerminal(
      key: key, flags: flags, bundleIdentifier: target.bundleIdentifier)
    {
      FlashLog.debug(
        "[normal_mode] suppress unbound terminal command chord key=\(key) "
          + "flags=\(flags.rawValue) bundle=\(target.bundleIdentifier)")
      applyModeOverlay()
      return
    }
    let (key, flags) = Self.appChord(
      key: key, flags: flags, bundleIdentifier: target.bundleIdentifier)
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
        // the same combo (e.g. a `⌘⇧]` tab-traversal chord).
        self?.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
        NormalModeDispatcher.sendKey(virtualKey: key, flags: flags, to: target.processID)
      }
    }
    let finalDelay = DispatchTimeInterval.milliseconds(activationDelayMs + (count - 1) * 35 + 35)
    DispatchQueue.main.asyncAfter(deadline: .now() + finalDelay) { [weak self] in
      self?.scheduleNormalModeRecapture()
    }
  }

  /// The command field owns keyboard focus while the picker is open. Return it
  /// to the originating app before delivering text, without changing base mode.
  func insertText(_ text: String, viaClipboard: Bool = true, targetPID: pid_t? = nil) {
    let pid = targetPID ?? finder.invocationTargetPID ?? normalModeDispatchContext()?.processID
    overlay.resignCommandTextFieldFocus()
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay()
    guard !text.isEmpty, let pid,
      pid != ProcessInfo.processInfo.processIdentifier,
      let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated
    else { return }
    normalModeTargetPID = pid
    RunningApplicationActivation.activate(target, options: [], restoringMinimizedWindows: false)
    let token = normalModePendingCommandToken
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      guard let self, self.normalModePendingCommandToken == token,
        !target.isTerminated, target.isActive
      else { return }
      if viaClipboard {
        NormalModeDispatcher.copy(text)
        self.mappings.noteSyntheticKey(virtualKey: UInt32(kVK_ANSI_V), flags: .maskCommand)
        NormalModeDispatcher.sendKey(
          virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, to: pid)
      } else {
        // Emoji (and other short glyphs): type the Unicode directly so inserting
        // it doesn't clobber the user's clipboard.
        NormalModeDispatcher.insertUnicode(text, to: pid)
      }
      self.scheduleNormalModeRecapture()
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
    // One unbound chord would type its character, so the whole sequence is
    // refused rather than half-delivered.
    if let unsafe = keys.first(where: {
      Self.normalModeCommandKeyShortcutIsUnsafeInTerminal(
        key: $0.0, flags: $0.1, bundleIdentifier: target.bundleIdentifier)
    }) {
      FlashLog.debug(
        "[normal_mode] suppress unbound terminal command chord key=\(unsafe.0) "
          + "flags=\(unsafe.1.rawValue) bundle=\(target.bundleIdentifier)")
      applyModeOverlay()
      return
    }
    let keys = keys.map {
      Self.appChord(key: $0.0, flags: $0.1, bundleIdentifier: target.bundleIdentifier)
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
    // A synthesized key needs the app active, not its minimized windows back.
    RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
    return true
  }

  private func normalModeKeyDispatchTarget() -> NormalModeKeyDispatchTarget? {
    let hasVisibleNonOverlayKeyWindow =
      NSApp.keyWindow.map {
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
    guard let context = normalModeDispatchContext() else { return nil }
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

  /// Command chords every macOS terminal emulator binds. A terminal that does
  /// NOT bind a Command chord does not ignore it: its key encoder falls
  /// through to the plain text path and writes the chord's base character to
  /// the pty, so an unbound `cmd+g` types a literal `g` into the shell. That
  /// is true of a hardware chord too — the emulator, not the synthesis, is
  /// what turns it into text. NORMAL is hermetic, so a mapping that would
  /// resolve to a chord outside this set does nothing in a terminal instead.
  private static let terminalBoundCommandChords: Set<CGKeyCode> = [
    CGKeyCode(kVK_ANSI_C), CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_ANSI_W),
    CGKeyCode(kVK_ANSI_T), CGKeyCode(kVK_ANSI_N), CGKeyCode(kVK_ANSI_Q),
    CGKeyCode(kVK_ANSI_F),
    CGKeyCode(kVK_ANSI_1), CGKeyCode(kVK_ANSI_2), CGKeyCode(kVK_ANSI_3),
    CGKeyCode(kVK_ANSI_4), CGKeyCode(kVK_ANSI_5), CGKeyCode(kVK_ANSI_6),
    CGKeyCode(kVK_ANSI_7), CGKeyCode(kVK_ANSI_8), CGKeyCode(kVK_ANSI_9),
  ]

  /// Terminals whose defaults put split traversal on the bare bracket chords.
  /// Elsewhere `cmd+[` / `cmd+]` are unbound and would type a bracket.
  private static let splitTraversalTerminalBundles: Set<String> = [
    "com.mitchellh.ghostty", "com.googlecode.iterm2",
  ]

  /// Whether synthesizing `key`+`flags` into `bundleIdentifier` would type a
  /// character instead of running a shortcut. Shift-bracket is the macOS
  /// standard tab traversal and is bound everywhere; the bare brackets are
  /// only safe where splits live on them.
  static func normalModeCommandKeyShortcutIsUnsafeInTerminal(
    key: CGKeyCode,
    flags: CGEventFlags,
    bundleIdentifier: String
  ) -> Bool {
    guard TerminalBundles.identifiers.contains(bundleIdentifier) else { return false }
    let modifiers = flags.intersection(normalModeKeyModifierMask)
    guard modifiers.contains(.maskCommand) else { return false }
    let bracket = key == CGKeyCode(kVK_ANSI_LeftBracket) || key == CGKeyCode(kVK_ANSI_RightBracket)
    if bracket {
      if modifiers == [.maskCommand, .maskShift] { return false }
      return
        !(modifiers == [.maskCommand]
        && splitTraversalTerminalBundles.contains(bundleIdentifier))
    }
    guard modifiers.subtracting([.maskCommand, .maskShift]).isEmpty else { return true }
    return !terminalBoundCommandChords.contains(key)
  }

  /// `y` — copy the focused app's current selection into `register`. Reads the
  /// selection off the AX tree when the app exposes it (no clipboard churn);
  /// otherwise synthesizes ⌘C and stores whatever lands on the pasteboard.
  private func yankSelection(into register: String?) {
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal_mode] no target app for yank_selection")
      applyModeOverlay()
      return
    }
    let pid = context.processID
    Self.normalModeAXActionQueue.async { [weak self] in
      let text = NormalModeDispatcher.selectedText(pid: pid)
      DispatchQueue.main.async { self?.finishYankSelection(axText: text, pid: pid, into: register) }
    }
  }

  private func finishYankSelection(axText: String?, pid: pid_t, into register: String?) {
    if let text = axText {
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
    guard let context = normalModeDispatchContext() else {
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
    guard let context = normalModeDispatchContext() else {
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
      hasHints: hintSession.isActive,
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

  /// Context for actions that only need app identity, not exact WindowServer
  /// geometry. Avoiding `CGWindowListCopyWindowInfo` keeps keyboard dispatch
  /// independent of the size and age of the global window list.
  func normalModeDispatchContext() -> AppContext? {
    if Self.normalModeShouldPreferCapturedContext(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: hintSession.isActive,
      activationInFlight: activationInFlight,
      normalModeTargetPID: normalModeTargetPID),
      let pid = normalModeTargetPID,
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated,
      let context = monitor.makeContext(for: app)
    {
      return context
    }
    let flashPID = ProcessInfo.processInfo.processIdentifier
    if let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != flashPID,
      let context = monitor.makeContext(for: app)
    {
      normalModeTargetPID = context.processID
      return context
    }
    if let pid = normalModeTargetPID,
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated
    {
      return monitor.makeContext(for: app)
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

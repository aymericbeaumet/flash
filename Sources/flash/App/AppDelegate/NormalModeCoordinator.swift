import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

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

  private func modeDidEnterNormal(reason: String) {
    resetModeInputState()
    if reason == "explicit_normal" {
      normalModeScrollSuppressionUntil = Date().addingTimeInterval(
        TimeInterval(Self.explicitNormalScrollSuppressionMs) / 1_000)
    } else {
      normalModeScrollSuppressionUntil = nil
    }
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
    normalModeScrollSuppressionUntil = nil
    normalModeRecaptureToken &+= 1
    normalModePendingCommandToken &+= 1
    resetModeInputState()
    normalModeTargetPID = nil
    editableFocusSuppressedPID = nil
    if currentHints.isEmpty {
      overlay.hide()
    }
    applyModeOverlay()
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
        name: "ax.changed",
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
    // Insert mode shows nothing — no badge, no border, no overlay
    // chrome. User asked for a pristine window in insert mode and
    // ergonomic feedback only in normal mode (via the mode badge).
    false
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

  static let explicitNormalScrollSuppressionMs = 700

  static func pointerScrollShouldBeSuppressed(
    mode: FlashMode,
    hasHints: Bool,
    suppressionUntil: Date?,
    now: Date = Date()
  ) -> Bool {
    guard mode == .normal, !hasHints, let suppressionUntil else { return false }
    return now < suppressionUntil
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
    // Insert mode is deliberately chromeless — no badge — so the focused
    // app feels untouched. Feedback is normal-mode only.
    return ModeOverlaySnapshot(
      text: mode == .normal ? labels.normal : labels.insert,
      visible: visible && mode != .insert,
      captureInput: capture,
      inputMode: capture ? .normal : .hints,
      refreshActiveWindowBorder: mode == .insert)
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

  private var shouldCaptureNormalModeInput: Bool {
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
      sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: repeatCount)
    case .tabClose:
      tabCloseInNormalMode(repeatCount: repeatCount)
    case .find:
      // Native find in the underlying app is a typing experience, so
      // flip into insert mode right after dispatching ⌘F. Without this
      // Flash stays in normal and swallows every character the user
      // types into the find field, leaving them stuck staring at an
      // empty search bar.
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
        self?.enterInsertMode(reason: .normalModeInput)
      }
    case .candidateFinder(let all):
      enterCommandLineMode(initialText: "open ", candidateFinderScope: all ? .all : .running)
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
    case .tabNewInsert:
      tabNewAndEnterInsertMode()
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
    case .showAlert, .dismissAlert, .dismissHints, .quit, .openApp, .pluginAction, .moveWindow:
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
    if let candidateFinderScope {
      self.candidateFinderScope = candidateFinderScope
      candidateFinderCandidates = candidateFinderCandidates(for: candidateFinderScope)
      candidateFinderSelectedIndex = 0
    } else {
      self.candidateFinderScope = .all
      clearCandidateFinderState()
    }
    overlay.setActiveWindowBorder(around: nil)
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
  /// `:mappings`, plugin-reload toast, future modals). Centralises the
  /// pre-modal cleanup (mode-pending bump, hint/candidate-finder reset,
  /// border clear) so the four call sites can't drift on a missed
  /// step. Pass a body closure rather than a pre-rendered string so the
  /// modal-text generator isn't run while the overlay is still busy.
  private func presentModal(
    reason: String,
    body: () -> String
  ) {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearTransientHintState(reason: reason)
    clearCandidateFinderState()
    overlay.hide()
    overlay.setActiveWindowBorder(around: nil)
    overlay.displayModal(body())
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
    refreshCandidateFinder(query: "")
  }

  func prewarmCandidateFinderCaches(reason: String) {
    refreshCandidatesAsync(scope: .running, reason: reason)
    refreshCandidatesAsync(scope: .all, reason: reason)
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
    timer.schedule(
      deadline: .now() + .seconds(2),
      repeating: .seconds(2),
      leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      self?.prewarmCandidateFinderCaches(reason: "live")
    }
    timer.resume()
    candidateFinderLiveRefreshTimer = timer
  }

  private func refreshVisibleCandidateFinderResultsFromCache() {
    guard overlay != nil else { return }
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
      return candidateFinderAllAppsCacheReady ? candidateFinderAllAppsCache : candidateFinderRunningAppsCache
    }
  }

  func refreshCandidateFinder(query: String) {
    updateCandidateMatches(query: query)
    overlay.displayCandidateFinder(query: query, items: candidateFinderDisplayItems())
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
      updateCandidateMatches(query: query)
      overlay.displayCommandLine(
        command,
        suggestions: candidateFinderDisplayItems(windowSize: 5),
        cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    if let context = commandLineCompletionContext(for: command) {
      clearCandidateFinderState()
      updateCommandLineCompletions(context: context)
      overlay.displayCommandLine(
        command,
        suggestions: commandLineCompletionDisplayItems(windowSize: 6),
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
    let actions = pluginManager.actionRegistrations()
    var subcommands: [String: [String]] = [:]
    var commandsOrdered: [String] = []
    for action in actions {
      let key = action.command.lowercased()
      if subcommands[key] == nil {
        subcommands[key] = []
        commandsOrdered.append(key)
      }
      if !subcommands[key]!.contains(where: {
        $0.localizedCaseInsensitiveCompare(action.name) == .orderedSame
      }) {
        subcommands[key]?.append(action.name)
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
      if trimmedQuery.isEmpty {
        return CommandLineCompletionMatch(completion: item, score: 0)
      }
      guard
        let score = NormalModeDispatcher.fuzzyScore(
          query: trimmedQuery, candidate: item.label)
      else { return nil }
      return CommandLineCompletionMatch(completion: item, score: score)
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

  private func commandLineCompletionDisplayItems(windowSize: Int = 6) -> [CandidateDisplayItem] {
    guard !commandLineCompletionMatches.isEmpty else { return [] }
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
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    candidateFinderCurrentQuery = trimmed
    // Normalize the query once per keystroke rather than once per
    // candidate. With ~1k candidates in the pool and ~10 chars of
    // typing, this saves ~10k normalize calls per query.
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(trimmed)
    let fuzzyScore = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    // Emoji glyphs share the global candidate pool but only surface under
    // `:emojis`; every other query (`open`, `flashlight`, the `f` finder)
    // hides them.
    let pool = candidateFinderCandidates.filter { candidate in
      candidateFinderEmojiMode
        ? candidate.kind == CandidateFinder.emojiKind
        : candidate.kind != CandidateFinder.emojiKind
    }
    let scored: [CandidateMatch] = pool.compactMap { candidate in
      if trimmed.isEmpty {
        return CandidateMatch(candidate: candidate, score: 0)
      }
      guard
        let score = CandidateFinder.score(
          normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)
      else { return nil }
      return CandidateMatch(candidate: candidate, score: score)
    }
    candidateFinderMatches = CandidateFinder.sortedMatches(scored)
    if candidateFinderMatches.isEmpty {
      candidateFinderSelectedIndex = 0
    } else {
      candidateFinderSelectedIndex = min(max(candidateFinderSelectedIndex, 0), candidateFinderMatches.count - 1)
    }
  }

  private func candidateFinderDisplayItems(windowSize: Int = 6) -> [CandidateDisplayItem] {
    guard !candidateFinderMatches.isEmpty else { return [] }
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

  func submitCommandLine(_ raw: String) {
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
    if let plugin = NormalModeDispatcher.pluginCommandLineInvocation(raw),
      pluginManager.invoke(
        command: plugin.command,
        name: plugin.name,
        args: plugin.args,
        raw: plugin.raw)
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
    case .copyAll:
      performMappedCommand(.copyAll)
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
    case .terminal, .pluginAction:
      clearCommandLineCompletionState()
      submitCommandLine(newBuffer)
      return true
    }
  }

  private func submitSelectedCommandLineApp() {
    guard !candidateFinderMatches.isEmpty else {
      finishCommandLineInteraction(reason: "command_open_empty")
      return
    }
    let candidate = candidateFinderMatches[min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)]
      .candidate
    finishCommandLineInteraction(reason: "command_open")
    openSourceItem(candidate)
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

  /// Insert an emoji glyph into the focused app: stash it on the
  /// pasteboard and synthesize Cmd+V into the app that owned focus when
  /// `:emojis` was invoked. The overlay never takes key focus, so the
  /// app's text field is still first responder once we dismiss.
  func insertEmoji(_ glyph: String) {
    let pid = normalModeContext()?.processID
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay(captureOverride: true)
    guard !glyph.isEmpty, let pid else { return }
    NormalModeDispatcher.copy(glyph)
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
      if result.didPerform {
        if let pid = result.targetPID {
          self.normalModeTargetPID = pid
        }
        self.scheduleNormalModeRecapture()
        return
      }
      guard let key = Self.tabIndexKeyCode(index) else {
        FlashLog.debug("[normal_mode] tab_select unsupported index=\(index)")
        self.applyModeOverlay()
        return
      }
      self.sendNormalModeKey(key, flags: .maskCommand)
    }
  }

  private func tabNextInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_next",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabNext(in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(
          CGKeyCode(kVK_ANSI_RightBracket),
          flags: [.maskCommand, .maskShift],
          repeatCount: count)
      })
  }

  private func tabPrevInNormalMode(repeatCount: Int) {
    performTabSourceAction(
      name: "tab_previous",
      repeatCount: repeatCount,
      action: { registry, context, completion in
        registry.tabPrev(in: context, completion: completion)
      },
      fallback: { [weak self] _, count in
        self?.sendNormalModeKey(
          CGKeyCode(kVK_ANSI_LeftBracket),
          flags: [.maskCommand, .maskShift],
          repeatCount: count)
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

  /// macOS terminals that have no native tabs (only windows). For these
  /// bundles, tab_new / :tabnew fall back to cmd-N so the gesture still
  /// produces a new workspace. tmux is handled by TmuxProvider one level
  /// up — when an attached tmux client is present, `new-window` runs
  /// before this fallback ever fires.
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
        if result.didPerform {
          if let pid = result.targetPID {
            self.normalModeTargetPID = pid
          }
          attempt(remaining - 1)
          return
        }
        fallback(context, remaining)
      }
    }

    attempt(count)
  }

  private func tabNewAndEnterInsertMode() {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for tab_new_insert")
      applyModeOverlay()
      return
    }
    registry.tabNew(in: context) { [weak self] result in
      guard let self else { return }
      if !result.didPerform {
        let key = AppDelegate.tabNewFallbackKey(forBundleIdentifier: context.bundleIdentifier)
        NormalModeDispatcher.sendKey(
          virtualKey: key,
          flags: .maskCommand,
          to: context.processID)
      }
      let targetPID = result.targetPID ?? context.processID
      self.normalModeTargetPID = targetPID
      self.suppressEditableFocus(for: targetPID)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
        self?.enterInsertMode(reason: .normalModeInput)
      }
    }
  }

  static func nativeBrowserTabIndexKey(index: Int, bundleIdentifier: String) -> CGKeyCode? {
    guard BrowserTabSources.allBundleIdentifiers.contains(bundleIdentifier) else { return nil }
    return tabIndexKeyCode(index)
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

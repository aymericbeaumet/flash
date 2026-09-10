import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

enum InsertModeTransitionReason: Equatable {
  case explicitCommand
  case normalModeInput
  case pointerClick
  case hintCommit
  case advancedModeDisabled
  case secureInput
  case normalModePassthrough

  var logValue: String {
    switch self {
    case .explicitCommand:
      return "explicit_command"
    case .normalModeInput:
      return "normal_mode_input"
    case .pointerClick:
      return "pointer_click"
    case .hintCommit:
      return "hint_commit"
    case .advancedModeDisabled:
      return "advanced_mode_disabled"
    case .secureInput:
      return "secure_input"
    case .normalModePassthrough:
      return "normal_mode_passthrough"
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
  enum HintCommitBehavior {
    case click
    case copyURL
    case moveMouse
    case drag
    case select
    case multiClick
    case adjustClick
    case searchClick
    case mouseGridClick
    case mouseGridMove
    case mouseGridDrag
    case mouseGridSelect
    case mouseGridMulti
  }

  struct MovementEntry {
    enum Kind {
      case app
      case candidate
      case route
    }

    var kind: Kind
    var key: String
    var pid: pid_t?
    var candidate: Candidate?
    var navigationURL: URL?

    static func app(pid: pid_t) -> MovementEntry {
      MovementEntry(kind: .app, key: "app:\(pid)", pid: pid, candidate: nil, navigationURL: nil)
    }

    static func candidate(_ candidate: Candidate) -> MovementEntry {
      let target =
        candidate.navigationURL?.absoluteString
        ?? candidate.url?.absoluteString
        ?? candidate.sourcePayload
        ?? candidate.title
      return MovementEntry(
        kind: .candidate,
        key: "candidate:\(candidate.sourceID):\(candidate.pid ?? 0):\(target)",
        pid: candidate.pid,
        candidate: candidate,
        navigationURL: candidate.navigationURL)
    }

    static func route(_ url: URL, pid: pid_t?) -> MovementEntry {
      MovementEntry(
        kind: .route,
        key: "route:\(url.absoluteString)",
        pid: pid,
        candidate: nil,
        navigationURL: url)
    }
  }

  struct MovementIdentity: Equatable {
    var key: String
  }

  var config = Config.default
  let pluginManager = PluginManager()
  let wifiInfoProvider = WiFiInfoProvider()
  let statusItemController = StatusItemController()
  /// Flat-JSON frecency persistence — keyed by stable item key
  /// (`app.bundle:…`, `url:…`, `command:…`), boost capped below the
  /// smallest `CandidateFinder` match-quality tier so it reorders
  /// within tiers without crossing them. Nil only if the support
  /// directory can't be created (read-only home, missing permission).
  var frecencyStore: FrecencyStore?
  /// Bumped on every keystroke. The scoring queue captures it at
  /// submission time and discards any late DB walk that returns after
  /// the user has typed past the query.
  var registry: SourceRegistry!
  var monitor: AppMonitor!
  var debugServer: DebugServer?
  var overlay: OverlayPanel!
  var statusBarController: FlashStatusBarController?
  var statusTerminalEnvironmentReady = false
  var terminalReturnApplicationPID: pid_t?
  var terminalInputMappings: TerminalInputMappingHandler<StatusTerminalInputOrigin>?
  var urlHandler: URLEventHandler!
  var configSources: [DispatchSourceFileSystemObject] = []
  /// Trailing-edge coalescer for config file events (one reload per burst).
  var configReloadWork: DispatchWorkItem?
  /// Bytes of the config file at the last applied reload; an event that
  /// leaves them unchanged (editor temp/rename dance, `touch`) is a no-op.
  var lastAppliedConfigFileContents: Data?
  var autoLaunchReconciled = false
  let mappings = MappingsCoordinator()
  let windowLayoutManager = WindowLayoutManager()
  /// Per-focused-app effective mapping tables (config + applicable plugin
  /// mappings), keyed by bundle id ("" for none/unknown). Cleared on config
  /// reload and when a plugin's mappings change.
  var effectiveMappingCache: [String: Config.Mode] = [:]
  /// The effective mode last handed to `MappingsCoordinator`, so a focus
  /// change only re-registers Carbon hotkeys when the chord set changed.
  var lastAppliedMappingMode: Config.Mode?
  var lastConfigErrorAlertMessage: String?
  var configErrorAlertVisible = false

  /// Owns transient hint content and any primary button held by pointer mode.
  var hintSession = HintSession()
  /// The single source of truth for the app's mode. Every UI-facing fact
  /// (overlay input routing, status bar, badge, capture, mapping scope) is a
  /// projection of `modeStore.mode`; transitions go through `dispatchMode`.
  let modeStore = ModeStore()
  /// The coarse insert/normal axis, projected from the unified mode.
  var flashMode: FlashMode { modeStore.mode.flashMode }
  /// Advanced mode (the normal/insert system) is configured — true unless the
  /// mode is `.disabled`, i.e. the user has an all-mode `leave_mode` or `enter_normal_mode` binding.
  /// Gates capture and the active-window border, NOT the status bar's
  /// visibility.
  var modeBadgeEnabled: Bool { modeStore.mode.advancedEnabled }
  /// Whether the persistent top status bar is shown. Mirrors
  /// `config.statusBar.enabled` and is the sole condition for the bar — set
  /// from `[statusbar] enabled`, independent of `modeBadgeEnabled`.
  var statusBarVisible = false
  var normalModeTargetPID: pid_t?
  /// Vim-style yank/paste registers. The unnamed register is the system
  /// clipboard; named registers (`a`–`z`, `0`–`9`) are in-process buffers.
  let registers = RegisterStore()
  let finder = CandidateFinderSession()
  /// Clipboard history mirrored for the inspector's Clipboard tab. Refreshed
  /// from the clipboard plugin on `:clipboard` and on each pasteboard change,
  /// then surfaced through `debugStateJSON`.
  var clipboardEntries: [ClipboardModalEntry] = []
  var pluginStateRefreshWork: DispatchWorkItem?
  var commandLineCompletionPrefix: String = ""
  var commandLineCompletionMatches: [CommandLineCompletionMatch] = []
  var commandLineCompletionSelectedIndex = 0
  var commandLineCompletionQuery: String = ""
  /// Session-local immutable completion catalog. Plugin registrations and help
  /// topics do not change while one command field is open, so rebuilding these
  /// collections on every character only adds input latency.
  var commandLineCompletionInventory: NormalModeDispatcher.CommandLineCompletionInventory?
  /// Past executed command-line inputs (most-recent last). up/down (and
  /// ctrl+n/p, which route to the same handler) recall these when no candidate
  /// or completion list is active — see `recallCommandLineHistory`. Loaded from
  /// `commandHistoryStore` at startup so recall survives restarts/reinstalls.
  var commandLineHistory: [String] = []
  /// On-disk persistence for `commandLineHistory`.
  var commandHistoryStore: CommandHistoryStore?
  /// Index into `commandLineHistory` while recalling; nil when editing a fresh
  /// buffer. `commandLineHistoryStash` holds that fresh buffer so stepping
  /// `down` past the newest entry restores what the user was typing.
  var commandLineHistoryCursor: Int?
  var commandLineHistoryStash: String = ""
  var selectedInitialMode = false
  /// The last click Flash committed (hints, grid, or multi session), replayed
  /// by `mouse_repeat`. Deliberately outside `hintSession`: it must survive
  /// the session reset so a repeat works after the overlay is gone.
  struct LastCommittedClick {
    var point: CGPoint
    var action: JumpAction
    var modifiers: ClickModifiers
    var pid: pid_t?
  }
  var lastCommittedClick: LastCommittedClick?
  var movementCurrent: MovementEntry?
  var movementBackStack: [MovementEntry] = []
  var movementForwardStack: [MovementEntry] = []
  var movementNavigationTargetKey: String?
  var ambientLocationRecordToken: UInt64 = 0
  var movementLocationResolutionGeneration: UInt64 = 0
  var sourceItemResolutionGeneration: UInt64 = 0
  var appCurrent: pid_t?
  var observedFocusedAppPID: pid_t?
  var appBackStack: [pid_t] = []
  var appForwardStack: [pid_t] = []
  var appNavigationTargetPID: pid_t?
  var workspaceTokens: [NSObjectProtocol] = []
  var localNotificationTokens: [NSObjectProtocol] = []
  var resignKeyToken: NSObjectProtocol?
  var normalModeRecaptureToken: UInt64 = 0
  var normalModeCaptureRecoveryToken: UInt64 = 0
  var normalModeCaptureRecoveryRecaptureToken: UInt64?
  /// Consolidated recapture-suppression windows (was three parallel `Date?`
  /// fields). The named accessors below forward to it so existing call sites and
  /// tests keep their field names while the storage + predicate live in one
  /// tested value.
  var recaptureSuppression = RecaptureSuppression()
  var menuBarInteractionRecaptureSuppressedUntil: Date? {
    get { recaptureSuppression.menuBarUntil }
    set { recaptureSuppression.menuBarUntil = newValue }
  }
  var contextMenuInteractionRecaptureSuppressedUntil: Date? {
    get { recaptureSuppression.contextMenuUntil }
    set { recaptureSuppression.contextMenuUntil = newValue }
  }
  var pointerInsertHandoffRecaptureSuppressedUntil: Date? {
    get { recaptureSuppression.pointerInsertHandoffUntil }
    set { recaptureSuppression.pointerInsertHandoffUntil = newValue }
  }
  var pointerInsertHandoffToken: UInt64 = 0
  /// True while a native surface (context menu / OS popup) owns the keyboard.
  /// The sole non-base-mode input to the capture projection — set by
  /// `suspendNormalCaptureForNativeSurface`, cleared when capture is
  /// re-established (recapture or any mode transition). Keeps `overlay.inputMode`
  /// and the badge's capture flag from drifting away from the mode.
  var nativeSurfaceSuspended = false
  var aboutWindowVisible = false
  var normalModePendingCommandToken: UInt64 = 0
  var clipboardMonitor: ClipboardMonitor?
  var powerSourceMonitor: PowerSourceMonitor?
  /// Captures NORMAL / hints keystrokes without taking key-window focus. nil
  /// (no grant) falls back to the legacy key-window capture in
  /// `captureKeyboardInput`.
  var keyboardCaptureTap: KeyboardCaptureTap?
  var activeWindowBorderReconciliationGeneration: UInt64 = 0
  var activeWindowBorderUpdateGeneration: UInt64 = 0
  var activeWindowBorderTrackedFrame: CGRect?
  var activeWindowBorderSessionSuspensions: Set<ActiveWindowBorderSessionSuspension> = []
  var activationLifecycle = ActivationLifecycle<HintActivationRequest>()
  var activationInFlight: Bool { activationLifecycle.inFlight }
  var activationGen: UInt64 { activationLifecycle.generation }
  /// AX trust is checked once per session — until we observe `true`, we
  /// re-query each time. Once granted, the value is sticky for the rest
  /// of the run. Saves one IPC per activation in the steady state.
  /// Reset to `false` if an activation walk returns zero targets, which
  /// is the symptom of permission revocation mid-session.
  var cachedAccessibilityTrusted: Bool = false
  var lastPermissionPromptAt: Date?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Resolve the login-shell environment once, off the main thread, so every
    // `script:`/`command:` task, mapping, and plugin inherits the same PATH
    // and tooling the user has in their terminal. A GUI launch from Finder/
    // launchd would otherwise hand children a bare environment. Until this
    // lands the seeded cache (process env + PATH fallback) keeps commands
    // usable, so the spawn need not block startup.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      FlashProcessEnvironment.shared.refresh()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.statusTerminalEnvironmentReady = true
        self.reloadTerminalPopupConfiguration()
      }
    }
    config = ConfigLoader.load()
    FlashTunables.apply(config)
    frecencyStore = FrecencyStore(
      configuration: FrecencyStore.Configuration(
        halfLifeDays: config.flashlight.frecencyHalfLifeDays,
        maxBoost: config.flashlight.frecencyMaxBoost))
    commandHistoryStore = CommandHistoryStore()
    commandLineHistory = commandHistoryStore?.load() ?? []
    let manager = pluginManager
    registry = SourceRegistry(
      openConfig: config.open,
      pluginSourcesProvider: { manager.sources })
    monitor = AppMonitor(registry: registry, config: config)
    monitor.focusedElementDidChange = { [weak self] pid, notification in
      guard let self else { return }
      guard self.pluginManager.hasListener(for: "core:ax.changed") else { return }
      self.pluginManager.emit(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["notification": notification, "pid": Int(pid)],
          bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier))
    }
    monitor.activeWindowMayHaveChanged = { [weak self] pid, notification, window in
      self?.activeWindowMayHaveChanged(
        pid: pid, notification: notification, observedWindow: window)
    }
    monitor.focusedWindowDidResolve = { [weak self] pid, window in
      guard let self, self.currentNonFlashContext()?.processID == pid else { return }
      self.windowLayoutManager.observedFocusedWindow(
        pid: pid,
        window: window,
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor)
    }
    monitor.start()
    pluginManager.onStateChanged = { [weak self] in
      self?.pluginStateDidChange()
    }
    pluginManager.onNormalModeTargetRequested = { [weak self] in
      guard let context = self?.normalModeContext() ?? self?.currentNonFlashContext() else {
        return nil
      }
      return (pid: context.processID, bundleID: context.bundleIdentifier)
    }
    pluginManager.onNotifyRequested = { [weak self] message, durationMs in
      self?.overlay.displayBanner(message, durationMs: durationMs)
    }
    pluginManager.wifiInfoProvider = wifiInfoProvider
    pluginManager.onCatalogsChanged = { [weak self] in
      self?.handlePluginCatalogsChanged()
    }
    pluginManager.onSyntheticKeysRequested = { [weak self] pid, chords, intervalMs in
      for (index, chord) in chords.enumerated() {
        DispatchQueue.main.asyncAfter(
          deadline: .now() + .milliseconds(index * intervalMs)
        ) {
          self?.mappings.noteSyntheticKey(
            virtualKey: UInt32(chord.key), flags: chord.flags)
          NormalModeDispatcher.sendKey(virtualKey: chord.key, flags: chord.flags, to: pid)
        }
      }
    }
    pluginManager.onGlobalSyntheticKeyRequested = { [weak self] key, flags in
      guard let self else { return false }
      self.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
      return NormalModeDispatcher.sendGlobalKey(virtualKey: key, flags: flags)
    }
    pluginManager.cacheRunningApplicationsSnapshot(runningApplicationsSnapshot())
    pluginManager.start(config: config)
    configureDebugServer(for: config)

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.statusBarPopupStyle = config.statusBar.popupStyle
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.effectiveMagicModifiers)
    overlay.normalModeSequenceTimeoutMs = config.mode.sequenceTimeoutMs
    overlay.normalModePassthroughKeyCodes = config.mode.normalPassthroughKeyCodes
    overlay.normalModePassthroughModifiers = config.mode.normalPassthroughModifiers
    // Pay the layer-allocation cost at launch instead of on the first
    // activation. 256 covers the steady state for most apps; further
    // growth uses the regular dequeue/alloc fallback.
    overlay.warmPool(count: 256)
    statusBarController = FlashStatusBarController(
      overlay: overlay,
      template: config.statusBar.template,
      popupTemplates: config.statusBar.popups,
      options: config.statusBar.options,
      sources: config.statusBar.sources,
      terminalPopupNames: Set(config.terminals.keys),
      refreshIntervalSeconds: config.statusBar.refreshIntervalSeconds,
      pluginStatusesProvider: { [weak self] in
        self?.pluginManager.statusBarInfos() ?? []
      })
    statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)
    overlay.statusBarActionHandler = { [weak self] name in
      self?.performStatusBarClickAction(named: name)
    }
    configureTerminalPopupInput()
    statusItemController.aboutVisibilityDidChange = { [weak self] visible in
      self?.aboutWindowVisibilityDidChange(visible)
    }

    urlHandler = URLEventHandler(
      handler: { [weak self] cmd in self?.handleURLCommand(cmd) ?? false },
      rejected: { [weak self] command in self?.warnUnsupportedCommand(command) })
    mappings.start(
      dispatch: { [weak self] action in
        self?.dispatchNativeMappingAction(action)
      })
    modeStore.perform = { [weak self] effects, previous, next in
      self?.applyModeEffects(effects, previous: previous, next: next)
    }
    refreshEffectiveMappings(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    if let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      movementCurrent = .app(pid: app.processIdentifier)
      appCurrent = app.processIdentifier
      observedFocusedAppPID = app.processIdentifier
    }
    watchConfigFile()
    selectInitialModeIfNeeded()
    logPermissionState()
    installDismissObservers()
    startClipboardMonitor()
    startPowerSourceMonitor()
    pluginManager.emit(
      PluginEvent(
        name: "core:flash.started", payload: [:], bundleID: nil))
    emitRunningApplicationsChanged(reason: "launch")
  }

  @discardableResult
  func handleURLCommand(_ cmd: URLCommand) -> Bool {
    FlashLog.trace(
      "[url] command=\(cmd.diagnosticDescription) mode=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight) overlay=\(String(describing: overlay?.inputMode))")
    switch cmd {
    case .mouseTarget(let command):
      activateMouseTarget(command, contextOverride: nil)
    case .mouseTargetScreen(let command):
      activateScreenScopeHints(command)
    case .mouseGrid(let command):
      activateMouseGrid(command, contextOverride: nil)
    case .mouseRepeat:
      performMouseRepeat()
    case .mousePointer:
      enterPointerMode()
    case .focusInput:
      focusTextInputInNormalMode(index: 1)
    case .scrollTarget:
      activateScrollTargetHints()
    case .mouseDock:
      activateDockHints()
    case .mouseStatusBar:
      activateStatusItemHints()
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
    case .insertMode:
      enterInsertMode()
    case .commandMode:
      enterCommandLineMode()
    case .scroll, .reload, .undo, .redo, .archive, .resourceNext, .resourcePrevious,
      .close, .tabClose, .find, .candidateFinder,
      .enterCommand, .copyURL, .yankSelection, .paste,
      .tabNext, .tabPrev, .tabFirst, .tabLast, .tabSelect,
      .tabMovePrev, .tabMoveNext, .tabReopen,
      .paneNext, .panePrev, .paneSplitVertical, .paneSplitHorizontal, .paneClose,
      .historyBack, .historyForward,
      .movementBack, .movementForward, .appPrev, .appNext,
      .quitApp, .saveAndQuit, .tabNew,
      .sendKey, .sendKeys:
      performMappedCommand(cmd)
    case .showAlert(let alert):
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      overlay.displayAlert(
        alert.message,
        duration: alert.duration,
        style: .from(alert.style))
    case .dismissAlert:
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      overlay.dismissAlert()
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showPlugins:
      openDebugDashboard(tab: "plugins")
    case .showAbout:
      statusItemController.showAbout()
    case .dismissHints:
      cancelOverlay()
    case .quit:
      NSApp.terminate(nil)
    case .openApp(let name):
      openSourceItem(matching: name)
    case .pluginCommand(let command, let subcommand, let args):
      let dispatched = pluginManager.invoke(
        command: command,
        subcommand: subcommand,
        args: args,
        raw: cmd.diagnosticDescription,
        in: pluginSelectorContext()
      ) { [weak self] ok, pid, stdout, navigationURL in
        guard ok else {
          self?.warnCommandFailure(cmd.diagnosticDescription)
          return
        }
        self?.activatePluginCommandTarget(pid, navigationURL: navigationURL)
        if let stdout { self?.overlay.displayBanner(stdout) }
      }
      if !dispatched { warnUnsupportedCommand(cmd.diagnosticDescription) }
      return dispatched
    case .moveWindow(let params):
      // Use the *non-Flash* frontmost app as the move target. Without
      // this, normal-mode capture (which activates Flash to satisfy the
      // Tahoe key-window rule) makes `frontmostApplication` resolve to
      // Flash itself, and the verb cheerfully maximises the status-bar
      // panel instead of the user's actual window.
      if let target = currentNonFlashContext() {
        windowLayoutManager.move(
          params,
          statusBarReservesSpace: statusBarVisible,
          statusBarMonitor: config.statusBar.monitor,
          targetPID: target.processID)
      } else {
        FlashLog.warn("[window_move] no non-flash frontmost app")
      }
    case .pluginVerb(let name, let args):
      // `core:focus.changed` etc. carry the focused-app pid/bundle id, but
      // verb dispatch is opportunistic and the verb may fire while normal
      // mode has retained a target across a focus blip — prefer that
      // target when present so e.g. `app_save` saves the file the user
      // was last looking at, not the app Flash happens to overlay.
      let target = normalModeContext() ?? currentNonFlashContext()
      let dispatched = pluginManager.invokeVerb(
        name: name,
        args: args,
        in: pluginSelectorContext(for: target),
        focusedPID: target?.processID
      ) { [weak self] ok, pid, stdout, navigationURL in
        guard ok else {
          self?.warnCommandFailure(cmd.diagnosticDescription)
          return
        }
        self?.activatePluginCommandTarget(pid, navigationURL: navigationURL)
        if let stdout { self?.overlay.displayBanner(stdout) }
      }
      if !dispatched {
        warnUnsupportedCommand(cmd.diagnosticDescription)
      }
      return dispatched
    }
    return true
  }

  func warnUnsupportedCommand(_ command: String) {
    displayCommandWarning(URLEventHandler.rejectionMessage(command))
  }

  func warnCommandFailure(_ command: String) {
    displayCommandWarning("Command failed or was not handled: \(command). Check :logs for details.")
  }

  private func displayCommandWarning(_ message: String) {
    FlashLog.warn(message, source: "core:Command")
    overlay.displayAlert(message, duration: 8, style: .error)
  }

  private func installDismissObservers() {
    // The user pressing Cmd-Tab, opening Mission Control, clicking another
    // app's window, switching Spaces, etc. should immediately hide the
    // overlay — its hint labels were computed against the previous front
    // app's geometry and would be wrong (and visually confusing) anywhere
    // else. Use the workspace's notification for app switches, plus
    // panel-level resignKey as a belt-and-suspenders catch for cases where
    // focus leaves Flash without an app switch (Spaces, full-screen apps,
    // some screen-saver paths).
    let nc = NSWorkspace.shared.notificationCenter
    let appSwitch = nc.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      // Ignore Flash itself activating (it shouldn't, but be safe).
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier == Bundle.main.bundleIdentifier
      {
        return
      }
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.terminalInputMappings?.flush()
        self.overlay.hideStatusBarPopup()
        let secureUI = Self.activeWindowBorderSecureUISuspendsSession(
          bundleIdentifier: app.bundleIdentifier)
        self.setActiveWindowBorderSessionSuspended(
          secureUI, source: .secureUI, reason: secureUI ? "secure_ui" : "secure_ui_exit")
        self.applyFocusedApplicationChange(app, reason: "focus_changed", emitFocusEvent: true)
        self.cancelOverlay()
        if self.shouldScheduleNormalModeRecaptureAfterWorkspaceActivation() {
          self.scheduleNormalModeRecapture()
        }
      } else {
        self.statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)
        self.cancelOverlay()
        if self.shouldScheduleNormalModeRecaptureAfterWorkspaceActivation() {
          self.scheduleNormalModeRecapture()
        }
      }
    }
    let activeSpace = nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.reconcileFrontmostApplication(reason: "space_changed")
      self.cancelOverlay()
      self.scheduleActiveWindowBorderReconciliation(
        delaysMs: Self.activeWindowBorderRecoveryDelaysMs, reason: "space_changed")
      self.pluginManager.emit(
        PluginEvent(
          name: "core:space.changed", payload: [:], bundleID: nil))
      if self.flashMode == .normal {
        self.scheduleNormalModeRecapture()
      }
    }
    let appLaunched = nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      self.registry.refreshRunningApplications()
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.pluginManager.emit(
          PluginEvent(
            name: "core:apps.launched",
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier))
      }
      self.emitRunningApplicationsChanged(reason: "app_launch")
      if self.flashMode == .normal {
        self.scheduleNormalModeRecapture()
      }
    }
    let appTerminated = nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      self.registry.refreshRunningApplications()
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.windowLayoutManager.appDidTerminate(pid: app.processIdentifier)
        if app.processIdentifier == self.observedFocusedAppPID {
          self.hideActiveWindowBorder(reason: "app_terminated")
          DispatchQueue.main.async {
            self.reconcileFrontmostApplication(reason: "app_terminated")
            self.updateActiveWindowBorder(reason: "app_terminated")
            self.scheduleActiveWindowBorderReconciliation(
              delaysMs: Self.activeWindowBorderRecoveryDelaysMs,
              reason: "app_terminated")
          }
        }
        self.pluginManager.emit(
          PluginEvent(
            name: "core:apps.terminated",
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier))
      }
      self.emitRunningApplicationsChanged(reason: "app_terminate")
    }
    let sessionResigned = nc.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setActiveWindowBorderSessionSuspended(
        true, source: .session, reason: "session_resigned")
    }
    let sessionBecameActive = nc.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.setActiveWindowBorderSessionSuspended(
        false, source: .session, reason: "session_active")
      // The secure login surface may have activated without a corresponding
      // regular-app activation on the way back. A session switch-in is the
      // authoritative signal that it no longer owns the desktop.
      self.setActiveWindowBorderSessionSuspended(
        false, source: .secureUI, reason: "session_active")
    }
    let screensSlept = nc.addObserver(
      forName: NSWorkspace.screensDidSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setActiveWindowBorderSessionSuspended(
        true, source: .screens, reason: "screens_sleep")
    }
    let screensWoke = nc.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setActiveWindowBorderSessionSuspended(
        false, source: .screens, reason: "screens_wake")
    }
    let systemWillSleep = nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setActiveWindowBorderSessionSuspended(
        true, source: .systemSleep, reason: "system_sleep")
    }
    let systemWoke = nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setActiveWindowBorderSessionSuspended(
        false, source: .systemSleep, reason: "system_wake")
    }
    workspaceTokens = [
      appSwitch, activeSpace, appLaunched, appTerminated,
      sessionResigned, sessionBecameActive, screensSlept, screensWoke,
      systemWillSleep, systemWoke,
    ]

    let screenParameters = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.windowLayoutManager.screenParametersDidChange(
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor
      ) { [weak self] _ in
        // The semantic window restore runs off-main. Repaint only after each
        // recovery pass has applied its AX frame so the border cannot sample
        // the pre-handoff geometry and remain on the disconnected display.
        self?.updateActiveWindowBorder(reason: "screen_layout_recovered")
      }
      // OverlayPanel invalidates its screen snapshot from the same notification.
      // Redraw on the next main turn so the border path uses the rebuilt union.
      DispatchQueue.main.async {
        self.updateActiveWindowBorder(reason: "screen_parameters")
        self.scheduleActiveWindowBorderReconciliation(
          delaysMs: Self.activeWindowBorderRecoveryDelaysMs,
          reason: "screen_parameters")
      }
    }
    localNotificationTokens = [screenParameters]

    resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: overlay,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // Belt-and-suspenders reconciliation for missed workspace activation
      // notifications. On Tahoe (26), focus can snap back from Flash's panel
      // to another app without `didActivateApplicationNotification`; only
      // updating the status-bar label left app-scoped plugin mappings stale,
      // so terminal chords such as tmux's `cmd+shift+[` leaked to Alacritty.
      self.reconcileFrontmostApplication(reason: "resign_key")
      if !self.hintSession.hints.isEmpty {
        self.cancelOverlay()
        return
      }
      if self.flashMode == .normal {
        self.scheduleNormalModeRecaptureAfterPointerFocusLoss()
      }
    }
  }

  /// Key-path reconcile. The focused app can change through the system app
  /// switcher without a workspace notification landing before the next
  /// keydown, so app-scoped plugin chords must be matched against the actual
  /// frontmost app. This runs inside the tap callback, so it does zero work
  /// when the event already names the observed frontmost pid, one workspace
  /// lookup otherwise, and the full focus refresh only on a real change.
  func reconcileFrontmostApplication(forKeyTargetingPID targetPID: pid_t) {
    if targetPID > 0, targetPID == observedFocusedAppPID { return }
    guard let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier != observedFocusedAppPID,
      front.bundleIdentifier != Bundle.main.bundleIdentifier,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: front.bundleIdentifier)
    else { return }
    FlashLog.trace(
      "[focus] key_reconcile target_pid=\(targetPID) observed=\(observedFocusedAppPID ?? 0) "
        + "front=\(front.processIdentifier)")
    applyFocusedApplicationChange(front, reason: "key_down", emitFocusEvent: true)
  }

  func reconcileFrontmostApplication(reason: String) {
    guard let front = NSWorkspace.shared.frontmostApplication,
      front.bundleIdentifier != Bundle.main.bundleIdentifier,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: front.bundleIdentifier)
    else { return }
    let changed = observedFocusedAppPID != front.processIdentifier
    applyFocusedApplicationChange(front, reason: reason, emitFocusEvent: changed)
  }

  func preparePendingApplicationActivation(_ app: NSRunningApplication, reason: String) {
    FlashLog.trace(
      "[focus] prepare_pending reason=\(reason) "
        + "bundle=\(app.bundleIdentifier ?? "") pid=\(app.processIdentifier)")
    refreshFocusDependentState(for: app)
    if flashMode == .normal {
      normalModeTargetPID = app.processIdentifier
    }
  }

  private func applyFocusedApplicationChange(
    _ app: NSRunningApplication,
    reason: String,
    emitFocusEvent: Bool
  ) {
    observedFocusedAppPID = app.processIdentifier
    refreshFocusDependentState(for: app)
    if emitFocusEvent {
      pluginManager.emit(
        PluginEvent(
          name: "core:focus.changed",
          payload: [
            "bundle_id": app.bundleIdentifier ?? "",
            "localized_name": app.localizedName ?? "",
            "pid": Int(app.processIdentifier),
          ],
          bundleID: app.bundleIdentifier))
      emitRunningApplicationsChanged(reason: reason)
      recordAppActivation(app.processIdentifier)
    }
    if flashMode == .normal {
      normalModeTargetPID = app.processIdentifier
    }
  }

  private func refreshFocusDependentState(for app: NSRunningApplication) {
    statusBarController?.updateFocusedApplication(app)
    registry.refreshRunningApplications()
    refreshEffectiveMappings(for: app.bundleIdentifier)
  }

  /// Start the in-process pasteboard watcher and bridge its callback onto the
  /// `clipboard.changed` plugin event. Owning the watch here keeps plugins
  /// free of polling — the clipboard plugin just subscribes to the event.
  private func startClipboardMonitor() {
    clipboardMonitor = ClipboardMonitor { [weak self] text in
      guard let self else { return }
      self.pluginManager.emit(
        PluginEvent(
          name: "core:clipboard.changed",
          payload: ["text": text],
          bundleID: nil))
      // Let the plugin fold the new entry into its history, then refresh the
      // inspector's Clipboard tab so an open dashboard updates live.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
        self?.refreshClipboardDashboardCache()
      }
    }
    clipboardMonitor?.start()
  }

  /// Bridge macOS power-source notifications into the plugin event stream.
  /// The power plugin samples `pmset -g batt` only when this fires, rather
  /// than waking up every N seconds.
  private func startPowerSourceMonitor() {
    powerSourceMonitor = PowerSourceMonitor { [weak self] in
      self?.pluginManager.emit(
        PluginEvent(
          name: "core:power.changed",
          payload: [:],
          bundleID: nil))
    }
    powerSourceMonitor?.start()
  }

  /// Install the keyboard tap so NORMAL / hints capture no longer needs the
  /// overlay to be the key window. Requires the Accessibility grant (which Flash
  /// already needs); if it's missing the tap won't create and we transparently
  /// fall back to key-window capture.
  func startKeyboardCaptureTap() {
    guard keyboardCaptureTap == nil else { return }
    guard AXIsProcessTrusted() else {
      FlashLog.warn("[tap] no accessibility grant — using key-window capture for normal mode")
      return
    }
    let tap = KeyboardCaptureTap(
      shouldSwallow: { [weak self] event in self?.keyboardTapShouldSwallow(event) ?? false },
      handle: { [weak self] event in self?.routeTapCapturedKey(event) })
    guard tap.start() else { return }
    keyboardCaptureTap = tap
    overlay.keyboardCaptureActive = true
  }

  /// Decide whether the keyboard tap should swallow a `keyDown`. Runs on the main
  /// thread. INSERT is never touched (keys flow straight to the focused app);
  /// NORMAL captures keys except configured passthrough keys. Modified chords are handled by the
  /// interpreter too:
  /// `normalModeMappings` carries the same compiled set the Carbon registry does,
  /// and the session tap swallows the event before Carbon dispatch, so there's no
  /// double-fire. An unmapped keypress matching a configured passthrough key or
  /// carrying a configured passthrough modifier instead passes through unchanged
  /// and switches Flash to INSERT. Command-line /
  /// modal / candidate-finder own the key window and type into their own fields,
  /// so the tap leaves those alone.
  private func keyboardTapShouldSwallow(_ event: CGEvent) -> Bool {
    if case .terminal = modeStore.mode { return false }
    // INSERT is transparent so typing flows to the focused app. But a modified
    // chord bound to an active mapping (`[mode.all]` / `[mode.insert]`) must
    // still fire Flash's action. Historically that went only through a Carbon
    // hotkey — a slower keypress→dispatch route than this session tap — which
    // is why *leaving* insert (⌘⌃[ → NORMAL) lagged while *entering* it (`i`,
    // swallowed right here) was instant, and why the app also saw the chord.
    // Handle mapped chords on the same fast tap path instead: swallow (so the
    // app never receives the chord) and let `routeTapCapturedKey` fire the
    // mapping. Only *mapped* chords are swallowed — ordinary typing and
    // unmapped chords (⌘C, ⌘Tab, …) pass straight through, and `hasMapping`
    // matches only modified chords so a bare key can never match. This is the
    // highest-rate branch (every keystroke while typing), so it is ordered
    // cheapest-first: raw flag test, O(1) table lookup, and only for a mapped
    // chord the frontmost reconcile and the secure-input syscall.
    if flashMode == .insert, !(aboutWindowVisible || nativeSurfaceSuspended) {
      let flags = event.flags
      guard
        flags.contains(.maskCommand) || flags.contains(.maskControl)
          || flags.contains(.maskAlternate)
      else { return false }
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      reconcileFrontmostApplication(
        forKeyTargetingPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
      guard mappings.hasMapping(virtualKey: keyCode, cgFlags: flags) else { return false }
      // A focused secure text field (password) turns on secure event input;
      // never intercept keystrokes bound for it.
      return !IsSecureEventInputEnabled()
    }
    // A focused secure text field (password) turns on secure event input.
    // Never intercept keystrokes bound for it — they must reach the field, and
    // a keyboard tap swallowing secure input is exactly what that mechanism
    // exists to prevent. Reflect it as INSERT (like focusing any text input) so
    // the badge/state match. Checked first, so even the first keystroke isn't
    // swallowed before the mode transition lands.
    if IsSecureEventInputEnabled() {
      if flashMode == .normal, overlay.inputMode == .normal {
        enterInsertMode(reason: .secureInput, targetPID: currentNonFlashContext()?.processID)
      }
      return false
    }
    let aboutOwnsNativeKeyboard = Self.aboutWindowShouldOwnNativeKeyboard(
      visible: aboutWindowVisible,
      hasTransientInput: hintSession.isActive,
      activationInFlight: activationInFlight)
    if aboutOwnsNativeKeyboard || nativeSurfaceSuspended {
      let flags = event.flags
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      let hasMapping = keyboardTapHasActiveMapping(keyCode: keyCode, flags: flags)
      let passthroughModifierFlags = overlay.normalModePassthroughModifierFlags
      let shouldEnterInsert =
        aboutOwnsNativeKeyboard
        && KeyboardCaptureTap.shouldEnterInsertAfterNativeSurfacePassthrough(
          flashMode: flashMode,
          modifierFlags: flags,
          hasMapping: hasMapping,
          isPassthroughKey: overlay.normalModePassthroughKeyCodes.contains(keyCode),
          passthroughModifierFlags: passthroughModifierFlags)
      if shouldEnterInsert {
        let targetPID = normalModeTargetPID
        DispatchQueue.main.async { [weak self] in
          guard let self, self.flashMode == .normal else { return }
          self.enterInsertMode(
            reason: .normalModePassthrough,
            targetPID: targetPID)
        }
      }
      return KeyboardCaptureTap.shouldSwallow(
        flashMode: flashMode,
        inputMode: overlay.inputMode,
        hasMapping: hasMapping,
        nativeSurfaceOwnsKeyboard: true)
    }
    // INSERT under a native surface (About window / suspended session) was
    // handled above; a bare INSERT never reaches here.
    guard flashMode == .normal, overlay.inputMode == .normal else {
      return KeyboardCaptureTap.shouldSwallow(
        flashMode: flashMode,
        inputMode: overlay.inputMode)
    }
    // In NORMAL, an unmapped keypress matching a configured passthrough key or
    // carrying a configured passthrough modifier is NOT swallowed — the original
    // event flows to the app / system natively. Not swallowing (rather than
    // swallow + re-post) is what makes system-level chords like ⌘Tab work. A
    // mapped keypress is still swallowed and fired by `routeTapCapturedKey`.
    //
    // Runs synchronously on every keystroke, so the decision reads raw CGEvent
    // fields — no `NSEvent(cgEvent:)`, which resolves the keyboard layout and
    // made holding a modifier + repeating a key (⌘Tab Tab Tab) feel laggier
    // than INSERT.
    guard overlay.inputMode == .normal else { return true }
    let flags = event.flags
    let passthroughModifierFlags = overlay.normalModePassthroughModifierFlags
    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let isPassthroughKey = overlay.normalModePassthroughKeyCodes.contains(keyCode)
    let usesPassthroughModifier = !flags.intersection(passthroughModifierFlags).isEmpty
    guard isPassthroughKey || usesPassthroughModifier else { return true }
    // Reconcile before deciding mapped-vs-passthrough so app-scoped plugin
    // chords (tmux `cmd+shift+[` / `cmd+shift+]`) are matched for the actual
    // frontmost app instead of leaking to the terminal as plain text.
    reconcileFrontmostApplication(
      forKeyTargetingPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
    let hasMapping = keyboardTapHasActiveMapping(keyCode: keyCode, flags: flags)
    let shouldSwallow = KeyboardCaptureTap.shouldSwallow(
      flashMode: flashMode,
      inputMode: overlay.inputMode,
      modifierFlags: flags,
      hasMapping: hasMapping,
      isPassthroughKey: isPassthroughKey,
      passthroughModifierFlags: passthroughModifierFlags)
    guard !shouldSwallow else { return true }

    // Keep the NORMAL mapping scope installed until the original event has
    // continued downstream. Switching synchronously would register INSERT-only
    // Carbon mappings soon enough to steal this very chord. The next main-loop
    // turn runs after the event has reached the app / WindowServer.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.flashMode == .normal, self.overlay.inputMode == .normal else { return }
      self.enterInsertMode(
        reason: .normalModePassthrough,
        targetPID: self.currentNonFlashContext()?.processID)
    }
    return false
  }

  private func keyboardTapHasActiveMapping(keyCode: UInt32, flags: CGEventFlags) -> Bool {
    mappings.hasMapping(virtualKey: keyCode, cgFlags: flags)
      || (flashMode == .normal && overlay.inputMode == .normal
        && NormalModeInterpreter.recognizesPhysicalKey(
          pending: overlay.normalModePending,
          repeatAnchor: overlay.normalModeRepeatAnchor,
          virtualKey: keyCode,
          modifierFlags: flags,
          mappings: overlay.normalModeMappings))
  }

  /// Dispatch a key the tap swallowed in NORMAL mode. Bare keys (and all hints
  /// keys) go to the overlay interpreter. Modified chords aren't in the
  /// interpreter's compiled set may live in the Carbon matcher or participate
  /// in a multi-key sequence. Try Carbon first, then fall back to the normal
  /// interpreter. Passthrough chords never reach here because the tap leaves
  /// them native.
  func routeTapCapturedKey(_ event: NSEvent) {
    MainThreadWatchdog.note("tap_key")
    // HID timestamp → this main-thread turn: the tap-side latency budget.
    FlashLog.debug(
      "[latency] tap_to_route key=\(event.keyCode) ms="
        + String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000))
    // A chord the tap swallowed in INSERT is an active mapping (see
    // `keyboardTapShouldSwallow`); fire it through the mapping matcher — the
    // same dispatch the Carbon hotkey used, minus the Carbon delivery latency.
    if flashMode == .insert {
      _ = mappings.handle(event: event)
      return
    }
    if overlay.inputMode == .normal {
      let strict = event.modifierFlags.intersection([.command, .control, .option])
      if !strict.isEmpty {
        if mappings.handle(event: event) { return }
      }
    }
    overlay.handleTapCapturedKey(event)
  }

  func emitRunningApplicationsChanged(reason: String) {
    pluginManager.emitRunningApplicationsChanged(
      reason: reason,
      applications: runningApplicationsSnapshot())
  }

  func runningApplicationsSnapshot() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
      guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
      return [
        "bundle_id": bundleID,
        "localized_name": app.localizedName ?? "",
        "pid": Int(app.processIdentifier),
      ]
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    activationLifecycle.invalidate()
    clearHintSessionState()
    ActionDispatcher.waitForPendingMouseEvents()
    activeWindowBorderReconciliationGeneration &+= 1
    for token in workspaceTokens {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    workspaceTokens.removeAll()
    for token in localNotificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    localNotificationTokens.removeAll()
    if let resignKeyToken {
      NotificationCenter.default.removeObserver(resignKeyToken)
      self.resignKeyToken = nil
    }
    pluginStateRefreshWork?.cancel()
    pluginStateRefreshWork = nil
    clipboardMonitor?.stop()
    clipboardMonitor = nil
    powerSourceMonitor?.stop()
    powerSourceMonitor = nil
    statusBarController?.stop()
    statusBarController = nil
    terminalInputMappings?.flush()
    overlay.statusPopupController.dismiss()
    overlay.statusTerminals.shutdown()
    monitor?.stop()
    pluginManager.stop()
    debugServer?.stop()
    debugServer = nil
    frecencyStore?.drain()
    frecencyStore = nil
    commandHistoryStore?.drain()
    commandHistoryStore = nil
  }

}

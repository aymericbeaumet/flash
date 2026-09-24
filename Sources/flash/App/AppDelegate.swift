import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

enum InsertModeTransitionReason: Equatable {
  case explicitCommand
  case normalModeInput
  case pointerClick
  case hintCommit

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
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
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
  /// `[app] keyboard_layout`'s reference table, rebuilt off the key path and
  /// handed to the overlay.
  let keyboardLayoutMonitor = KeyboardLayoutMonitor()
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
  /// Pushes the system appearance to the overlay for `[overlay.dark]`.
  var appearanceObserver: AppearanceObserver?
  var statusBarController: FlashStatusBarController?
  var statusTerminalEnvironmentReady = false
  var terminalReturnApplicationPID: pid_t?
  let mainRunLoopStallObserver = MainRunLoopStallObserver()
  /// The swallowed Escape that closed a hover preview; its routing, queued
  /// right behind, must not also reach a mapping or the interpreter.
  var tapEscapeClosedPopup = false
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
  /// The config error last shown: its message, so an unchanged error is not
  /// re-shown on every reload, and its toast, so clearing the error closes
  /// that toast and never another one.
  struct ShownConfigError {
    let message: String
    let toastToken: UInt64
  }
  var shownConfigError: ShownConfigError?

  /// Owns transient hint content and any primary button held by pointer mode.
  /// The overlay's key routing and the focus border's visibility are
  /// projections of it, pushed here on every change so neither keeps a copy
  /// that could disagree.
  var hintSession = HintSession() {
    didSet {
      guard let overlay else { return }
      overlay.hintKeyRoute = hintSession.keyRoute
      overlay.hintSessionCapture = hintSession.capture
      if oldValue.isActive != hintSession.isActive {
        refreshOverlayInputRouting()
        updateActiveWindowBorder(
          reason: hintSession.isActive ? "hint_session_started" : "hint_session_ended")
      }
    }
  }
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
  var movementCatalogSnapshot: (pid: pid_t, keys: Set<String>)?
  var ambientLocationRecordToken: UInt64 = 0
  var movementLocationResolutionGeneration: UInt64 = 0
  var sourceItemResolutionGeneration: UInt64 = 0
  var appCurrent: pid_t?
  var observedFocusedAppPID: pid_t?
  var lastFocusedApplicationPID: pid_t? {
    observedFocusedAppPID.flatMap { $0 == getpid() ? nil : $0 }
  }
  var appBackStack: [pid_t] = []
  var appForwardStack: [pid_t] = []
  var appNavigationTargetPID: pid_t?
  var workspaceTokens: [NSObjectProtocol] = []
  var localNotificationTokens: [NSObjectProtocol] = []
  var resignKeyToken: NSObjectProtocol?
  var normalModeRecaptureToken: UInt64 = 0
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
  var nativeSurfaceSuspended = false {
    didSet { if oldValue != nativeSurfaceSuspended { refreshOverlayInputRouting() } }
  }
  var aboutWindowVisible = false {
    didSet { if oldValue != aboutWindowVisible { refreshOverlayInputRouting() } }
  }
  var normalModePendingCommandToken: UInt64 = 0
  var clipboardMonitor: ClipboardMonitor?
  var powerSourceMonitor: PowerSourceMonitor?
  /// Captures NORMAL / hints keystrokes without taking key-window focus. nil
  /// (no grant) falls back to the legacy key-window capture in
  /// `captureKeyboardInput`.
  var keyboardCaptureTap: KeyboardCaptureTap?
  /// See `noteSecureInput`.
  var secureInputObserved = false
  var activeWindowBorderReconciliationGeneration: UInt64 = 0
  var activeWindowBorderUpdateGeneration: UInt64 = 0
  /// The authoritative front-window read queued for the next main turn.
  var activeWindowBorderPendingRead: ActiveWindowBorderRead?
  /// Last frame observed for each app's front window, fed by the AX geometry
  /// notifications Flash already subscribes to, so an app switch paints the
  /// right rectangle on the activation itself and the window-list read on the
  /// next main turn corrects it.
  var activeWindowBorderFrameCache: [pid_t: CGRect] = [:]
  var activeWindowBorderSessionSuspensions: Set<ActiveWindowBorderSessionSuspension> = []
  var activationLifecycle = ActivationLifecycle<HintActivationRequest>() {
    didSet {
      if oldValue.inFlight != activationLifecycle.inFlight { refreshOverlayInputRouting() }
    }
  }
  var activationInFlight: Bool { activationLifecycle.inFlight }
  var activationGen: UInt64 { activationLifecycle.generation }
  /// AX trust is checked once per session — until we observe `true`, we
  /// re-query each time. Once granted, the value is sticky for the rest
  /// of the run. Saves one IPC per activation in the steady state.
  /// Reset to `false` if an activation walk returns zero targets, which
  /// is the symptom of permission revocation mid-session.
  var cachedAccessibilityTrusted: Bool = false
  var lastPermissionPromptAt: Date?
  /// Launched without Accessibility and still waiting for the grant; see
  /// `checkAccessibilityAtLaunch`.
  var awaitingAccessibilityGrant = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // First, so the cached primary-screen height refreshes before any other
    // screen-parameter observer reads it.
    ScreenSpace.startObserving()
    mainRunLoopStallObserver.start()
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
    // First run: give the user a working shortcut before the first load.
    StarterConfig.seedIfNeeded(environment: ProcessInfo.processInfo.environment)
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
      // Identity, not a window-list scan: resolution fires on every focus
      // swap, and the list's top window can belong to another app.
      guard let self, self.currentNonFlashRunningApplication()?.processIdentifier == pid
      else { return }
      self.windowLayoutManager.observedFocusedWindow(
        pid: pid,
        window: window,
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor)
      // A launching app activates before it has a window, so the stroke found
      // nothing; its focused window resolving is the first sign one exists.
      if self.overlay.activeWindowBorderFrame == nil {
        self.updateActiveWindowBorder(reason: "focused_window_resolved")
      }
    }
    monitor.start()
    pluginManager.onStateChanged = { [weak self] in
      self?.pluginStateDidChange()
    }
    pluginManager.onNormalModeTargetRequested = { [weak self] in
      guard let self,
        let context = self.normalModeDispatchContext()
      else { return nil }
      let window = HintWindowSnapshot.current(
        pid: context.processID, primaryHeight: self.monitor.primaryScreenHeight())
      return (
        pid: context.processID, bundleID: context.bundleIdentifier, windowID: window?.number
      )
    }
    pluginManager.onNotifyRequested = { [weak self] message, durationMs in
      self?.overlay.displayBanner(message, durationMs: durationMs)
    }
    pluginManager.wifiInfoProvider = wifiInfoProvider
    pluginManager.onCatalogsChanged = { [weak self] in
      self?.handlePluginCatalogsChanged()
      self?.recordPublishedLocations()
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
    pluginManager.cacheRunningApplicationsSnapshot(Self.runningApplicationsSnapshot())
    pluginManager.start(config: config)

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    appearanceObserver = AppearanceObserver(NSApplication.shared) { [weak self] dark in
      self?.overlay.darkAppearance = dark
    }
    overlay.debugConfig = config.debug
    overlay.statusBarPopupStyle = config.statusBar.popupStyle
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.effectiveMagicModifiers)
    overlay.normalModeSequenceTimeoutMs = config.mode.sequenceTimeoutMs
    keyboardLayoutMonitor.onChange = { [weak self] state in
      self?.overlay.keyboardLayout = state.reference.table
    }
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
    // Once at launch; afterwards the tap and hint activations refresh it.
    noteSecureInput(IsSecureEventInputEnabled())
    overlay.statusBarActionHandler = { [weak self] name in
      self?.performStatusBarClickAction(named: name)
    }
    configureTerminalPopupInput()
    statusItemController.aboutVisibilityDidChange = { [weak self] visible in
      self?.aboutWindowVisibilityDidChange(visible)
    }

    urlHandler = URLEventHandler(
      handler: { [weak self] cmd in Trace.ensure(.cli) { self?.handleURLCommand(cmd) ?? false } },
      rejected: { [weak self] command in self?.warnUnsupportedCommand(command) },
      queries: URLEventHandler.QueryAnswers(
        status: { [weak self] in self?.statusReport().data ?? Data("{}".utf8) },
        doctor: { [weak self] reply in
          guard let self else { return reply(Data("{}".utf8)) }
          self.runDoctor { reply($0.data) }
        }))
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
    configureDebugServer(for: config)
    checkAccessibilityAtLaunch()
    installDismissObservers()
    reconcileClipboardMonitor()
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
    case .mouseGrid(let request):
      activateMouseGrid(request, contextOverride: nil)
    case .mouseRepeat:
      performMouseRepeat()
    case .mousePointer:
      enterPointerMode()
    case .mouseButton(let request):
      performMouseButton(request)
    case .focusInput:
      focusTextInputInNormalMode(index: 1)
    case .scrollTarget:
      activateScrollTargetHints()
    case .mouseDock:
      activateDockHints()
    case .mouseMenuBar:
      activateMenuBarHints()
    case .mouseNotifications:
      activateNotificationHints()
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
      shownConfigError = nil
      overlay.displayAlert(
        alert.message,
        duration: alert.duration,
        style: .from(alert.style))
    case .dismissAlert:
      shownConfigError = nil
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

  /// An unknown or unsupported command does nothing visible: a typo on the
  /// command line or a key with no handler in this app is not an error worth
  /// a toast. The log keeps the diagnostic, and the CLI still gets its
  /// rejection reply.
  func warnUnsupportedCommand(_ command: String) {
    FlashLog.warn(URLEventHandler.rejectionMessage(command), source: "core:Command")
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
        // Move the stroke on the activation itself rather than waiting for the
        // new app's first AX geometry notification. `app` is authoritative
        // here; the workspace's frontmost pointer is not yet. The recovery
        // ticks then absorb an app that reports its window geometry late.
        self.updateActiveWindowBorder(reason: "app_activated", activated: app)
        self.scheduleActiveWindowBorderReconciliation(
          delaysMs: Self.activeWindowBorderRecoveryDelaysMs, reason: "app_activated")
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
      self.overlay.reassertStatusBar(reason: "space_changed")
      self.scheduleActiveWindowBorderReconciliation(
        delaysMs: [0] + Self.activeWindowBorderRecoveryDelaysMs, reason: "space_changed")
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
      self.registry.scheduleRunningApplicationsRefresh()
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
      self.registry.scheduleRunningApplicationsRefresh()
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.windowLayoutManager.appDidTerminate(pid: app.processIdentifier)
        self.forgetActiveWindowBorderFrames(for: app.processIdentifier)
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
      self.overlay.reassertStatusBar(reason: "session_active")
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
      self?.overlay.reassertStatusBar(reason: "screens_wake")
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
      self?.overlay.reassertStatusBar(reason: "system_wake")
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
        statusBarMonitor: self.config.statusBar.monitor,
        beforeRecoveryPass: { [weak self] in self?.overlay.settleNativeMenuBarHeights() },
        afterRecoveryPass: { [weak self] _ in self?.windowLayoutRecovered() })
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
    // This runs inside the synchronous tap callback. Settle only what this
    // keystroke's swallow decision reads — the observed app and its effective
    // mappings — and let the rest of the focus change (plugin events,
    // running-app snapshots, activation history) follow on the next turn.
    let pid = front.processIdentifier
    observedFocusedAppPID = pid
    refreshEffectiveMappings(for: front.bundleIdentifier)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.observedFocusedAppPID == pid else { return }
      self.applyFocusedApplicationChange(front, reason: "key_down", emitFocusEvent: true)
    }
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
      overlay.dismissEphemeralStatusBarPopup(reason: "focus_changed")
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
    registry.scheduleRunningApplicationsRefresh()
    refreshEffectiveMappings(for: app.bundleIdentifier)
  }

  /// Run the in-process pasteboard watcher only while a plugin subscribes to
  /// `clipboard.changed`. macOS publishes no pasteboard notification, so this
  /// is the one unavoidable poll on that path — and with no subscriber there
  /// is nothing to poll for. Owning the watch here keeps plugins free of
  /// polling; the clipboard plugin just subscribes to the event.
  func reconcileClipboardMonitor() {
    let wanted = pluginManager.hasListener(for: "core:clipboard.changed")
    guard wanted != (clipboardMonitor != nil) else { return }
    guard wanted else {
      clipboardMonitor?.stop()
      clipboardMonitor = nil
      FlashLog.debug("[clipboard] watcher stopped: no subscriber")
      return
    }
    FlashLog.debug("[clipboard] watcher started")
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

  /// Whether the keyboard tap swallows a `keyDown`: the pure
  /// `KeyboardCaptureTap.decide`, then only the effects that decision needs.
  /// Runs on the main thread inside the synchronous tap callback on every
  /// keystroke, so nothing here resolves the keyboard layout or touches
  /// AppKit. NORMAL is hermetic: `normalModeMappings` carries the same
  /// compiled set the Carbon registry does, and the session tap swallows the
  /// event before Carbon dispatch, so there's no double-fire.
  private func keyboardTapShouldSwallow(_ event: CGEvent) -> Bool {
    let flags = event.flags
    let decision = KeyboardCaptureTap.decide(
      isTerminal: modeStore.mode.isTerminal,
      flashMode: flashMode,
      inputMode: overlay.inputMode,
      aboutWindowVisible: aboutWindowVisible,
      aboutWindowOwnsKeyboard: Self.aboutWindowShouldOwnNativeKeyboard(
        visible: aboutWindowVisible,
        hasTransientInput: hintSession.isActive,
        activationInFlight: activationInFlight),
      nativeSurfaceSuspended: nativeSurfaceSuspended,
      isModifiedChord: flags.contains(.maskCommand) || flags.contains(.maskControl)
        || flags.contains(.maskAlternate),
      isBareEscape: event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
        && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
      ephemeralPopupShown: overlay.statusPopupController.presentation.ephemeralName != nil)
    switch decision {
    case .pass:
      return false
    case .swallow:
      return !tapReadsSecureInput()
    case .swallowIfInsertChordIsMapped:
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      reconcileFrontmostApplication(
        forKeyTargetingPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
      guard mappings.hasMapping(virtualKey: keyCode, cgFlags: flags) else { return false }
      return !tapReadsSecureInput()
    case .closeEphemeralPopup:
      guard !tapReadsSecureInput() else { return false }
      tapEscapeClosedPopup = true
      // Out of the synchronous tap callback: hiding a panel is AppKit work.
      DispatchQueue.main.async { [weak self] in
        self?.overlay.dismissEphemeralStatusBarPopup(reason: "escape")
      }
      return true
    case .swallowIfNativeSurfaceKeyIsMapped:
      guard !tapReadsSecureInput() else { return false }
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      return keyboardTapHasActiveMapping(keyCode: keyCode, flags: flags)
    }
  }

  /// The swallow decision's secure-input read. Every swallow yields to a
  /// focused password field; a change it sees is published on the next
  /// turn, outside the synchronous tap callback.
  private func tapReadsSecureInput() -> Bool {
    let enabled = IsSecureEventInputEnabled()
    if enabled != secureInputObserved {
      DispatchQueue.main.async { [weak self] in self?.noteSecureInput(enabled) }
    }
    return enabled
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
  /// interpreter.
  func routeTapCapturedKey(_ event: NSEvent) {
    MainThreadWatchdog.note("tap_key")
    if tapEscapeClosedPopup {
      tapEscapeClosedPopup = false
      return
    }
    Trace.begin(.key, triggeredAt: event.timestamp) { routeTracedKey(event) }
  }

  private func routeTracedKey(_ event: NSEvent) {
    // HID timestamp → this main-thread turn: the tap-side latency budget.
    FlashLog.debug(
      "[latency] tap_to_route ms="
        + String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000))
    switch overlay.inputMode {
    case .passive:
      // A chord the tap swallowed in INSERT is an active mapping (see
      // `keyboardTapShouldSwallow`); fire it through the mapping matcher — the
      // same dispatch the Carbon hotkey used, minus the Carbon delivery latency.
      _ = mappings.handle(event: event)
      return
    case .normal:
      let strict = event.modifierFlags.intersection([.command, .control, .option])
      if !strict.isEmpty, mappings.handle(event: event) { return }
    case .hints, .commandLine:
      break
    }
    overlay.handleTapCapturedKey(event)
  }

  func emitRunningApplicationsChanged(reason: String) {
    pluginManager.emitRunningApplicationsChanged(
      reason: reason, snapshot: Self.runningApplicationsSnapshot)
  }

  /// Thread-safe: `NSRunningApplication` properties read atomically.
  static func runningApplicationsSnapshot() -> [[String: Any]] {
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
    releaseHeldMouseButton(reason: "quit")
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
    statusBarController?.stopAndWait()
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

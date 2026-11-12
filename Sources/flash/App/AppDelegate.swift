import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

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

  var config = Config.default {
    // What the inspector derived from the previous configuration.
    didSet { inspectorConfigCache = nil }
  }
  /// The inspector snapshot's configuration-only parts, built once per
  /// `config` (`inspectorConfigSnapshot()`).
  var inspectorConfigCache: InspectorConfigSnapshot?
  /// When this resident started; the inspector derives uptime from it.
  let runtimeStartedAt = Date()
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
  /// The help server's access token (`HelpAccess`): the private file's, or a
  /// fresh in-memory one inside the test runner or when the file cannot be
  /// written (the page Flash opens then still works until Flash restarts).
  lazy var helpAccessToken: String = {
    guard NSClassFromString("XCTestCase") == nil else { return HelpAccess.newToken() }
    do {
      return try HelpAccess.loadOrCreate()
    } catch {
      FlashLog.error("[debug] help_token_unavailable error=\(error)")
      return HelpAccess.newToken()
    }
  }()
  /// Received OpenTelemetry data; empty while the receiver is off.
  let telemetryStore = TelemetryStore()
  /// `[telemetry.receiver]` and `[telemetry.exporter]`, when enabled; see
  /// `configureTelemetry`.
  var telemetryReceiver: OTLPReceiver?
  var telemetryExporter: TelemetryExporter?
  var telemetryLogSink: UUID?
  let telemetryStatePush = TelemetryStatePush()
  /// The notifications only the inspector needs; see `attachDebugServer`.
  var inspectorChangeObservers: InspectorChangeObservers?
  var overlay: OverlayPanel!
  /// Pushes the system appearance to the overlay for `[overlay.dark]`.
  var appearanceObserver: AppearanceObserver?
  var statusBarController: FlashStatusBarController?
  /// Samples `flash.top_cpu`, `flash.top_mem` and `flash.focused_app_details`
  /// while the status controller reports a surface showing one of them.
  lazy var processStatusSampler = ProcessStatusSampler(publish: { [weak self] values in
    DispatchQueue.main.async { self?.statusBarController?.updateProcessValues(values) }
  })
  /// Desktop widget windows; the status controller evaluates their lines.
  var widgetController: WidgetController?
  /// Every `[monitors.<name>]` as the status controller last evaluated it:
  /// the inspector's `monitors`.
  var monitorSnapshots: [MonitorSnapshot] = []
  /// The enabled `[monitors]` that watch host events, from the config.
  var eventMonitors: [String: EventMonitorSpec] = [:]
  /// The monitors' `run`s: one at a time per monitor, steps in order,
  /// bounded and reported; see `MonitorRunner`.
  lazy var monitorRunner: MonitorRunner = {
    let runner = MonitorRunner(store: MonitorRunLedger.live()) {
      [weak self] step, extra, timeout, completion in
      guard let self else {
        completion(.commandFailed, "")
        return nil
      }
      return self.performMonitorStep(
        step, environment: extra, timeout: timeout, completion: completion)
    }
    runner.didChange = { [weak self] in self?.debugStateDidChange() }
    runner.didFail = { [weak self] name, record in self?.monitorRunFailed(name, record) }
    return runner
  }()
  /// `[startup] run`, once at launch and on `startup run`; see
  /// `StartupRunner`.
  lazy var startupRunner = makeStartupRunner()
  let systemEventObservers = SystemEventObservers()
  /// `.` and the macro registers (`MacroCommands`).
  var macros = MacroState()
  /// A monitor alert held while a confirmation owns the centred alert; shown
  /// when the session ends (`clearHintSessionState`).
  var pendingMonitorAlert: StatusAlert?
  let mainRunLoopStallObserver = MainRunLoopStallObserver()
  var terminalInputMappings: TerminalInputMappingHandler<StatusTerminalInputOrigin>?
  /// The resident's socket (`IPCServer`): nil until launch reaches it, or
  /// when it could not listen.
  var ipcServer: IPCServer?
  /// Which socket clients subscribe to which host events.
  let ipcEvents = IPCEventHub()
  var configSources: [DispatchSourceFileSystemObject] = []
  /// Trailing-edge coalescer for config file events (one reload per burst).
  let configReload = PollDeadline("core:config_reload", priority: .normal, on: .main)
  /// Bytes of the config file at the last applied reload; an event that
  /// leaves them unchanged (editor temp/rename dance, `touch`) is a no-op.
  var lastAppliedConfigFileContents: Data?
  var autoLaunchReconciled = false
  let mappings = MappingsCoordinator()
  let windowLayoutManager = WindowLayoutManager()
  /// `window switch`'s prepared list: window recency and every app's
  /// windows, read on the navigation build queue.
  lazy var windowSwitcherCatalog = WindowSwitcherCatalog(
    queue: windowLayoutManager.navigationBuildQueue)
  /// Bumped by every switcher opened and every window it chose, so only the
  /// latest choice activates its app.
  var windowSwitcherFocusGeneration: UInt64 = 0
  /// Per-focused-app effective mapping tables (config + applicable plugin
  /// mappings), keyed by bundle id ("" for none/unknown). Cleared on config
  /// reload and when a plugin's mappings change.
  var effectiveMappingCache: [String: Config.Mode] = [:]
  /// The effective mode last handed to `MappingsCoordinator`, so a focus
  /// change only re-registers Carbon hotkeys when the chord set changed.
  var lastAppliedMappingMode: Config.Mode?
  /// The selector cache key `lastAppliedMappingMode` was resolved for.
  var lastAppliedMappingKey: String?
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
  /// The focused window's text for `mouse bigram`. Nil until the first
  /// activation; cleared by generation, not by dropping the object, so a walk
  /// already on `axQueue` cannot present after Escape.
  var bigramSearch: BigramSearch?
  var hintSession = HintSession() {
    didSet {
      guard let overlay else { return }
      overlay.hintKeyRoute = hintSession.keyRoute
      overlay.hintSessionCapture = hintSession.capture
      if debugServer != nil, !hintSession.showsSameInspectorState(as: oldValue) {
        debugStateDidChange()
      }
      if oldValue.isActive != hintSession.isActive {
        refreshOverlayInputRouting()
        updateActiveWindowBorder(
          reason: hintSession.isActive ? "hint_session_started" : "hint_session_ended")
      }
    }
  }
  /// Where the pointer last left each display through `mouse screens`, for
  /// `--to=last`. Main thread only.
  var screenPointerMemory = ScreenPointerMemory()
  /// Recent hint activations per app, for `flash resident status` and `flash resident doctor`.
  /// Main thread only; recorded where `[latency]` lines are logged.
  var hintActivationStats = HintActivationStats()
  /// The single source of truth for the app's mode. Every UI-facing fact
  /// (overlay input routing, status bar, badge, capture, mapping scope) is a
  /// projection of `modeStore.mode`; transitions go through `dispatchMode`.
  let modeStore = ModeStore()
  /// The coarse insert/normal axis, projected from the unified mode.
  var flashMode: FlashMode { modeStore.mode.flashMode }
  /// Advanced mode (the normal/insert system) is configured — true unless the
  /// mode is `.disabled`, i.e. the user has an all-mode `mode leave` or `mode normal` binding.
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
  /// Presses the menu items a plugin's `bindings` name (`{"menu": [...]}`).
  var menuPathPresser: MenuPathPresser = AXMenuPathPresser()
  let finder = CandidateFinderSession()
  /// Made on main (at launch, by `reconcileClipboardMonitor`); its listing
  /// feeds the flashlight's clipboard rows from the store's queue.
  lazy var clipboardHistoryStore: ClipboardHistoryStore = {
    let flashlight = clipboardFlashlight
    return ClipboardHistoryStore(
      capacity: config.clipboard.historySize,
      didList: { listing in flashlight.update(listing) },
      didChange: { [weak self] in self?.refreshClipboardDashboardCache() })
  }()
  /// The flashlight's `@clipboard` rows: history from the store, named
  /// registers from `registers`.
  lazy var clipboardFlashlight: ClipboardFlashlight = {
    let flashlight = ClipboardFlashlight { [weak self] in self?.registers.namedSnapshot() ?? [] }
    flashlight.onChange = { [weak self] in
      self?.refreshLiveCandidates(sourceID: ClipboardFlashlight.sourceID)
    }
    return flashlight
  }()
  /// First clipboard history page mirrored for the inspector's Clipboard tab.
  var clipboardEntries: [ClipboardModalEntry] = [] {
    didSet { debugStateDidChange() }
  }
  var clipboardNextOffset: Int?
  var clipboardTotal = 0
  /// MIME types for image entries served to the inspector, including pages
  /// fetched after the first one.
  var clipboardImageMimes = ClipboardImageCache()
  let pluginStateRefresh = PollDeadline("core:plugin_state_refresh", priority: .normal, on: .main)
  var commandLineCompletionPrefix: String = ""
  var commandLineCompletionMatches: [CommandLineCompletionMatch] = []
  /// The highlighted row; Enter applies a `chosen` one rather than
  /// resolving the text. See `CommandLineCompletionSelection`.
  var commandLineCompletionSelection = CommandLineCompletionSelection.none
  var commandLineCompletionQuery: String = ""
  /// Session-local immutable completion catalog. Plugin registrations and help
  /// topics do not change while one command field is open, so rebuilding these
  /// collections on every character only adds input latency.
  var commandLineCompletionInventory: NormalModeDispatcher.CommandLineInventory?
  /// Every page path and alias of the bundled manual, read once at launch:
  /// `:help` completes them and plugin topics cannot take them.
  var manualTopicNames: [String] = []
  /// Past executed command-line inputs and the recall in progress. up/down
  /// (and ctrl+n/p, which route to the same handler) recall them when no
  /// candidate or completion list is active — see `recallCommandLineHistory`.
  /// Loaded from `commandHistoryStore` at startup so recall survives
  /// restarts/reinstalls.
  var commandLineHistory = CommandLineHistory()
  /// On-disk persistence for `commandLineHistory`.
  var commandHistoryStore: CommandHistoryStore?
  var selectedInitialMode = false
  /// The last click Flash committed (hints, grid, or multi session), replayed
  /// by `mouse repeat`. Deliberately outside `hintSession`: it must survive
  /// the session reset so a repeat works after the overlay is gone.
  struct LastCommittedClick {
    var point: CGPoint
    var action: JumpAction
    var modifiers: ClickModifiers
    var pid: pid_t?
  }
  var lastCommittedClick: LastCommittedClick?
  /// `mouse position`'s saved pointer positions.
  var positionHistory = PositionHistory()
  var movementCurrent: MovementEntry?
  var movementBackStack: [MovementEntry] = []
  var movementForwardStack: [MovementEntry] = []
  var movementNavigationTargetKey: String?
  var movementCatalogSnapshot: (pid: pid_t, keys: Set<String>)?
  var ambientLocationRecordToken: UInt64 = 0
  /// The pending ambient-location record or its retry; a newer focus
  /// replaces it.
  let ambientLocationRecord = PollDeadline(
    "core:ambient_location", priority: .normal, on: .main)
  var movementLocationResolutionGeneration: UInt64 = 0
  var sourceItemResolutionGeneration: UInt64 = 0
  /// The app MRU behind `app next` / `app previous`; see `AppNavigationHistory`.
  var appNavigation = AppNavigationHistory()
  var observedFocusedAppPID: pid_t?
  /// The last app plugins heard focus move to; see `FocusEmissionGate`.
  var focusEmissionGate = FocusEmissionGate()
  var lastFocusedApplicationPID: pid_t? {
    observedFocusedAppPID.flatMap { $0 == getpid() ? nil : $0 }
  }
  var workspaceTokens: [NSObjectProtocol] = []
  var localNotificationTokens: [NSObjectProtocol] = []
  var resignKeyToken: NSObjectProtocol?
  var normalModeRecaptureToken: UInt64 = 0
  /// Consolidated recapture-suppression windows. The named accessors below
  /// forward to it so existing call sites and tests keep their field names
  /// while the storage + predicate live in one tested value.
  var recaptureSuppression = RecaptureSuppression()
  var menuBarInteractionRecaptureSuppressedUntil: Date? {
    get { recaptureSuppression.menuBarUntil }
    set { recaptureSuppression.menuBarUntil = newValue }
  }
  var contextMenuInteractionRecaptureSuppressedUntil: Date? {
    get { recaptureSuppression.contextMenuUntil }
    set { recaptureSuppression.contextMenuUntil = newValue }
  }
  /// Whether a native surface (context menu / OS popup) owns the keyboard.
  /// The sole non-base-mode input to the capture projection — begun by
  /// `suspendNormalCaptureForNativeSurface`, ended by the surface's close
  /// notification, an explicit mode entry, another app coming forward, or a
  /// recapture after the bounded window for a surface Flash never saw open.
  /// Keeps `overlay.inputMode` and the badge's capture flag from drifting
  /// away from the mode.
  var nativeSurfaceOwnership = NativeSurfaceOwnership() {
    didSet {
      if oldValue.isOwned != nativeSurfaceOwnership.isOwned { refreshOverlayInputRouting() }
    }
  }
  var nativeSurfaceSuspended: Bool { nativeSurfaceOwnership.isOwned }
  var aboutWindowVisible = false {
    didSet { if oldValue != aboutWindowVisible { refreshOverlayInputRouting() } }
  }
  var normalModePendingCommandToken: UInt64 = 0
  /// Where the focus sits in the focused app, for `move` (`FocusRegion`),
  /// re-read after each focus change.
  lazy var focusRegionTracker = makeFocusRegionTracker()
  /// The field NORMAL acts on, once engaged (`TextScope`); changed only
  /// through `updateTextScope`.
  var textScope = TextScope()
  /// The last `f` `F` `t` `T` search, which `;` and `,` repeat.
  var lastCharacterSearch: TextCharacterSearch?
  /// VISUAL's selection while VISUAL is on (`VisualSession`).
  var visualSession: VisualSession?
  /// The selection VISUAL last ended with, which `gv` selects again
  /// (`mode visual --reselect`).
  var lastVisualSession: VisualSession?
  /// VISUAL's steps waiting their turn (`runVisualStep`).
  var visualSteps: [(@escaping () -> Void) -> Void] = []
  var visualStepRunning = false
  /// The which-key palette's pause after a NORMAL prefix. `.high`: it is
  /// what the user looks at next. Armed only while a prefix is pending.
  lazy var whichKeyDeadline = PollDeadline("core:which-key", priority: .high, on: .main)
  /// Whether the which-key palette is drawn.
  var whichKeyShown = false
  /// The next read of a Mission Control view the Dock is still building.
  /// `.high`: the user is waiting on its labels. Armed only while an
  /// activation over Mission Control or App Exposé waits on the tree.
  lazy var missionControlReadyDeadline = PollDeadline(
    "core:mission_control_ready", priority: .high, on: .main)
  /// A click chain's walk after its app reported a change. `.high`: the
  /// labels on screen follow it. Armed only while a `--multi` chain waits
  /// for its next pick (`ClickChain.refreshes`).
  lazy var clickChainRefreshDeadline = PollDeadline(
    "core:click_chain_refresh", priority: .high, on: .main)
  /// Numbers each chain refresh; a session change, a pick or a newer refresh
  /// moves it, so an old walk's result is dropped.
  var clickChainRefreshGeneration: UInt64 = 0
  /// A change arrived while a label was half typed: refresh once the prefix
  /// is empty again.
  var clickChainRefreshPending = false
  /// Numbers each yank's pasteboard wait on the shared clock.
  var pasteboardWaitSerial: UInt64 = 0
  /// Numbers each clipboard loan's give-back deadline (`borrowPasteboard`).
  var pasteboardLoanSerial: UInt64 = 0
  var clipboardMonitor: ClipboardMonitor?
  var powerSourceMonitor: PowerSourceMonitor?
  /// `volume_*`, `audio_*` and `media status`; see `performMediaCommand`.
  let mediaController = MediaController()
  /// `caffeinate_*`, made by the first one; see `performCaffeinate`.
  var caffeinateController: CaffeinateController?
  /// `desktop`, `missioncontrol`, `appwindows`, `launchpad`,
  /// `notificationcenter` and `controlcenter`; see `performSystemSurface`.
  /// Lazy, so a delegate that never launches (a test) observes no Dock.
  /// The Dock's view it reports lands in `dockViewChanged`.
  lazy var systemSurfaces = SystemSurfaceController(dockViewChanged: { [weak self] view in
    self?.dockViewChanged(view)
  })
  /// The Dock's view as the Dock last reported it (nil: unknown); see
  /// `missionControlView`. Main-thread only.
  var observedDockView: DockView?
  /// `notify send` and monitors with `notify = true`; nil in the test runner,
  /// which has no notification center. Lazy: authorization waits for a post.
  lazy var notifications = NotificationController.live()
  /// The tiling workspaces as last published: what `core:workspace.changed`
  /// compares against.
  var lastTilingStatus: TilingStatus?
  /// `[app] updates` and the `updates` commands; see `reconcileUpdates`.
  /// Nil in the test runner, so no test reaches GitHub or replaces a bundle.
  lazy var updates: UpdateController? =
    NSClassFromString("XCTestCase") == nil ? UpdateController.live() : nil
  var updateMode: UpdateMode = .install
  var updatesSettled = false
  var updateCheckArmed = false
  /// The screen-lock and display-sleep observers armed while an update
  /// waits that may install itself.
  var updateApplyTokens: [(NotificationCenter, NSObjectProtocol)] = []
  /// `@notes`, `@reminders`, `@contacts` and the
  /// `<catalog> open` / `<catalog> refresh` commands; see `AppleCatalogs`.
  let appleCatalogs = AppleCatalogs(readers: AppleCatalogReaders.live())
  /// `#{flash.calendar.next…}` and the `calendar` commands; see
  /// `CalendarEvents`. Lazy, so a delegate that never launches (a test)
  /// never reads the calendar's authorization.
  lazy var calendarEvents = CalendarEvents(publish: { [weak self] agenda in
    DispatchQueue.main.async { self?.statusBarController?.updateCalendarAgenda(agenda) }
  })
  /// The 36 app marks behind `mark set` and `mark jump`; see
  /// `performMarkCommand`. Lazy, so a delegate that never launches (a test)
  /// never reads or migrates the file.
  lazy var markStore = MarkStore()
  /// `core:network.changed` and `core:volumes.changed`, each observed only
  /// while a plugin listens; see `reconcileHostEventSources`.
  lazy var hostEventSources = HostEventSources([
    HostEvent.networkChanged.rawValue: { [weak self] in
      NetworkChangeMonitor { self?.emitSignal(.networkChanged) }
    },
    HostEvent.volumesChanged.rawValue: { [weak self] in
      VolumeChangeMonitor { self?.emitSignal(.volumesChanged) }
    },
    // Keyed by the attach event, it serves core:usb.detached's listeners too
    // (`reconcileHostEventSources`).
    HostEvent.usbAttached.rawValue: { [weak self] in
      USBDeviceMonitor { event, payload in
        self?.emitHostEvent(PluginEvent(event, payload: payload))
      }
    },
    // Keyed by the idle event, it serves core:user.active's listeners too
    // (`reconcileHostEventSources`).
    HostEvent.userIdle.rawValue: { [weak self] in
      UserIdleMonitor(
        thresholds: { self?.userIdleThresholds() ?? [] },
        announce: { self?.announceUserIdle($0) })
    },
    HostEvent.clockMinute.rawValue: { [weak self] in
      ClockMinuteMonitor(
        wants: { self?.clockWants() ?? .init() },
        announce: { self?.announceClockMinute($0) })
    },
  ])
  /// Captures NORMAL / hints keystrokes without taking key-window focus. nil
  /// (no grant) falls back to the legacy key-window capture in
  /// `captureKeyboardInput`.
  var keyboardCaptureTap: KeyboardCaptureTap? {
    didSet { debugStateDidChange() }
  }
  /// See `noteSecureInput`.
  var secureInputObserved = false
  let secureInputFixer = SecureInputFixer()
  var activeWindowBorderReconciliationGeneration: UInt64 = 0
  var activeWindowBorderUpdateGeneration: UInt64 = 0
  /// The authoritative front-window read queued for the next main turn.
  var activeWindowBorderPendingRead: ActiveWindowBorderRead?
  /// The window-list read behind `performActiveWindowBorderRead`, on main
  /// (see `scheduleActiveWindowBorderRead`); tests substitute a frame.
  var activeWindowBorderFrameReader: (pid_t) -> CGRect? = {
    AppMonitor.topApplicationWindowFrame(for: $0, primaryH: ScreenSpace.primaryHeight)
  }
  /// Last frame observed for each app's front window, fed by the AX geometry
  /// notifications Flash already subscribes to, so an app switch paints the
  /// right rectangle on the activation itself and the settle pass 80 ms
  /// later, after the activation animation, corrects it.
  var activeWindowBorderFrameCache: [pid_t: CGRect] = [:]
  /// Bumped by every event that can move, raise or replace an app's front
  /// window: a border-relevant AX notification, an activation, a quit, a
  /// Space or display change.
  var activeWindowBorderEventEpoch: UInt64 = 0
  /// The epoch each app's cached frame was read at: while no event has
  /// followed, the cache is the window list's answer and a mode change
  /// does not ask again.
  var activeWindowBorderReadEpochs: [pid_t: UInt64] = [:]
  var activeWindowBorderSessionSuspensions: Set<ActiveWindowBorderSessionSuspension> = []
  /// The latest `input focus` request; an older one still queued is dropped.
  var focusTextInputRequest: UInt64 = 0
  var activationLifecycle = ActivationLifecycle<HintActivationRequest>() {
    didSet {
      guard oldValue.inFlight != activationLifecycle.inFlight else { return }
      refreshOverlayInputRouting()
      debugStateDidChange()
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
  /// SIGTERM (the installer's `pkill`) runs the normal quit, so owned state
  /// such as a lingering Gecko accessibility mode is restored on the way out.
  private var terminationSignal: DispatchSourceSignal?
  /// Keeps App Nap off for the resident's life (`ResidentActivity`).
  private var residentActivity: NSObjectProtocol?
  /// Launched without Accessibility and still waiting for the grant; see
  /// `checkAccessibilityAtLaunch`.
  var awaitingAccessibilityGrant = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // First, so the cached primary-screen height refreshes before any other
    // screen-parameter observer reads it.
    ScreenSpace.startObserving()
    // Before any AX work: every element without a timeout of its own is
    // bounded from here on.
    AXApp.configureProcessMessagingTimeout()
    mainRunLoopStallObserver.start()
    residentActivity = ResidentActivity.begin()
    // Hint labels hide the pointer while another app stays frontmost.
    let backgroundCursor = BackgroundCursor.enable()
    FlashLog.debug("[overlay] background_cursor enabled=\(backgroundCursor)")
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler { NSApp.terminate(nil) }
    termination.resume()
    terminationSignal = termination
    // Resolve the login-shell environment once, off the main thread, so every
    // `script:`/`command:` task, mapping, and plugin inherits the same PATH
    // and tooling the user has in their terminal. A GUI launch from Finder/
    // launchd would otherwise hand children a bare environment. Until this
    // lands the seeded cache (process env + PATH fallback) keeps commands
    // usable, so the spawn need not block startup. The launch reload below
    // does not ask again: this is the one launch refresh.
    FlashProcessEnvironment.shared.refresh { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.reloadTerminalPopupConfiguration()
        self.overlay.statusTerminals.retryFailedLaunches()
      }
    }
    // First run: give the user a working shortcut before the first load.
    StarterConfig.seedIfNeeded(environment: ProcessInfo.processInfo.environment)
    manualTopicNames = HelpDocs.manualNames(root: DebugServer.bundledDocs)
    config = ConfigLoader.load()
    FlashTunables.apply(config)
    frecencyStore = FrecencyStore(
      configuration: FrecencyStore.Configuration(
        halfLifeDays: config.flashlight.frecencyHalfLifeDays,
        maxBoost: config.flashlight.frecencyMaxBoost))
    commandHistoryStore = CommandHistoryStore()
    commandLineHistory = CommandLineHistory(entries: commandHistoryStore?.load() ?? [])
    let manager = pluginManager
    registry = SourceRegistry(
      flashlight: config.flashlight,
      pluginSourcesProvider: { manager.sources },
      appleCatalogs: appleCatalogs,
      clipboard: clipboardFlashlight,
      windows: WindowListSource(
        rows: { [weak self] in self?.windowListRows() ?? ([], nil) },
        focus: { [weak self] key in self?.focusWindowSwitcherChoice(key) }),
      perform: { [weak self] command in self?.performMappedCommand(command) })
    monitor = AppMonitor(registry: registry, config: config)
    // A held mouse button enters HOLD:
    // whichever path presses or releases it, the mode follows the hold, from
    // NORMAL, a layer or INSERT (an all-mode `mode hold` chord).
    ActionDispatcher.heldButtonDidChange = { [weak self] held in
      guard let self else { return }
      let mode = self.modeStore.mode
      if let held, mode == .normal || mode.isInsert || mode.isLayer {
        self.dispatchMode(.buttonHeld(held.purpose))
      } else if held == nil, self.modeStore.mode.buttonHold != nil {
        self.dispatchMode(.buttonReleased)
      }
    }
    // A native menu's own open and close are the evidence that decides how
    // long it keeps the keyboard (`NativeSurfaceOwnership`), and the menus
    // they name are what `f` walks while one is open.
    monitor.menuDidChange = { [weak self] pid, opened, menu in
      guard let self else { return }
      if opened {
        self.nativeSurfaceOwnership.menuOpened(pid: pid, menu: menu)
      } else if self.nativeSurfaceOwnership.menuClosed(menu), self.flashMode == .normal {
        self.scheduleNormalModeRecapture()
      }
    }
    // Every observed AX notification reaches plugins exactly once, here.
    monitor.focusedElementDidChange = { [weak self] pid, bundleID, notification in
      if Self.windowSwitcherNotifications.contains(notification) {
        self?.windowSwitcherCatalog.windowsMayHaveChanged(pid: pid)
      }
      guard let self, self.pluginManager.hasListener(for: .axChanged) else {
        return
      }
      self.pluginManager.emit(
        .axChanged(pid: pid, notification: notification, bundleID: bundleID))
    }
    // `move` reads where the focus sits from a cache each focus change
    // refreshes off the main loop.
    monitor.focusedElementMayHaveChanged = { [weak self] pid in
      guard let self else { return }
      // Another app: the engaged field is no longer focused.
      self.updateTextScope { $0.focusMayHaveChanged(pid: pid) }
      self.focusRegionTracker.focusMayHaveChanged(pid: pid)
    }
    // A click chain waiting for its next pick follows its app's changes.
    monitor.uiDidChange = { [weak self] pid in
      self?.clickChainUIDidChange(pid: pid)
    }
    monitor.activeWindowMayHaveChanged = { [weak self] pid, notification, window in
      self?.activeWindowBorderEventEpoch &+= 1
      self?.activeWindowMayHaveChanged(
        pid: pid, notification: notification, observedWindow: window)
    }
    monitor.focusedWindowDidResolve = { [weak self] pid, window in
      // Every app's resolution, background ones included: the switcher
      // promotes only the frontmost app's, and remembers the rest.
      self?.windowSwitcherCatalog.focusResolved(pid: pid, window: window)
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
    // A relaunched Dock is observed again at once; see `SystemSurfaceController`.
    monitor.applicationDidLaunch = { [weak self] app in
      self?.systemSurfaces.applicationLaunched(bundleIdentifier: app.bundleIdentifier)
    }
    monitor.start()
    systemSurfaces.start()
    windowLayoutManager.refreshNavigationCatalog(
      statusBarReservesSpace: statusBarVisible,
      statusBarMonitor: config.statusBar.monitor)
    if let front = NSWorkspace.shared.frontmostApplication,
      front.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      windowSwitcherCatalog.appActivated(pid: front.processIdentifier)
    }
    refreshWindowSwitcherCatalog()
    pluginManager.onStateChanged = { [weak self] in
      self?.pluginStateDidChange()
    }
    pluginManager.onOwnTextEditingAppsChanged = { [weak self] in
      guard let self else { return }
      self.applyTextScopePolicy(self.config.mode, invalidatesPending: true)
    }
    pluginManager.onNormalModeTargetRequested = { [weak self] in
      guard let self,
        let context = self.normalModeDispatchContext()
      else { return nil }
      let window = HintWindowSnapshot.current(
        pid: context.processID, primaryHeight: ScreenSpace.primaryHeight)
      return (
        pid: context.processID, bundleID: context.bundleIdentifier, windowID: window?.number
      )
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
    let launchApplications = Self.runningApplicationsSnapshot()
    pluginManager.cacheRunningApplicationsSnapshot(launchApplications)
    pluginManager.start(config: config)
    appleCatalogs.onChange = { [weak self] catalog in
      self?.refreshLiveCandidates(sourceID: catalog.sourceID)
    }
    appleCatalogs.start(
      runningBundleIDs: Set(launchApplications.compactMap { $0["bundle_id"] as? String }))
    // Made at launch so it loads, and moves the retired plugin's file, on
    // its queue before the first jump.
    _ = markStore

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    applyCaptureSharing(hidden: config.app.hideFromCapture)
    appearanceObserver = AppearanceObserver(NSApplication.shared) { [weak self] dark in
      self?.overlay.darkAppearance = dark
    }
    overlay.debugConfig = config.debug
    overlay.popupStyle = config.popupStyle
    overlay.statusLinkOpener.schemes = Set(config.statusBar.linkSchemes)
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.effectiveMagicModifiers)
    overlay.keyboardNavigation = Alphabet.navigation(layoutName: config.positionLayoutName)
    overlay.normalModeSequenceTimeoutMs = config.mode.sequenceTimeoutMs
    keyboardLayoutMonitor.onChange = { [weak self] state in
      self?.overlay.keyboardLayout = state.reference.table
    }
    // Pay the layer-allocation cost at launch instead of on the first
    // activation. 256 covers the steady state for most apps; further
    // growth uses the regular dequeue/alloc fallback.
    overlay.warmPool(count: 256)
    widgetController = WidgetController(setVisible: { [weak self] name, visible in
      self?.statusBarController?.setWidgetVisible(name: name, visible)
      self?.pluginManager.setWidgetVisible(name: name, visible)
    })
    let processSampler = processStatusSampler
    let calendar = calendarEvents
    calendar.configure(config.calendar)
    statusBarController = FlashStatusBarController(
      overlay: overlay,
      template: config.statusBar.template,
      popupTemplates: config.textPopups,
      sources: config.statusBar.sources,
      terminalPopupNames: config.terminalPopupNames,
      refreshIntervalSeconds: config.statusBar.refreshIntervalSeconds,
      pluginStatusesProvider: { [weak self] in
        self?.pluginManager.statusBarInfos() ?? []
      },
      widgetSink: { [weak self] name, lines in self?.widgetController?.show(name, lines: lines) },
      processValuesObserver: { [weak processSampler] values in processSampler?.observe(values) },
      monitorSink: { [weak self] snapshots in self?.monitorsDidChange(snapshots) },
      monitorAlertSink: { [weak self] alert in self?.presentMonitorAlert(alert) },
      monitorFireSink: { [weak self] fire in self?.monitorDidFire(fire) },
      monitorNotifySink: { [weak self] name, alert in
        self?.notifyMonitor(
          name, title: alert.title, body: alert.value ?? "", error: alert.style == .error)
      },
      monitorTriggerSink: { [weak self] name, level in self?.emitMonitorTriggered(name, level) },
      telemetry: telemetryStore,
      calendarObserver: { [weak calendar] observed in calendar?.observe(observed) })
    wireTelemetryStore()
    statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)
    if let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      processSampler.focusChanged(
        FocusedProcess(pid: front.processIdentifier, bundleID: front.bundleIdentifier ?? ""))
    }
    // Once at launch; afterwards the tap, hint activations and the secure-input
    // poll refresh it. The poll is what notices a hold that starts while the
    // tap is blind.
    noteSecureInput(IsSecureEventInputEnabled())
    secureInputFixer.onFlag = { [weak self] enabled in
      DispatchQueue.main.async { self?.noteSecureInput(enabled) }
    }
    secureInputFixer.start()
    overlay.statusBarActionHandler = { [weak self] name in
      self?.performStatusBarClickAction(named: name)
    }
    overlay.statusBarCycleStepHandler = { [weak self] key, delta in
      self?.statusBarController?.stepCycle(key: key, by: delta)
    }
    configureTerminalPopupInput()
    wireInspectorChangeSources()
    windowLayoutManager.tilingStatusDidChange = { [weak self] status in
      self?.tilingStatusDidChange(status)
    }
    statusItemController.aboutKeyDidChange = { [weak self] in
      guard let self else { return }
      self.refreshOverlayInputRouting()
      // About went behind another app: NORMAL takes that app's keys again.
      if self.aboutWindowVisible, !self.statusItemController.aboutWindowIsKey,
        self.flashMode == .normal
      {
        self.scheduleNormalModeRecapture()
      }
    }
    statusItemController.aboutVisibilityDidChange = { [weak self] visible in
      self?.aboutWindowVisibilityDidChange(visible)
    }

    startIPCServer()
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
      appNavigation = AppNavigationHistory(current: app.processIdentifier)
      observedFocusedAppPID = app.processIdentifier
    }
    watchConfigFile()
    // After the first configuration load, once per launch; a reload never
    // runs the list again.
    runStartupCommandsAtLaunch()
    selectInitialModeIfNeeded()
    configureDebugServer(for: config)
    configureTelemetry(for: config)
    checkAccessibilityAtLaunch()
    installDismissObservers()
    reconcileClipboardMonitor()
    reconcileHostEventSources()
    activateNotificationClicks()
    startPowerSourceMonitor()
    systemEventObservers.start { [weak self] event in
      guard let self, self.hostEventHasSubscriber(event.name) else { return }
      self.emitHostEvent(event)
    }
    emitRunningApplicationsChanged()
  }

  /// Dispatch `cmd`. With a `completion`, it runs once with how the command
  /// ended and any output it produced, which the caller presents; without
  /// one, a plugin's output shows on a banner.
  @discardableResult
  func handleURLCommand(
    _ cmd: URLCommand,
    completion: ((NormalModeCommandOutcome, String?) -> Void)? = nil
  ) -> Bool {
    FlashLog.trace(
      "[url] command=\(cmd.diagnosticDescription) mode=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight) overlay=\(String(describing: overlay?.inputMode))")
    var completesLater = false
    defer { if !completesLater { completion?(.performed, nil) } }
    switch cmd {
    case .mouseTarget(let command):
      activateMouseTarget(command, contextOverride: nil)
    case .mouseBigram(let command):
      activateMouseBigram(command, contextOverride: nil)
    case .mouseTargetScreen(let command):
      activateScreenScopeHints(command)
    case .mouseTargetWords(let command):
      activateWordHints(command, contextOverride: nil)
    case .mouseScreens(let request):
      activateScreens(request)
    case .mouseWarp(let request):
      performMouseWarp(request)
    case .mouseStep(let direction):
      performMouseStep(direction)
    case .mouseNudge(let direction, let distance):
      performMouseNudge(direction, distance: distance)
    case .mouseJump(let jump):
      performMouseJump(jump)
    case .trackpadGesture(let fingers, let motion):
      performGesture(fingers: fingers, motion: motion)
    case .selection(let action, let register):
      performSelection(action, register: register)
    case .mousePosition(let request):
      performMousePosition(request)
    case .mouseGrid(let request):
      activateMouseGrid(request, contextOverride: nil)
    case .mouseRepeat:
      performMouseRepeat()
    case .mousePointer:
      enterPointerMode()
    case .mouseButton(let request):
      performMouseButton(request)
    case .holdMode(let button):
      toggleHoldMode(button)
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
    case .popupRestart(let name):
      restartPopup(named: name)
    case .popupQuit(let name):
      quitPopup(named: name)
    case .insertMode:
      enterInsertMode(.explicitCommand)
    case .commandMode:
      enterCommandLineMode()
    case .terminalMode(let name):
      enterTerminalMode(named: name)
    case .layerMode(let name):
      if let rejection = enterLayer(named: name) {
        completesLater = true
        completion?(.failed, rejection)
      }
    case .scroll, .reload, .undo, .redo, .archive, .resourceNext, .resourcePrevious,
      .tabClose, .find, .findNext, .findPrevious, .appSwitch, .flashlight,
      .enterCommand, .copyURL, .yankSelection, .paste,
      .tabNext, .tabPrev, .tabFirst, .tabLast, .tabSelect,
      .tabMovePrev, .tabMoveNext, .tabReopen,
      .paneNext, .panePrev, .paneSplitVertical, .paneSplitHorizontal, .paneClose,
      .historyBack, .historyForward,
      .movementBack, .movementForward, .appPrev, .appNext,
      .quitApp, .saveAndQuit, .appClose, .tabNew, .save, .print, .documentOpen, .windowNew,
      .windowClose,
      .clipboardCopy, .clipboardPaste, .lookUp, .zoomIn, .zoomOut, .zoomReset,
      .viewSource, .inputMotion, .move, .cursor, .scrollCursor, .visualMode, .visualReselect,
      .documentSaveAs, .documentExportPDF, .documentRevert, .documentDuplicate,
      .documentRename, .documentPageSetup, .appSettings, .selectAll, .appHelp, .appCancel,
      .appStop, .appDownloads, .developerTools, .windowCloseAll, .windowZoom, .urlBookmark,
      .urlEdit, .historyShow, .tabDuplicate, .tabPin, .tabMute, .tabDetach, .appVisibility,
      .menuPress,
      .sendKey, .sendKeys, .systemKey, .functionKey, .arrow, .systemAction, .processKill:
      if let completion {
        completesLater = true
        performMappedCommand(cmd, completion: { completion($0, nil) })
      } else {
        performMappedCommand(cmd)
      }
    case .showAlert(let alert):
      shownConfigError = nil
      overlay.displayAlert(alert.alert)
    case .confirm(let request):
      presentConfirmation(request.prompt, command: request.command)
    case .dismissAlert:
      shownConfigError = nil
      overlay.dismissAlert()
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showMappings:
      showMappings()
    case .showPlugins:
      openDebugDashboard(.plugins(id: nil))
    case .reloadPlugins:
      reloadPlugins()
    case .showLogs:
      openDebugDashboard(.logs)
    case .showCommands:
      openDebugDashboard(.commands)
    case .showMonitors:
      openDebugDashboard(.monitors)
    case .showTelemetry:
      openDebugDashboard(.telemetry)
    case .showAbout:
      statusItemController.showAbout()
    case .dismissHints:
      cancelOverlay()
    case .quit:
      // The caller hears back before the resident goes away.
      completesLater = true
      completion?(.performed, nil)
      DispatchQueue.main.async { NSApp.terminate(nil) }
    case .openApp(let name):
      openSourceItem(matching: name)
    case .clipboardHistory(let action, let id, let offset):
      if action == "show", offset == 0 {
        openClipboardDashboard()
      } else {
        let args = action == "show" ? ["offset=\(offset ?? 0)"] : ["id=\(id ?? "")"]
        completesLater = true
        _ = performClipboardHistoryCommand(subcommand: action, args: args) {
          [weak self] ok, output in
          if ok {
            if action != "show" { self?.refreshClipboardDashboardCache() }
            if let completion {
              completion(.performed, output)
            } else {
              self?.presentPluginResult(output)
            }
          } else {
            if let output {
              self?.displayCommandWarning(output)
            } else {
              self?.warnCommandFailure(cmd.diagnosticDescription)
            }
            completion?(.failed, output)
          }
        }
      }
    case .clipboardRestore(let id, let paste, let plain):
      completesLater = true
      restoreClipboardEntry(id: id, paste: paste, plain: plain) { [weak self] ok in
        if ok {
          completion?(.performed, nil)
        } else {
          self?.warnCommandFailure(cmd.diagnosticDescription)
          completion?(.failed, nil)
        }
      }
    case .pluginCommand(let command, let subcommand, let args):
      completesLater = true
      let dispatched = pluginManager.invoke(
        command: command,
        subcommand: subcommand,
        args: args,
        in: pluginSelectorContext()
      ) { [weak self] ok, pid, stdout, navigationURL in
        guard ok else {
          self?.warnCommandFailure(cmd.diagnosticDescription)
          completion?(.failed, nil)
          return
        }
        self?.activateCommandTarget(pid, navigationURL: navigationURL)
        if let completion {
          completion(.performed, stdout)
        } else {
          self?.presentPluginResult(stdout)
        }
      }
      if !dispatched {
        warnUnsupportedCommand(cmd.diagnosticDescription)
        completion?(.unavailable, nil)
      }
      return dispatched
    case .moveWindow(let params):
      // Use the *non-Flash* frontmost app as the move target. Without
      // this, normal-mode capture (which activates Flash to satisfy the
      // Tahoe key-window rule) makes `frontmostApplication` resolve to
      // Flash itself, and the verb cheerfully maximises the status-bar
      // panel instead of the user's actual window.
      if let targetPID = currentNonFlashProcessID() {
        windowLayoutManager.move(
          params,
          statusBarReservesSpace: statusBarVisible,
          statusBarMonitor: config.statusBar.monitor,
          targetPID: targetPID)
      } else {
        FlashLog.warn("[window] no non-flash frontmost app")
      }
    case .focusWindow(let request):
      if let target = currentNonFlashRunningApplication() {
        focusWindow(request, targetPID: target.processIdentifier)
      }
    case .windowState(let action):
      if let targetPID = currentNonFlashProcessID() {
        windowLayoutManager.setWindowState(action, targetPID: targetPID)
      } else {
        FlashLog.warn("[window] no non-flash frontmost app")
      }
    case .windowSwitch:
      performWindowSwitch()
    case .windowLast:
      performWindowLast()
    case .tile(let command):
      completesLater = true
      windowLayoutManager.performTiling(command) { [weak self] outcome in
        self?.finishTiling(outcome, completion: completion)
      }
    case .workspace(let command):
      completesLater = true
      windowLayoutManager.performWorkspace(command) { [weak self] outcome in
        self?.finishTiling(outcome, completion: completion)
      }
    case .media(let command):
      completesLater = true
      // A caller presents an answer itself: the CLI prints it.
      performMediaCommand(command, presents: completion == nil) { outcome, output in
        completion?(outcome, output)
      }
    case .caffeinate(let request):
      completesLater = true
      performCaffeinate(request, presents: completion == nil) { outcome, output in
        completion?(outcome, output)
      }
    case .systemSurface(let command):
      if let completion {
        completesLater = true
        performSystemSurface(command) { failure in
          completion(failure == nil ? .performed : .failed, failure)
        }
      } else {
        performSystemSurface(command)
      }
    case .statusPush(let push):
      completesLater = true
      // A script pushes on every event, so a wrong name is logged, not alerted;
      // the CLI exits 1 with it.
      pushStatusSource(push) { rejection in
        if let rejection {
          FlashLog.info(
            "[statusbar] push_rejected", fields: ["reason": rejection], source: "core:Command")
          completion?(.failed, rejection)
        } else {
          completion?(.performed, nil)
        }
      }
    case .notify(let notify):
      completesLater = true
      performNotify(notify) { failure in
        completion?(failure == nil ? .performed : .failed, failure)
      }
    case .logWrite(let write):
      performLogWrite(write)
    case .metricRecord(let record):
      performMetricRecord(record)
    case .menuChoose(let file, let prompt):
      completesLater = true
      performMenuChoose(file: file, prompt: prompt) { result in
        switch result {
        case .success(let picked): completion?(.performed, picked)
        case .failure(let failure): completion?(.failed, failure.description)
        }
      }
    case .statusRefresh(let source):
      completesLater = true
      refreshStatusSource(source) { refusal in
        if let refusal {
          FlashLog.warn("[statusbar] refresh refused: \(refusal)", source: "core:Command")
          completion?(.failed, refusal)
        } else {
          completion?(.performed, nil)
        }
      }
    case .updates(let command):
      completesLater = true
      performUpdatesCommand(command) { [weak self] outcome, text in
        if let completion {
          completion(outcome, text)
        } else if let text {
          self?.overlay.displayBanner(text.split(separator: "\n").first.map(String.init) ?? text)
        }
      }
    case .startup(let command):
      completesLater = true
      performStartupCommand(command) { [weak self] outcome, text in
        if let completion {
          completion(outcome, text)
        } else {
          self?.overlay.displayBanner(text.split(separator: "\n").first.map(String.init) ?? text)
        }
      }
    case .appleCatalog(let command):
      performAppleCatalogCommand(command)
    case .calendar(let command):
      completesLater = true
      // A caller presents the output itself: the CLI prints it.
      performCalendarCommand(command, presents: completion == nil) { outcome, output in
        completion?(outcome, output)
      }
    case .marks(let command):
      performMarkCommand(command)
    case .macro(let command):
      completesLater = true
      performMacroCommand(command, repeatCount: 1) { outcome, message in
        completion?(outcome, message)
      }
    case .configReload:
      completesLater = true
      completion?(.performed, reloadConfigNow())
    case .configEdit:
      Self.openConfigurationFile()
    }
    return true
  }

  /// An unknown or unsupported command does nothing visible: a typo on the
  /// command line or a key with no handler in this app is not an error worth
  /// a toast. The log keeps the diagnostic, and the CLI still gets its
  /// rejection reply.
  func warnUnsupportedCommand(_ command: String) {
    FlashLog.info(
      "[command] unsupported", fields: ["command": command], source: "core:Command")
  }

  func warnCommandFailure(_ command: String) {
    displayCommandWarning("Command failed or was not handled: \(command). Check :logs for details.")
  }

  private func presentPluginResult(_ stdout: String?) {
    guard let stdout, !stdout.isEmpty else { return }
    overlay.displayBanner(stdout)
  }

  /// `status set` / `status clear`: `completion` gets nil once the value
  /// landed, or why it could not (no such source).
  func pushStatusSource(_ push: StatusPush, completion: @escaping (String?) -> Void) {
    if let rejection = StatusPush.rejection(
      source: push.source, declared: Set(config.statusBar.sources.keys))
    {
      return completion(rejection)
    }
    guard let controller = statusBarController else { return completion(nil) }
    controller.push(source: push.source, value: push.value) { accepted in
      completion(
        accepted
          ? nil
          : StatusPush.rejection(source: push.source, declared: []))
    }
  }

  func refreshStatusSource(_ source: String, completion: @escaping (String?) -> Void) {
    guard let controller = statusBarController else {
      return completion(
        StatusRefresh.refusal(
          source: source, definition: config.statusBar.sources[source], shown: false))
    }
    controller.refresh(source: source, completion: completion)
  }

  private func displayCommandWarning(_ message: String) {
    FlashLog.warn("[command] failed", fields: ["message": message], source: "core:Command")
    overlay.displayAlert(.message(message, style: .error))
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
      self.activeWindowBorderEventEpoch &+= 1
      // The inspector's `focused_app` follows every activation, Flash's own too.
      self.debugStateDidChange()
      // Ignore Flash itself activating (it shouldn't, but be safe).
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier == Bundle.main.bundleIdentifier
      {
        return
      }
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        self.terminalInputMappings?.flush()
        self.overlay.relinquishShownStatusPopup(reason: "focus_changed")
        let secureUI = Self.activeWindowBorderSecureUISuspendsSession(
          bundleIdentifier: app.bundleIdentifier)
        self.setSessionSuspended(
          secureUI, source: .secureUI, reason: secureUI ? "secure_ui" : "secure_ui_exit")
        self.applyFocusedApplicationChange(app, emitFocusEvent: true)
        self.cancelOverlay(departure: .activated(app.processIdentifier))
        // Move the stroke on the activation itself rather than waiting for the
        // new app's first AX geometry notification. `app` is authoritative
        // here; the workspace's frontmost pointer is not yet. With a cached
        // frame the window list is first read by the 80 ms pass, after the
        // activation animation; the later passes run only while it still
        // disagrees, absorbing an app that reports its geometry late.
        self.updateActiveWindowBorder(
          reason: "app_activated", activated: app, read: .onlyWithoutCache)
        self.scheduleActiveWindowBorderReconciliation(
          delaysMs: Self.activeWindowBorderRecoveryDelaysMs, reason: "app_activated",
          endsWhenSettled: true)
        if self.shouldScheduleNormalModeRecaptureAfterWorkspaceActivation() {
          self.scheduleNormalModeRecapture()
        }
      } else {
        self.statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)
        self.cancelOverlay(departure: .focusLost)
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
      self.activeWindowBorderEventEpoch &+= 1
      self.reconcileFrontmostApplication()
      // Accessibility lists the active Space's windows: read them all again.
      self.refreshWindowSwitcherCatalog()
      // Raising a commit's target can switch Spaces: that is its handoff.
      self.cancelOverlay(departure: .focusLost)
      self.overlay.reassertStatusBar(reason: "space_changed")
      self.scheduleActiveWindowBorderReconciliation(
        delaysMs: [0] + Self.activeWindowBorderRecoveryDelaysMs, reason: "space_changed")
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
      self.windowLayoutManager.refreshNavigationCatalog(
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor)
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        // Its first windows, once the launch settles; later ones arrive with
        // its focus and its AX window events.
        if app.activationPolicy == .regular {
          self.windowSwitcherCatalog.appLaunched(pid: app.processIdentifier)
        }
        self.emitHostEvent(
          PluginEvent(
            .appsLaunched,
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier))
        self.appleCatalogs.appLaunched(bundleID: app.bundleIdentifier)
      }
      self.emitRunningApplicationsChanged()
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
      self.activeWindowBorderEventEpoch &+= 1
      self.registry.scheduleRunningApplicationsRefresh()
      self.windowLayoutManager.refreshNavigationCatalog(
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor)
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        let pid = app.processIdentifier
        self.windowLayoutManager.appDidTerminate(pid: pid)
        self.windowSwitcherCatalog.appTerminated(pid: pid)
        self.pluginManager.appTerminated(pid: pid)
        self.forgetActiveWindowBorderFrames(for: pid)
        // Cmd-Q and a last window that quits the app never pass through
        // `app quit`. Focus the previous app before macOS picks one.
        self.focusAppAfterQuit(of: pid)
        if pid == self.observedFocusedAppPID || self.appNavigation.target != nil {
          self.hideActiveWindowBorder(reason: "app_terminated")
          DispatchQueue.main.async {
            if let aimed = self.appNavigation.target,
              let next = NSRunningApplication(processIdentifier: aimed), !next.isTerminated
            {
              self.applyFocusedApplicationChange(next, emitFocusEvent: true)
            } else {
              self.reconcileFrontmostApplication()
            }
            self.updateActiveWindowBorder(reason: "app_terminated")
            self.scheduleActiveWindowBorderReconciliation(
              delaysMs: Self.activeWindowBorderRecoveryDelaysMs,
              reason: "app_terminated")
          }
        }
        self.emitHostEvent(
          PluginEvent(
            .appsTerminated,
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier))
        self.appleCatalogs.appTerminated(bundleID: app.bundleIdentifier)
      }
      self.emitRunningApplicationsChanged()
    }
    let sessionResigned = nc.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setSessionSuspended(
        true, source: .session, reason: "session_resigned")
    }
    let sessionBecameActive = nc.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.overlay.reassertStatusBar(reason: "session_active")
      self.setSessionSuspended(
        false, source: .session, reason: "session_active")
      // The secure login surface may have activated without a corresponding
      // regular-app activation on the way back. A session switch-in is the
      // authoritative signal that it no longer owns the desktop.
      self.setSessionSuspended(
        false, source: .secureUI, reason: "session_active")
    }
    let screensSlept = nc.addObserver(
      forName: NSWorkspace.screensDidSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setSessionSuspended(
        true, source: .screens, reason: "screens_sleep")
    }
    let screensWoke = nc.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.overlay.reassertStatusBar(reason: "screens_wake")
      self?.setSessionSuspended(
        false, source: .screens, reason: "screens_wake")
    }
    let systemWillSleep = nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setSessionSuspended(
        true, source: .systemSleep, reason: "system_sleep")
    }
    let systemWoke = nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.overlay.reassertStatusBar(reason: "system_wake")
      self?.setSessionSuspended(
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
      self.activeWindowBorderEventEpoch &+= 1
      self.windowLayoutManager.screenParametersDidChange(
        statusBarReservesSpace: self.statusBarVisible,
        statusBarMonitor: self.config.statusBar.monitor,
        beforeRecoveryPass: { [weak self] in self?.overlay.settleNativeMenuBarHeights() },
        afterRecoveryPass: { [weak self] _ in self?.windowLayoutRecovered() })
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(3_100)) { [weak self] in
        guard let self else { return }
        self.windowLayoutManager.refreshNavigationCatalog(
          statusBarReservesSpace: self.statusBarVisible,
          statusBarMonitor: self.config.statusBar.monitor)
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
    let appResigned = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Deactivation can restore a panel that hidesOnDeactivate left visible,
      // and on Tahoe an app switch sometimes never posts didActivateApplication.
      // Order the popup out on the next turn, once that restoration has run,
      // and only when another app actually holds the front.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            != Bundle.main.bundleIdentifier
        else { return }
        self.overlay.relinquishShownStatusPopup(reason: "app_resigned")
      }
    }
    // Flash active in INSERT sends the keys the tap passes to Flash; a
    // surface of its own that needs them keeps it (`IdleActivation`).
    let appActivated = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handBackActivationIfIdle(reason: "became_active")
    }
    localNotificationTokens = [screenParameters, appResigned, appActivated]

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
      self.reconcileFrontmostApplication()
      if !self.hintSession.hints.isEmpty {
        // A key-window session's commit raises its target, which resigns
        // the panel: that is the commit's handoff, not the user leaving.
        self.cancelOverlay(departure: .focusLost)
        return
      }
      if self.overlay.inputMode == .commandLine {
        self.overlay.recoverCommandLineFocusAfterKeyLoss()
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
      self.applyFocusedApplicationChange(front, emitFocusEvent: true)
    }
  }

  func reconcileFrontmostApplication() {
    guard let front = NSWorkspace.shared.frontmostApplication,
      front.bundleIdentifier != Bundle.main.bundleIdentifier,
      !Self.activeWindowBorderSecureUISuspendsSession(bundleIdentifier: front.bundleIdentifier)
    else { return }
    let changed = observedFocusedAppPID != front.processIdentifier
    applyFocusedApplicationChange(front, emitFocusEvent: changed)
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

  func applyFocusedApplicationChange(_ app: NSRunningApplication, emitFocusEvent: Bool) {
    observedFocusedAppPID = app.processIdentifier
    // Another app coming forward ends any native surface of the previous one.
    nativeSurfaceOwnership.end()
    refreshFocusDependentState(for: app)
    debugStateDidChange()
    if emitFocusEvent, focusEmissionGate.shouldEmit(pid: app.processIdentifier) {
      overlay.relinquishShownStatusPopup(reason: "focus_changed")
      processStatusSampler.focusChanged(
        FocusedProcess(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? ""))
      emitHostEvent(
        PluginEvent(
          .focusChanged,
          payload: [
            "bundle_id": app.bundleIdentifier ?? "",
            "localized_name": app.localizedName ?? "",
            "pid": Int(app.processIdentifier),
          ],
          bundleID: app.bundleIdentifier))
      appleCatalogs.focusChanged(bundleID: app.bundleIdentifier)
      emitRunningApplicationsChanged()
      recordAppActivation(app.processIdentifier)
      followFocusWithPointer(pid: app.processIdentifier)
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

  /// macOS publishes no pasteboard notification, so the core history watches
  /// its change count through the one shared poll scheduler.
  /// Every session-suspension signal lands here: the active-window border
  /// hides, and the shared poll clock holds every registration — nothing a
  /// poll produces can be seen while the displays sleep or the session is
  /// locked or switched out. The last release resumes both.
  func setSessionSuspended(
    _ suspended: Bool, source: ActiveWindowBorderSessionSuspension, reason: String
  ) {
    let poll: PollScheduler.Suspension
    switch source {
    case .session: poll = .session
    case .screens: poll = .screens
    case .systemSleep: poll = .systemSleep
    case .secureUI: poll = .secureUI
    }
    PollScheduler.shared.setSuspended(suspended, reason: poll)
    setActiveWindowBorderSessionSuspended(suspended, source: source, reason: reason)
  }

  /// Start or stop each host event monitor as plugins start or stop
  /// listening to its event.
  func reconcileHostEventSources() {
    // One source serves each pair of events.
    let partner: [String: HostEvent] = [
      HostEvent.userIdle.rawValue: .userActive, HostEvent.usbAttached.rawValue: .usbDetached,
    ]
    hostEventSources.reconcile { event in
      hostEventHasSubscriber(event)
        || partner[event].map { hostEventHasSubscriber($0.rawValue) } == true
    }
    (hostEventSources.source(for: HostEvent.userIdle.rawValue) as? UserIdleMonitor)?.refresh()
    (hostEventSources.source(for: HostEvent.clockMinute.rawValue) as? ClockMinuteMonitor)?
      .refresh()
  }

  /// The minutes `core:clock.minute` announces: every one for a listening
  /// plugin, each listening event monitor's `at` times.
  func clockWants() -> ClockWatch.Wants {
    ClockWatch.Wants(
      everyMinute: hostEventHasClientListener(.clockMinute),
      times: Set(eventMonitors.values.filter(\.listensToClock).flatMap(\.clockTimes)))
  }

  private func announceClockMinute(_ announcement: ClockWatch.Announcement) {
    FlashLog.debug(
      "[events] clock_minute",
      fields: [
        "time": announcement.time.description, "late_s": String(announcement.lateSeconds),
      ])
    emitHostEvent(PluginEvent(.clockMinute, payload: announcement.payload))
  }

  /// The idle times `core:user.idle` announces: each listening event
  /// monitor's `idle`, and the default for a listening plugin.
  func userIdleThresholds() -> [Int] {
    var seconds = Set(eventMonitors.values.filter(\.listensToIdle).map(\.idleSeconds))
    if hostEventHasClientListener(.userIdle) || hostEventHasClientListener(.userActive) {
      seconds.insert(IdleWatch.defaultSeconds)
    }
    return seconds.sorted()
  }

  private func announceUserIdle(_ announcement: IdleWatch.Announcement) {
    switch announcement {
    case .idle(let seconds):
      FlashLog.debug("[events] user_idle", fields: ["seconds": String(seconds)])
      emitHostEvent(PluginEvent(.userIdle, payload: ["seconds": seconds]))
    case .active(let idleSeconds):
      FlashLog.debug("[events] user_active", fields: ["idle_seconds": String(idleSeconds)])
      emitHostEvent(PluginEvent(.userActive, payload: ["idle_seconds": idleSeconds]))
    }
  }

  /// A payload-free change signal: listeners re-read what they show.
  private func emitSignal(_ event: HostEvent) {
    emitHostEvent(PluginEvent(event))
  }

  func reconcileClipboardMonitor() {
    // Never in the test runner: the watcher reads the real pasteboard and
    // the store loads the user's history, whose load then pushes inspector
    // state at a moment no test chose.
    guard clipboardMonitor == nil, NSClassFromString("XCTestCase") == nil else { return }
    FlashLog.debug("[clipboard] watcher started")
    // Made here, on main, so the history loads (and lists for the
    // flashlight) at launch rather than on the watcher's queue.
    let store = clipboardHistoryStore
    clipboardMonitor = ClipboardMonitor(
      onChange: { [weak self] item in
        store.record(item)
        DispatchQueue.main.async { [weak self] in self?.debugStateDidChange() }
      },
      onRestore: { id in store.touch(id: id) })
    clipboardMonitor?.start()
  }

  /// Bridge macOS power-source notifications into the plugin event stream.
  /// The sysinfo plugin reads its IOPowerSources snapshot only when this
  /// fires, rather than waking up every N seconds.
  private func startPowerSourceMonitor() {
    powerSourceMonitor = PowerSourceMonitor { [weak self] in
      self?.emitHostEvent(PluginEvent(.powerChanged))
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
      shouldSwallow: { [weak self] event in self?.keyboardTapShouldSwallow(event) ?? .pass },
      handle: { [weak self] event in self?.routeTapCapturedKey(event) },
      handleKeyUp: { [weak self] event in _ = self?.handleLeaderKeyUp(event) },
      keyUpMatters: { [weak self] keyCode in
        self?.config.mode.resolvedHyperMatcher?.mayMatch(keyCode: keyCode) ?? false
      })
    guard tap.start() else { return }
    keyboardCaptureTap = tap
    overlay.keyboardCaptureActive = true
  }

  /// Whether the keyboard tap swallows a `keyDown`: the pure
  /// `KeyboardCaptureTap.decide`, then only the effects that decision needs.
  /// Runs on the main thread inside the synchronous tap callback on every
  /// keystroke, so it never resolves the keyboard layout or performs AX IPC.
  /// A mismatched target pid reconciles the active mapping table before the
  /// key is routed. NORMAL is hermetic: `normalModeMappings` carries the same
  /// compiled set the Carbon registry does, and the session tap swallows the
  /// event before Carbon dispatch, so there's no double-fire.
  /// The tap's keyDown decision, with its routing: a swallowed key reaches
  /// `routeTapCapturedKey` unless the decision already acted on it here.
  private func keyboardTapShouldSwallow(_ event: CGEvent) -> KeyboardCaptureTap.KeyDownOutcome {
    let flags = event.flags
    let decision = tapDecision(
      isModifiedChord: flags.contains(.maskCommand) || flags.contains(.maskControl)
        || flags.contains(.maskAlternate),
      isBareEscape: event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
        && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
    return keyDownOutcome(for: decision, event: event)
  }

  /// What the tap would decide for a Command chord now: `flash resident status`
  /// reads it to say where such a chord goes.
  func modifiedChordDecision() -> KeyboardCaptureTap.Decision {
    tapDecision(isModifiedChord: true, isBareEscape: false)
  }

  /// The tap's decision from the live state, for a key of that shape.
  private func tapDecision(isModifiedChord: Bool, isBareEscape: Bool)
    -> KeyboardCaptureTap.Decision
  {
    KeyboardCaptureTap.decide(
      isTerminal: modeStore.mode.isTerminal,
      flashMode: flashMode,
      inputMode: overlay.inputMode,
      // About in the background is no surface of the keys typed elsewhere.
      aboutWindowVisible: aboutWindowVisible && statusItemController.aboutWindowIsKey,
      aboutWindowOwnsKeyboard: Self.aboutWindowShouldOwnNativeKeyboard(
        visible: aboutWindowVisible, isKey: statusItemController.aboutWindowIsKey,
        hasTransientInput: hintSession.isActive,
        activationInFlight: activationInFlight),
      // This callback is the tap, so a hint session over a menu takes its keys.
      nativeSurfaceSuspended: NativeSurfaceOwnership.ownsKeyboard(
        owned: nativeSurfaceSuspended, hintSessionActive: hintSession.isActive,
        activationInFlight: activationInFlight, tapLive: true),
      isModifiedChord: isModifiedChord,
      isBareEscape: isBareEscape,
      ephemeralPopupShown: overlay.statusPopupController.previewName != nil,
      dockViewShown: missionControlView != nil)
  }

  private func keyDownOutcome(for decision: KeyboardCaptureTap.Decision, event: CGEvent)
    -> KeyboardCaptureTap.KeyDownOutcome
  {
    let flags = event.flags
    switch decision {
    case .pass:
      return .pass
    case .swallow:
      reconcileFrontmostApplication(
        forKeyTargetingPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
      return tapReadsSecureInput() ? .pass : .swallow(route: true)
    case .swallowIfInsertChordIsMapped:
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      reconcileFrontmostApplication(
        forKeyTargetingPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)))
      guard mappings.hasMapping(virtualKey: keyCode, cgFlags: flags) else { return .pass }
      return tapReadsSecureInput() ? .pass : .swallow(route: true)
    case .closeEphemeralPopup:
      guard !tapReadsSecureInput() else { return .pass }
      // Out of the synchronous tap callback: hiding a panel is AppKit work.
      // The key is spent here: it must not also reach a mapping or the
      // interpreter, so it is swallowed without being routed.
      DispatchQueue.main.async { [weak self] in
        self?.overlay.dismissEphemeralStatusBarPopup(reason: "escape")
      }
      return .swallow(route: false)
    case .swallowIfNativeSurfaceKeyIsMapped:
      guard !tapReadsSecureInput() else { return .pass }
      let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
      // The surface's own Escape closes it, as without Flash.
      guard
        !NormalModeInterpreter.passesToNativeSurface(
          virtualKey: keyCode, modifierFlags: flags, mappings: overlay.normalModeMappings)
      else { return .pass }
      return keyboardTapHasActiveMapping(keyCode: keyCode, flags: flags)
        ? .swallow(route: true) : .pass
    }
  }

  /// The swallow decision's secure-input read. Every swallow yields to a
  /// focused password field; a change it sees is published on the next
  /// turn, outside the synchronous tap callback. While the flag is on, this
  /// tap receives no keys, so `SecureInputFixer` is what notices a hold that
  /// starts or sticks in the background.
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
    MainThreadActivity.note("tap_key")
    Trace.begin(.key, triggeredAt: event.timestamp) { routeTracedKey(event) }
  }

  private func routeTracedKey(_ event: NSEvent) {
    // HID timestamp → this main-thread turn: the tap-side latency budget.
    if FlashLog.wouldEmit(.trace) {
      FlashLog.trace(
        "[latency] tap_to_route ms="
          + String(
            format: "%.2f", (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000))
    }
    // HYPER is a hold on top of NORMAL routing. Claim the leader, and every
    // key while it is held, before a NORMAL chord or sequence can see them.
    if overlay.inputMode == .normal || modeStore.mode.isHyper {
      if handleLeaderHoldKeyDown(event) { return }
    }
    switch overlay.inputMode {
    case .passive:
      // A chord the tap swallowed in INSERT is an active mapping (see
      // `keyboardTapShouldSwallow`); fire it through the mapping matcher — the
      // same dispatch the Carbon hotkey used, minus the Carbon delivery latency.
      _ = mappings.handle(event: event)
      return
    case .normal:
      // A chord mapping fires natively, with the count typed before it,
      // unless a half-typed sequence, mark, macro or register name reads
      // the chord itself (`NormalModeInterpreter.pendingReadsNextKey`).
      let strict = event.modifierFlags.intersection([.command, .control, .option])
      if !strict.isEmpty,
        !NormalModeInterpreter.pendingReadsNextKey(overlay.normalModePending),
        mappings.handle(event: event)
      {
        return
      }
    case .hints, .commandLine:
      break
    }
    overlay.handleTapCapturedKey(event)
  }

  func emitRunningApplicationsChanged() {
    pluginManager.emitRunningApplicationsChanged(snapshot: Self.runningApplicationsSnapshot)
  }

  /// Thread-safe: `NSRunningApplication` properties read atomically.
  static func runningApplicationsSnapshot() -> [[String: Any]] {
    // Regular apps only, as the protocol promises: background helpers and
    // agents (Chrome's automation instances among them) share their app's
    // bundle id and would make plugins act on the same app many times over.
    NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
      guard let bundleID = app.bundleIdentifier, !app.isTerminated,
        app.activationPolicy == .regular
      else { return nil }
      return [
        "bundle_id": bundleID,
        "localized_name": app.localizedName ?? "",
        "pid": Int(app.processIdentifier),
      ]
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    // Windows parked for hidden workspaces come back before Flash goes.
    windowLayoutManager.releaseTiling()
    secureInputFixer.stop()
    caffeinateController?.shutdown()
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
    pluginStateRefresh.cancel()
    clipboardMonitor?.stop()
    clipboardMonitor = nil
    powerSourceMonitor?.stop()
    powerSourceMonitor = nil
    hostEventSources.stopAll()
    // A monitor run or startup command in progress, children included, ends
    // with Flash; no startup command starts after this.
    startupRunner.stop()
    MonitorProcess.shutdown()
    statusBarController?.stopAndWait()
    statusBarController = nil
    widgetController?.stop()
    widgetController = nil
    terminalInputMappings?.flush()
    overlay.statusPopupController.dismiss()
    overlay.statusTerminals.shutdown()
    monitor?.stop()
    pluginManager.stop()
    stopTelemetry()
    stopDebugServer()
    stopIPCServer()
    frecencyStore?.drain()
    frecencyStore = nil
    commandHistoryStore?.drain()
    commandHistoryStore = nil
    applyUpdateAtQuit()
  }

}

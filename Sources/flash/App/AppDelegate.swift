import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

enum InsertModeTransitionReason: Equatable {
  case explicitCommand
  case normalModeInput
  case lockedNormalModeInput
  case pointerClick
  case hintCommit
  case advancedModeDisabled

  var logValue: String {
    switch self {
    case .explicitCommand:
      return "explicit_command"
    case .normalModeInput:
      return "normal_mode_input"
    case .lockedNormalModeInput:
      return "locked_normal_mode_input"
    case .pointerClick:
      return "pointer_click"
    case .hintCommit:
      return "hint_commit"
    case .advancedModeDisabled:
      return "advanced_mode_disabled"
    }
  }

  var locksInsertMode: Bool {
    self == .lockedNormalModeInput
  }
}

struct ModeOverlaySnapshot: Equatable {
  var text: String
  var visible: Bool
  var captureInput: Bool
  var inputMode: OverlayInputMode
  var refreshActiveWindowBorder: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
  enum HintCommitBehavior {
    case click
    case copyURL
    case moveMouse
    case mouseGridClick
    case mouseGridMove
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
  /// Flat-JSON frecency persistence — keyed by stable item key
  /// (`app.bundle:…`, `url:…`, `command:…`), boost capped below the
  /// smallest `CandidateFinder` match-quality tier so it reorders
  /// within tiers without crossing them. Nil only if the support
  /// directory can't be created (read-only home, missing permission).
  var frecencyStore: FrecencyStore?
  /// Bumped on every keystroke. The scoring queue captures it at
  /// submission time and discards any late DB walk that returns after
  /// the user has typed past the query.
  var candidateFinderIndexGenerationCounter: UInt64 = 0
  var registry: SourceRegistry!
  var monitor: AppMonitor!
  var debugServer: DebugServer?
  var overlay: OverlayPanel!
  var statusBarController: FlashStatusBarController?
  var urlHandler: URLEventHandler!
  var configSources: [DispatchSourceFileSystemObject] = []
  let mappings = MappingsCoordinator()
  /// Per-focused-app effective mapping tables (config + applicable plugin
  /// mappings), keyed by bundle id ("" for none/unknown). Cleared on config
  /// reload and when a plugin's mappings change.
  var effectiveMappingCache: [String: Config.Mode] = [:]
  /// The effective mode last handed to `MappingsCoordinator`, so a focus
  /// change only re-registers Carbon hotkeys when the chord set changed.
  var lastAppliedMappingMode: Config.Mode?
  var lastConfigErrorAlertMessage: String?
  var configErrorAlertVisible = false

  /// The transient hint / mouse-grid session content. Reset in one move
  /// (`clearHintSessionState`), so a new session field can't leak by being
  /// forgotten in a hand-maintained reset list. The named accessors below
  /// forward to it so existing call sites keep their field names.
  var hintSession = HintSession()
  var currentHints: [AssignedHint] {
    get { hintSession.hints }
    set { hintSession.hints = newValue }
  }
  var currentPrefix: String {
    get { hintSession.prefix }
    set { hintSession.prefix = newValue }
  }
  /// The pointer action a committed hint performs. NOT part of `hintSession`:
  /// the mouse-grid commit reads it *after* the session reset, so it must
  /// outlive `clearHintSessionState()`.
  var pendingAction: JumpAction = .leftClick
  var pendingHintCommitBehavior: HintCommitBehavior {
    get { hintSession.commitBehavior }
    set { hintSession.commitBehavior = newValue }
  }
  /// The single source of truth for the app's mode. Every UI-facing fact
  /// (overlay input routing, status bar, badge, capture, mapping scope) is a
  /// projection of `modeStore.mode`; transitions go through `dispatchMode`.
  let modeStore = ModeStore()
  /// The coarse insert/normal axis, projected from the unified mode.
  var flashMode: FlashMode { modeStore.mode.flashMode }
  /// Advanced mode (the normal/insert system) is configured — true unless the
  /// mode is `.disabled`, i.e. the user has an `enter_normal_mode` binding.
  /// Gates capture and the active-window border, NOT the status bar's
  /// visibility.
  var modeBadgeEnabled: Bool { modeStore.mode != .disabled }
  /// Whether the persistent top status bar is shown. Mirrors
  /// `config.statusBar.enabled` and is the sole condition for the bar — set
  /// from `[statusbar] enabled`, independent of `modeBadgeEnabled`.
  var statusBarVisible = false
  var normalModeTargetPID: pid_t?
  var candidateFinderCandidates: [Candidate] = [] {
    didSet {
      // Each flashlight session freezes one source snapshot. Bump the
      // epoch only when that snapshot's observable candidate identity
      // changes; selection movement and repeated renders should keep the
      // filter and incremental scoring caches intact.
      if Self.candidatePoolsCarrySameSourceIDs(oldValue, candidateFinderCandidates) {
        return
      }
      candidateFinderCandidatesEpoch &+= 1
      candidateFinderFilteredPoolCache = nil
      candidateFinderIncrementalCache = nil
    }
  }

  /// Fast pool-equality probe for candidate-finder cache invalidation. It
  /// checks stable scalar identity only, avoiding attributed-display work while
  /// still noticing same-source tab/window rows whose titles or URLs changed.
  static func candidatePoolsCarrySameSourceIDs(
    _ lhs: [Candidate],
    _ rhs: [Candidate]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for index in lhs.indices {
      let left = lhs[index]
      let right = rhs[index]
      if left.sourceID != right.sourceID
        || left.source != right.source
        || left.title != right.title
        || left.url?.absoluteString != right.url?.absoluteString
        || left.sourcePayload != right.sourcePayload
      {
        return false
      }
    }
    return true
  }
  /// Monotonic counter bumped on every `candidateFinderCandidates`
  /// reassignment so the filtered-pool cache can detect a stale base
  /// without comparing 2k-entry arrays element-wise per keystroke.
  var candidateFinderCandidatesEpoch: UInt64 = 0
  /// One-slot cache for the per-keystroke pool filter. While the user
  /// types into flashlight the base pool and selectors stay constant — so
  /// re-filtering 2k+ candidates on every keystroke is pure waste. The
  /// cache is invalidated whenever the underlying array or the filter
  /// signature differs from the prior key.
  var candidateFinderFilteredPoolCache: (epoch: UInt64, signature: String, pool: [Candidate])?
  /// Frozen alongside `candidateFinderCandidates` when a flashlight session
  /// opens. Source descriptors come from plugin manifests/native sources, so
  /// do that lookup once per session instead of rebuilding the table on every
  /// keystroke.
  var candidateFinderPrecedenceTable: CandidateFinder.PrecedenceTable = .default
  /// Incremental-narrowing cache for fuzzy scoring. When the next query
  /// extends the previous one (`mo` → `mor` → `moria`), no candidate
  /// that failed `mo` can pass `mor`, so we only need to re-score the
  /// previous match set. Each keystroke narrows the candidate space and
  /// the scoring path gets faster as the user types. Invalidated when
  /// the pool epoch or attribute-filter signature change, since either
  /// shifts the candidate base.
  var candidateFinderIncrementalCache:
    (normalizedQuery: String, matches: [CandidateMatch], epoch: UInt64, signature: String)?
  var candidateFinderMatches: [CandidateMatch] = []
  var candidateFinderSelectedIndex = 0
  /// Entries backing the dedicated `:clipboard` modal, same order as the
  /// rendered list; the panel owns the selected index, read back on submit.
  var clipboardModalEntries: [ClipboardModalEntry] = []
  /// Clipboard history mirrored for the inspector's Clipboard tab. Refreshed
  /// from the clipboard plugin on `:clipboard` and on each pasteboard change,
  /// then surfaced through `debugStateJSON`.
  var clipboardEntries: [ClipboardModalEntry] = []
  var candidateFinderCurrentQuery = ""
  var candidateFinderScope: CandidateScope = .all
  /// Bumped every time a flashlight session is (re)seeded. Each async location
  /// query captures the value live at fan-out and only merges its reply if the
  /// session is still the same one — so a slow plugin's answer from a closed or
  /// superseded session can't mutate the visible list.
  var candidateFinderSessionGeneration: UInt64 = 0
  /// Whether this session has already pulled the non-location candidate sources
  /// (emojis, bangs, notes, …). They're fetched lazily the first time the user
  /// types an `@source`/`!`bang filter, not on open — open fetches only
  /// locations. Reset when a session is (re)seeded.
  var candidateFinderNonLocationFetched = false
  /// Coalesces the re-render triggered by async location merges: many sources
  /// can reply within one runloop turn, so we append each to the pool
  /// immediately but re-score/repaint only once per turn instead of N times.
  var candidateFinderMergeRerenderScheduled = false
  var pluginStateRefreshWork: DispatchWorkItem?
  var commandLineCompletionPrefix: String = ""
  var commandLineCompletionMatches: [CommandLineCompletionMatch] = []
  var commandLineCompletionSelectedIndex = 0
  var commandLineCompletionQuery: String = ""
  /// Past executed command-line inputs (most-recent last). up/down (and
  /// ctrl+n/p, which route to the same handler) recall these when no candidate
  /// or completion list is active — see `recallCommandLineHistory`.
  var commandLineHistory: [String] = []
  /// Index into `commandLineHistory` while recalling; nil when editing a fresh
  /// buffer. `commandLineHistoryStash` holds that fresh buffer so stepping
  /// `down` past the newest entry restores what the user was typing.
  var commandLineHistoryCursor: Int?
  var commandLineHistoryStash: String = ""
  var selectedInitialMode = false
  var sourceAppPID: pid_t? {
    get { hintSession.sourceAppPID }
    set { hintSession.sourceAppPID = newValue }
  }
  var mouseGridRegion: MouseGrid.Region? {
    get { hintSession.mouseGridRegion }
    set { hintSession.mouseGridRegion = newValue }
  }
  var mouseGridDepth: Int {
    get { hintSession.mouseGridDepth }
    set { hintSession.mouseGridDepth = newValue }
  }
  var movementCurrent: MovementEntry?
  var movementBackStack: [MovementEntry] = []
  var movementForwardStack: [MovementEntry] = []
  var movementNavigationTargetKey: String?
  var ambientLocationRecordToken: UInt64 = 0
  var appCurrent: pid_t?
  var appBackStack: [pid_t] = []
  var appForwardStack: [pid_t] = []
  var appNavigationTargetPID: pid_t?
  var workspaceTokens: [NSObjectProtocol] = []
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
  var normalModePendingCommandToken: UInt64 = 0
  var clipboardMonitor: ClipboardMonitor?
  /// Captures NORMAL / hints keystrokes without taking key-window focus. nil
  /// (no grant) falls back to the legacy key-window capture in
  /// `captureKeyboardInput`.
  var keyboardCaptureTap: KeyboardCaptureTap?
  /// Debounces re-resolving URL-scoped plugin mappings when the focused
  /// document changes without an app-focus change (browser tab/navigation).
  var urlContextMappingRefreshWork: DispatchWorkItem?
  var windowGeometryChangeToken: UInt64 = 0
  var windowGeometryChangeInProgress = false
  var activeWindowBorderTrackingTimer: DispatchSourceTimer?
  var activeWindowBorderTrackedFrame: CGRect?
  /// The activation generation-token machine (stale-walk rejection). The named
  /// accessors below forward to it so existing call sites keep working; the
  /// `begin`/`complete`/`supersede`/`invalidate` operations are the consolidated
  /// home for what were scattered inline three-field mutations.
  var activationLifecycle = ActivationLifecycle()
  /// Set while an activation walk is in flight on the AX queue. New URL
  /// events that arrive during this window are dropped, not queued. Same
  /// guard rejects re-entry if hints are already on screen.
  var activationInFlight: Bool {
    get { activationLifecycle.inFlight }
    set { activationLifecycle.inFlight = newValue }
  }
  /// Bumped on every `activate(action:)` *and* every `cancelOverlay()`.
  /// The discovery completion captures the value at activation time and
  /// only renders if it still matches when the walk finishes. This is what
  /// prevents a stale walk from rendering hints over the wrong app after
  /// the user dismisses or switches focus mid-flight.
  var activationGen: UInt64 {
    get { activationLifecycle.generation }
    set { activationLifecycle.generation = newValue }
  }
  /// AX trust is checked once per session — until we observe `true`, we
  /// re-query each time. Once granted, the value is sticky for the rest
  /// of the run. Saves one IPC per activation in the steady state.
  /// Reset to `false` if an activation walk returns zero targets, which
  /// is the symptom of permission revocation mid-session.
  var cachedAccessibilityTrusted: Bool = false
  var activationInFlightGeneration: UInt64? {
    get { activationLifecycle.inFlightGeneration }
    set { activationLifecycle.inFlightGeneration = newValue }
  }
  var lastPermissionPromptAt: Date?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Resolve the login-shell environment once, off the main thread, so every
    // `script:`/`command:` task, mapping, and plugin inherits the same PATH
    // and tooling the user has in their terminal. A GUI launch from Finder/
    // launchd would otherwise hand children a bare environment. Until this
    // lands the seeded cache (process env + PATH fallback) keeps commands
    // usable, so the spawn need not block startup.
    DispatchQueue.global(qos: .userInitiated).async {
      FlashProcessEnvironment.shared.refresh()
    }
    config = ConfigLoader.load()
    frecencyStore = FrecencyStore()
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
          bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          configPath: nil,
          focused: true))
    }
    monitor.focusedElementMayHaveChanged = { [weak self] pid in
      self?.focusedInputMayHaveChanged(pid: pid)
    }
    monitor.focusedWindowGeometryDidChange = { [weak self] pid, notification in
      self?.focusedWindowGeometryDidChange(pid: pid, notification: notification)
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
    pluginManager.cacheRunningApplicationsSnapshot(runningApplicationsSnapshot())
    pluginManager.start(config: config)
    configureDebugServer(for: config)

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.hints.magicModifiers)
    overlay.normalModeSequenceTimeoutMs = config.mode.sequenceTimeoutMs
    // Pay the layer-allocation cost at launch instead of on the first
    // activation. 256 covers the steady state for most apps; further
    // growth uses the regular dequeue/alloc fallback.
    overlay.warmPool(count: 256)
    statusBarController = FlashStatusBarController(
      overlay: overlay,
      template: config.statusBar.template,
      pluginStatusesProvider: { [weak self] in
        self?.pluginManager.pluginStatuses() ?? []
      })
    statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)

    let dispatch: (URLCommand) -> Void = { [weak self] cmd in
      self?.handleURLCommand(cmd)
    }
    urlHandler = URLEventHandler(handler: dispatch)
    mappings.start(
      dispatch: { [weak self] action in
        self?.dispatchNativeMappingAction(action)
      },
      currentMode: { [weak self] in self?.flashMode ?? .insert })
    modeStore.perform = { [weak self] effects, previous, next in
      self?.applyModeEffects(effects, previous: previous, next: next)
    }
    refreshEffectiveMappings(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    if let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      movementCurrent = .app(pid: app.processIdentifier)
      appCurrent = app.processIdentifier
    }
    watchConfigFile()
    selectInitialModeIfNeeded()
    logPermissionState()
    installDismissObservers()
    startClipboardMonitor()
    startKeyboardCaptureTap()
    pluginManager.emit(
      PluginEvent(
        name: "core:flash.started", payload: [:], bundleID: nil, configPath: nil, focused: nil))
    emitRunningApplicationsChanged(reason: "launch")
  }

  func handleURLCommand(_ cmd: URLCommand) {
    FlashLog.trace(
      "[url] command=\(cmd.diagnosticDescription) mode=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight) overlay=\(String(describing: overlay?.inputMode))")
    switch cmd {
    case .mouseTarget(let command):
      activateMouseTarget(command, contextOverride: nil)
    case .mouseGrid(let command):
      activateMouseGrid(command, contextOverride: nil)
    case .normalMode:
      enterNormalMode()
    case .insertMode:
      enterInsertMode()
    case .lockedInsertMode:
      enterInsertMode(reason: .lockedNormalModeInput)
    case .commandMode:
      enterCommandLineMode()
    case .scroll, .reload, .undo, .redo, .archive, .resourceNext, .resourcePrevious,
      .close, .tabClose, .find, .candidateFinder,
      .enterCommand, .copyURL,
      .tabNext, .tabPrev, .tabFirst, .tabLast, .tabSelect,
      .tabMovePrev, .tabMoveNext, .tabReopen,
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
    case .dismissHints:
      cancelOverlay()
    case .quit:
      NSApp.terminate(nil)
    case .openApp(let name):
      openSourceItem(matching: name)
    case .pluginCommand(let command, let subcommand, let args):
      pluginManager.invoke(
        command: command,
        subcommand: subcommand,
        args: args,
        raw: cmd.diagnosticDescription,
        in: pluginSelectorContext()
      ) { [weak self] ok, pid, stdout, navigationURL in
        guard ok else { return }
        self?.activatePluginCommandTarget(pid, navigationURL: navigationURL)
        if let stdout { self?.overlay.displayBanner(stdout) }
      }
    case .moveWindow(let params):
      // Use the *non-Flash* frontmost app as the move target. Without
      // this, normal-mode capture (which activates Flash to satisfy the
      // Tahoe key-window rule) makes `frontmostApplication` resolve to
      // Flash itself, and the verb cheerfully maximises the status-bar
      // panel instead of the user's actual window.
      if let target = currentNonFlashContext() {
        WindowMover.move(
          params, statusBarReservesSpace: statusBarVisible, targetPID: target.processID)
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
        guard ok else { return }
        self?.activatePluginCommandTarget(pid, navigationURL: navigationURL)
        if let stdout { self?.overlay.displayBanner(stdout) }
      }
      if !dispatched {
        FlashLog.debug("[plugin_verb] no plugin claims verb=\(name)")
      }
    }
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
        self.statusBarController?.updateFocusedApplication(app)
        self.registry.refreshRunningApplications()
        self.refreshEffectiveMappings(for: app.bundleIdentifier, includeURL: false)
        if self.pluginManager.needsURLSelectorContext() {
          let pid = app.processIdentifier
          let bundleID = app.bundleIdentifier
          DispatchQueue.main.async { [weak self] in
            guard let self,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            else { return }
            self.refreshEffectiveMappings(for: bundleID, includeURL: true)
          }
        }
        self.pluginManager.emit(
          PluginEvent(
            name: "core:focus.changed",
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier,
            configPath: nil,
            focused: true))
        self.emitRunningApplicationsChanged(reason: "focus_changed")
        self.recordAppActivation(app.processIdentifier)
        if self.flashMode == .normal {
          self.normalModeTargetPID = app.processIdentifier
          self.suppressEditableFocus(for: app.processIdentifier)
        }
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
      self.cancelOverlay()
      self.pluginManager.emit(
        PluginEvent(
          name: "core:space.changed", payload: [:], bundleID: nil, configPath: nil, focused: nil))
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
            bundleID: app.bundleIdentifier,
            configPath: nil,
            focused: false))
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
        self.pluginManager.emit(
          PluginEvent(
            name: "core:apps.terminated",
            payload: [
              "bundle_id": app.bundleIdentifier ?? "",
              "localized_name": app.localizedName ?? "",
              "pid": Int(app.processIdentifier),
            ],
            bundleID: app.bundleIdentifier,
            configPath: nil,
            focused: false))
      }
      self.emitRunningApplicationsChanged(reason: "app_terminate")
    }
    workspaceTokens = [appSwitch, activeSpace, appLaunched, appTerminated]

    resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: overlay,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // Belt-and-suspenders refresh for the status-bar app name. The
      // workspace's `didActivateApplicationNotification` is the primary
      // signal, but on Tahoe (26) the system occasionally skips that
      // notification when focus snaps back from the Flash panel to
      // another app — most reproducibly when normal-mode capture loses
      // key and the user clicks straight into a different window. The
      // status bar then froze on whatever app was frontmost the last
      // time the notification fired. Re-pulling the workspace's
      // `frontmostApplication` whenever our panel resigns key catches
      // that drop without us having to chase the missing notification.
      if let front = NSWorkspace.shared.frontmostApplication,
        front.bundleIdentifier != Bundle.main.bundleIdentifier
      {
        self.statusBarController?.updateFocusedApplication(front)
      }
      if !self.currentHints.isEmpty {
        self.cancelOverlay()
        return
      }
      if self.flashMode == .normal {
        self.scheduleNormalModeRecaptureAfterPointerFocusLoss()
      }
    }
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
          bundleID: nil,
          configPath: nil,
          focused: nil))
      // Let the plugin fold the new entry into its history, then refresh the
      // inspector's Clipboard tab so an open dashboard updates live.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
        self?.refreshClipboardDashboardCache()
      }
    }
    clipboardMonitor?.start()
  }

  /// Install the keyboard tap so NORMAL / hints capture no longer needs the
  /// overlay to be the key window. Requires the Accessibility grant (which Flash
  /// already needs); if it's missing the tap won't create and we transparently
  /// fall back to key-window capture.
  private func startKeyboardCaptureTap() {
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
  /// NORMAL mode is a fully hermetic capture surface (like Vim's normal mode) —
  /// EVERY key is interpreted as a mapping or consumed, nothing reaches the
  /// focused app. Modified chords are handled by the interpreter too:
  /// `normalModeMappings` carries the same compiled set the Carbon registry does,
  /// and the session tap swallows the event before Carbon dispatch, so there's no
  /// double-fire. Command-line / modal / candidate-finder own the key window and
  /// type into their own fields, so the tap leaves those alone.
  private func keyboardTapShouldSwallow(_ event: CGEvent) -> Bool {
    // The decision depends only on mode × overlay input — the event itself is
    // never inspected here (NORMAL is hermetic; `routeTapCapturedKey` does the
    // per-key routing). Kept as a pure static func so it's unit-testable.
    KeyboardCaptureTap.shouldSwallow(flashMode: flashMode, inputMode: overlay.inputMode)
  }

  /// Dispatch a key the tap swallowed in NORMAL mode. Bare keys (and all hints
  /// keys) go to the overlay interpreter. Modified chords aren't in the
  /// interpreter's compiled set — they live in the Carbon matcher — so route
  /// those to `mappings.handle`: a configured chord fires, an unmatched one is
  /// simply consumed, keeping NORMAL hermetic without breaking native mappings.
  func routeTapCapturedKey(_ event: NSEvent) {
    if overlay.inputMode == .normal {
      let strict = event.modifierFlags.intersection([.command, .control, .option])
      if !strict.isEmpty {
        _ = mappings.handle(event: event)
        return
      }
    }
    overlay.handleTapCapturedKey(event)
  }

  func emitRunningApplicationsChanged(reason: String) {
    pluginManager.emitRunningApplicationsChanged(
      reason: reason,
      applications: runningApplicationsSnapshot())
  }

  private func runningApplicationsSnapshot() -> [[String: Any]] {
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
    pluginStateRefreshWork?.cancel()
    pluginStateRefreshWork = nil
    clipboardMonitor?.stop()
    clipboardMonitor = nil
    statusBarController?.stop()
    statusBarController = nil
    monitor?.stop()
    pluginManager.stop()
    debugServer?.stop()
    debugServer = nil
    frecencyStore?.drain()
    frecencyStore = nil
  }

}

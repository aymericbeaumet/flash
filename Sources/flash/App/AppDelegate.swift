import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore
import FlashProviders

enum InsertModeTransitionReason: Equatable {
  case explicitCommand
  case normalModeInput
  case pointerClick
  case hintCommit
  case advancedModeDisabled

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
    }
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

  var currentHints: [AssignedHint] = []
  var currentPrefix: String = ""
  var pendingAction: JumpAction = .leftClick
  var pendingHintCommitBehavior: HintCommitBehavior = .click
  var flashMode: FlashMode = .insert
  var modeBadgeEnabled = false
  var normalModeTargetPID: pid_t?
  /// Mode to restore on `finishCommandLineInteraction` when the verb that
  /// opened the modal asked for it (`restore_mode=1`). nil means "exit to
  /// the default — normal mode". See ``URLCommand/flashlight`` /
  /// ``URLCommand/emojiPicker``.
  var commandLineRestoreModeTarget: FlashMode?
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
  var candidateFinderCurrentQuery = ""
  var candidateFinderScope: CandidateScope = .all
  let candidateFinderCacheQueue = DispatchQueue(
    label: "flash.candidate_finder.cache", qos: .utility)
  /// Per-keystroke scoring runs Pass A (strict word-start tier, sync,
  /// sub-ms) on the main thread for instant paint, then dispatches
  /// Pass B (full fuzzy ladder) here so longer queries don't block the
  /// runloop. The serial label + `.userInteractive` QoS keeps results
  /// landing in order; the per-call generation check (`candidateFinderIndexGenerationCounter`)
  /// is what actually cancels a stale scoring job — a new keystroke
  /// bumps the counter and the next chunk-boundary check in Pass B
  /// exits early.
  let candidateFinderScoringQueue = DispatchQueue(
    label: "flash.candidate_finder.scoring", qos: .userInteractive)
  var candidateFinderRunningAppsRefreshInFlight = false
  var candidateFinderAllAppsRefreshInFlight = false
  var pluginStateRefreshWork: DispatchWorkItem?
  var commandLineCompletionPrefix: String = ""
  var commandLineCompletionItems: [NormalModeDispatcher.CommandLineCompletion] = []
  var commandLineCompletionMatches: [CommandLineCompletionMatch] = []
  var commandLineCompletionSelectedIndex = 0
  var commandLineCompletionQuery: String = ""
  var editableFocusSuppressedPID: pid_t?
  var selectedInitialMode = false
  var sourceAppPID: pid_t?
  var mouseGridRegion: MouseGrid.Region?
  var mouseGridDepth = 0
  var movementCurrent: MovementEntry?
  var movementBackStack: [MovementEntry] = []
  var movementForwardStack: [MovementEntry] = []
  var movementNavigationTargetKey: String?
  var appCurrent: pid_t?
  var appBackStack: [pid_t] = []
  var appForwardStack: [pid_t] = []
  var appNavigationTargetPID: pid_t?
  var workspaceTokens: [NSObjectProtocol] = []
  var resignKeyToken: NSObjectProtocol?
  var normalModeRecaptureToken: UInt64 = 0
  var normalModeCaptureVerificationToken: UInt64 = 0
  var normalModePendingCommandToken: UInt64 = 0
  var insertFocusExitProbeToken: UInt64 = 0
  var insertFocusOwnerPID: pid_t?
  var insertEditableFocusExitPID: pid_t?
  var insertNavigationExitToken: UInt64 = 0
  var clipboardMonitor: ClipboardMonitor?
  var windowGeometryChangeToken: UInt64 = 0
  var windowGeometryChangeInProgress = false
  var activeWindowBorderTrackingTimer: DispatchSourceTimer?
  var activeWindowBorderTrackedFrame: CGRect?
  /// Set while an activation walk is in flight on the AX queue. New URL
  /// events that arrive during this window are dropped, not queued. Same
  /// guard rejects re-entry if hints are already on screen.
  var activationInFlight: Bool = false
  /// Bumped on every `activate(action:)` *and* every `cancelOverlay()`.
  /// The discovery completion captures the value at activation time and
  /// only renders if it still matches when the walk finishes. This is what
  /// prevents a stale walk from rendering hints over the wrong app after
  /// the user dismisses or switches focus mid-flight.
  var activationGen: UInt64 = 0
  /// AX trust is checked once per session — until we observe `true`, we
  /// re-query each time. Once granted, the value is sticky for the rest
  /// of the run. Saves one IPC per activation in the steady state.
  /// Reset to `false` if an activation walk returns zero targets, which
  /// is the symptom of permission revocation mid-session.
  var cachedAccessibilityTrusted: Bool = false
  var activationInFlightGeneration: UInt64?
  var lastPermissionPromptAt: Date?

  func applicationDidFinishLaunching(_ notification: Notification) {
    config = ConfigLoader.load()
    frecencyStore = FrecencyStore()
    let manager = pluginManager
    registry = SourceRegistry(
      openConfig: config.open,
      pluginSourcesProvider: { manager.sources })
    monitor = AppMonitor(registry: registry, config: config)
    monitor.focusedElementDidChange = { [weak self] pid in
      guard let self else { return }
      self.pluginManager.emit(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["pid": Int(pid)],
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
      pluginSnapshotsProvider: { [weak self] in
        self?.pluginManager.statusSnapshots() ?? []
    })
    statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)

    let dispatch: (URLCommand) -> Void = { [weak self] cmd in
      self?.handleURLCommand(cmd)
    }
    urlHandler = URLEventHandler(handler: dispatch)
    mappings.start(
      dispatch: { [weak self] action in
        self?.performMappingCommand(action)
      },
      currentMode: { [weak self] in self?.flashMode ?? .insert })
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
    prewarmCandidateFinderCaches(reason: "launch")
    startClipboardMonitor()
    pluginManager.emit(
      PluginEvent(
        name: "core:flash.started", payload: [:], bundleID: nil, configPath: nil, focused: nil))
    emitRunningApplicationsSnapshot(reason: "launch")
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
      .sendKey:
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
      showPlugins()
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
        forBundleID: currentNonFlashContext()?.bundleIdentifier
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
          params, statusBarReservesSpace: modeBadgeEnabled, targetPID: target.processID)
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
        forBundleID: target?.bundleIdentifier,
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
        self.prewarmCandidateFinderCaches(reason: "focus_changed")
        self.refreshEffectiveMappings(for: app.bundleIdentifier)
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
        self.emitRunningApplicationsSnapshot(reason: "focus_changed")
        self.recordAppActivation(app.processIdentifier)
        if self.flashMode == .normal {
          self.normalModeTargetPID = app.processIdentifier
          self.suppressEditableFocus(for: app.processIdentifier)
        }
        self.cancelOverlay()
        self.scheduleNormalModeRecapture()
      } else {
        self.statusBarController?.updateFocusedApplication(NSWorkspace.shared.frontmostApplication)
        self.cancelOverlay()
        self.scheduleNormalModeRecapture()
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
      self.emitRunningApplicationsSnapshot(reason: "app_launch")
      self.invalidateCandidateFinderCaches(reason: "app_launch", refreshApps: false)
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
      self.emitRunningApplicationsSnapshot(reason: "app_terminate")
      self.invalidateCandidateFinderCaches(reason: "app_terminate", refreshApps: false)
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
      self?.pluginManager.emit(
        PluginEvent(
          name: "core:clipboard.changed",
          payload: ["text": text],
          bundleID: nil,
          configPath: nil,
          focused: nil))
    }
    clipboardMonitor?.start()
  }

  func emitRunningApplicationsSnapshot(reason: String) {
    let applications = NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
      guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
      return [
        "bundle_id": bundleID,
        "localized_name": app.localizedName ?? "",
        "pid": Int(app.processIdentifier),
      ]
    }
    pluginManager.emit(
      PluginEvent(
        name: "core:apps.snapshot",
        payload: [
          "reason": reason,
          "running_applications": applications,
        ],
        bundleID: nil,
        configPath: nil,
        focused: nil))
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

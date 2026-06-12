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
    }

    var kind: Kind
    var key: String
    var pid: pid_t?
    var candidate: Candidate?

    static func app(pid: pid_t) -> MovementEntry {
      MovementEntry(kind: .app, key: "app:\(pid)", pid: pid, candidate: nil)
    }

    static func candidate(_ candidate: Candidate) -> MovementEntry {
      let target =
        candidate.url?.absoluteString
        ?? candidate.sourcePayload
        ?? candidate.name
      return MovementEntry(
        kind: .candidate,
        key: "candidate:\(candidate.sourceID):\(candidate.pid ?? 0):\(target)",
        pid: candidate.pid,
        candidate: candidate)
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
  var alertPanel: AlertPanel!
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
  var candidateFinderCandidates: [Candidate] = [] {
    didSet { candidateFinderCandidatesEpoch &+= 1 }
  }
  /// Monotonic counter bumped on every `candidateFinderCandidates`
  /// reassignment so the filtered-pool cache can detect a stale base
  /// without comparing 2k-entry arrays element-wise per keystroke.
  var candidateFinderCandidatesEpoch: UInt64 = 0
  /// One-slot cache for the per-keystroke pool filter. While the user
  /// types into flashlight the base pool, `emojiMode`, and selectors
  /// stay constant — so re-filtering 2k+ candidates on every keystroke
  /// is pure waste. The cache is invalidated whenever the underlying
  /// array, emoji mode, or filter signature differs from the prior key.
  var candidateFinderFilteredPoolCache:
    (epoch: UInt64, emojiMode: Bool, signature: String, pool: [Candidate])?
  var candidateFinderMatches: [CandidateMatch] = []
  var candidateFinderSelectedIndex = 0
  /// Entries backing the dedicated `:clipboard` modal, same order as the
  /// rendered list; the panel owns the selected index, read back on submit.
  var clipboardModalEntries: [ClipboardModalEntry] = []
  var candidateFinderCurrentQuery = ""
  var candidateFinderScope: CandidateScope = .all
  /// `:emojis` narrows the shared candidate pool to emoji glyphs and routes
  /// selection to text insertion; every other candidate query excludes them.
  var candidateFinderEmojiMode = false
  /// One-shot flag: set when the user pressed `<cmd+cr>` on an
  /// `@<source>` completion row, indicating that after the next
  /// async-scoring pass settles we should open the top non-bang,
  /// non-source candidate. Clears itself on consumption so the bare
  /// keystroke can't trigger an open later.
  var pendingFlashlightSubmitAfterSourceLock = false
  let candidateFinderCacheQueue = DispatchQueue(label: "flash.candidate_finder.cache", qos: .utility)
  var candidateFinderRunningAppsCache: [Candidate] = []
  var candidateFinderRunningAppsCacheReady = false
  var candidateFinderRunningAppsRefreshInFlight = false
  var candidateFinderAllAppsCache: [Candidate] = []
  var candidateFinderAllAppsCacheReady = false
  var candidateFinderAllAppsRefreshInFlight = false
  var candidateFinderLiveRefreshTimer: DispatchSourceTimer?
  /// Last time the user touched the flashlight query. Used by the
  /// live-refresh timer to skip a refresh that would swap the pool out
  /// from under an actively-typed keystroke. Performance: every refresh
  /// pays a full `registry.candidates(scope:)` walk (AppleScript-backed
  /// browser tabs are the heavy contributors); skipping mid-typing is
  /// free CPU back to the user.
  var candidateFinderLastInputAt: Date?
  /// `true` after the user types into the flashlight at least once. The
  /// initial display is locked to the snapshot captured at open time so
  /// the list doesn't visibly reflow when a slow `refreshCandidatesAsync`
  /// finishes in the background — the user sees a static, instantly-
  /// ready list and only sees it change in response to their keystrokes.
  /// The async refresh is *not* cancelled (the pool stays warm for the
  /// next session); only the visible re-render is suppressed.
  var candidateFinderUserHasTyped: Bool = false
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
  /// Vim-style marks. `m<letter>` records the focused app at the
  /// moment the user pressed it; `` `<letter> `` re-activates that
  /// app. PIDs aren't stable across launches, so the bundle id is
  /// used as the durable handle and pid is the fast-path lookup.
  var marks: [Character: MarkState] = [:]

  struct MarkState {
    let bundleID: String
    let pid: pid_t
    let recordedAt: Date
  }
  var workspaceTokens: [NSObjectProtocol] = []
  var resignKeyToken: NSObjectProtocol?
  var normalModeRecaptureToken: UInt64 = 0
  var normalModeCaptureVerificationToken: UInt64 = 0
  var normalModePendingCommandToken: UInt64 = 0
  var normalModeEventTap: NormalModeEventTap?
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
      self?.pluginManager.emit(
        PluginEvent(
          name: "core:ax.changed",
          payload: ["pid": Int(pid)],
          bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          configPath: nil,
          focused: true))
    }
    monitor.focusedWindowGeometryDidChange = { [weak self] pid, notification in
      self?.focusedWindowGeometryDidChange(pid: pid, notification: notification)
    }
    monitor.start()
    pluginManager.onStateChanged = { [weak self] in
      self?.pluginStateDidChange()
    }
    // A plugin edited its registered mappings: drop the cached effective
    // modes and re-apply for the frontmost app so the new bindings take
    // effect without waiting for the next focus change. Fired on main after
    // the manager has already rebuilt its mapping index.
    pluginManager.onMappingsChanged = { [weak self] in
      guard let self else { return }
      self.invalidateEffectiveMappings()
      self.refreshEffectiveMappings(
        for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
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
    alertPanel = AlertPanel()

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
    normalModeEventTap = NormalModeEventTap { [weak self] cgEvent in
      self?.normalModeEventTapShouldSwallow(cgEvent) ?? false
    }
    normalModeEventTap?.install()

    watchConfigFile()
    selectInitialModeIfNeeded()
    logPermissionState()
    installDismissObservers()
    prewarmCandidateFinderCaches(reason: "launch")
    startCandidateFinderLiveRefresh()
    startClipboardMonitor()
    pluginManager.emit(
      PluginEvent(name: "core:flash.started", payload: [:], bundleID: nil, configPath: nil, focused: nil))
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
    case .scroll, .reload, .undo, .redo, .close, .tabClose, .find, .candidateFinder, .flashlight,
      .emojiPicker,
      .copyURL,
      .tabNext, .tabPrev, .tabFirst, .tabLast, .tabSelect,
      .tabMovePrev, .tabMoveNext, .tabReopen,
      .historyBack, .historyForward,
      .movementBack, .movementForward, .appPrev, .appNext,
      .setMark, .jumpToMark,
      .quitApp, .save, .saveAndQuit, .print,
      .openDocument, .newWindow, .tabNew, .copy, .cut, .paste, .copyAll,
      .sendKey:
      performMappedCommand(cmd)
    case .showAlert(let message):
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      alertPanel.show(message)
    case .dismissAlert:
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      alertPanel.dismiss()
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
      ) { [weak self] ok, pid, stdout in
        guard ok else { return }
        self?.activatePluginCommandTarget(pid)
        if let stdout { self?.overlay.displayBanner(stdout) }
      }
    case .moveWindow(let params):
      WindowMover.move(params)
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
        self.registry.refreshRunningApplications()
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
        self.recordAppActivation(app.processIdentifier)
        if self.flashMode == .normal {
          self.normalModeTargetPID = app.processIdentifier
          self.suppressEditableFocus(for: app.processIdentifier)
        }
        self.cancelOverlay()
        self.scheduleNormalModeRecapture()
      } else {
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
        PluginEvent(name: "core:space.changed", payload: [:], bundleID: nil, configPath: nil, focused: nil))
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
      self.invalidateCandidateFinderCaches(reason: "app_terminate", refreshApps: false)
    }
    workspaceTokens = [appSwitch, activeSpace, appLaunched, appTerminated]

    resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: overlay,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
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

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    candidateFinderLiveRefreshTimer?.cancel()
    candidateFinderLiveRefreshTimer = nil
    pluginStateRefreshWork?.cancel()
    pluginStateRefreshWork = nil
    normalModeEventTap?.uninstall()
    normalModeEventTap = nil
    clipboardMonitor?.stop()
    clipboardMonitor = nil
    monitor?.stop()
    pluginManager.stop()
    debugServer?.stop()
    debugServer = nil
    frecencyStore?.drain()
    frecencyStore = nil
  }


}

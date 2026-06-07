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
  private enum HintCommitBehavior {
    case click
    case copyURL
    case moveMouse
    case mouseGridClick
    case mouseGridMove
  }

  private struct MovementEntry {
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
        candidate.tmuxTarget
        ?? candidate.url?.absoluteString
        ?? candidate.sourcePayload
        ?? candidate.name
      return MovementEntry(
        kind: .candidate,
        key: "candidate:\(candidate.sourceID):\(candidate.pid ?? 0):\(target)",
        pid: candidate.pid,
        candidate: candidate)
    }
  }

  private struct MovementIdentity: Equatable {
    var key: String
  }

  private var config = Config.default
  private let pluginManager = PluginManager()
  private var registry: SourceRegistry!
  private var monitor: AppMonitor!
  private var debugServer: DebugServer?
  private var overlay: OverlayPanel!
  private var alertPanel: AlertPanel!
  private var urlHandler: URLEventHandler!
  private var configSources: [DispatchSourceFileSystemObject] = []
  private let mappings = MappingsCoordinator()
  private var lastConfigErrorAlertMessage: String?
  private var configErrorAlertVisible = false

  private var currentHints: [AssignedHint] = []
  private var currentPrefix: String = ""
  private var pendingAction: JumpAction = .leftClick
  private var pendingHintCommitBehavior: HintCommitBehavior = .click
  private var flashMode: FlashMode = .insert
  private var modeBadgeEnabled = false
  private var normalModeTargetPID: pid_t?
  private var candidateFinderCandidates: [Candidate] = []
  private var candidateFinderMatches: [CandidateMatch] = []
  private var candidateFinderSelectedIndex = 0
  private var candidateFinderCurrentQuery = ""
  private var candidateFinderScope: CandidateScope = .all
  private let candidateFinderCacheQueue = DispatchQueue(label: "flash.candidate_finder.cache", qos: .utility)
  private var candidateFinderRunningAppsCache: [Candidate] = []
  private var candidateFinderRunningAppsCacheReady = false
  private var candidateFinderRunningAppsRefreshInFlight = false
  private var candidateFinderAllAppsCache: [Candidate] = []
  private var candidateFinderAllAppsCacheReady = false
  private var candidateFinderAllAppsRefreshInFlight = false
  private var candidateFinderLiveRefreshTimer: DispatchSourceTimer?
  private var commandLineCompletionPrefix: String = ""
  private var commandLineCompletionItems: [NormalModeDispatcher.CommandLineCompletion] = []
  private var commandLineCompletionMatches: [CommandLineCompletionMatch] = []
  private var commandLineCompletionSelectedIndex = 0
  private var commandLineCompletionQuery: String = ""
  private var editableFocusSuppressedPID: pid_t?
  private var selectedInitialMode = false
  private var sourceAppPID: pid_t?
  private var mouseGridRegion: MouseGrid.Region?
  private var mouseGridDepth = 0
  private var movementCurrent: MovementEntry?
  private var movementBackStack: [MovementEntry] = []
  private var movementForwardStack: [MovementEntry] = []
  private var movementNavigationTargetKey: String?
  private var appCurrent: pid_t?
  private var appBackStack: [pid_t] = []
  private var appForwardStack: [pid_t] = []
  private var appNavigationTargetPID: pid_t?
  /// Vim-style marks. `m<letter>` records the focused app at the
  /// moment the user pressed it; `` `<letter> `` re-activates that
  /// app. PIDs aren't stable across launches, so the bundle id is
  /// used as the durable handle and pid is the fast-path lookup.
  private var marks: [Character: MarkState] = [:]

  private struct MarkState {
    let bundleID: String
    let pid: pid_t
    let recordedAt: Date
  }
  private var workspaceTokens: [NSObjectProtocol] = []
  private var resignKeyToken: NSObjectProtocol?
  private var normalModeRecaptureToken: UInt64 = 0
  private var normalModeCaptureVerificationToken: UInt64 = 0
  private var normalModePendingCommandToken: UInt64 = 0
  private var normalModeScrollSuppressionUntil: Date?
  private var normalModeDragGlobalMonitor: Any?
  private var normalModeDragLocalMonitor: Any?
  private var normalModeDragAction: JumpAction = .leftClick
  private var normalModeDragModifiers: ClickModifiers = []
  private var windowGeometryChangeToken: UInt64 = 0
  private var windowGeometryChangeInProgress = false
  private var activeWindowBorderTrackingTimer: DispatchSourceTimer?
  private var activeWindowBorderTrackedFrame: CGRect?
  /// Set while an activation walk is in flight on the AX queue. New URL
  /// events that arrive during this window are dropped, not queued. Same
  /// guard rejects re-entry if hints are already on screen.
  private var activationInFlight: Bool = false
  /// Bumped on every `activate(action:)` *and* every `cancelOverlay()`.
  /// The discovery completion captures the value at activation time and
  /// only renders if it still matches when the walk finishes. This is what
  /// prevents a stale walk from rendering hints over the wrong app after
  /// the user dismisses or switches focus mid-flight.
  private var activationGen: UInt64 = 0
  /// AX trust is checked once per session — until we observe `true`, we
  /// re-query each time. Once granted, the value is sticky for the rest
  /// of the run. Saves one IPC per activation in the steady state.
  /// Reset to `false` if an activation walk returns zero targets, which
  /// is the symptom of permission revocation mid-session.
  private var cachedAccessibilityTrusted: Bool = false
  private var activationInFlightGeneration: UInt64?

  func applicationDidFinishLaunching(_ notification: Notification) {
    config = ConfigLoader.load()
    let manager = pluginManager
    registry = SourceRegistry(
      openConfig: config.open,
      pluginSourcesProvider: { manager.sources })
    monitor = AppMonitor(registry: registry, config: config)
    monitor.focusedElementDidChange = { [weak self] pid in
      self?.pluginManager.emit(
        PluginEvent(
          name: "ax.changed",
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
    pluginManager.start(config: config)
    configureDebugServer(for: config)

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.hints.magicModifiers)
    overlay.normalModeMappings = config.mode.mappings(for: .normal)
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
        self?.performMappingAction(action)
      },
      currentMode: { [weak self] in self?.flashMode ?? .insert })

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
    startCandidateFinderLiveRefresh()
    pluginManager.emit(
      PluginEvent(name: "flash.started", payload: [:], bundleID: nil, configPath: nil, focused: nil))
  }

  private func handleURLCommand(_ cmd: URLCommand) {
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
      .copyURL,
      .nextFrame, .mainFrame, .tabNext, .tabPrev, .tabSelect, .historyBack, .historyForward,
      .movementBack, .movementForward, .appPrev, .appNext,
      .setMark, .jumpToMark,
      .quitApp, .save, .saveAndQuit, .print,
      .openDocument, .newWindow, .tabNew, .tabNewInsert, .copy, .cut, .paste, .copyAll:
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
    case .pluginAction(let command, let name, let args):
      _ = pluginManager.invoke(
        command: command,
        name: name,
        args: args,
        raw: cmd.diagnosticDescription)
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
        self.pluginManager.emit(
          PluginEvent(
            name: "focus.changed",
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
        PluginEvent(name: "space.changed", payload: [:], bundleID: nil, configPath: nil, focused: nil))
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
            name: "apps.launched",
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
            name: "apps.terminated",
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

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    candidateFinderLiveRefreshTimer?.cancel()
    candidateFinderLiveRefreshTimer = nil
    pluginManager.stop()
    debugServer?.stop()
    debugServer = nil
  }

  // MARK: Activation

  private func activateMouseTarget(_ command: MouseCommand, contextOverride: AppContext?) {
    let behavior: HintCommitBehavior = command.isMove ? .moveMouse : .click
    activate(action: command.action, commitBehavior: behavior, contextOverride: contextOverride)
  }

  private func activateMouseGrid(_ command: MouseCommand, contextOverride: AppContext?) {
    let context = contextOverride ?? currentNonFlashContext() ?? normalModeContext()
    let region = MouseGrid.preparedRegion(
      MouseGrid.initialRegion(
        context: context,
        screens: NSScreen.screens,
        fallback: OverlayPanel.unionScreenFrame()),
      alphabet: config.resolvedAlphabet.chars)
    mouseGridRegion = region
    mouseGridDepth = 0
    sourceAppPID = context?.processID
    pendingAction = command.action
    pendingHintCommitBehavior = command.isMove ? .mouseGridMove : .mouseGridClick
    currentPrefix = ""
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    displayMouseGridRegion(region, depth: 0)
  }

  private func displayMouseGridRegion(_ region: MouseGrid.Region, depth: Int) {
    let region = MouseGrid.preparedRegion(region, alphabet: config.resolvedAlphabet.chars)
    mouseGridRegion = region
    let hints = MouseGrid.hints(
      in: region,
      depth: depth,
      alphabet: config.resolvedAlphabet.chars)
    guard !hints.isEmpty else {
      applyModeOverlay()
      return
    }
    activationGen &+= 1
    activationInFlight = false
    activationInFlightGeneration = nil
    currentHints = hints
    currentPrefix = ""
    overlay.inputMode = .hints
    overlay.display(hints: hints)
  }

  private func activate(
    action: JumpAction,
    commitBehavior: HintCommitBehavior = .click,
    targetFilter: ((JumpTarget) -> Bool)? = nil,
    contextOverride: AppContext? = nil
  ) {
    let profiler = FlashProfiler(kind: "activation", debug: config.debug)
    profiler.mark("url", detail: "action=\(action)")
    FlashLog.trace(
      "[activation] begin action=\(action) behavior=\(commitBehavior) mode=\(flashMode) "
        + "hints=\(currentHints.count) in_flight=\(activationInFlight) gen=\(activationGen)")

    // Cancel any in-flight walk and clear any visible hints. The
    // earlier "drop on busy" behaviour rejected the new trigger; the
    // user-facing rule now is "the most recent mouse target wins" —
    // pressing the hotkey again while hints are up restarts from
    // scratch (cancel current, kick off a fresh walk on the now-
    // focused window). cancelOverlay() bumps activationGen, so any
    // in-flight discoverAsync completion will see a stale generation
    // and bail before rendering.
    let wasBusy = activationInFlight || !currentHints.isEmpty
    if wasBusy {
      FlashLog.trace(
        "[activation] restart previous_in_flight=\(activationInFlight) "
          + "previous_hints=\(currentHints.count) gen=\(activationGen)")
      cancelOverlay()
      profiler.mark(
        "restart",
        detail: "in_flight=\(activationInFlight) visible_hints=\(currentHints.count)")
    }

    let contextStart = profiler.intervalStart()
    guard let context = contextOverride ?? currentNonFlashContext() else {
      FlashLog.debug("[activation] no target app")
      FlashLog.trace("[activation] no_context mode=\(flashMode) target_override=\(contextOverride != nil)")
      profiler.finish(outcome: "no_context")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[activation] target pid=\(context.processID) bundle=\(context.bundleIdentifier) "
        + "source=\(contextOverride == nil ? "focused" : "override")"
    )
    profiler.finishInterval(
      "current_context",
      since: contextStart,
      detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)"
    )
    sourceAppPID = context.processID
    pendingAction = action
    pendingHintCommitBehavior = commitBehavior

    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug

    let permissionStart = profiler.intervalStart()
    if !isAccessibilityTrusted() {
      profiler.finishInterval(
        "accessibility_check", since: permissionStart, detail: "trusted=false")
      promptForAccessibility()
      profiler.finish(
        outcome: "accessibility_denied",
        detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
      FlashLog.debug(
        "[activation] accessibility_denied pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier)"
      )
      applyModeOverlay()
      return
    }
    profiler.finishInterval("accessibility_check", since: permissionStart, detail: "trusted=true")

    activationGen &+= 1
    let myGen = activationGen
    activationInFlight = true
    activationInFlightGeneration = myGen
    overlay.inputMode = .hints
    FlashLog.trace(
      "[activation] dispatch_discover gen=\(myGen) pid=\(context.processID) "
        + "bundle=\(context.bundleIdentifier)")
    monitor.discoverAsync(
      context: context,
      profiler: profiler,
      targetFilter: targetFilter
    ) { [weak self] hints in
      guard let self else { return }
      if self.activationInFlightGeneration == myGen {
        self.activationInFlight = false
        self.activationInFlightGeneration = nil
      }
      FlashLog.trace(
        "[activation] discover_complete gen=\(myGen) current_gen=\(self.activationGen) "
          + "hints=\(hints.count) mode=\(self.flashMode)")
      // The walk is done; gate is open for the next activation
      // regardless of whether *this* walk's result is still relevant.
      guard self.activationGen == myGen else {
        profiler.finish(
          outcome: "stale_generation",
          detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
        FlashLog.debug(
          "[activation] stale_generation pid=\(context.processID) "
            + "bundle=\(context.bundleIdentifier)"
        )
        return
      }
      if hints.isEmpty {
        // Empty result is also the symptom of accessibility
        // permission being revoked between activations: AX walks
        // silently return [] when the process is no longer trusted.
        // Cheap to re-check — and we want the permission banner to
        // appear instead of the user staring at nothing.
        if !PermissionCheck.isAccessibilityTrusted {
          self.cachedAccessibilityTrusted = false
          self.promptForAccessibility()
          profiler.finish(
            outcome: "accessibility_revoked",
            detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
          FlashLog.debug(
            "[activation] accessibility_revoked pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
        } else {
          profiler.finish(
            outcome: "no_targets",
            detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
          FlashLog.debug(
            "[activation] no_targets pid=\(context.processID) "
              + "bundle=\(context.bundleIdentifier)"
          )
        }
        self.applyModeOverlay()
        return
      }
      self.currentHints = hints
      self.currentPrefix = ""
      let displayStart = profiler.intervalStart()
      self.overlay.display(hints: hints)
      profiler.finishInterval(
        "overlay_display", since: displayStart, detail: "hints=\(hints.count)")
      profiler.finish(
        outcome: "displayed",
        detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier) hints=\(hints.count)")
      FlashLog.debug(
        "[activation] displayed pid=\(context.processID) "
          + "bundle=\(context.bundleIdentifier) hints=\(hints.count)"
      )
    }
  }

  private func isAccessibilityTrusted() -> Bool {
    if cachedAccessibilityTrusted { return true }
    let trusted = PermissionCheck.isAccessibilityTrusted
    if trusted { cachedAccessibilityTrusted = true }
    return trusted
  }

  private func cancelOverlay() {
    FlashLog.trace(
      "[overlay] cancel hints=\(currentHints.count) in_flight=\(activationInFlight) "
        + "mode=\(flashMode) gen=\(activationGen) input=\(overlay.inputMode)")
    if overlay.inputMode == .commandLine {
      finishCommandLineInteraction(reason: "cancel_overlay")
      return
    }
    // Dismissal observers fire on every app switch, including when no
    // transient overlay is up. Even then, re-render the mode badge so
    // normal mode can immediately recapture keyboard input.
    if currentHints.isEmpty && !activationInFlight {
      overlay.hide()
      applyModeOverlay()
      return
    }
    overlay.hide()
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    mouseGridRegion = nil
    mouseGridDepth = 0
    pendingHintCommitBehavior = .click
    invalidateActivation(reason: "cancel_overlay")
    applyModeOverlay()
  }

  private var lastPermissionPromptAt: Date?

  private func promptForAccessibility() {
    // Open the Privacy & Security → Accessibility pane directly.
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      let now = Date()
      if let last = lastPermissionPromptAt, now.timeIntervalSince(last) < 5 {
        // Settings was already opened recently; don't re-open.
      } else {
        NSWorkspace.shared.open(url)
        lastPermissionPromptAt = now
      }
    }
    let bundlePath = Bundle.main.bundlePath
    let lines = [
      "Flash needs Accessibility permission",
      "to read clickable elements from the focused app",
      "and to dispatch the click on commit.",
      "",
      "System Settings → Privacy & Security → Accessibility",
      "",
      "If Flash is NOT in the list:",
      "  Click '+' and add this exact path:",
      "  \(bundlePath)",
      "  Then enable the toggle.",
      "",
      "If Flash IS already in the list (toggle ON):",
      "  The grant is bound to the previous binary's hash.",
      "  Toggle Flash OFF then ON to re-bind to the current build.",
      "  (./Scripts/dev.sh resets this for you next time.)",
      "",
      "System Settings has been opened.",
    ]
    overlay.displayBanner(lines.joined(separator: "\n"), durationMs: 10_000)
  }

  // MARK: Normal mode

  private func enterNormalMode() {
    FlashLog.trace(
      "[mode] enter_normal from=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight)")
    transitionMode(to: .normal, reason: "explicit_normal")
  }

  private func enterInsertMode(
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

  private func invalidateActivation(reason: String) {
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

  private func refreshCurrentModeSideEffects(reason: String) {
    switch flashMode {
    case .insert:
      updateInsertModeActiveWindowBorder(reason: reason)
    case .normal:
      break
    }
  }

  private func focusedWindowGeometryDidChange(pid: pid_t, notification: String) {
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
    return ModeOverlaySnapshot(
      text: mode == .normal ? labels.normal : labels.insert,
      visible: visible,
      captureInput: capture,
      inputMode: capture ? .normal : .hints,
      refreshActiveWindowBorder: mode == .insert)
  }

  private func applyModeOverlay(captureOverride: Bool? = nil) {
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

  private func suppressEditableFocus(for pid: pid_t) {
    guard pid > 0 else { return }
    editableFocusSuppressedPID = pid
  }

  private func scheduleNormalModeRecapture() {
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

  private func scheduleNormalModeRecaptureAfterPointerFocusLoss() {
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

  private static func pointIsInMenuBar(_ point: CGPoint) -> Bool {
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

  private func hasNormalModeBinding(_ cfg: Config) -> Bool {
    cfg.mode.containsAdvancedModeMapping
  }

  private func performMappedCommand(_ command: URLCommand, repeatCount: Int = 1) {
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
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
    case .candidateFinder(let all):
      enterCommandLineMode(initialText: "open ", candidateFinderScope: all ? .all : .running)
    case .flashlight:
      enterCommandLineMode(initialText: "flashlight ", candidateFinderScope: .all)
    case .mouseTarget(let command):
      activateMouseTarget(command, contextOverride: normalModeContext())
    case .mouseGrid(let command):
      activateMouseGrid(command, contextOverride: normalModeContext())
    case .copyURL:
      copyFocusedDocumentURL()
      applyModeOverlay()
    case .nextFrame:
      FlashLog.debug("[mappings] frame_next has no AX frame target in the focused app")
      applyModeOverlay()
    case .mainFrame:
      FlashLog.debug("[mappings] frame_main has no AX frame target in the focused app")
      applyModeOverlay()
    case .tabNext:
      tabNextInNormalMode(repeatCount: repeatCount)
    case .tabPrev:
      tabPrevInNormalMode(repeatCount: repeatCount)
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

  private func performMappingAction(_ action: MappingAction, repeatCount: Int = 1) {
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

  private func enterCommandLineMode(
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

  private func showHelp(topic: String? = nil) {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearTransientHintState(reason: "enter_help")
    clearCandidateFinderState()
    overlay.hide()
    overlay.setActiveWindowBorder(around: nil)
    overlay.displayModal(HelpDocs.render(topic: topic, config: config, showModes: modeBadgeEnabled))
  }

  private func showPlugins() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearTransientHintState(reason: "enter_plugins")
    clearCandidateFinderState()
    overlay.hide()
    overlay.setActiveWindowBorder(around: nil)
    overlay.displayModal(pluginManager.statusText())
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
      overlay.displayModal("PLUGINS RELOAD\n\n\(summary)")
    }
  }

  private func showMappings() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearTransientHintState(reason: "enter_mappings")
    clearCandidateFinderState()
    overlay.hide()
    overlay.setActiveWindowBorder(around: nil)
    overlay.displayModal(NormalModeDispatcher.mappingsText(config: config))
  }

  private func enterCandidateFinderMode(scope: CandidateScope) {
    guard flashMode == .normal else { return }
    overlay.normalModePending = ""
    clearTransientHintState(reason: "enter_candidate_finder")
    overlay.candidateFinderQuery = ""
    overlay.commandLineCursorIndex = 0
    candidateFinderScope = scope
    candidateFinderCandidates = candidateFinderCandidates(for: scope)
    candidateFinderSelectedIndex = 0
    overlay.setActiveWindowBorder(around: nil)
    refreshCandidateFinder(query: "")
  }

  private func prewarmCandidateFinderCaches(reason: String) {
    refreshCandidatesAsync(scope: .running, reason: reason)
    refreshCandidatesAsync(scope: .all, reason: reason)
  }

  private func invalidateCandidateFinderCaches(reason: String, refreshApps: Bool) {
    FlashLog.trace("[candidate_finder] refresh_cache reason=\(reason) refresh_apps=\(refreshApps)")
    if refreshApps {
      registry.refreshRunningApplications()
    }
    prewarmCandidateFinderCaches(reason: reason)
  }

  private func startCandidateFinderLiveRefresh() {
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

  private func refreshCandidateFinder(query: String) {
    updateCandidateMatches(query: query)
    overlay.displayCandidateFinder(query: query, items: candidateFinderDisplayItems())
  }

  private func refreshCommandLine(text: String, cursorIndex: Int? = nil) {
    let command = Self.commandLineBuffer(from: text)
    overlay.commandLineText = command
    overlay.commandLineCursorIndex = cursorIndex ?? command.count
    if let query = NormalModeDispatcher.commandLineCandidateQuery(command) {
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
    let scored: [CandidateMatch] = candidateFinderCandidates.compactMap { candidate in
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

  private func submitCommandLine(_ raw: String) {
    if NormalModeDispatcher.commandLineCandidateQuery(raw) != nil {
      submitSelectedCommandLineApp()
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

  private func finishCommandLineInteraction(reason: String) {
    overlay.hide()
    resetCommandLineState()
    transitionMode(to: Self.commandLineExitMode(currentMode: flashMode), reason: reason)
  }

  private func resetCommandLineState() {
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    overlay.candidateFinderQuery = ""
    candidateFinderScope = .all
    clearCandidateFinderState()
    clearCommandLineCompletionState()
  }

  private func clearCandidateFinderState() {
    overlay.candidateFinderQuery = ""
    candidateFinderCandidates = []
    candidateFinderMatches = []
    candidateFinderSelectedIndex = 0
    candidateFinderCurrentQuery = ""
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

  private func normalModeContext() -> AppContext? {
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

  private enum NavigationDirection {
    case back
    case forward
  }

  private func recordAppActivation(_ pid: pid_t) {
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

  // MARK: Vim-style marks

  private func setMark(letter: String) {
    guard let key = Self.normalizedMarkKey(letter) else {
      FlashLog.debug("[marks] reject set letter=\(letter) reason=invalid")
      return
    }
    guard let context = normalModeContext() ?? currentNonFlashContext() else {
      FlashLog.debug("[marks] set letter=\(key) reason=no_focused_app")
      return
    }
    marks[key] = MarkState(
      bundleID: context.bundleIdentifier,
      pid: context.processID,
      recordedAt: Date())
    FlashLog.debug(
      "[marks] set letter=\(key) bundle=\(context.bundleIdentifier) pid=\(context.processID)")
    scheduleNormalModeRecapture()
  }

  private func jumpToMark(letter: String) {
    guard let key = Self.normalizedMarkKey(letter) else {
      FlashLog.debug("[marks] reject jump letter=\(letter) reason=invalid")
      return
    }
    guard let mark = marks[key] else {
      FlashLog.debug("[marks] jump letter=\(key) reason=unset")
      return
    }
    if let runningApp = NSRunningApplication(processIdentifier: mark.pid),
      !runningApp.isTerminated
    {
      FlashLog.debug("[marks] jump letter=\(key) pid=\(mark.pid)")
      RunningApplicationActivation.activate(runningApp, options: [.activateAllWindows])
      normalModeTargetPID = mark.pid
      scheduleNormalModeRecapture()
      return
    }
    // PID dead → fall back to the durable bundle identifier so a
    // restarted app still answers the jump.
    if let fallback =
      NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == mark.bundleID && !$0.isTerminated
      })
    {
      FlashLog.debug(
        "[marks] jump_fallback letter=\(key) bundle=\(mark.bundleID) pid=\(fallback.processIdentifier)")
      marks[key] = MarkState(
        bundleID: mark.bundleID, pid: fallback.processIdentifier, recordedAt: mark.recordedAt)
      RunningApplicationActivation.activate(fallback, options: [.activateAllWindows])
      normalModeTargetPID = fallback.processIdentifier
      scheduleNormalModeRecapture()
      return
    }
    FlashLog.debug("[marks] jump letter=\(key) reason=app_not_running bundle=\(mark.bundleID)")
  }

  private static func normalizedMarkKey(_ raw: String) -> Character? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let ch = trimmed.first, trimmed.count == 1, ch.isLetter || ch.isNumber else {
      return nil
    }
    return Character(ch.lowercased())
  }

  private func navigateAppMRU(direction: NavigationDirection) {
    var source: [pid_t]
    var destination: [pid_t]
    switch direction {
    case .back:
      source = appBackStack
      destination = appForwardStack
    case .forward:
      source = appForwardStack
      destination = appBackStack
    }
    let flashBundleID = Bundle.main.bundleIdentifier
    while let candidate = source.popLast() {
      guard let app = NSRunningApplication(processIdentifier: candidate),
        !app.isTerminated,
        app.bundleIdentifier != flashBundleID
      else { continue }
      if let current = appCurrent, current != candidate {
        destination.append(current)
      }
      switch direction {
      case .back:
        appBackStack = source
        appForwardStack = destination
      case .forward:
        appForwardStack = source
        appBackStack = destination
      }
      appNavigationTargetPID = candidate
      appCurrent = candidate
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      return
    }
    switch direction {
    case .back:
      appBackStack = source
    case .forward:
      appForwardStack = source
    }
  }


  private func recordMovement(_ entry: MovementEntry, source: String) {
    guard let identity = movementIdentity(entry) else { return }
    if movementNavigationTargetKey == identity.key {
      movementNavigationTargetKey = nil
      movementCurrent = entry
      pruneMovementStacks()
      FlashLog.trace("[movement] activation target=\(identity.key) raw=\(entry.key) source=navigation")
      return
    }
    if let current = movementCurrent,
      let currentIdentity = movementIdentity(current),
      currentIdentity.key == identity.key
    {
      movementCurrent = entry
      movementNavigationTargetKey = nil
      pruneMovementStacks()
      FlashLog.trace("[movement] coalesced source=\(source) current=\(identity.key) raw=\(entry.key)")
      return
    }
    if let current = movementCurrent,
      movementEntriesShareActivation(current, entry)
    {
      movementNavigationTargetKey = nil
      pruneMovementStacks()
      FlashLog.trace("[movement] coalesced_activation source=\(source) current=\(identity.key) raw=\(entry.key)")
      return
    }
    if let current = movementCurrent {
      appendMovementEntry(current, to: &movementBackStack)
    }
    movementCurrent = entry
    movementForwardStack.removeAll(keepingCapacity: true)
    pruneMovementStacks()
    FlashLog.trace(
      "[movement] record source=\(source) current=\(identity.key) raw=\(entry.key) back=\(movementBackStack.count) "
        + "forward=\(movementForwardStack.count)")
  }

  private func navigateMovementHistory(direction: NavigationDirection) {
    let current = currentMovementEntry()
    if let current { movementCurrent = current }

    var sourceStack: [MovementEntry]
    var destinationStack: [MovementEntry]
    let label: String
    switch direction {
    case .back:
      sourceStack = movementBackStack
      destinationStack = movementForwardStack
      label = "back"
    case .forward:
      sourceStack = movementForwardStack
      destinationStack = movementBackStack
      label = "forward"
    }

    while let target = sourceStack.popLast() {
      guard movementEntryIsRestorable(target) else {
        continue
      }
      let targetIdentity = movementIdentity(target)
      if let current,
        let currentIdentity = movementIdentity(current),
        currentIdentity.key != targetIdentity?.key
      {
        appendMovementEntry(current, to: &destinationStack)
      }
      movementCurrent = target
      movementNavigationTargetKey = targetIdentity?.key
      storeMovementStacks(source: sourceStack, destination: destinationStack, direction: direction)
      FlashLog.debug("[movement] navigate \(label) target=\(targetIdentity?.key ?? target.key)")
      restoreMovement(target)
      return
    }

    storeMovementStacks(source: sourceStack, destination: destinationStack, direction: direction)
    pruneMovementStacks()
    FlashLog.debug("[movement] no \(label) target")
    applyModeOverlay()
  }

  private func currentMovementEntry() -> MovementEntry? {
    if let current = movementCurrent,
      let context = currentNonFlashContext(),
      current.pid == context.processID
    {
      return current
    }
    if let context = currentNonFlashContext() {
      return .app(pid: context.processID)
    }
    if let current = movementCurrent {
      return current
    }
    if let pid = normalModeTargetPID {
      return .app(pid: pid)
    }
    return nil
  }

  private func restoreMovement(_ entry: MovementEntry) {
    switch entry.kind {
    case .app:
      guard let pid = entry.pid, let item = registry.candidate(forProcessID: pid) else {
        applyModeOverlay()
        return
      }
      openSourceItem(item, recordMovement: false)
    case .candidate:
      guard let candidate = entry.candidate else {
        applyModeOverlay()
        return
      }
      openSourceItem(candidate, recordMovement: false)
    }
  }

  private func appendMovementEntry(_ entry: MovementEntry, to stack: inout [MovementEntry]) {
    guard let identity = movementIdentity(entry) else { return }
    stack.removeAll { existing in
      guard let existingIdentity = movementIdentity(existing) else { return true }
      return existingIdentity.key == identity.key
    }
    stack.append(entry)
    if stack.count > 20 {
      stack.removeFirst(stack.count - 20)
    }
  }

  private func movementEntriesShareActivation(
    _ current: MovementEntry,
    _ next: MovementEntry
  ) -> Bool {
    current.kind == .candidate
      && next.kind == .app
      && current.pid != nil
      && current.pid == next.pid
  }

  private func movementIdentity(_ entry: MovementEntry) -> MovementIdentity? {
    switch entry.kind {
    case .app:
      guard let pid = entry.pid, pid > 0,
        let candidate = registry.candidate(forProcessID: pid)
      else { return nil }
      return Self.appMovementIdentity(candidate)
    case .candidate:
      guard let candidate = entry.candidate else { return nil }
      if candidate.kind == .app {
        return Self.appMovementIdentity(candidate)
      }
      if let pid = candidate.pid, NSRunningApplication(processIdentifier: pid) == nil {
        return nil
      }
      guard registry.source(identifier: candidate.sourceID) != nil else { return nil }
      return MovementIdentity(key: entry.key)
    }
  }

  private static func appMovementIdentity(_ candidate: Candidate) -> MovementIdentity? {
    if !candidate.bundleIdentifier.isEmpty {
      return MovementIdentity(key: "app.bundle:\(candidate.bundleIdentifier)")
    }
    if let path = candidate.url?.standardizedFileURL.path, !path.isEmpty {
      return MovementIdentity(key: "app.path:\(path)")
    }
    if let pid = candidate.pid, pid > 0 {
      return MovementIdentity(key: "app.pid:\(pid)")
    }
    return nil
  }

  private func movementEntryIsRestorable(_ entry: MovementEntry) -> Bool {
    movementIdentity(entry) != nil
  }

  private func storeMovementStacks(
    source: [MovementEntry],
    destination: [MovementEntry],
    direction: NavigationDirection
  ) {
    switch direction {
    case .back:
      movementBackStack = source
      movementForwardStack = destination
    case .forward:
      movementForwardStack = source
      movementBackStack = destination
    }
  }

  private func pruneMovementStacks() {
    movementBackStack.removeAll { !movementEntryIsRestorable($0) }
    movementForwardStack.removeAll { !movementEntryIsRestorable($0) }
  }

  private func currentNonFlashContext() -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostContext(excludingBundleIdentifier: flashBundleIdentifier)
  }

  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent) {
    if case .scroll = intent,
      Self.pointerScrollShouldBeSuppressed(
        mode: flashMode,
        hasHints: !currentHints.isEmpty,
        suppressionUntil: normalModeScrollSuppressionUntil)
    {
      FlashLog.trace("[mode] suppress_pointer_scroll reason=explicit_normal_momentum")
      applyModeOverlay()
      scheduleNormalModeRecapture()
      return
    }
    let replayClick: OverlayPointerClick?
    if case .click(let click) = intent,
      flashMode == .normal,
      currentHints.isEmpty,
      !Self.pointIsInMenuBar(click.location)
    {
      replayClick = click
    } else {
      replayClick = nil
    }
    normalModeScrollSuppressionUntil = nil
    cancelOverlay()
    if flashMode != .insert {
      enterInsertMode(reason: .pointerClick)
    }
    if let replayClick {
      beginNormalModeDrag(initial: replayClick)
    }
  }

  /// Replay the user's in-progress mouse gesture so the underlying app
  /// sees either a single click (release with no movement) or a real
  /// drag (press → drag → release). The mouseDown is deferred until we
  /// detect actual movement, so a quick press-release degrades cleanly
  /// to the prior `synthesizeClick` behavior.
  ///
  /// We stamp synthetic events via `eventSourceUserData` and ignore the
  /// tag in our own monitor — otherwise the dragged events we post would
  /// re-trigger the monitor and feed themselves back in a tight loop.
  private func beginNormalModeDrag(initial: OverlayPointerClick) {
    stopNormalModeDrag()
    normalModeDragAction = initial.action
    normalModeDragModifiers = initial.modifiers
    let initialLocation = initial.location
    let initialAction = initial.action
    let initialModifiers = initial.modifiers
    let isDoubleClick = initialAction == .doubleClick
    var dragStarted = false
    let dragThreshold: CGFloat = 4

    if isDoubleClick {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
        _ = ActionDispatcher.synthesizeClick(
          at: initialLocation,
          action: initialAction,
          modifiers: initialModifiers)
      }
      return
    }

    let mask: NSEvent.EventTypeMask = [
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    let handle: (NSEvent) -> Void = { [weak self] event in
      guard let self else { return }
      if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
        == ActionDispatcher.syntheticMouseEventTag
      {
        return
      }
      let point = NSEvent.mouseLocation
      switch event.type {
      case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        let dx = point.x - initialLocation.x
        let dy = point.y - initialLocation.y
        if !dragStarted, (dx * dx + dy * dy) < dragThreshold * dragThreshold {
          return
        }
        if !dragStarted {
          dragStarted = true
          _ = ActionDispatcher.synthesizeMouseButton(
            at: initialLocation,
            phase: .down,
            action: initialAction,
            modifiers: initialModifiers)
        }
        _ = ActionDispatcher.synthesizeMouseButton(
          at: point,
          phase: .dragged,
          action: initialAction,
          modifiers: initialModifiers)
      case .leftMouseUp, .rightMouseUp, .otherMouseUp:
        if dragStarted {
          _ = ActionDispatcher.synthesizeMouseButton(
            at: point,
            phase: .up,
            action: initialAction,
            modifiers: initialModifiers)
        } else {
          _ = ActionDispatcher.synthesizeClick(
            at: initialLocation,
            action: initialAction,
            modifiers: initialModifiers)
        }
        self.stopNormalModeDrag()
      default:
        break
      }
    }

    normalModeDragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
      handle(event)
    }
    normalModeDragLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
      handle(event)
      return event
    }
  }

  private func stopNormalModeDrag() {
    if let m = normalModeDragGlobalMonitor { NSEvent.removeMonitor(m) }
    if let m = normalModeDragLocalMonitor { NSEvent.removeMonitor(m) }
    normalModeDragGlobalMonitor = nil
    normalModeDragLocalMonitor = nil
  }

  func overlayDidHandleNormalMode(_ action: MappingAction?, repeatCount: Int) {
    guard flashMode == .normal else { return }
    normalModePendingCommandToken &+= 1
    guard let action else {
      schedulePendingNormalModeCommandIfNeeded()
      return
    }
    performMappingAction(action, repeatCount: repeatCount)
  }

  private func schedulePendingNormalModeCommandIfNeeded() {
    guard
      let pending = NormalModeInterpreter.pendingCommand(
        pending: overlay.normalModePending,
        mappings: overlay.normalModeMappings)
    else { return }

    let token = normalModePendingCommandToken
    let pendingText = overlay.normalModePending
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(NormalModeInterpreter.sequenceTimeoutMs)
    ) { [weak self] in
      guard let self, self.normalModePendingCommandToken == token else { return }
      guard self.flashMode == .normal, self.overlay.normalModePending == pendingText else { return }
      self.overlay.normalModePending = ""
      self.normalModePendingCommandToken &+= 1
      self.performMappingAction(pending.action, repeatCount: pending.repeatCount)
    }
  }

  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers) {
    if prefix == "__BACKSPACE__" {
      if !currentPrefix.isEmpty {
        currentPrefix.removeLast()
        overlay.filter(prefix: currentPrefix, hints: currentHints)
      }
      return
    }
    for ch in prefix.lowercased() {
      currentPrefix.append(ch)
    }
    overlay.filter(prefix: currentPrefix, hints: currentHints)

    // Single pass: count matches and remember the first one. Avoids
    // building a [AssignedHint] array per keystroke (was a 1-N alloc
    // every time the user typed a character). The hints carry a
    // pre-uppercased `display` field, so we don't pay an `uppercased()`
    // per chip per keystroke either.
    let upper = currentPrefix.uppercased()
    var matchCount = 0
    var firstMatch: AssignedHint?
    for h in currentHints where h.display.hasPrefix(upper) {
      matchCount += 1
      if matchCount == 1 {
        firstMatch = h
      } else {
        break
      }
    }
    if matchCount == 0 {
      cancelOverlay()
    } else if matchCount == 1, let m = firstMatch, m.display == upper {
      commit(hint: m, clickModifiers: clickModifiers)
    }
  }

  func overlayDidUpdatePrefix(_ prefix: String) {
    if prefix == "__BACKSPACE__" {
      if !currentPrefix.isEmpty {
        currentPrefix.removeLast()
        overlay.filter(prefix: currentPrefix, hints: currentHints)
      }
    } else {
      currentPrefix = prefix
      overlay.filter(prefix: currentPrefix, hints: currentHints)
    }
  }

  private func commit(hint: AssignedHint, clickModifiers: ClickModifiers) {
    if pendingHintCommitBehavior == .mouseGridClick || pendingHintCommitBehavior == .mouseGridMove {
      commitMouseGridCell(hint: hint, clickModifiers: clickModifiers)
      return
    }
    if pendingHintCommitBehavior == .copyURL {
      if let url = hint.target.url {
        NormalModeDispatcher.copy(url)
      }
      overlay.hide()
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
      mouseGridRegion = nil
      mouseGridDepth = 0
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      applyModeOverlay()
      return
    }
    if pendingHintCommitBehavior == .moveMouse {
      let targetFrame = hint.target.frame
      let point = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
      _ = ActionDispatcher.moveCursor(to: point)
      overlay.hide()
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
      mouseGridRegion = nil
      mouseGridDepth = 0
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      applyModeOverlay()
      return
    }

    let action = pendingAction
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.mouseTargetCommitShouldEnterInsertMode(action: action)
    let shouldRestoreNormalMode = flashMode == .normal && !shouldEnterInsertAfterCommit
    // The target carries its owning pid (always the focused app at
    // walk time). Fall back to the activation-time focused pid if the
    // provider didn't set one.
    let pid = hint.target.pid ?? sourceAppPID
    if let pid {
      recordMovement(.app(pid: pid), source: "hint_commit")
    }
    // Click the middle of the underlying target. For small targets
    // (most AX buttons / links / inputs) `chipFrame` already centres
    // the chip on the target, so target-centre and chip-centre
    // coincide. For wide targets (long tmux words, big AX buttons,
    // table rows) the chip anchors to the target's top-left for
    // visibility — but the *click* should still land in the middle of
    // the underlying element. Clicking near the left edge of a word
    // ("f" of "filename") instead of its middle felt wrong, and AX's
    // own AXPress fallback already uses the target's geometric centre
    // for the same reason, so this keeps the two paths consistent.
    let targetFrame = hint.target.frame
    let clickPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

    if shouldRestoreNormalMode {
      applyModeOverlay(captureOverride: false)
    }
    overlay.hide()
    // Restore focus to the target app before dispatching, so AXPress / the
    // synthesized click both reach the intended window.
    if let pid, let app = NSRunningApplication(processIdentifier: pid) {
      RunningApplicationActivation.activate(app, options: [])
    }
    // Hold the activation gate closed across the click dispatch. Without
    // this, the 20-ms delay below opens a window where a fresh
    // ctrl+space can land and start a second walk, and *this* commit's
    // click would then fire during the new activation (clicking
    // whatever the user was about to hint, not what they committed to).
    activationInFlight = true
    activationGen &+= 1
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    mouseGridRegion = nil
    mouseGridDepth = 0
    pendingHintCommitBehavior = .click
    if shouldEnterInsertAfterCommit {
      enterInsertMode(reason: .hintCommit)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      _ = ActionDispatcher.perform(
        action, on: hint.target, pid: pid, clickPoint: clickPoint, modifiers: clickModifiers)
      guard let self else { return }
      self.activationInFlight = false
      if shouldRestoreNormalMode {
        self.scheduleNormalModeRecapture()
      }
    }
  }

  private func commitMouseGridCell(hint: AssignedHint, clickModifiers: ClickModifiers) {
    let nextRegion = MouseGrid.Region(frame: hint.target.frame, grid: mouseGridRegion?.grid)
    let nextDepth = mouseGridDepth + 1
    if !MouseGrid.shouldCommit(region: nextRegion, depth: nextDepth) {
      mouseGridRegion = nextRegion
      mouseGridDepth = nextDepth
      currentPrefix = ""
      displayMouseGridRegion(nextRegion, depth: nextDepth)
      return
    }

    let point = CGPoint(x: nextRegion.frame.midX, y: nextRegion.frame.midY)
    let shouldMove = pendingHintCommitBehavior == .mouseGridMove
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.mouseGridCommitShouldEnterInsertMode(isMove: shouldMove)
    overlay.hide()
    currentHints = []
    currentPrefix = ""
    mouseGridRegion = nil
    mouseGridDepth = 0
    activationGen &+= 1
    sourceAppPID = nil
    pendingHintCommitBehavior = .click
    if shouldMove {
      _ = ActionDispatcher.moveCursor(to: point)
    } else {
      _ = ActionDispatcher.synthesizeClick(
        at: point,
        action: pendingAction,
        modifiers: clickModifiers)
    }
    if shouldEnterInsertAfterCommit {
      enterInsertMode(reason: .hintCommit)
    } else {
      applyModeOverlay()
    }
  }

  static func mouseTargetCommitShouldEnterInsertMode(action: JumpAction = .leftClick) -> Bool {
    switch action {
    case .leftClick, .rightClick, .doubleClick:
      return true
    }
  }

  static func mouseGridCommitShouldEnterInsertMode(isMove: Bool) -> Bool {
    !isMove
  }

  private func usesTmuxProvider(_ context: AppContext?) -> Bool {
    guard let context else { return false }
    return registry.chain(for: context).contains { $0.identifier == "plugin.tmux" }
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  func overlayDidCancelModal() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidPassThroughModalKey(_ event: NSEvent) {
    let targetPID = currentNonFlashContext()?.processID ?? normalModeTargetPID
    overlayDidCancelModal()
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
      _ = ActionDispatcher.forwardKeyDown(event, to: targetPID)
    }
  }

  func overlayDidCancelCommandLine() {
    finishCommandLineInteraction(reason: "command_cancel")
  }

  func overlayDidUpdateCommandLine(
    _ command: String,
    cursorIndex: Int,
    resetSelection: Bool
  ) {
    guard command.hasPrefix(":") else {
      FlashLog.trace("[input] command_line cancel reason=prompt_erased")
      overlayDidCancelCommandLine()
      return
    }
    if resetSelection {
      candidateFinderSelectedIndex = 0
    }
    refreshCommandLine(text: command, cursorIndex: cursorIndex)
  }

  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    if NormalModeDispatcher.commandLineCandidateQuery(overlay.commandLineText) != nil {
      guard !candidateFinderMatches.isEmpty else {
        refreshCommandLine(
          text: overlay.commandLineText,
          cursorIndex: overlay.commandLineCursorIndex)
        return true
      }
      candidateFinderSelectedIndex = min(
        max(candidateFinderSelectedIndex + delta, 0),
        candidateFinderMatches.count - 1)
      refreshCommandLine(
        text: overlay.commandLineText,
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    if !commandLineCompletionMatches.isEmpty {
      commandLineCompletionSelectedIndex = min(
        max(commandLineCompletionSelectedIndex + delta, 0),
        commandLineCompletionMatches.count - 1)
      refreshCommandLine(
        text: overlay.commandLineText,
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    return false
  }

  func overlayDidSubmitCommandLine(_ command: String) {
    submitCommandLine(command)
  }

  func overlayDidCancelCandidateFinder() {
    clearCandidateFinderState()
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidUpdateCandidateFinderQuery(_ query: String) {
    candidateFinderSelectedIndex = 0
    refreshCandidateFinder(query: query)
  }

  func overlayDidMoveCandidateFinderSelection(_ delta: Int) {
    guard !candidateFinderMatches.isEmpty else {
      refreshCandidateFinder(query: overlay.candidateFinderQuery)
      return
    }
    candidateFinderSelectedIndex = min(
      max(candidateFinderSelectedIndex + delta, 0),
      candidateFinderMatches.count - 1)
    refreshCandidateFinder(query: overlay.candidateFinderQuery)
  }

  func overlayDidSubmitCandidateFinder() {
    guard !candidateFinderMatches.isEmpty else {
      overlayDidCancelCandidateFinder()
      return
    }
    let candidate = candidateFinderMatches[min(candidateFinderSelectedIndex, candidateFinderMatches.count - 1)]
      .candidate
    openSourceItem(candidate)
  }

  private func openSourceItem(matching target: String) {
    guard let item = registry.candidate(matching: target) else {
      FlashLog.warn("[app_open] no source item found for \"\(target)\"")
      return
    }
    openSourceItem(item)
  }

  private func openSourceItem(_ candidate: Candidate, recordMovement shouldRecordMovement: Bool = true) {
    if shouldRecordMovement {
      recordMovement(.candidate(candidate), source: "source_open")
    }
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay(captureOverride: true)

    registry.resolveCandidate(candidate) { [weak self] result in
      guard let self else { return }
      if let pid = result.targetPID {
        self.normalModeTargetPID = pid
        self.suppressEditableFocus(for: pid)
      } else if !result.didResolve {
        FlashLog.debug(
          "[candidate_finder] unresolved candidate source=\(candidate.sourceID) name=\(candidate.name)")
      }
      self.refreshCurrentModeSideEffects(reason: "source_resolved")
      self.scheduleNormalModeRecapture()
    }
  }

  // MARK: Config hot reload

  /// `DispatchSource` watches a specific file descriptor → a specific
  /// inode. Two complications make this non-trivial:
  ///
  ///  1. Editors that save via write-temp-then-rename (vim's
  ///     `writebackup`, most editor "atomic writes", the `Edit` tool
  ///     in this harness, …) replace the inode under our fd: the
  ///     source fires once with `.delete`/`.rename`, then the fd
  ///     points at a deleted-but-still-open tombstone and subsequent
  ///     edits never fire. We re-arm by cancelling and reopening the
  ///     path after a short delay.
  ///
  ///  2. The config file may not exist when Flash launches — first-
  ///     run users start without `~/.config/flash/flash.toml`, and
  ///     some workflows delete the file when switching configs. In
  ///     that case `open(path, O_EVTONLY)` returns -1 and a naive
  ///     watcher silently no-ops, so the user's later "I'll just
  ///     create the file now" doesn't get picked up until the next
  ///     Flash restart. We fall back to watching the nearest existing
  ///     ancestor directory and re-evaluate the whole chain on any
  ///     event in it — which means creating an intermediate directory
  ///     or finally writing the file both kick the watcher one step
  ///     down the cascade toward a real file watcher.
  ///
  /// Watch every candidate config path. Reload on any event:
  ///   - file edit at the currently-loaded path → re-read it
  ///   - a higher-precedence path springs into existence → switch to it
  ///   - the currently-loaded file is deleted → fall through to the
  ///     next candidate
  ///
  /// Missing files have their parent directory watched instead, so
  /// creation triggers a re-watch + reload.
  private func watchConfigFile() {
    teardownConfigWatchers()
    let candidates = ConfigLoader.candidatePaths(
      arguments: CommandLine.arguments,
      environment: ProcessInfo.processInfo.environment)
    var watchedDirs = Set<String>()
    for url in candidates {
      attachWatcher(forPath: url.path)
      let dir = url.deletingLastPathComponent().path
      if watchedDirs.insert(dir).inserted {
        attachWatcher(forPath: dir)
      }
    }
    reloadConfig()
  }

  private func teardownConfigWatchers() {
    for s in configSources { s.cancel() }
    configSources.removeAll()
  }

  /// Attach a `kqueue`-backed watcher to `path` if it exists. On any
  /// event, debounce + re-run `watchConfigFile` (which re-evaluates
  /// existence and reloads the active config). Silently skipped when
  /// the path doesn't exist — the parent-dir watcher already covers
  /// "file gets created later".
  private func attachWatcher(forPath path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let mask: DispatchSource.FileSystemEvent =
      [.write, .delete, .rename, .extend]
    let source = makeWatcher(fd: fd, eventMask: mask) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
        [weak self] in
        self?.watchConfigFile()
      }
    }
    configSources.append(source)
  }

  private func makeWatcher(
    fd: Int32,
    eventMask: DispatchSource.FileSystemEvent,
    onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void
  ) -> DispatchSourceFileSystemObject {
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: eventMask, queue: .main)
    source.setEventHandler { [weak source] in
      guard let source else { return }
      onEvent(source.data)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
  }

  /// Re-read the config from disk, layer env + CLI overrides on top,
  /// then publish to overlay + monitor under their internal locks. Every
  /// future activation snapshots the new config at the start of its walk.
  private func reloadConfig() {
    let cfg = ConfigLoader.load()
    config = cfg
    // Apply log settings immediately — they need to be live for
    // any warning the rest of `reloadConfig` might emit (e.g.
    // unparsable native mappings logged by `mappings.apply`).
    // `configureProviders` re-applies this on every activation walk
    // so a hot-reload of the config also propagates without needing
    // to touch `FlashLog` from two places.
    FlashLog.setLevel(cfg.debug.logLevel)
    for diagnostic in cfg.loadingDiagnostics {
      FlashLog.warn("[config] \(diagnostic.logMessage)")
    }
    FlashLog.debug("[config] resolved_config=\(cfg.resolvedConfigJSON)")
    FlashLog.debug("[config] resolved_hints_keys=\(cfg.resolvedHintsKeysJSON)")
    showConfigErrorAlertIfNeeded(for: cfg)
    overlay.overlayConfig = cfg.overlay
    overlay.debugConfig = cfg.debug
    overlay.modeLabels = cfg.mode.labels
    overlay.magicModifiers = ClickModifiers(names: cfg.hints.magicModifiers)
    overlay.normalModeMappings = cfg.mode.mappings(for: .normal)
    overlay.normalModeSequenceTimeoutMs = cfg.mode.sequenceTimeoutMs
    registry.updateOpenConfig(cfg.open)
    pluginManager.updateConfig(cfg)
    pluginManager.emit(
      PluginEvent(
        name: "config.changed",
        payload: ["resolved": cfg.resolvedConfigJSON],
        bundleID: nil,
        configPath: "*",
        focused: nil))
    configureDebugServer(for: cfg)
    invalidateCandidateFinderCaches(reason: "config_reload", refreshApps: true)
    monitor.updateConfig(cfg)
    modeBadgeEnabled = hasNormalModeBinding(cfg)
    if !modeBadgeEnabled, flashMode == .normal {
      enterInsertMode(
        reason: .advancedModeDisabled,
        force: true)
    }
    applyModeOverlay()
    // Push native mappings too — the Carbon hotkey registry rebuilds
    // from scratch each call, so add/remove/edit all converge atomically.
    mappings.apply(mode: cfg.mode)
  }

  private func pluginStateDidChange() {
    invalidateCandidateFinderCaches(reason: "plugin_state", refreshApps: false)
    debugServer?.broadcastState()
  }

  private func configureDebugServer(for cfg: Config) {
    guard let httpHost = cfg.debug.httpHost, !httpHost.isEmpty else {
      debugServer?.stop()
      debugServer = nil
      return
    }
    if debugServer?.hostPort == httpHost {
      debugServer?.broadcastState()
      return
    }
    debugServer?.stop()
    let server = DebugServer(
      hostPort: httpHost,
      stateProvider: { [weak self] in self?.debugStateJSON() ?? [:] })
    debugServer = server
    server.start()
  }

  private func debugStateJSON() -> [String: Any] {
    let configJSON: Any
    if let data = config.resolvedConfigJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    {
      configJSON = object
    } else {
      configJSON = config.resolvedConfigJSON
    }
    let app = NSWorkspace.shared.frontmostApplication
    let focusedPID: Any = app.map { Int($0.processIdentifier) } ?? NSNull()
    return [
      "config": configJSON,
      "focused_app": [
        "bundle_id": app?.bundleIdentifier ?? NSNull(),
        "localized_name": app?.localizedName ?? NSNull(),
        "pid": focusedPID,
      ],
      "mode": "\(flashMode)",
      "overlay": String(describing: overlay?.inputMode),
      "plugins": pluginManager.stateJSON(),
    ]
  }

  private func selectInitialModeIfNeeded() {
    guard !selectedInitialMode else { return }
    selectedInitialMode = true
    if modeBadgeEnabled {
      enterNormalMode()
    } else {
      applyModeOverlay()
    }
  }

  private func showConfigErrorAlertIfNeeded(for cfg: Config) {
    guard let message = cfg.loadingErrorAlertMessage else {
      lastConfigErrorAlertMessage = nil
      if configErrorAlertVisible {
        configErrorAlertVisible = false
        alertPanel.dismiss()
      }
      return
    }
    guard message != lastConfigErrorAlertMessage else { return }
    lastConfigErrorAlertMessage = message
    configErrorAlertVisible = true
    alertPanel.show(message, duration: 8, style: .error)
  }

  private func logPermissionState() {
    let trusted = AXIsProcessTrusted()
    // Seed the activation-path cache so the very first ctrl+space
    // doesn't pay the AX IPC cost just to discover the user already
    // granted permission at some prior session.
    if trusted { cachedAccessibilityTrusted = true }
    if !trusted {
      FlashLog.warn(
        "[ax] accessibility permission not granted. "
          + "Grant it in System Settings → Privacy & Security → Accessibility "
          + "for /Applications/Flash.app."
      )
    }
  }
}

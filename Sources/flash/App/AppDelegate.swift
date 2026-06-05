import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FlashCore

enum InsertModeTransitionReason: Equatable {
  case explicitCommand
  case hintCommit
  case advancedModeDisabled

  var logValue: String {
    switch self {
    case .explicitCommand:
      return "explicit_command"
    case .hintCommit:
      return "hint_commit"
    case .advancedModeDisabled:
      return "advanced_mode_disabled"
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
  private enum HintCommitBehavior {
    case click
    case copyURL
    case moveMouse
  }

  private static let editableHintTargetRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXComboBox",
    "AXSearchField",
  ]

  private enum AppFinderScope {
    case running
    case all
  }

  private enum AppFinderCandidateKind {
    case app
    case tmuxWindow
    case browserTab
    case slackChannel
  }

  private struct AppFinderCandidate {
    var kind: AppFinderCandidateKind
    var sourceName: String
    var pid: pid_t?
    var name: String
    var subtitle: String
    var bundleIdentifier: String
    var url: URL?
    var tmuxClientTTY: String?
    var tmuxTarget: String?
    var targetElement: AXUIElement?
    var displayTitle: String = ""
    var normalizedSearchText: String = ""
  }

  private struct AppFinderMatch {
    var candidate: AppFinderCandidate
    var score: Int
    var highlightedRanges: [Range<Int>]
  }

  private struct AppFinderSource {
    var name: String
    var candidates: (AppDelegate, AppFinderScope) -> [AppFinderCandidate]
  }

  private var config = Config.default
  private var registry: ProviderRegistry!
  private var monitor: AppMonitor!
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
  private var appFinderCandidates: [AppFinderCandidate] = []
  private var appFinderMatches: [AppFinderMatch] = []
  private var appFinderSelectedIndex = 0
  private var appFinderScope: AppFinderScope = .all
  private let appFinderCacheQueue = DispatchQueue(label: "flash.app_finder.cache", qos: .utility)
  private var appFinderAllAppsCache: [AppFinderCandidate] = []
  private var appFinderAllAppsCacheReady = false
  private var appFinderAllAppsRefreshInFlight = false
  private var appFinderDynamicCache: [AppFinderCandidate] = []
  private var appFinderDynamicCacheTimestamp: TimeInterval = 0
  private var appFinderDynamicRefreshInFlight = false
  private let appFinderDynamicCacheTTL: TimeInterval = 1.0
  private var editableFocusSuppressedPID: pid_t?
  private var selectedInitialMode = false
  private var sourceAppPID: pid_t?
  private var appHistoryCurrentPID: pid_t?
  private var appHistoryBackStack: [pid_t] = []
  private var appHistoryForwardStack: [pid_t] = []
  private var appHistoryNavigationTargetPID: pid_t?
  private var workspaceTokens: [NSObjectProtocol] = []
  private var resignKeyToken: NSObjectProtocol?
  private var normalModeRecaptureToken: UInt64 = 0
  private var normalModePendingCommandToken: UInt64 = 0
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

  private var applicationAppFinderSource: AppFinderSource {
    AppFinderSource(name: "app") { app, scope in
      switch scope {
      case .running:
        return app.runningAppFinderCandidates(sourceName: "app")
      case .all:
        return app.allAppFinderCandidates(sourceName: "app")
      }
    }
  }

  private var dynamicAppFinderSources: [AppFinderSource] {
    [
      AppFinderSource(name: "tmux") { app, _ in
        app.tmuxWindowCandidates(sourceName: "tmux")
      },
      AppFinderSource(name: "browser-tabs") { app, _ in
        app.browserTabCandidates()
      },
      AppFinderSource(name: "slack") { app, _ in
        app.slackChannelCandidates(sourceName: "slack")
      },
    ]
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    config = ConfigLoader.load()
    registry = ProviderRegistry()
    monitor = AppMonitor(registry: registry, config: config)
    monitor.start()

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    overlay.modeLabels = config.mode.labels
    overlay.magicModifiers = ClickModifiers(names: config.hints.magicModifiers)
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
      dispatch: dispatch,
      currentMode: { [weak self] in self?.flashMode ?? .insert })

    if let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      appHistoryCurrentPID = app.processIdentifier
    }
    watchConfigFile()
    selectInitialModeIfNeeded()
    logPermissionState()
    installDismissObservers()
    prewarmAppFinderCaches(reason: "launch")
  }

  private func handleURLCommand(_ cmd: URLCommand) {
    FlashLog.trace(
      "[url] command=\(cmd.diagnosticDescription) mode=\(flashMode) hints=\(currentHints.count) "
        + "in_flight=\(activationInFlight) overlay=\(String(describing: overlay?.inputMode))")
    switch cmd {
    case .mouseClick(let action):
      activate(action: action)
    case .mouseMove:
      activate(action: .leftClick, commitBehavior: .moveMouse, contextOverride: normalModeContext())
    case .normalMode:
      enterNormalMode()
    case .insertMode:
      enterInsertMode()
    case .commandMode:
      enterCommandLineMode()
    case .scroll, .reload, .undo, .redo, .close, .find, .appFinder, .copyURL,
      .nextFrame, .mainFrame, .nextTab, .previousTab, .appBack, .appForward, .quitApp, .save,
      .saveAndQuit, .print, .openDocument, .newWindow, .newTab, .copy, .cut, .paste, .copyAll:
      performMappedCommand(cmd)
    case .showAlert(let message):
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      alertPanel.show(message)
    case .dismissAlert:
      configErrorAlertVisible = false
      lastConfigErrorAlertMessage = nil
      alertPanel.dismiss()
    case .showUsage:
      showHelp()
    case .dismissHints:
      cancelOverlay()
    case .quit:
      NSApp.terminate(nil)
    case .openApp(let name):
      AppLauncher.activate(target: name)
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
    ) { [weak self] _ in self?.cancelOverlay() }
    let appLaunched = nc.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.invalidateAppFinderCaches(reason: "app_launch", refreshApps: false)
    }
    let appTerminated = nc.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.invalidateAppFinderCaches(reason: "app_terminate", refreshApps: false)
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

  // MARK: Activation

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
    // user-facing rule now is "the most recent mouse_click wins" —
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
      self.activationInFlight = false
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
    pendingHintCommitBehavior = .click
    // Invalidate any in-flight discovery walk's right to render. We
    // *don't* clear `activationInFlight` here — the walk is still
    // running on the AX queue and clearing the flag would let a fresh
    // activation arrive and race with the previous walk's completion.
    // Once the walk does complete, it checks the generation and bails.
    activationGen &+= 1
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
      "  (./Scripts/install-release.sh resets this for you next time.)",
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
    flashMode = .normal
    overlay.normalModePending = ""
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    overlay.appFinderQuery = ""
    appFinderCandidates = []
    appFinderMatches = []
    appFinderSelectedIndex = 0
    currentPrefix = ""
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

  private func enterInsertMode(
    reason: InsertModeTransitionReason = .explicitCommand,
    force: Bool = false,
    showFocusIndicator: Bool = true
  ) {
    if flashMode == .normal, modeBadgeEnabled, !force,
      !Self.normalModeMayEnterInsert(reason: reason)
    {
      FlashLog.debug(
        "[mode] enter_insert_denied reason=\(reason.logValue) "
          + "rule=normal_requires_hint_focus")
      normalModePendingCommandToken &+= 1
      overlay.normalModePending = ""
      overlay.commandLineText = ""
      overlay.commandLineCursorIndex = 0
      overlay.appFinderQuery = ""
      appFinderCandidates = []
      appFinderMatches = []
      appFinderSelectedIndex = 0
      currentPrefix = ""
      if overlay.inputMode == .commandLine || overlay.inputMode == .appFinder || overlay.inputMode == .help {
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
    let focusFrame =
      (currentNonFlashContext() ?? normalModeContext())
      .flatMap { NormalModeDispatcher.focusedElementFrame(pid: $0.processID) }
    flashMode = .insert
    overlay.normalModePending = ""
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    overlay.appFinderQuery = ""
    appFinderCandidates = []
    appFinderMatches = []
    appFinderSelectedIndex = 0
    currentPrefix = ""
    normalModeTargetPID = nil
    editableFocusSuppressedPID = nil
    applyModeOverlay()
    if currentHints.isEmpty {
      overlay.hide()
      applyModeOverlay()
    }
    if showFocusIndicator, let focusFrame {
      overlay.displayFocusIndicator(around: focusFrame)
    }
  }

  static func normalModeMayEnterInsert(reason: InsertModeTransitionReason) -> Bool {
    reason == .hintCommit
  }

  private func applyModeOverlay(captureOverride: Bool? = nil) {
    let capture =
      captureOverride
      ?? (flashMode == .normal && currentHints.isEmpty && !activationInFlight)
    FlashLog.trace(
      "[mode] overlay mode=\(flashMode) capture=\(capture) override=\(String(describing: captureOverride)) "
        + "visible=\(modeBadgeEnabled) hints=\(currentHints.count) in_flight=\(activationInFlight)")
    overlay.inputMode = capture ? .normal : .hints
    overlay.setModeBadge(
      text: flashMode == .normal ? config.mode.labels.normal : config.mode.labels.insert,
      visible: modeBadgeEnabled,
      captureInput: capture,
      mode: flashMode)
  }

  private func suppressEditableFocus(for pid: pid_t) {
    guard pid > 0 else { return }
    editableFocusSuppressedPID = pid
  }

  private func scheduleNormalModeRecapture() {
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    FlashLog.trace("[mode] schedule_recapture token=\(token) delays=0,30,100,250,500,900,1400")
    for delayMs in [0, 30, 100, 250, 500, 900, 1_400] {
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

  private func scheduleNormalModeRecaptureAfterPointerFocusLoss() {
    normalModeRecaptureToken &+= 1
    FlashLog.trace(
      "[mode] pointer_recapture_suppressed target=\(Self.pointerFocusLossTarget()) "
        + "reason=preserve_menu_or_popup")
  }

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
    case .commandLine, .help, .appFinder:
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
      enterInsertMode()
    case .normalMode:
      enterNormalMode()
    case .commandMode:
      enterCommandLineMode()
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
    case .reload:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_R), flags: .maskCommand, repeatCount: repeatCount)
    case .undo:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand, repeatCount: repeatCount)
    case .redo:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_Z),
        flags: [.maskCommand, .maskShift],
        repeatCount: repeatCount)
    case .close:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand, repeatCount: repeatCount)
    case .find:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_F),
        flags: .maskCommand,
        repeatCount: repeatCount)
    case .appFinder(let all):
      enterCommandLineMode(initialText: "open ", appFinderScope: all ? .all : .running)
    case .mouseClick(let action):
      guard let context = normalModeContext() else {
        FlashLog.debug("[mappings] no target app for mouse_click")
        applyModeOverlay()
        return
      }
      activate(action: action, contextOverride: context)
    case .mouseMove:
      guard let context = normalModeContext() else {
        FlashLog.debug("[mappings] no target app for mouse_move")
        applyModeOverlay()
        return
      }
      activate(
        action: .leftClick,
        commitBehavior: .moveMouse,
        contextOverride: context)
    case .copyURL:
      copyFocusedDocumentURL()
      applyModeOverlay()
    case .nextFrame:
      FlashLog.debug("[mappings] frame_next has no AX frame target in the focused app")
      applyModeOverlay()
    case .mainFrame:
      FlashLog.debug("[mappings] frame_main has no AX frame target in the focused app")
      applyModeOverlay()
    case .nextTab:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_RightBracket),
        flags: [.maskCommand, .maskShift],
        repeatCount: repeatCount)
    case .previousTab:
      sendNormalModeKey(
        CGKeyCode(kVK_ANSI_LeftBracket),
        flags: [.maskCommand, .maskShift],
        repeatCount: repeatCount)
    case .appBack:
      navigateAppHistory(direction: .back)
    case .appForward:
      navigateAppHistory(direction: .forward)
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
    case .newTab:
      sendNormalModeKey(CGKeyCode(kVK_ANSI_T), flags: .maskCommand, repeatCount: repeatCount)
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
    case .showUsage:
      showHelp()
    case .showAlert, .dismissAlert, .dismissHints, .quit, .openApp, .moveWindow:
      handleURLCommand(command)
    }
  }

  private func normalizedRepeatCount(_ repeatCount: Int) -> Int {
    min(max(repeatCount, 1), 999)
  }

  private func enterCommandLineMode(
    initialText: String = "",
    appFinderScope: AppFinderScope? = nil
  ) {
    guard flashMode == .normal else { return }
    overlay.normalModePending = ""
    if let appFinderScope {
      self.appFinderScope = appFinderScope
      appFinderCandidates = appFinderCandidates(for: appFinderScope)
      appFinderSelectedIndex = 0
    } else {
      self.appFinderScope = .all
      clearAppFinderState()
    }
    refreshCommandLine(text: initialText, cursorIndex: initialText.count)
  }

  private func showHelp() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    clearAppFinderState()
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    pendingHintCommitBehavior = .click
    activationGen &+= 1
    overlay.hide()
    overlay.displayHelp(NormalModeDispatcher.helpText(config: config, showModes: modeBadgeEnabled))
  }

  private func enterAppFinderMode(scope: AppFinderScope) {
    guard flashMode == .normal else { return }
    overlay.normalModePending = ""
    overlay.appFinderQuery = ""
    overlay.commandLineCursorIndex = 0
    appFinderScope = scope
    appFinderCandidates = appFinderCandidates(for: scope)
    appFinderSelectedIndex = 0
    refreshAppFinder(query: "")
  }

  private func prewarmAppFinderCaches(reason: String) {
    refreshAllAppFinderCandidatesAsync(reason: reason)
    refreshDynamicAppFinderCandidatesAsync(reason: reason)
  }

  private func invalidateAppFinderCaches(reason: String, refreshApps: Bool) {
    FlashLog.trace("[app_finder] invalidate_cache reason=\(reason) refresh_apps=\(refreshApps)")
    appFinderDynamicCacheTimestamp = 0
    refreshDynamicAppFinderCandidatesAsync(reason: reason)
    if refreshApps {
      appFinderAllAppsCacheReady = false
      refreshAllAppFinderCandidatesAsync(reason: reason)
    }
  }

  private func refreshVisibleAppFinderResultsFromCache() {
    guard overlay != nil else { return }
    switch overlay.inputMode {
    case .commandLine:
      guard NormalModeDispatcher.commandLineOpenAppQuery(overlay.commandLineText) != nil else {
        return
      }
      appFinderCandidates = appFinderCandidates(for: appFinderScope)
      refreshCommandLine(text: overlay.commandLineText, cursorIndex: overlay.commandLineCursorIndex)
    case .appFinder:
      appFinderCandidates = appFinderCandidates(for: appFinderScope)
      refreshAppFinder(query: overlay.appFinderQuery)
    case .hints, .normal, .help:
      return
    }
  }

  private func refreshAllAppFinderCandidatesAsync(reason: String) {
    guard !appFinderAllAppsRefreshInFlight else { return }
    appFinderAllAppsRefreshInFlight = true
    let roots = applicationSearchRoots()
    FlashLog.trace("[app_finder] refresh_all_apps_start reason=\(reason)")
    appFinderCacheQueue.async { [weak self] in
      let candidates = Self.scanApplicationBundleCandidates(roots: roots)
      DispatchQueue.main.async {
        guard let self else { return }
        self.appFinderAllAppsCache = self.prepareAppFinderCandidates(candidates)
        self.appFinderAllAppsCacheReady = true
        self.appFinderAllAppsRefreshInFlight = false
        FlashLog.trace(
          "[app_finder] refresh_all_apps_done count=\(self.appFinderAllAppsCache.count) "
            + "reason=\(reason)")
        self.refreshVisibleAppFinderResultsFromCache()
      }
    }
  }

  private func cachedDynamicAppFinderCandidates() -> [AppFinderCandidate] {
    let now = Date().timeIntervalSinceReferenceDate
    if now - appFinderDynamicCacheTimestamp > appFinderDynamicCacheTTL {
      refreshDynamicAppFinderCandidatesAsync(reason: "ttl")
    }
    return appFinderDynamicCache
  }

  private func refreshDynamicAppFinderCandidatesAsync(reason: String) {
    guard !appFinderDynamicRefreshInFlight else { return }
    appFinderDynamicRefreshInFlight = true
    FlashLog.trace("[app_finder] refresh_dynamic_start reason=\(reason)")
    appFinderCacheQueue.async { [weak self] in
      guard let self else { return }
      let candidates = self.prepareAppFinderCandidates(
        self.dynamicAppFinderSources.flatMap { source in
          let sourceCandidates = source.candidates(self, self.appFinderScope)
          FlashLog.trace("[app_finder] source=\(source.name) count=\(sourceCandidates.count)")
          return sourceCandidates
        })
      DispatchQueue.main.async {
        self.appFinderDynamicCache = candidates
        self.appFinderDynamicCacheTimestamp = Date().timeIntervalSinceReferenceDate
        self.appFinderDynamicRefreshInFlight = false
        FlashLog.trace(
          "[app_finder] refresh_dynamic_done count=\(candidates.count) reason=\(reason)")
        self.refreshVisibleAppFinderResultsFromCache()
      }
    }
  }

  private func appFinderCandidates(for scope: AppFinderScope) -> [AppFinderCandidate] {
    var candidates = applicationAppFinderSource.candidates(self, scope)
    candidates.append(contentsOf: cachedDynamicAppFinderCandidates())
    return prepareAppFinderCandidates(candidates)
  }

  private func runningAppFinderCandidates(sourceName: String) -> [AppFinderCandidate] {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return NSWorkspace.shared.runningApplications.compactMap { app in
      guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
      guard app.bundleIdentifier != flashBundleIdentifier else { return nil }
      let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty else { return nil }
      return AppFinderCandidate(
        kind: .app,
        sourceName: sourceName,
        pid: app.processIdentifier,
        name: name,
        subtitle: "app",
        bundleIdentifier: app.bundleIdentifier ?? "",
        url: app.bundleURL,
        tmuxClientTTY: nil,
        tmuxTarget: nil,
        targetElement: nil)
    }
    .sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func allAppFinderCandidates(sourceName: String) -> [AppFinderCandidate] {
    var byIdentifier: [String: AppFinderCandidate] = [:]
    var byPath: [String: AppFinderCandidate] = [:]

    for candidate in runningAppFinderCandidates(sourceName: sourceName) {
      if !candidate.bundleIdentifier.isEmpty {
        byIdentifier[candidate.bundleIdentifier] = candidate
      } else if let path = candidate.url?.path {
        byPath[path] = candidate
      }
    }

    if appFinderAllAppsCacheReady {
      for candidate in appFinderAllAppsCache {
        if !candidate.bundleIdentifier.isEmpty {
          if byIdentifier[candidate.bundleIdentifier]?.pid == nil {
            byIdentifier[candidate.bundleIdentifier] = candidate
          }
        } else if let path = candidate.url?.path {
          byPath[path] = candidate
        }
      }
    } else {
      refreshAllAppFinderCandidatesAsync(reason: "cache_miss")
    }

    let combined = Array(byIdentifier.values) + Array(byPath.values)
    return combined.sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func applicationSearchRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/System/Applications"),
      URL(fileURLWithPath: "/System/Applications/Utilities"),
      home.appendingPathComponent("Applications"),
    ]
  }

  private static func scanApplicationBundleCandidates(roots: [URL]) -> [AppFinderCandidate] {
    var byIdentifier: [String: AppFinderCandidate] = [:]
    var byPath: [String: AppFinderCandidate] = [:]
    for root in roots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }

      for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "app" else { continue }
        let candidate = appBundleCandidate(fromBundleURL: url)
        if !candidate.bundleIdentifier.isEmpty {
          byIdentifier[candidate.bundleIdentifier] = candidate
        } else {
          byPath[url.path] = candidate
        }
      }
    }
    return (Array(byIdentifier.values) + Array(byPath.values)).sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static func appBundleCandidate(fromBundleURL url: URL) -> AppFinderCandidate {
    let bundle = Bundle(url: url)
    let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary ?? [:]
    let rawName =
      (info["CFBundleDisplayName"] as? String)
      ?? (info["CFBundleName"] as? String)
      ?? url.deletingPathExtension().lastPathComponent
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    return AppFinderCandidate(
      kind: .app,
      sourceName: "app",
      pid: nil,
      name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
      subtitle: "app",
      bundleIdentifier: bundle?.bundleIdentifier ?? "",
      url: url,
      tmuxClientTTY: nil,
      tmuxTarget: nil,
      targetElement: nil)
  }

  private func appCandidate(fromBundleURL url: URL) -> AppFinderCandidate {
    var candidate = Self.appBundleCandidate(fromBundleURL: url)
    let bundleIdentifier = candidate.bundleIdentifier
    let running = NSWorkspace.shared.runningApplications.first {
      if !bundleIdentifier.isEmpty, $0.bundleIdentifier == bundleIdentifier {
        return true
      }
      return $0.bundleURL == url
    }
    candidate.pid = running?.processIdentifier
    return prepareAppFinderCandidate(candidate)
  }

  private func prepareAppFinderCandidates(_ candidates: [AppFinderCandidate]) -> [AppFinderCandidate] {
    candidates.map(prepareAppFinderCandidate)
  }

  private func prepareAppFinderCandidate(_ candidate: AppFinderCandidate) -> AppFinderCandidate {
    var prepared = candidate
    prepared.displayTitle = appFinderDisplayTitle(candidate)
    prepared.normalizedSearchText = NormalModeDispatcher.normalizedSearchText(
      "\(candidate.sourceName) \(candidate.name) \(candidate.subtitle) \(candidate.bundleIdentifier)")
    return prepared
  }

  private static let tmuxPath: String? = {
    for path in [
      "/opt/homebrew/bin/tmux",
      "/usr/local/bin/tmux",
      "/opt/local/bin/tmux",
      "/usr/bin/tmux",
    ] where FileManager.default.isExecutableFile(atPath: path) {
      return path
    }
    return nil
  }()

  struct TmuxFinderClient: Equatable {
    var tty: String
    var session: String
    var clientPID: pid_t
    var terminalPID: pid_t?
  }

  struct TmuxFinderWindowSpec: Equatable {
    var session: String
    var index: String
    var name: String
    var tty: String?
    var terminalPID: pid_t?

    var title: String {
      name.isEmpty ? "\(session):\(index)" : "\(session):\(index) \(name)"
    }

    var subtitle: String {
      name.isEmpty ? "tmux \(session)" : "tmux \(session) \(name)"
    }

    var target: String {
      "\(session):\(index)"
    }
  }

  private func tmuxWindowCandidates(sourceName: String) -> [AppFinderCandidate] {
    guard let tmux = Self.tmuxPath else { return [] }
    let clients = tmuxFinderClients(tmux: tmux)
    guard
      let raw = runShell(
        tmux,
        [
          "list-windows", "-a", "-F",
          "#{session_name}\t#{window_index}\t#{window_name}",
        ])
    else { return [] }

    return Self.tmuxFinderWindowSpecs(windowListRaw: raw, clients: clients).map { spec in
      return AppFinderCandidate(
        kind: .tmuxWindow,
        sourceName: sourceName,
        pid: spec.terminalPID,
        name: spec.title,
        subtitle: spec.subtitle,
        bundleIdentifier: "",
        url: nil,
        tmuxClientTTY: spec.tty,
        tmuxTarget: spec.target,
        targetElement: nil)
    }
  }

  private func tmuxFinderClients(tmux: String) -> [TmuxFinderClient] {
    guard
      let raw = runShell(
        tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_pid}"])
    else { return [] }
    return Self.tmuxFinderClients(raw: raw) { clientPID in
      terminalApplicationPID(hosting: clientPID)
    }
  }

  static func tmuxFinderClients(
    raw: String,
    terminalPIDForClient: (pid_t) -> pid_t?
  ) -> [TmuxFinderClient] {
    return raw.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
      guard parts.count == 3, let clientPID = pid_t(parts[2]) else { return nil }
      return TmuxFinderClient(
        tty: parts[0],
        session: parts[1],
        clientPID: clientPID,
        terminalPID: terminalPIDForClient(clientPID))
    }
  }

  static func tmuxFinderWindowSpecs(
    windowListRaw raw: String,
    clients: [TmuxFinderClient]
  ) -> [TmuxFinderWindowSpec] {
    let fallbackClient = clients.first { $0.terminalPID != nil } ?? clients.first
    let clientBySession = Dictionary(
      clients.map { ($0.session, $0) },
      uniquingKeysWith: { first, second in
        first.terminalPID != nil ? first : second
      })
    return raw.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
      guard parts.count == 3 else { return nil }
      let session = parts[0]
      let client = clientBySession[session] ?? fallbackClient
      return TmuxFinderWindowSpec(
        session: session,
        index: parts[1],
        name: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
        tty: client?.tty,
        terminalPID: client?.terminalPID)
    }
  }

  private func terminalApplicationPID(hosting descendant: pid_t) -> pid_t? {
    NSWorkspace.shared.runningApplications.first { app in
      app.activationPolicy == .regular
        && Self.isAncestor(app.processIdentifier, of: descendant)
    }?.processIdentifier
  }

  private static let browserBundleIdentifiers: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Canary",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
  ]

  private func browserTabCandidates() -> [AppFinderCandidate] {
    var out: [AppFinderCandidate] = []
    var seen = Set<String>()
    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
        Self.browserBundleIdentifiers.contains(bundleID)
      else { continue }
      let appName = app.localizedName ?? "Browser"
      let sourceName = Self.browserSourceName(bundleID: bundleID, appName: appName)
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      let windows = axElementArrayAttribute(axApp, kAXWindowsAttribute as String)
      for window in windows {
        let windowTitle = axStringAttribute(window, kAXTitleAttribute as String) ?? appName
        for tab in browserTabElements(in: window) {
          let title =
            axStringAttribute(tab, kAXTitleAttribute as String)
            ?? axStringAttribute(tab, kAXDescriptionAttribute as String)
            ?? axStringAttribute(tab, kAXValueAttribute as String)
            ?? windowTitle
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { continue }
          let key = "\(app.processIdentifier)|\(windowTitle)|\(trimmed)"
          guard seen.insert(key).inserted else { continue }
          out.append(
            AppFinderCandidate(
              kind: .browserTab,
              sourceName: sourceName,
              pid: app.processIdentifier,
              name: trimmed,
              subtitle: "\(appName) tab \(windowTitle)",
              bundleIdentifier: bundleID,
              url: nil,
              tmuxClientTTY: nil,
              tmuxTarget: nil,
              targetElement: tab))
        }
      }
    }
    return out
  }

  private static func browserSourceName(bundleID: String, appName: String) -> String {
    switch bundleID {
    case "org.mozilla.firefox":
      return "firefox"
    case "org.mozilla.firefoxdeveloperedition":
      return "firefox-dev"
    case "com.google.Chrome", "com.google.Chrome.canary":
      return "chrome"
    case "com.brave.Browser":
      return "brave"
    case "com.microsoft.edgemac", "com.microsoft.edgemac.Canary":
      return "edge"
    case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
      return "safari"
    default:
      return appName.lowercased().replacingOccurrences(of: " ", with: "-")
    }
  }

  private static let slackBundleIdentifiers: Set<String> = [
    "com.tinyspeck.slackmacgap",
    "com.tinyspeck.slackmacgap.direct",
  ]

  private func slackChannelCandidates(sourceName: String) -> [AppFinderCandidate] {
    var out: [AppFinderCandidate] = []
    var seen = Set<String>()
    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
        Self.slackBundleIdentifiers.contains(bundleID)
      else { continue }
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      let windows = axElementArrayAttribute(axApp, kAXWindowsAttribute as String)
      for window in windows {
        for element in slackChannelElements(in: window) {
          guard let channel = slackChannelName(for: element) else { continue }
          let key = "\(app.processIdentifier)|\(channel)"
          guard seen.insert(key).inserted else { continue }
          out.append(
            AppFinderCandidate(
              kind: .slackChannel,
              sourceName: sourceName,
              pid: app.processIdentifier,
              name: channel,
              subtitle: "Slack channel",
              bundleIdentifier: bundleID,
              url: nil,
              tmuxClientTTY: nil,
              tmuxTarget: nil,
              targetElement: element))
        }
      }
    }
    return out
  }

  private func slackChannelElements(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue = [root]
    var index = 0
    while index < queue.count, index < 3_000 {
      let element = queue[index]
      index += 1
      if slackChannelName(for: element) != nil {
        out.append(element)
      }
      queue.append(contentsOf: axElementArrayAttribute(element, kAXChildrenAttribute as String))
    }
    return out
  }

  private func slackChannelName(for element: AXUIElement) -> String? {
    let raw =
      axStringAttribute(element, kAXTitleAttribute as String)
      ?? axStringAttribute(element, kAXDescriptionAttribute as String)
      ?? axStringAttribute(element, kAXValueAttribute as String)
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#"), trimmed.count > 1 else { return nil }
    return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)
  }

  private func browserTabElements(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue = [root]
    var index = 0
    while index < queue.count, index < 2_000 {
      let element = queue[index]
      index += 1
      let role = axStringAttribute(element, kAXRoleAttribute as String)
      if role == "AXTab" || role == "AXRadioButton" {
        out.append(element)
      }
      queue.append(contentsOf: axElementArrayAttribute(element, kAXChildrenAttribute as String))
    }
    return out
  }

  private func refreshAppFinder(query: String) {
    updateAppFinderMatches(query: query)
    overlay.displayAppFinder(query: query, items: appFinderDisplayItems())
  }

  private func refreshCommandLine(text: String, cursorIndex: Int? = nil) {
    overlay.commandLineText = text
    overlay.commandLineCursorIndex = cursorIndex ?? text.count
    guard let query = NormalModeDispatcher.commandLineOpenAppQuery(text) else {
      clearAppFinderState()
      overlay.displayCommandLine(text, cursorIndex: overlay.commandLineCursorIndex)
      return
    }
    if appFinderCandidates.isEmpty {
      appFinderCandidates = appFinderCandidates(for: appFinderScope)
      appFinderSelectedIndex = 0
    }
    updateAppFinderMatches(query: query)
    overlay.displayCommandLine(
      text,
      suggestions: appFinderDisplayItems(windowSize: 5),
      cursorIndex: overlay.commandLineCursorIndex)
  }

  private func updateAppFinderMatches(query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(trimmed)
    let scored: [AppFinderMatch] = appFinderCandidates.compactMap { candidate in
      let title = candidate.displayTitle.isEmpty ? appFinderDisplayTitle(candidate) : candidate.displayTitle
      if normalizedQuery.isEmpty {
        return AppFinderMatch(candidate: candidate, score: 0, highlightedRanges: [])
      }
      guard
        let score = NormalModeDispatcher.fuzzyScore(
          normalizedQuery: normalizedQuery,
          normalizedCandidate: candidate.normalizedSearchText)
      else { return nil }
      return AppFinderMatch(
        candidate: candidate,
        score: score,
        highlightedRanges: NormalModeDispatcher.fuzzyHighlightRanges(
          query: trimmed,
          candidate: title))
    }
    appFinderMatches = scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name)
        == .orderedAscending
    }
    if appFinderMatches.isEmpty {
      appFinderSelectedIndex = 0
    } else {
      appFinderSelectedIndex = min(max(appFinderSelectedIndex, 0), appFinderMatches.count - 1)
    }
  }

  private func appFinderDisplayItems(windowSize: Int = 6) -> [AppFinderDisplayItem] {
    guard !appFinderMatches.isEmpty else { return [] }
    let maxStart = max(0, appFinderMatches.count - windowSize)
    let start = min(max(0, appFinderSelectedIndex - windowSize / 2), maxStart)
    let end = min(appFinderMatches.count, start + windowSize)
    return appFinderMatches[start..<end].enumerated().map { offset, match in
      AppFinderDisplayItem(
        title: match.candidate.displayTitle.isEmpty
          ? appFinderDisplayTitle(match.candidate) : match.candidate.displayTitle,
        highlightedRanges: match.highlightedRanges,
        isSelected: start + offset == appFinderSelectedIndex)
    }
  }

  private func appFinderDisplayTitle(_ candidate: AppFinderCandidate) -> String {
    Self.appFinderDisplayTitle(sourceName: candidate.sourceName, name: candidate.name)
  }

  static func appFinderDisplayTitle(sourceName: String, name: String) -> String {
    "[\(sourceName)] \(name)"
  }

  private func submitCommandLine(_ raw: String) {
    if NormalModeDispatcher.commandLineOpenAppQuery(raw) != nil {
      submitSelectedCommandLineApp()
      return
    }
    overlay.hide()
    guard let command = NormalModeDispatcher.commandLineCommand(raw) else {
      FlashLog.debug("[normal_mode] unknown command :\(raw)")
      applyModeOverlay()
      return
    }
    performCommandLineCommand(command)
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
      performMappedCommand(.newTab)
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
    }
  }

  private func submitSelectedCommandLineApp() {
    guard !appFinderMatches.isEmpty else {
      overlay.hide()
      clearAppFinderState()
      applyModeOverlay()
      return
    }
    let candidate = appFinderMatches[min(appFinderSelectedIndex, appFinderMatches.count - 1)]
      .candidate
    openAppFinderCandidate(candidate)
  }

  private func clearAppFinderState() {
    overlay.appFinderQuery = ""
    appFinderCandidates = []
    appFinderMatches = []
    appFinderSelectedIndex = 0
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
    repeatCount: Int = 1
  ) {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for key \(key)")
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

  private func copyFocusedDocumentURL() {
    guard let context = normalModeContext() else {
      FlashLog.debug("[normal_mode] no target app for copyDocumentURL")
      return
    }
    guard let url = NormalModeDispatcher.documentURL(pid: context.processID) else {
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

  private enum AppHistoryDirection {
    case back
    case forward
  }

  private func recordAppActivation(_ pid: pid_t) {
    guard pid > 0 else { return }
    if appHistoryNavigationTargetPID == pid {
      appHistoryNavigationTargetPID = nil
      appHistoryCurrentPID = pid
      pruneAppHistoryStacks()
      FlashLog.trace("[app_history] activation target=\(pid) source=navigation")
      return
    }
    guard appHistoryCurrentPID != pid else { return }
    if let current = appHistoryCurrentPID, NSRunningApplication(processIdentifier: current) != nil {
      appendAppHistoryPID(current, to: &appHistoryBackStack)
    }
    appHistoryCurrentPID = pid
    appHistoryForwardStack.removeAll(keepingCapacity: true)
    pruneAppHistoryStacks()
    FlashLog.trace(
      "[app_history] activation current=\(pid) back=\(appHistoryBackStack.count) "
        + "forward=\(appHistoryForwardStack.count)")
  }

  private func navigateAppHistory(direction: AppHistoryDirection) {
    let current = currentNonFlashContext()?.processID ?? appHistoryCurrentPID
    if let current {
      appHistoryCurrentPID = current
    }

    switch direction {
    case .back:
      navigateAppHistory(
        source: &appHistoryBackStack,
        destination: &appHistoryForwardStack,
        current: current,
        label: "back")
    case .forward:
      navigateAppHistory(
        source: &appHistoryForwardStack,
        destination: &appHistoryBackStack,
        current: current,
        label: "forward")
    }
  }

  private func navigateAppHistory(
    source: inout [pid_t],
    destination: inout [pid_t],
    current: pid_t?,
    label: String
  ) {
    while let target = source.popLast() {
      guard let app = NSRunningApplication(processIdentifier: target), !app.isTerminated else {
        continue
      }
      if let current, current != target {
        appendAppHistoryPID(current, to: &destination)
      }
      appHistoryCurrentPID = target
      appHistoryNavigationTargetPID = target
      normalModeTargetPID = target
      suppressEditableFocus(for: target)
      FlashLog.debug("[app_history] navigate \(label) target=\(target)")
      app.activate(options: [.activateAllWindows])
      applyModeOverlay(captureOverride: true)
      scheduleNormalModeRecapture()
      return
    }
    FlashLog.debug("[app_history] no \(label) target")
    applyModeOverlay()
  }

  private func appendAppHistoryPID(_ pid: pid_t, to stack: inout [pid_t]) {
    guard pid > 0 else { return }
    stack.removeAll { $0 == pid || NSRunningApplication(processIdentifier: $0) == nil }
    stack.append(pid)
    if stack.count > 20 {
      stack.removeFirst(stack.count - 20)
    }
  }

  private func pruneAppHistoryStacks() {
    appHistoryBackStack.removeAll { NSRunningApplication(processIdentifier: $0) == nil }
    appHistoryForwardStack.removeAll { NSRunningApplication(processIdentifier: $0) == nil }
  }

  private func currentNonFlashContext() -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostContext(excludingBundleIdentifier: flashBundleIdentifier)
  }

  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCancelByPointer() {
    cancelOverlay()
    if flashMode == .normal {
      scheduleNormalModeRecaptureAfterPointerFocusLoss()
    }
  }

  func overlayDidHandleNormalMode(_ command: URLCommand?, repeatCount: Int) {
    guard flashMode == .normal else { return }
    normalModePendingCommandToken &+= 1
    guard let command else {
      schedulePendingNormalModeCommandIfNeeded()
      return
    }
    performMappedCommand(command, repeatCount: repeatCount)
  }

  private func schedulePendingNormalModeCommandIfNeeded() {
    guard
      let pending = NormalModeInterpreter.pendingCommand(
        pending: overlay.normalModePending,
        mappings: overlay.normalModeMappings)
    else { return }

    let token = normalModePendingCommandToken
    let pendingText = overlay.normalModePending
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
      guard let self, self.normalModePendingCommandToken == token else { return }
      guard self.flashMode == .normal, self.overlay.normalModePending == pendingText else { return }
      self.overlay.normalModePending = ""
      self.normalModePendingCommandToken &+= 1
      self.performMappedCommand(pending.command, repeatCount: pending.repeatCount)
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
    if pendingHintCommitBehavior == .copyURL {
      if let url = hint.target.url {
        NormalModeDispatcher.copy(url)
      }
      overlay.hide()
      currentHints = []
      currentPrefix = ""
      sourceAppPID = nil
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
      pendingHintCommitBehavior = .click
      activationGen &+= 1
      applyModeOverlay()
      return
    }

    let action = pendingAction
    let shouldEnterInsertAfterCommit =
      flashMode == .normal
      && Self.hintCommitShouldEnterInsertMode(hint.target)
    let shouldRestoreNormalMode = flashMode == .normal && !shouldEnterInsertAfterCommit
    // The target carries its owning pid (always the focused app at
    // walk time). Fall back to the activation-time focused pid if the
    // provider didn't set one.
    let pid = hint.target.pid ?? sourceAppPID
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
    } else if shouldEnterInsertAfterCommit {
      enterInsertMode(reason: .hintCommit, showFocusIndicator: false)
    }
    overlay.hide()
    // Restore focus to the target app before dispatching, so AXPress / the
    // synthesized click both reach the intended window.
    if let pid, let app = NSRunningApplication(processIdentifier: pid) {
      app.activate()
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
    pendingHintCommitBehavior = .click
    if shouldEnterInsertAfterCommit {
      applyModeOverlay()
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

  static func hintCommitShouldEnterInsertMode(_ target: JumpTarget) -> Bool {
    if target.providerID == "tmux" { return true }
    guard let role = target.role else { return false }
    return editableHintTargetRoles.contains(role)
  }

  private func usesTmuxProvider(_ context: AppContext?) -> Bool {
    guard let context else { return false }
    return registry.chain(for: context).contains { $0.identifier == "tmux" }
  }

  func overlayDidHandleMapping(_ event: NSEvent) -> Bool {
    mappings.handle(event: event)
  }

  func overlayDidCancelHelp() {
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidCancelCommandLine() {
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    clearAppFinderState()
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidUpdateCommandLine(
    _ command: String,
    cursorIndex: Int,
    resetSelection: Bool
  ) {
    if resetSelection {
      appFinderSelectedIndex = 0
    }
    refreshCommandLine(text: command, cursorIndex: cursorIndex)
  }

  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool {
    guard NormalModeDispatcher.commandLineOpenAppQuery(overlay.commandLineText) != nil else {
      return false
    }
    guard !appFinderMatches.isEmpty else {
      refreshCommandLine(
        text: overlay.commandLineText,
        cursorIndex: overlay.commandLineCursorIndex)
      return true
    }
    appFinderSelectedIndex = min(
      max(appFinderSelectedIndex + delta, 0),
      appFinderMatches.count - 1)
    refreshCommandLine(
      text: overlay.commandLineText,
      cursorIndex: overlay.commandLineCursorIndex)
    return true
  }

  func overlayDidSubmitCommandLine(_ command: String) {
    submitCommandLine(command)
  }

  func overlayDidCancelAppFinder() {
    clearAppFinderState()
    overlay.hide()
    applyModeOverlay()
  }

  func overlayDidUpdateAppFinderQuery(_ query: String) {
    appFinderSelectedIndex = 0
    refreshAppFinder(query: query)
  }

  func overlayDidMoveAppFinderSelection(_ delta: Int) {
    guard !appFinderMatches.isEmpty else {
      refreshAppFinder(query: overlay.appFinderQuery)
      return
    }
    appFinderSelectedIndex = min(
      max(appFinderSelectedIndex + delta, 0),
      appFinderMatches.count - 1)
    refreshAppFinder(query: overlay.appFinderQuery)
  }

  func overlayDidSubmitAppFinder() {
    guard !appFinderMatches.isEmpty else {
      overlayDidCancelAppFinder()
      return
    }
    let candidate = appFinderMatches[min(appFinderSelectedIndex, appFinderMatches.count - 1)]
      .candidate
    openAppFinderCandidate(candidate)
  }

  private func openAppFinderCandidate(_ candidate: AppFinderCandidate) {
    overlay.hide()
    clearAppFinderState()

    switch candidate.kind {
    case .app:
      openAppCandidate(candidate)
    case .tmuxWindow:
      openTmuxWindowCandidate(candidate)
    case .browserTab, .slackChannel:
      openAXElementCandidate(candidate)
    }
  }

  private func openAppCandidate(_ candidate: AppFinderCandidate) {
    if let pid = candidate.pid {
      normalModeTargetPID = pid
      suppressEditableFocus(for: pid)
      applyModeOverlay(captureOverride: true)
      if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [.activateAllWindows])
      }
      scheduleNormalModeRecapture()
    } else if let url = candidate.url {
      applyModeOverlay(captureOverride: true)
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
        DispatchQueue.main.async {
          guard let self else { return }
          if let app {
            self.normalModeTargetPID = app.processIdentifier
            self.suppressEditableFocus(for: app.processIdentifier)
          } else if let error {
            FlashLog.warn("[app_finder] could not open \(url.path): \(error.localizedDescription)")
          }
          self.scheduleNormalModeRecapture()
        }
      }
    }
  }

  private func openTmuxWindowCandidate(_ candidate: AppFinderCandidate) {
    if let pid = candidate.pid {
      normalModeTargetPID = pid
      suppressEditableFocus(for: pid)
      if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [.activateAllWindows])
      }
    }
    if let tmux = Self.tmuxPath, let target = candidate.tmuxTarget {
      var args = ["switch-client"]
      if let tty = candidate.tmuxClientTTY {
        args.append(contentsOf: ["-c", tty])
      }
      args.append(contentsOf: ["-t", target])
      appFinderCacheQueue.async { [weak self] in
        _ = self?.runShell(tmux, args)
      }
    }
    applyModeOverlay(captureOverride: true)
    scheduleNormalModeRecapture()
  }

  private func openAXElementCandidate(_ candidate: AppFinderCandidate) {
    if let pid = candidate.pid {
      normalModeTargetPID = pid
      suppressEditableFocus(for: pid)
      if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [.activateAllWindows])
      }
    }
    if let element = candidate.targetElement {
      if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
        _ = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
      }
    }
    applyModeOverlay(captureOverride: true)
    scheduleNormalModeRecapture()
  }

  private func runShell(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  private func axStringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return value as? String
  }

  private func axElementArrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let values = raw as? [AXUIElement]
    else { return [] }
    return values
  }

  private static func isAncestor(_ ancestor: pid_t, of descendant: pid_t) -> Bool {
    var current = descendant
    var hops = 0
    while current > 1, hops < 64 {
      if current == ancestor { return true }
      guard let parent = parentPID(of: current), parent != current else {
        return false
      }
      current = parent
      hops += 1
    }
    return false
  }

  private static func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
    }
    guard result == Int32(size) else { return nil }
    return pid_t(info.pbi_ppid)
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
    // `configureProviders` re-applies these on every activation
    // walk so a hot-reload of the config also propagates without
    // needing to touch `FlashLog` from two places.
    FlashLog.setLevel(cfg.debug.logLevel)
    FlashLog.setMirrorToFile(cfg.debug.dumpLogs)
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
    monitor.updateConfig(cfg)
    modeBadgeEnabled = hasNormalModeBinding(cfg)
    if !modeBadgeEnabled, flashMode == .normal {
      enterInsertMode(
        reason: .advancedModeDisabled,
        force: true,
        showFocusIndicator: false)
    }
    applyModeOverlay()
    // Push native mappings too — the Carbon hotkey registry rebuilds
    // from scratch each call, so add/remove/edit all converge atomically.
    mappings.apply(mode: cfg.mode)
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

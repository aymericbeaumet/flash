import AppKit
import ApplicationServices
import FlashCore

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
  private var config = Config.default
  private var registry: ProviderRegistry!
  private var monitor: AppMonitor!
  private var overlay: OverlayPanel!
  private var urlHandler: URLEventHandler!
  private var configSources: [DispatchSourceFileSystemObject] = []
  private let shortcuts = ShortcutsCoordinator()

  private var currentHints: [AssignedHint] = []
  private var currentPrefix: String = ""
  private var pendingAction: JumpAction = .leftClick
  private var sourceAppPID: pid_t?
  private var workspaceTokens: [NSObjectProtocol] = []
  private var resignKeyToken: NSObjectProtocol?
  /// Set while an activation walk is in flight on the AX queue. New URL
  /// events that arrive during this window are dropped, not queued. Same
  /// guard rejects re-entry if hints are already on screen.
  private var activationInFlight: Bool = false
  /// Bumped on every `activate(rightClick:)` *and* every `cancelOverlay()`.
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

  func applicationDidFinishLaunching(_ notification: Notification) {
    config = ConfigLoader.load()
    registry = ProviderRegistry()
    monitor = AppMonitor(registry: registry, config: config)
    monitor.start()

    overlay = OverlayPanel()
    overlay.coordinator = self
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    // Pay the layer-allocation cost at launch instead of on the first
    // activation. 256 covers the steady state for most apps; further
    // growth uses the regular dequeue/alloc fallback.
    overlay.warmPool(count: 256)

    let dispatch: (URLCommand) -> Void = { [weak self] cmd in
      guard let self else { return }
      switch cmd {
      case .showHints(let right): self.activate(rightClick: right)
      case .dismissHints: self.cancelOverlay()
      case .quit: NSApp.terminate(nil)
      case .openApp(let name): AppLauncher.activate(target: name)
      case .moveWindow(let params): WindowMover.move(params)
      }
    }
    urlHandler = URLEventHandler(handler: dispatch)
    shortcuts.start(dispatch: dispatch)

    watchConfigFile()
    logPermissionState()
    installDismissObservers()
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
      self.cancelOverlay()
    }
    let activeSpace = nc.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.cancelOverlay() }
    workspaceTokens = [appSwitch, activeSpace]

    resignKeyToken = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: overlay,
      queue: .main
    ) { [weak self] _ in
      // Only dismiss if hints are actually showing — resignKey also fires
      // when hide() is invoked, which would otherwise create a loop.
      guard let self, !self.currentHints.isEmpty else { return }
      self.cancelOverlay()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  // MARK: Activation

  private func activate(rightClick: Bool) {
    let profiler = FlashProfiler(kind: "activation", debug: config.debug)
    profiler.mark("url", detail: "right_click=\(rightClick)")

    // Cancel any in-flight walk and clear any visible hints. The
    // earlier "drop on busy" behaviour rejected the new trigger; the
    // user-facing rule now is "the most recent show_hints wins" —
    // pressing the hotkey again while hints are up restarts from
    // scratch (cancel current, kick off a fresh walk on the now-
    // focused window). cancelOverlay() bumps activationGen, so any
    // in-flight discoverAsync completion will see a stale generation
    // and bail before rendering.
    let wasBusy = activationInFlight || !currentHints.isEmpty
    if wasBusy {
      cancelOverlay()
      profiler.mark(
        "restart",
        detail: "in_flight=\(activationInFlight) visible_hints=\(currentHints.count)")
    }

    let contextStart = profiler.intervalStart()
    guard let context = monitor.currentContext() else {
      profiler.finish(outcome: "no_context")
      return
    }
    profiler.finishInterval(
      "current_context",
      since: contextStart,
      detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)"
    )
    sourceAppPID = context.processID
    pendingAction = rightClick ? .rightClick : .leftClick

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
      return
    }
    profiler.finishInterval("accessibility_check", since: permissionStart, detail: "trusted=true")

    activationGen &+= 1
    let myGen = activationGen
    activationInFlight = true
    monitor.discoverAsync(context: context, profiler: profiler) { [weak self] hints in
      guard let self else { return }
      self.activationInFlight = false
      // The walk is done; gate is open for the next activation
      // regardless of whether *this* walk's result is still relevant.
      guard self.activationGen == myGen else {
        profiler.finish(
          outcome: "stale_generation",
          detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
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
        } else {
          profiler.finish(
            outcome: "no_targets",
            detail: "pid=\(context.processID) bundle=\(context.bundleIdentifier)")
        }
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
    }
  }

  private func isAccessibilityTrusted() -> Bool {
    if cachedAccessibilityTrusted { return true }
    let trusted = PermissionCheck.isAccessibilityTrusted
    if trusted { cachedAccessibilityTrusted = true }
    return trusted
  }

  private func cancelOverlay() {
    // The fast no-op exit: dismissal observers fire on every app switch,
    // including when no overlay is up. Skip the layer-recycle churn when
    // there's nothing to dismiss.
    if currentHints.isEmpty && !activationInFlight { return }
    overlay.hide()
    currentHints = []
    currentPrefix = ""
    sourceAppPID = nil
    // Invalidate any in-flight discovery walk's right to render. We
    // *don't* clear `activationInFlight` here — the walk is still
    // running on the AX queue and clearing the flag would let a fresh
    // activation arrive and race with the previous walk's completion.
    // Once the walk does complete, it checks the generation and bails.
    activationGen &+= 1
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

  // MARK: OverlayCoordinator

  func overlayDidCancel() {
    cancelOverlay()
  }

  func overlayDidCommit(prefix: String) {
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
      commit(hint: m)
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

  private func commit(hint: AssignedHint) {
    let action = pendingAction
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
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
      _ = ActionDispatcher.perform(action, on: hint.target, pid: pid, clickPoint: clickPoint)
      self?.activationInFlight = false
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
  ///     run users start without `~/.config/flash/config.toml`, and
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
    // unparsable hotkeys logged by `shortcuts.apply`).
    // `configureProviders` re-applies these on every activation
    // walk so a hot-reload of the config also propagates without
    // needing to touch `FlashLog` from two places.
    FlashLog.setLevel(cfg.debug.logLevel)
    FlashLog.setMirrorToFile(cfg.debug.dumpLogs)
    for warning in cfg.warnings {
      FlashLog.warn("[config] \(warning)")
    }
    overlay.overlayConfig = cfg.overlay
    overlay.debugConfig = cfg.debug
    monitor.updateConfig(cfg)
    // Push the new shortcut set in too — the Carbon hotkey registry
    // rebuilds from scratch each call, so add/remove/edit all
    // converge atomically.
    shortcuts.apply(shortcuts: cfg.shortcuts)
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

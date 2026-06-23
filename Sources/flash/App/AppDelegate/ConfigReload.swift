import AppKit
import FlashCore
import FlashProviders

/// Hot-reload pipeline for `flash.toml`. The file watcher fires
/// `reloadConfig()`, which (re)parses, validates, applies the new
/// config to every subsystem, and shows an alert if parsing failed.
extension AppDelegate {
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
  func watchConfigFile() {
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
    // Re-resolve the login-shell environment off the main thread so a user who
    // changed their shell rc files (new PATH entry, mise plugin, …) and then
    // touched the config picks the change up without restarting Flash.
    DispatchQueue.global(qos: .userInitiated).async {
      FlashProcessEnvironment.shared.refresh()
    }
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
    overlay.normalModeSequenceTimeoutMs = cfg.mode.sequenceTimeoutMs
    statusBarController?.updateTemplate(cfg.statusBar.template)
    registry.updateOpenConfig(cfg.open)
    pluginManager.updateConfig(cfg)
    pluginManager.emit(
      PluginEvent(
        name: "core:config.changed",
        payload: ["resolved": cfg.resolvedConfigJSON],
        bundleID: nil,
        configPath: "*",
        focused: nil))
    configureDebugServer(for: cfg)
    invalidateCandidateFinderCaches(reason: "config_reload", refreshApps: true)
    monitor.updateConfig(cfg)
    // The status bar's visibility is an explicit, standalone config switch —
    // it is NOT derived from advanced mode. `[statusbar] enabled` alone
    // decides whether the bar (and its reserved screen space) appears.
    statusBarVisible = cfg.statusBar.enabled
    applySystemStatusBarSpaceReservation(enabled: statusBarVisible)
    if statusBarVisible {
      statusBarController?.start()
    } else {
      statusBarController?.stop()
      overlay.setStatusRightText("")
    }
    // Advanced mode is on iff an `enter_normal_mode` binding exists. Turning it
    // off drops to a non-capturing insert; the reducer re-renders either way.
    dispatchMode(.advancedModeChanged(enabled: hasNormalModeBinding(cfg)))
    applyModeOverlay()
    // Recompute the effective mappings (config defaults + plugin mappings)
    // for the frontmost app and push them to both the overlay and the Carbon
    // hotkey registry. The new config invalidates every cached effective mode;
    // the registry rebuilds from scratch, so add/remove/edit converge atomically.
    invalidateEffectiveMappings()
    refreshEffectiveMappings(
      for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  /// Plugins emit a state notification on every log line, heartbeat, and
  /// snapshot. Coalesce a burst into a single status/debug refresh. Candidate
  /// surfaces deliberately do not re-render from plugin-state churn; their
  /// typed-query update points are explicit so rows do not reshuffle while
  /// the prompt is idle.
  func pluginStateDidChange() {
    pluginStateRefreshWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.statusBarController?.refreshPluginSections()
      self.debugServer?.broadcastState()
    }
    pluginStateRefreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
  }

  func pluginSnapshotsDidChange(pluginID: String) {
    let affectsDefault = pluginManager.snapshotAffectsDefaultFlashlight(pluginID: pluginID)
    let targetWork = affectsDefault ? candidateFinderPrewarmWork : candidateFinderStandardPrewarmWork
    targetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let now = Date()
      let hasCache =
        self.candidateFinderPreparedRunningCache != nil
        || self.candidateFinderPreparedAllCache != nil
      if affectsDefault {
        if hasCache, let last = self.candidateFinderLastPluginSnapshotPrewarmAt,
          now.timeIntervalSince(last) < 1.0
        {
          return
        }
        self.candidateFinderLastPluginSnapshotPrewarmAt = now
      } else {
        if hasCache, let last = self.candidateFinderLastStandardPluginSnapshotPrewarmAt,
          now.timeIntervalSince(last) < 15.0
        {
          FlashLog.trace(
            "[candidate_finder] snapshot_prewarm_deferred plugin=\(pluginID)")
          return
        }
        self.candidateFinderLastStandardPluginSnapshotPrewarmAt = now
      }
      self.prewarmCandidateFinderCaches(reason: "plugin_snapshot:\(pluginID)", force: true)
    }
    if affectsDefault {
      candidateFinderPrewarmWork = work
    } else {
      candidateFinderStandardPrewarmWork = work
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
  }

  func configureDebugServer(for cfg: Config) {
    guard cfg.debug.httpInspectorEnabled else {
      debugServer?.stop()
      debugServer = nil
      return
    }
    let host = cfg.debug.httpInspectorHost
    let port = cfg.debug.httpInspectorPort
    if debugServer?.host == host, debugServer?.port == port {
      debugServer?.broadcastState()
      return
    }
    debugServer?.stop()
    let server = DebugServer(
      host: host,
      port: port,
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
    let snapshots = pluginManager.statusSnapshots()
    var commands = NormalModeDispatcher.coreCommandCatalog()
    for snapshot in snapshots {
      for command in snapshot.commands {
        commands.append([
          "name": ":\(command.command) \(command.subcommand)",
          "syntax": ":\(command.command) \(command.subcommand)",
          "command": command.command,
          "subcommand": command.subcommand,
          "description": command.description,
          "source": snapshot.id,
          "source_kind": "plugin",
        ])
      }
    }
    return [
      "config": configJSON,
      "commands": commands,
      "focused_app": [
        "bundle_id": app?.bundleIdentifier ?? NSNull(),
        "localized_name": app?.localizedName ?? NSNull(),
        "pid": focusedPID,
      ],
      "mode": "\(flashMode)",
      "overlay": String(describing: overlay?.inputMode),
      "plugins": snapshots.map(\.jsonObject),
    ]
  }

  func selectInitialModeIfNeeded() {
    guard !selectedInitialMode else { return }
    selectedInitialMode = true
    dispatchMode(.startup(advancedEnabled: hasNormalModeBinding(config)))
  }

  func applySystemStatusBarSpaceReservation(enabled: Bool) {
    let current = NSApp.presentationOptions
    let updated = Self.systemStatusBarSpaceReservationPresentationOptions(
      current: current,
      enabled: enabled)
    let changed = updated != current
    if changed {
      NSApp.presentationOptions = updated
    }
    FlashLog.debug("[statusbar] system_menu_bar_reservation enabled=\(enabled) changed=\(changed)")
  }

  static func systemStatusBarSpaceReservationPresentationOptions(
    current: NSApplication.PresentationOptions,
    enabled: Bool
  ) -> NSApplication.PresentationOptions {
    var options = current
    if enabled {
      options.remove(.autoHideMenuBar)
    }
    return options
  }

  private func showConfigErrorAlertIfNeeded(for cfg: Config) {
    guard let message = cfg.loadingErrorAlertMessage else {
      lastConfigErrorAlertMessage = nil
      if configErrorAlertVisible {
        configErrorAlertVisible = false
        overlay.dismissAlert()
      }
      return
    }
    guard message != lastConfigErrorAlertMessage else { return }
    lastConfigErrorAlertMessage = message
    configErrorAlertVisible = true
    overlay.displayAlert(message, duration: 8, style: .error)
  }

  func logPermissionState() {
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

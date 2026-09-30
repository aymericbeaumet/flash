import AppKit
import Carbon.HIToolbox
import FlashCore

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
      environment: ProcessInfo.processInfo.environment)
    var watchedDirs = Set<String>()
    for url in candidates {
      attachWatcher(forPath: url.path)
      let dir = url.deletingLastPathComponent().path
      if watchedDirs.insert(dir).inserted {
        attachWatcher(forPath: dir)
      }
    }
    // Re-arming the watchers above is always needed (the inode may have been
    // replaced); re-applying the config is not when its bytes are unchanged.
    let contents = try? Data(
      contentsOf: ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment))
    if let lastAppliedConfigFileContents, contents == lastAppliedConfigFileContents {
      FlashLog.trace("[config] reload_skipped reason=unchanged")
      return
    }
    lastAppliedConfigFileContents = contents
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
      self?.scheduleConfigReload()
    }
    configSources.append(source)
  }

  /// One editor save produces a burst of vnode events (write, extend, attrib,
  /// rename of the temp file, …). Coalesce the burst into a single trailing
  /// re-watch + reload instead of one synchronous reload per event.
  private func scheduleConfigReload() {
    configReloadWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.configReloadWork = nil
      self.watchConfigFile()
    }
    configReloadWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
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
    MainThreadActivity.note("config_reload")
    // Re-resolve the login-shell environment off the main thread so a user who
    // changed their shell rc files (new PATH entry, mise plugin, …) and then
    // touched the config picks the change up without restarting Flash.
    // Popups whose command could not start retry once it lands.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      FlashProcessEnvironment.shared.refresh()
      DispatchQueue.main.async { self?.overlay.statusTerminals.retryFailedLaunches() }
    }
    let cfg = ConfigLoader.load()
    if hintSession.isActive || activationInFlight { cancelOverlay() }
    let previousAutostart = config.app.autostart
    // Rebuild the frecency store only when its tuning actually changed —
    // reconstruction reloads the on-disk snapshot, which is fine but not
    // worth doing on every unrelated reload.
    let frecencyTuningChanged =
      cfg.flashlight.frecencyHalfLifeDays != config.flashlight.frecencyHalfLifeDays
      || cfg.flashlight.frecencyMaxBoost != config.flashlight.frecencyMaxBoost
    config = cfg
    FlashTunables.apply(cfg)
    if frecencyTuningChanged {
      frecencyStore = FrecencyStore(
        configuration: FrecencyStore.Configuration(
          halfLifeDays: cfg.flashlight.frecencyHalfLifeDays,
          maxBoost: cfg.flashlight.frecencyMaxBoost))
    }
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
    FlashLog.debug(
      "[config] resolved warnings=\(cfg.warnings.count) "
        + "configured_plugins=\(cfg.plugins.settings.count)")
    FlashLog.debug("[config] resolved_hints_keys=\(cfg.resolvedHintsKeysJSON)")
    showConfigErrorAlertIfNeeded(for: cfg)
    // Menu-bar icon and login-item registration both reconcile from the
    // config on every load — the TOML file is the single source of truth
    // for both (defaults: visible + autostart).
    statusItemController.apply(enabled: cfg.app.menuBarIcon)
    // SMAppService status/register is an XPC round trip; reconcile once at
    // startup and afterwards only when the setting changes.
    if !autoLaunchReconciled || cfg.app.autostart != previousAutostart {
      autoLaunchReconciled = true
      AutoLaunch.reconcile(enabled: cfg.app.autostart)
    }
    overlay.overlayConfig = cfg.overlay
    overlay.debugConfig = cfg.debug
    overlay.popupStyle = cfg.popupStyle
    overlay.modeLabels = cfg.mode.labels
    overlay.magicModifiers = ClickModifiers(names: cfg.effectiveMagicModifiers)
    overlay.normalModeSequenceTimeoutMs = cfg.mode.sequenceTimeoutMs
    // Rebuilt on every load: the setting may have changed, and so may the
    // installed layouts an explicit input-source ID names.
    keyboardLayoutMonitor.apply(setting: KeyboardLayout.Setting(cfg.app.keyboardLayout) ?? .auto)
    statusBarController?.updateTemplate(
      cfg.statusBar.template,
      popupTemplates: cfg.textPopups,
      sources: cfg.statusBar.sources,
      terminalPopupNames: cfg.terminalPopupNames,
      refreshIntervalSeconds: cfg.statusBar.refreshIntervalSeconds)
    statusBarController?.setBar(enabled: cfg.statusBar.enabled)
    statusBarController?.updateWidgets(cfg.enabledWidgets.mapValues(\.spec))
    registry.updateFlashlightConfig(cfg.flashlight)
    pluginManager.updateConfig(cfg)
    pluginManager.emit(
      PluginEvent(
        name: "core:config.changed",
        payload: [:],
        bundleID: nil))
    configureDebugServer(for: cfg)
    // Refresh the running-app set so the next flashlight open reflects any
    // ignored-app changes; candidates themselves are pulled live on open.
    registry.scheduleRunningApplicationsRefresh()
    monitor.updateConfig(cfg)
    // The status bar's visibility is an explicit, standalone config switch —
    // it is NOT derived from advanced mode. `[statusbar] enabled` alone
    // decides whether the bar (and its reserved screen space) appears.
    statusBarVisible = cfg.statusBar.enabled
    overlay.statusBarMonitor = cfg.statusBar.monitor
    NativeMenuBarAutoHide.reconcile(hidden: statusBarVisible)
    windowLayoutManager.setDeclaredLayouts(cfg.mode.declaredWindowLayouts)
    windowLayoutManager.screenParametersDidChange(
      statusBarReservesSpace: statusBarVisible,
      statusBarMonitor: cfg.statusBar.monitor,
      forceRecovery: false)
    // The status controller runs for the bar and for desktop widgets alike.
    if statusBarVisible || !cfg.enabledWidgets.isEmpty {
      statusBarController?.start()
    } else {
      statusBarController?.stop()
    }
    widgetController?.apply(
      widgets: cfg.enabledWidgets, statusBarReservesSpace: statusBarVisible,
      statusBarMonitor: cfg.statusBar.monitor, screenCapture: cfg.overlay.screenCapture)
    // Advanced mode is on iff an all-mode exit or normal-entry binding exists. Turning it
    // off disables capture; the reducer re-renders either way.
    dispatchMode(.advancedModeChanged(enabled: hasNormalModeBinding(cfg)))
    applyModeOverlay()
    // Recompute the effective mappings (config defaults + plugin mappings)
    // for the frontmost app and push them to both the overlay and the Carbon
    // hotkey registry. The new config invalidates every cached effective mode;
    // the registry rebuilds from scratch, so add/remove/edit converge atomically.
    invalidateEffectiveMappings()
    refreshEffectiveMappings(
      for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    reloadTerminalPopupConfiguration()
  }

  /// Plugins emit a state notification on every log line, lifecycle
  /// transition, and publish. Coalesce a burst into a single status refresh;
  /// the inspector coalesces its own push. Candidate
  /// surfaces deliberately do not re-render from plugin-state churn; their
  /// typed-query update points are explicit so rows do not reshuffle while
  /// the prompt is idle.
  func pluginStateDidChange() {
    debugStateDidChange()
    pluginStateRefreshWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.reconcileClipboardMonitor()
      self.reconcileHostEventSources()
      self.statusBarController?.refreshPluginSections()
    }
    pluginStateRefreshWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
  }

  func selectInitialModeIfNeeded() {
    guard !selectedInitialMode else { return }
    selectedInitialMode = true
    dispatchMode(.startup(advancedEnabled: hasNormalModeBinding(config)))
  }

  private func showConfigErrorAlertIfNeeded(for cfg: Config) {
    guard let message = cfg.loadingErrorAlertMessage else {
      if let shown = shownConfigError {
        shownConfigError = nil
        overlay.dismissToast(token: shown.toastToken)
      }
      return
    }
    guard message != shownConfigError?.message else { return }
    overlay.displayAlert(message, duration: 8, style: .error)
    shownConfigError = ShownConfigError(message: message, toastToken: overlay.toastToken)
  }
}

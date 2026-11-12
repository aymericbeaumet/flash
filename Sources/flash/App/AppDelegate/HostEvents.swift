import AppKit
import FlashCore

/// Every host event goes out once, here, to every subscriber: the plugins
/// whose manifest `listen` admits it, the `[monitors]` whose `event` does,
/// and the socket clients subscribed to it (`IPCEventHub`). One catalog
/// (`PluginProtocol.hostEvents`), one fan-out, so a hook in the
/// configuration and a script hear exactly what a plugin hears.
extension AppDelegate {
  func emitHostEvent(_ event: PluginEvent) {
    pluginManager.emit(event)
    fireEventMonitors(event)
    ipcEvents.publish(event)
  }

  /// Whether a plugin, an event monitor or a socket client subscribes to
  /// `name`: what keeps the OS source behind a host event running.
  func hostEventHasSubscriber(_ name: String) -> Bool {
    pluginManager.hasListener(for: name) || ipcEvents.hasSubscriber(for: name)
      || eventMonitors.values.contains { $0.listens(to: name) }
  }

  /// Whether a plugin or a socket client hears every `event`: unlike an
  /// event monitor, which names its times and thresholds, they take the
  /// defaults (every minute, the 300 s idle threshold).
  func hostEventHasClientListener(_ event: HostEvent) -> Bool {
    pluginManager.hasListener(for: event) || ipcEvents.hasSubscriber(for: event.rawValue)
  }

  /// `core:mode.changed`, when the mode's name changed and something listens.
  func emitModeChanged(from previous: Mode, to next: Mode) {
    let mode = FlashStatusReport.modeName(next)
    let before = FlashStatusReport.modeName(previous)
    guard mode != before, hostEventHasSubscriber(HostEvent.modeChanged.rawValue) else { return }
    emitHostEvent(PluginEvent(.modeChanged, payload: ["mode": mode, "previous": before]))
  }

  /// The session's first labels are on screen: `core:hints.shown`, once.
  func announceHintSession(surface: String, targets: Int) {
    guard hintSession.shownSurface == nil else { return }
    hintSession.shownSurface = surface
    guard hostEventHasSubscriber(HostEvent.hintsShown.rawValue) else { return }
    emitHostEvent(PluginEvent(.hintsShown, payload: ["surface": surface, "targets": targets]))
  }

  /// The session committed a target: `core:hints.committed`, never which.
  func noteHintCommitted() {
    guard let surface = hintSession.shownSurface else { return }
    hintSession.committed = true
    guard hostEventHasSubscriber(HostEvent.hintsCommitted.rawValue) else { return }
    emitHostEvent(PluginEvent(.hintsCommitted, payload: ["surface": surface]))
  }

  /// A shown session is ending: `core:hints.cancelled` unless it committed.
  func noteHintSessionEnding(_ session: HintSession) {
    guard let surface = session.shownSurface, !session.committed,
      hostEventHasSubscriber(HostEvent.hintsCancelled.rawValue)
    else { return }
    emitHostEvent(PluginEvent(.hintsCancelled, payload: ["surface": surface]))
  }

  /// A value monitor rose into warning or error: `core:monitor.triggered`,
  /// with its name and level, never its value.
  func emitMonitorTriggered(_ name: String, _ level: MonitorLevel) {
    guard hostEventHasSubscriber(HostEvent.monitorTriggered.rawValue) else { return }
    emitHostEvent(
      PluginEvent(.monitorTriggered, payload: ["monitor": name, "level": level.rawValue]))
  }

  private func fireEventMonitors(_ event: PluginEvent) {
    for name in eventMonitors.keys.sorted() {
      guard let spec = eventMonitors[name], spec.matches(event) else { continue }
      FlashLog.info("[monitors] event name=\(name) event=\(event.name)")
      if let message = spec.message {
        if spec.alerts { presentMonitorAlert(.message(message)) }
        if spec.notifies {
          notifyMonitor(name, title: MonitorText.displayName(name), body: message, error: false)
        }
      }
      runMonitor(name, environment: MonitorEnvironment.event(event, monitor: name))
    }
  }

  /// A value monitor rose, or changed: run its `run`.
  func monitorDidFire(_ fire: MonitorFire) {
    runMonitor(fire.monitor, environment: MonitorEnvironment.value(fire))
  }

  /// A monitor's `run`: its steps in order, through `MonitorRunner`, one
  /// run at a time per monitor and none within its cooldown.
  private func runMonitor(_ name: String, environment: [String: String]) {
    guard let monitor = config.monitors[name], !monitor.run.isEmpty else { return }
    monitorRunner.start(
      name, steps: monitor.run, environment: environment, timeoutSeconds: monitor.timeout,
      cooldownSeconds: monitor.cooldown)
  }

  /// One step, answered on main: a Flash command in process, as a mapping
  /// runs it; an executable with Flash's login environment and `environment`
  /// beside it, waited for and bounded by `timeout`. Returns how to stop an
  /// executable before it answers; a Flash command runs to its end.
  func performMonitorStep(
    _ step: MappingCommand, environment: [String: String], timeout: TimeInterval,
    completion: @escaping (MonitorStepResult, String) -> Void
  ) -> ((String) -> Void)? {
    switch step {
    case .flashCommand(let command):
      performMappedCommand(command) { outcome in
        switch outcome {
        case .performed, .chordSent: completion(.succeeded, "")
        case .failed, .unavailable, .noTarget, .refused: completion(.commandFailed, "")
        }
      }
      return nil
    case .shellCommand(let argv):
      let merged = FlashProcessEnvironment.shared.environment.merging(
        environment, uniquingKeysWith: { _, extra in extra })
      let handle = MonitorProcess.run(argv, environment: merged, timeout: timeout) {
        result, output in
        DispatchQueue.main.async { completion(result, output) }
      }
      return handle.map { handle in { reason in handle.cancel(reason: reason) } }
    }
  }

  /// A run failed: one alert naming the step and why; the output is in the
  /// log and on the monitors page.
  func monitorRunFailed(_ name: String, _ record: MonitorRunRecord) {
    presentMonitorAlert(
      StatusAlert(
        title: "\(MonitorText.displayName(name)) run failed",
        value: "\(record.failedCommand ?? "") \(record.reason ?? "")", style: .warning))
  }

  /// The monitors page's entries for the event monitors and the runs of the
  /// value ones, beside the status controller's snapshots.
  func monitorsJSON() -> [[String: Any]] {
    var entries = monitorSnapshots.map { snapshot -> [String: Any] in
      var object = snapshot.jsonObject
      object["kind"] = "value"
      runFields(snapshot.id, into: &object)
      return object
    }
    for name in config.monitors.keys.sorted() {
      guard let monitor = config.monitors[name], !monitor.event.isEmpty else { continue }
      entries.append([
        "id": name,
        "name": MonitorText.displayName(name),
        "origin": Config.defaultMonitors[name] == nil ? "config" : "default",
        "kind": "event",
        "enabled": monitor.enabled && monitor.problem == nil,
        "event": monitor.event,
        "app": monitor.app.isEmpty ? NSNull() : monitor.app,
        "usb": monitor.usb.map(Config.usbFilterJSON) ?? NSNull(),
        "message": monitor.message,
        "state": "ok",
      ])
      runFields(name, into: &entries[entries.count - 1])
    }
    return entries
  }

  /// A monitor's steps, how often they ran since launch, when last (across
  /// restarts) and how that run went.
  private func runFields(_ name: String, into object: inout [String: Any]) {
    let monitor = config.monitors[name]
    object["run"] =
      monitor.map { $0.run.isEmpty ? NSNull() : $0.run.map(\.argv) as Any } ?? NSNull()
    object["timeout_s"] = monitor?.timeout ?? MonitorRunDefaults.timeoutSeconds
    object["cooldown_s"] = monitor?.cooldown ?? 0
    object["runs"] = monitorRunner.counts[name] ?? 0
    object["last_run_ms"] = monitorRunner.lastStart(of: name) as Any? ?? NSNull()
    object["last_run"] = monitorRunner.records[name]?.jsonObject as Any? ?? NSNull()
  }
}

/// The host events Flash observes for nobody but its subscribers: sleep
/// and wake, the displays sleeping and waking, the lock screen, a display
/// connected or removed, and the active Space. Workspace and distributed
/// notifications, delivered on main; each emits only while something listens.
final class SystemEventObservers {
  private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
  private var displays: [CGDirectDisplayID: String] = SystemEventObservers.currentDisplays()

  func start(emit: @escaping (PluginEvent) -> Void) {
    guard tokens.isEmpty else { return }
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let signals: [(NotificationCenter, Notification.Name, HostEvent)] = [
      (workspace, NSWorkspace.willSleepNotification, .systemSlept),
      (workspace, NSWorkspace.didWakeNotification, .systemWoke),
      (workspace, NSWorkspace.screensDidSleepNotification, .displaysSlept),
      (workspace, NSWorkspace.screensDidWakeNotification, .displaysWoke),
      (workspace, NSWorkspace.activeSpaceDidChangeNotification, .spaceChanged),
      (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
      (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
    ]
    for (center, notification, event) in signals {
      let token = center.addObserver(forName: notification, object: nil, queue: .main) { _ in
        emit(PluginEvent(event))
      }
      tokens.append((center, token))
    }
    let screens = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let change = self.displayChange() else { return }
      emit(PluginEvent(.displaysChanged, payload: change))
    }
    tokens.append((NotificationCenter.default, screens))
    // Foundation caches the system time zone until it is reset: without
    // this, `calendar next`, `calendar join` and every other reader of
    // `TimeZone.current` would keep the old zone whatever the bar shows. The
    // status controller re-renders on the same notification.
    let zone = NotificationCenter.default.addObserver(
      forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
    ) { _ in NSTimeZone.resetSystemTimeZone() }
    tokens.append((NotificationCenter.default, zone))
  }

  func stop() {
    for (center, token) in tokens { center.removeObserver(token) }
    tokens.removeAll()
  }

  /// The displays connected or removed since the last look; nil when the
  /// set is the same (a resolution or arrangement change).
  private func displayChange() -> [String: Any]? {
    let now = Self.currentDisplays()
    guard let change = Self.displayChange(from: displays, to: now) else { return nil }
    displays = now
    return change
  }

  static func displayChange(
    from previous: [CGDirectDisplayID: String], to current: [CGDirectDisplayID: String]
  ) -> [String: Any]? {
    let added = current.keys.filter { previous[$0] == nil }.compactMap { current[$0] }.sorted()
    let removed = previous.keys.filter { current[$0] == nil }.compactMap { previous[$0] }.sorted()
    guard !added.isEmpty || !removed.isEmpty else { return nil }
    return ["added": added, "removed": removed, "displays": current.values.sorted()]
  }

  private static func currentDisplays() -> [CGDirectDisplayID: String] {
    var displays: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { continue }
      displays[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
    }
    return displays
  }
}

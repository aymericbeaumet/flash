import AppKit
import FlashCore

/// The inspector snapshot's configuration-only parts.
struct InspectorConfigSnapshot {
  let config: Any
  let sources: [String: Any]
  let mappingRows: [[String: String]]
}

/// The HTTP inspector's app state: what `/api/state` and the `/api/events`
/// stream carry, and the changes that push it. The inspector has no clock;
/// `DebugServer.stateDidChange` coalesces a burst of these into one snapshot,
/// taken only while someone can read it.
extension AppDelegate {
  /// Every change the state reflects calls this (main thread); a no-op while
  /// the inspector is off. A change that can move only some sections names
  /// them, so the snapshot it causes rebuilds no more than that.
  func debugStateDidChange(_ scope: DebugServer.StateScope = .all) {
    debugServer?.stateDidChange(scope)
  }

  func configureDebugServer(for cfg: Config) {
    guard cfg.debug.httpInspectorEnabled else { return stopDebugServer() }
    let host = cfg.debug.httpInspectorHost
    let port = cfg.debug.httpInspectorPort
    if debugServer?.host == host, debugServer?.port == port {
      debugStateDidChange()
      return
    }
    startDebugServer(host: host, port: port)
  }

  /// Start the inspector on `host:port`, replacing any running one.
  func startDebugServer(host: String, port: Int) {
    stopDebugServer()
    let server = DebugServer(
      host: host, port: port, accessToken: helpAccessToken,
      clipboardHTTP: { [weak self] method, id, completion in
        guard let self else {
          completion(
            "503 Service Unavailable", "text/plain; charset=utf-8", Data("unavailable".utf8))
          return
        }
        self.serveClipboardHTTP(method: method, id: id, completion: completion)
      },
      clipboardPinHTTP: { [weak self] pinned, id, completion in
        guard let self else {
          completion(
            "503 Service Unavailable", "application/json; charset=utf-8", Data("{}".utf8))
          return
        }
        self.serveClipboardPinHTTP(pinned: pinned, id: id, completion: completion)
      },
      clipboardHistoryHTTP: { [weak self] offset, completion in
        guard let self else {
          completion(
            "503 Service Unavailable", "application/json; charset=utf-8", Data("{}".utf8))
          return
        }
        self.serveClipboardHistoryHTTP(offset: offset, completion: completion)
      },
      configHTTP: { [weak self] method, purge, body, completion in
        guard let self else {
          completion(
            "503 Service Unavailable", "application/json; charset=utf-8",
            Self.configJSON(["error": "unavailable"]))
          return
        }
        self.serveConfigHTTP(method: method, purge: purge, body: body, completion: completion)
      },
      telemetryHTTP: { [telemetryStore] in telemetryStore.snapshotJSON() },
      sectionsProvider: { [weak self] sections in
        self?.debugStateJSON(sections: sections) ?? [:]
      },
      stateProvider: { [weak self] in
        self?.debugStateJSON() ?? [:]
      }
    )
    attachDebugServer(server)
    server.start()
  }

  /// `GET /api/config` reads the file Flash loaded. `PUT` replaces it after
  /// the body parses as TOML. `POST /api/config/purge` returns the editor
  /// text with bundled defaults removed and does not write.
  func serveConfigHTTP(
    method: String, purge: Bool, body: Data,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    let type = "application/json; charset=utf-8"
    DispatchQueue.main.async { [weak self] in
      guard self != nil else {
        completion("503 Service Unavailable", type, Self.configJSON(["error": "unavailable"]))
        return
      }
      let url = ConfigLoader.resolvePath(environment: ProcessInfo.processInfo.environment)
      switch (method, purge) {
      case ("GET", false):
        let toml = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        completion("200 OK", type, Self.configJSON(["path": url.path, "toml": toml]))
      case ("PUT", false):
        guard let text = String(data: body, encoding: .utf8) else {
          completion(
            "400 Bad Request", type, Self.configJSON(["error": "configuration must be UTF-8"]))
          return
        }
        if let error = ConfigPurge.tomlError(in: text) {
          completion("400 Bad Request", type, Self.configJSON(["error": error]))
          return
        }
        do {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
          completion(
            "500 Internal Server Error", type,
            Self.configJSON(["error": "could not write configuration"]))
          return
        }
        completion("200 OK", type, Self.configJSON(["ok": true]))
      case ("POST", true):
        guard let text = String(data: body, encoding: .utf8) else {
          completion(
            "400 Bad Request", type, Self.configJSON(["error": "configuration must be UTF-8"]))
          return
        }
        guard let defaults = ConfigLoader.embeddedDefaultLayer()?.text else {
          completion(
            "503 Service Unavailable", type,
            Self.configJSON(["error": "bundled defaults are unavailable"]))
          return
        }
        let toml = ConfigPurge.purgeDefaults(in: text, defaults: defaults)
        completion("200 OK", type, Self.configJSON(["toml": toml]))
      default:
        completion(
          "405 Method Not Allowed", type, Self.configJSON(["error": "method not allowed"]))
      }
    }
  }

  private static func configJSON(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      ?? Data("{}".utf8)
  }

  func serveClipboardHistoryHTTP(
    offset: Int,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completion("503 Service Unavailable", "application/json; charset=utf-8", Data("{}".utf8))
        return
      }
      self.clipboardHistoryStore.page(offset: offset) { [weak self] page in
        let type = "application/json; charset=utf-8"
        guard let page, let self else {
          completion("503 Service Unavailable", type, Data("{}".utf8))
          return
        }
        self.clipboardImageMimes.remember(page.entries, offset: offset)
        // A page carries up to its byte budget of text: encode it off main.
        DispatchQueue.global(qos: .userInitiated).async {
          guard let data = try? JSONEncoder().encode(page) else {
            return completion("503 Service Unavailable", type, Data("{}".utf8))
          }
          completion("200 OK", type, data)
        }
      }
    }
  }

  /// `GET /api/clipboard/<id>` returns that entry's image. `DELETE` removes
  /// the entry from the core history and from this cache.
  func serveClipboardHTTP(
    method: String, id: String,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completion(
          "503 Service Unavailable", "text/plain; charset=utf-8", Data("unavailable".utf8))
        return
      }
      switch method {
      case "GET":
        self.readClipboardImage(id: id, completion: completion)
      case "DELETE":
        self.deleteClipboardHistoryEntry(id: id, completion: completion)
      default:
        completion(
          "405 Method Not Allowed", "text/plain; charset=utf-8", Data("method not allowed".utf8))
      }
    }
  }

  private func readClipboardImage(
    id: String,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    guard
      let mime = clipboardImageMimes.mime(for: id),
      let url = ClipboardImageStore.fileURL(dataDir: Self.clipboardDataDir(), id: id, mime: mime)
    else {
      completion("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
      return
    }
    DispatchQueue.global(qos: .utility).async {
      guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        completion("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        return
      }
      completion("200 OK", mime, data)
    }
  }

  private func deleteClipboardHistoryEntry(
    id: String,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    clipboardHistoryStore.delete(id: id) { [weak self] ok in
      guard let self else {
        completion(
          "503 Service Unavailable", "text/plain; charset=utf-8", Data("unavailable".utf8))
        return
      }
      guard ok else {
        completion("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        return
      }
      self.clipboardEntries.removeAll { $0.id == id }
      self.clipboardImageMimes.remove(id)
      self.refreshClipboardDashboardCache()
      completion("200 OK", "application/json; charset=utf-8", Data("{\"ok\":true}".utf8))
    }
  }

  /// `PUT /api/clipboard/<id>/pin` pins the entry, `DELETE` unpins it: 404
  /// for no such entry, 409 with the reason when pins would fill the history.
  func serveClipboardPinHTTP(
    pinned: Bool, id: String,
    completion: @escaping (_ status: String, _ contentType: String, _ body: Data) -> Void
  ) {
    let type = "application/json; charset=utf-8"
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completion("503 Service Unavailable", type, Self.configJSON(["error": "unavailable"]))
        return
      }
      self.clipboardHistoryStore.setPinned(id: id, pinned) { result in
        switch result {
        case .changed, .unchanged:
          completion("200 OK", type, Self.configJSON(["ok": true]))
        case .missing:
          completion("404 Not Found", type, Self.configJSON(["error": "not found"]))
        case .full(let capacity):
          completion(
            "409 Conflict", type,
            Self.configJSON(["error": Self.clipboardPinsFullMessage(capacity)]))
        case .failed:
          completion(
            "500 Internal Server Error", type,
            Self.configJSON(["error": "could not write clipboard history"]))
        }
      }
    }
  }

  static func clipboardDataDir() -> URL {
    ClipboardHistoryStore.defaultDirectory()
  }

  /// The components whose changes the state reads report them here; wired
  /// once at launch, and a no-op while the inspector is off.
  ///
  /// The status bar republishes as its values change, several times a second
  /// with a clock or a graph on it: its snapshot rebuilds only the bar and
  /// the popup anchors it places, not the mappings, commands and plugins.
  func wireInspectorChangeSources() {
    overlay.statusBarDidChange = { [weak self] in
      self?.debugStateDidChange(.sections(Self.statusBarSections))
    }
    overlay.statusPopupController.didChange = { [weak self] in
      self?.debugStateDidChange(.sections(["terminals"]))
    }
    widgetController?.didChange = { [weak self] in
      self?.debugStateDidChange(.sections(["widgets"]))
    }
  }

  /// What a status bar publish can move: the bar, and the popup anchors it lays out.
  static let statusBarSections: Set<String> = ["statusbar", "terminals"]

  /// Adopt `server` along with the observers only the inspector needs.
  func attachDebugServer(_ server: DebugServer) {
    debugServer = server
    inspectorChangeObservers = InspectorChangeObservers { [weak self] in
      self?.debugStateDidChange()
    }
  }

  func stopDebugServer() {
    inspectorChangeObservers?.invalidate()
    inspectorChangeObservers = nil
    debugServer?.stop()
    debugServer = nil
  }

  /// The inspector's app state. Each field is pushed by the change that
  /// moves it, never by a clock:
  ///
  /// | Field | Pushed by |
  /// | --- | --- |
  /// | `snapshot_at_unix_ms` | Stamped on each snapshot |
  /// | `runtime.version`, `build`, `pid`, `started_at_unix_ms`, `config_path` | Fixed for the process (uptime is derived client-side) |
  /// | `runtime.accessibility_trusted` | The system's Accessibility trust-list notification; the grant starting the tap |
  /// | `runtime.keyboard_capture_active`, `secure_input` | The tap installing (`keyboardCaptureTap`); `noteSecureInput` |
  /// | `runtime.advanced_mode`, `mode`, `overlay` | `applyModeOverlay`; `refreshOverlayInputRouting` |
  /// | `runtime.config_error`, `config`, `config_sources`, `docs` | Config reload (`configureDebugServer`); plugin state for plugin topics |
  /// | `commands`, `plugins` | `pluginStateDidChange` (lifecycle, status publishes, logs, reloads) |
  /// | `mappings` | Config reload, focus, plugin state, `refreshEffectiveMappings` applying a new table |
  /// | `focused_app` | Workspace activation, including Flash's own; `applyFocusedApplicationChange` |
  /// | `hints`, `hint_command`, `hint_session`, `activation_in_flight` | `hintSession`; `activationLifecycle` |
  /// | `keyboard` | Config reload (layout, alphabet, grid keys); `hintSession` (what the keys do now) |
  /// | `clipboard` | `clipboardEntries` (the core clipboard history page) |
  /// | `statusbar`, `terminals`, `widgets` | Status model publishes and menu-bar yielding; popup presentation and terminal sessions; widget placement; their windows' notifications (below) |
  /// | `monitors` | `monitorsDidChange`: a monitor evaluated to a new value, message or state, alerted, or its definition changed |
  /// | `telemetry` | `configureTelemetry`; the receiver's and exporter's status changes and each received request (`TelemetryStatePush`, one push per main turn) |
  /// | `windows` | Flash's windows moving, resizing, ordering in or out, changing screen or key status, or closing; the active Space |
  ///
  /// Plugin `memory_bytes` and `cpu_time_ms` and the status bar's in-flight
  /// animation opacities have no change notification: they are sampled with
  /// every snapshot and on an explicit `/api/state?refresh=1`.
  ///
  /// Built on main, so the snapshot names itself to the watchdog and logs
  /// its cost (`[latency] inspector_snapshot`), and carries previews rather
  /// than values: clipboard text, HTML and plugin command lists live behind
  /// their own endpoints and the top-level `commands`.
  ///
  /// With `sections`, only those (and the snapshot's time) are rebuilt, for
  /// a change that named them; the server keeps the rest of the last
  /// snapshot, plugin samples included.
  func debugStateJSON(sections: Set<String>? = nil) -> [String: Any] {
    MainThreadActivity.note("inspector_snapshot")
    let startedAt = DispatchTime.now()
    let state = sections.map(buildDebugStateSections) ?? buildDebugStateJSON()
    let elapsedMs =
      Double(DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds) / 1_000_000
    FlashLog.trace(
      String(format: "[latency] inspector_snapshot ms=%.1f", elapsedMs),
      fields: [
        "sections": sections.map { $0.sorted().joined(separator: ",") } ?? "all",
        "clipboard": "\(clipboardEntries.count)",
        "plugins": "\((state["plugins"] as? [Any])?.count ?? 0)",
        "mappings": "\(((state["mappings"] as? [String: Any])?["rows"] as? [Any])?.count ?? 0)",
      ])
    return state
  }

  /// The sections a scoped change names, built as the whole snapshot builds
  /// them. Any other name rebuilds the whole state: a section is never
  /// silently left out.
  private func buildDebugStateSections(_ sections: Set<String>) -> [String: Any] {
    var state: [String: Any] = [
      "snapshot_at_unix_ms": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    for section in sections {
      switch section {
      case "statusbar": state[section] = overlay?.statusBarDiagnostics() ?? [:]
      case "terminals": state[section] = statusTerminalDebugState()
      case "widgets": state[section] = widgetController?.diagnostics() ?? [:]
      default: return buildDebugStateJSON()
      }
    }
    return state
  }

  /// The core command catalog is built from static tables: once.
  static let inspectorCoreCommands = NormalModeDispatcher.coreCommandCatalog()

  /// What a snapshot derives from the configuration alone — about half of
  /// a snapshot's own cost — built once per `config`, whose assignment
  /// drops it.
  func inspectorConfigSnapshot() -> InspectorConfigSnapshot {
    if let cached = inspectorConfigCache { return cached }
    let json: Any
    if let data = config.resolvedConfigJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    {
      json = object
    } else {
      json = config.resolvedConfigJSON
    }
    let snapshot = InspectorConfigSnapshot(
      config: json, sources: config.resolvedConfigSources(),
      mappingRows: NormalModeDispatcher.mappingsJSON(mode: config.mode))
    inspectorConfigCache = snapshot
    return snapshot
  }

  private func buildDebugStateJSON() -> [String: Any] {
    let configSnapshot = inspectorConfigSnapshot()
    let app = NSWorkspace.shared.frontmostApplication
    let focusedPID: Any = app.map { Int($0.processIdentifier) } ?? NSNull()
    let mappingApp = currentNonFlashRunningApplication() ?? app
    let mappingContext = PluginSelectorContext(bundleID: mappingApp?.bundleIdentifier)
    let effectiveMappings = effectiveMode(for: mappingContext)
    // Before launch wiring (tests) there is no monitor or registry to ask.
    let registry: SourceRegistry? = self.registry
    let appContext = mappingApp.flatMap { app in monitor.flatMap { $0.makeContext(for: app) } }
    let commandRows = Self.commandResolutionRows(
      resolutions: pluginManager.commandBindingResolutions(in: mappingContext)
    ) { name in
      guard let registry, let appContext else { return [] }
      return registry.claimants(of: name, in: appContext)
    }
    let bundleInfo = Bundle.main.infoDictionary ?? [:]
    let secureInput = secureInputObserved
    let statuses = pluginManager.pluginStatuses()
    var commands = Self.inspectorCoreCommands
    for status in statuses {
      for command in status.commands {
        commands.append([
          "name": ":\(command.command) \(command.subcommand)",
          "syntax": ":\(command.command) \(command.subcommand)",
          "command": command.command,
          "subcommand": command.subcommand,
          "description": command.description,
          "source": status.id,
          "source_kind": "plugin",
        ])
      }
    }
    // The manual comes from the bundle (`/api/docs`); the snapshot carries
    // only the plugins' own help topics, as raw Markdown the browser renders
    // at `/docs/<topic>`.
    let docs = HelpDocs.pluginTopics(
      pluginManager.pluginHelpTopics(), reserved: manualTopicNames
    ).map { topic -> [String: Any] in
      [
        "name": topic.name,
        "title": topic.title,
        "summary": topic.summary,
        "body": topic.body,
      ]
    }
    return [
      "snapshot_at_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
      "runtime": [
        "version": bundleInfo["CFBundleShortVersionString"] as? String ?? "development",
        "build": bundleInfo["CFBundleVersion"] as? String ?? "unknown",
        "pid": ProcessInfo.processInfo.processIdentifier,
        "started_at_unix_ms": Int64(runtimeStartedAt.timeIntervalSince1970 * 1000),
        "accessibility_trusted": PermissionCheck.isAccessibilityTrusted,
        "keyboard_capture_active": keyboardCaptureTap != nil && !secureInput,
        "secure_input": secureInput,
        "advanced_mode": modeBadgeEnabled,
        "config_path": ConfigLoader.resolvePath(
          environment: ProcessInfo.processInfo.environment
        ).path,
        "config_error": config.loadingErrorAlertMessage as Any? ?? NSNull(),
      ] as [String: Any],
      "config": configSnapshot.config,
      "config_sources": configSnapshot.sources,
      "commands": commands,
      "clipboard": clipboardEntries.map(Self.clipboardStateObject),
      "clipboard_registers": registers.snapshot().map { entry in
        ["name": entry.name, "text": entry.text, "kind": entry.kind, "truncated": entry.truncated]
      },
      "clipboard_total": clipboardTotal,
      "clipboard_next_offset": clipboardNextOffset as Any? ?? NSNull(),
      "docs": docs,
      "mappings": [
        "normal_leader": config.mode.normalLeader ?? "",
        "rows": configSnapshot.mappingRows,
        "effective_rows": NormalModeDispatcher.mappingsJSON(mode: effectiveMappings),
        "commands": commandRows,
        "bundle_id": mappingApp?.bundleIdentifier as Any? ?? NSNull(),
        "localized_name": mappingApp?.localizedName as Any? ?? NSNull(),
      ] as [String: Any],
      "focused_app": [
        "bundle_id": app?.bundleIdentifier ?? NSNull(),
        "localized_name": app?.localizedName ?? NSNull(),
        "pid": focusedPID,
      ],
      // A layer by its own name, as `flash resident status` reports it.
      "mode": modeStore.mode.layer?.name ?? String(describing: modeStore.mode.label),
      "hint_session": FlashStatusReport.hintSessionPhase(
        route: hintSession.keyRoute, active: hintSession.isActive,
        discovering: activationInFlight),
      "keyboard": keyboardStateJSON(),
      "hints": hintSession.hints.map { hint -> [String: Any] in
        [
          "label": hint.label,
          "accessibility_label": hint.target.accessibilityLabel ?? "",
          "role": hint.target.role ?? "",
          "text_input": hint.target.isTextInput,
          "frame": [
            "x": hint.target.frame.origin.x,
            "y": hint.target.frame.origin.y,
            "width": hint.target.frame.width,
            "height": hint.target.frame.height,
          ],
        ]
      },
      "hint_command": String(describing: hintSession.command),
      "activation_in_flight": activationInFlight,
      "terminals": statusTerminalDebugState(),
      "overlay": overlay.map { String(describing: $0.inputMode) } as Any? ?? NSNull(),
      "statusbar": overlay?.statusBarDiagnostics() ?? [:],
      "widgets": widgetController?.diagnostics() ?? [:],
      "windows": NSApp.windows.map { window -> [String: Any] in
        [
          "class": String(describing: type(of: window)),
          "frame": [
            Double(window.frame.minX), Double(window.frame.minY), Double(window.frame.width),
            Double(window.frame.height),
          ],
          "visible": window.isVisible,
          "level": window.level.rawValue,
          "number": window.windowNumber,
        ]
      },
      "plugins": statuses.map(\.jsonObject),
      "monitors": monitorsJSON(),
      "telemetry": telemetryStateJSON(),
    ]
  }
}

extension AppDelegate {
  /// One row per binding key for the focused app, in the order dispatch
  /// tries them: `claimed_by` lists the sources (and Flash's own step) that
  /// get first try, then `binding` is what runs otherwise and `source` who
  /// declared it — a plugin id, `flash` for Flash's own scrolling, or null
  /// when nothing happens.
  static func commandResolutionRows(
    resolutions: [(CommandBindingKey, CommandBindingIndex.Resolution)],
    claimants: (CommandName) -> [String]
  ) -> [[String: Any]] {
    let byKey = Dictionary(resolutions, uniquingKeysWith: { first, _ in first })
    let windowClose = CommandName("window", "close")
    return URLEventHandler.sourceCommandBindingKeys.map { key in
      var claimedBy = claimants(key.name).map {
        "source:" + ($0.hasPrefix("plugin:") ? String($0.dropFirst("plugin:".count)) : $0)
      }
      if key.name == windowClose { claimedBy.append("flash:close_button") }
      var binding: Any = NSNull()
      var source: Any = NSNull()
      if let resolution = byKey[key] {
        binding = resolution.spec.display
        source = resolution.pluginID
      } else if key.flags.isEmpty, let flashOwned = SourceCommandFallback.flashOwned[key.name] {
        binding = flashOwned.inspectorDescription
        source = "flash"
      }
      return [
        "command": key.description, "binding": binding, "source": source,
        "claimed_by": claimedBy,
      ]
    }
  }
}

extension SourceCommandFallback {
  /// Flash's own step as the inspector names it.
  fileprivate var inspectorDescription: String {
    switch self {
    case .scroll(let kind): return "scroll \(kind)"
    case .scrollEdge(let kind): return "scroll to \(kind)"
    case .binding(let binding): return "\(binding)"
    case .none: return "none"
    }
  }
}

extension HintSession {
  /// Whether the inspector's `hints` and `hint_command` read the same for
  /// both sessions. Typing a label prefix changes neither.
  func showsSameInspectorState(as other: HintSession) -> Bool {
    command == other.command && keyRoute == other.keyRoute && hints.count == other.hints.count
      && zip(hints, other.hints).allSatisfy { new, old in
        new.label == old.label && new.target.frame == old.target.frame
          && new.target.role == old.target.role
          && new.target.accessibilityLabel == old.target.accessibilityLabel
          && new.target.isTextInput == old.target.isTextInput
      }
  }
}

/// Changes to state no Flash owner reports: its windows moving, resizing,
/// ordering in or out (occlusion), changing screen or key status, or closing;
/// the active Space; and the system's Accessibility trust list. Registered
/// only while the inspector's server runs.
final class InspectorChangeObservers: NSObject {
  private let changed: () -> Void
  private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

  init(changed: @escaping () -> Void) {
    self.changed = changed
    super.init()
    let windowNotifications: [Notification.Name] = [
      NSWindow.didMoveNotification, NSWindow.didResizeNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.willCloseNotification,
    ]
    for name in windowNotifications {
      observe(name, in: .default)
    }
    observe(NSWorkspace.activeSpaceDidChangeNotification, in: NSWorkspace.shared.notificationCenter)
    // AppKit suspends distributed delivery while an accessory app is inactive.
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(accessibilityTrustListDidChange(_:)),
      name: AppDelegate.accessibilityTrustListDidChangeNotification, object: nil,
      suspensionBehavior: .deliverImmediately)
  }

  deinit { invalidate() }

  func invalidate() {
    for (center, token) in tokens { center.removeObserver(token) }
    tokens.removeAll()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  private func observe(_ name: Notification.Name, in center: NotificationCenter) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [changed] _ in
      changed()
    }
    tokens.append((center, token))
  }

  /// The notification can precede the trust database it announces, so the
  /// state is pushed on the next turn and once more shortly after.
  @objc func accessibilityTrustListDidChange(_ note: Notification) {
    for delayMs in AppDelegate.accessibilityGrantCheckDelaysMs {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
        [changed] in changed()
      }
    }
  }
}

extension AppDelegate {
  /// The keyboard page's model: the physical layout `[keyboard] layout`
  /// names, the hint alphabet with each key's ease, the grid block, the zone
  /// rows of `label_order = "zones"`, and the navigation keys. What the keys
  /// do right now comes from `mode`, `hint_session` and `mappings`.
  func keyboardStateJSON() -> [String: Any] {
    let layoutName = config.positionLayoutName
    let layout = Alphabet.layouts[layoutName]
    let resolved = config.resolvedAlphabet
    let navigation = Alphabet.navigation(layoutName: layoutName)
    return [
      "layout": layoutName,
      "rows": (layout?.physical ?? []).map { String($0) },
      "alphabet": String(resolved.chars),
      "key_scores": Dictionary(
        uniqueKeysWithValues: resolved.chars.map { (String($0), resolved.keyScores[$0] ?? 0) }),
      "grid_keys": config.resolvedMouseGridKeys.map { String($0) },
      "label_order": config.hints.labelOrder.rawValue,
      "zone_rows": HintLabelOrdering.zoneRows(
        alphabet: resolved.chars, keyRows: resolved.keyRows, keyColumns: resolved.keyColumns
      ).map { String($0) },
      "navigation": [
        "left": String(navigation.left), "down": String(navigation.down),
        "up": String(navigation.up), "right": String(navigation.right),
        "quadrants": navigation.quadrants.map { String($0) },
      ],
      "adjust_digits": config.hints.adjustDigits.rawValue,
      "held_button": ActionDispatcher.heldButton?.rawValue as Any? ?? NSNull(),
    ]
  }
}

import AppKit
import FlashCore

/// The HTTP inspector's app state: what `/api/state` and the `/api/events`
/// stream carry, and the changes that push it. The inspector has no clock;
/// `DebugServer.stateDidChange` coalesces a burst of these into one snapshot,
/// taken only while someone can read it.
extension AppDelegate {
  /// Every change the state reflects calls this (main thread); a no-op while
  /// the inspector is off.
  func debugStateDidChange() {
    debugServer?.stateDidChange()
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
    let server = DebugServer(host: host, port: port) { [weak self] in
      self?.debugStateJSON() ?? [:]
    }
    attachDebugServer(server)
    server.start()
  }

  /// The components whose changes the state reads report them here; wired
  /// once at launch, and a no-op while the inspector is off.
  func wireInspectorChangeSources() {
    overlay.statusBarDidChange = { [weak self] in self?.debugStateDidChange() }
    overlay.statusPopupController.didChange = { [weak self] in self?.debugStateDidChange() }
    widgetController?.didChange = { [weak self] in self?.debugStateDidChange() }
  }

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
  /// | `runtime.config_error`, `config`, `docs` | Config reload (`configureDebugServer`); plugin state for plugin topics |
  /// | `commands`, `plugins` | `pluginStateDidChange` (lifecycle, status publishes, logs, reloads) |
  /// | `mappings` | Config reload, focus, plugin state, `refreshEffectiveMappings` applying a new table |
  /// | `focused_app` | Workspace activation, including Flash's own; `applyFocusedApplicationChange` |
  /// | `hints`, `hint_command`, `activation_in_flight` | `hintSession`; `activationLifecycle` |
  /// | `clipboard` | `clipboardEntries` (the clipboard plugin's history reply) |
  /// | `statusbar`, `terminals`, `widgets` | Status model publishes and menu-bar yielding; popup presentation and terminal sessions; widget placement; their windows' notifications (below) |
  /// | `windows` | Flash's windows moving, resizing, ordering in or out, changing screen or key status, or closing; the active Space |
  ///
  /// Plugin `memory_bytes` and `cpu_time_ms` and the status bar's in-flight
  /// animation opacities have no change notification: they are sampled with
  /// every snapshot and on an explicit `/api/state?refresh=1`.
  func debugStateJSON() -> [String: Any] {
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
    let mappingApp = currentNonFlashRunningApplication() ?? app
    let mappingContext = PluginSelectorContext(bundleID: mappingApp?.bundleIdentifier)
    let effectiveMappings = effectiveMode(for: mappingContext)
    // Before launch wiring (tests) there is no monitor or registry to ask.
    let registry: SourceRegistry? = self.registry
    let appContext = mappingApp.flatMap { app in monitor.flatMap { $0.makeContext(for: app) } }
    let actionRows = Self.actionResolutionRows(
      resolutions: pluginManager.actionBindingResolutions(in: mappingContext)
    ) { action in
      guard let registry, let appContext else { return [] }
      return registry.claimants(of: action, in: appContext)
    }
    let bundleInfo = Bundle.main.infoDictionary ?? [:]
    let secureInput = secureInputObserved
    let statuses = pluginManager.pluginStatuses()
    var commands = NormalModeDispatcher.coreCommandCatalog()
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
    // Docs are Markdown in `HelpTopic.body`; the inspector's Docs tab renders
    // them (and `:help [topic]` deep-links there). Ship the raw Markdown so the
    // browser owns rendering, collapsibles, and topic navigation.
    let docs = HelpDocs.allTopics(
      config: config,
      showModes: modeBadgeEnabled,
      pluginTopics: pluginManager.pluginHelpTopics()
    ).map { topic -> [String: Any] in
      [
        "name": topic.name,
        "title": topic.title,
        "summary": topic.summary,
        "body": topic.body,
        "aliases": topic.aliases,
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
      "config": configJSON,
      "commands": commands,
      "clipboard": clipboardEntries.map { ["preview": $0.preview, "value": $0.value] },
      "docs": docs,
      "mappings": [
        "normal_leader": config.mode.normalLeader ?? "",
        "rows": NormalModeDispatcher.mappingsJSON(mode: config.mode),
        "effective_rows": NormalModeDispatcher.mappingsJSON(mode: effectiveMappings),
        "actions": actionRows,
        "bundle_id": mappingApp?.bundleIdentifier as Any? ?? NSNull(),
        "localized_name": mappingApp?.localizedName as Any? ?? NSNull(),
      ] as [String: Any],
      "focused_app": [
        "bundle_id": app?.bundleIdentifier ?? NSNull(),
        "localized_name": app?.localizedName ?? NSNull(),
        "pid": focusedPID,
      ],
      "mode": String(describing: modeStore.mode.label),
      "hints": hintSession.hints.map { hint -> [String: Any] in
        [
          "label": hint.label,
          "accessibility_label": hint.target.accessibilityLabel ?? "",
          "role": hint.target.role ?? "",
          "enters_insert_mode": hint.target.entersInsertMode,
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
    ]
  }
}

extension AppDelegate {
  /// One row per action for the focused app, in the order dispatch tries
  /// them: `claimed_by` lists the sources (and Flash's own step) that get
  /// first try, then `binding` is what runs otherwise and `source` who
  /// declared it — a plugin id, `flash` for Flash's own scrolling, or null
  /// when nothing happens.
  static func actionResolutionRows(
    resolutions: [(SourceActionName, ActionBindingIndex.Resolution)],
    claimants: (SourceAction) -> [String]
  ) -> [[String: Any]] {
    let byName = Dictionary(resolutions, uniquingKeysWith: { first, _ in first })
    return SourceActionName.allCases.map { name in
      let action =
        name == .appReloadForce ? .reload(force: true) : SourceAction.byWireName[name.rawValue]
      var claimedBy =
        action.map(claimants)?.map {
          "source:" + ($0.hasPrefix("plugin:") ? String($0.dropFirst("plugin:".count)) : $0)
        } ?? []
      if name == .windowClose { claimedBy.append("flash:close_button") }
      var binding: Any = NSNull()
      var source: Any = NSNull()
      if let resolution = byName[name] {
        binding = resolution.spec.display
        source = resolution.pluginID
      } else if let flashOwned = SourceActionFallback.flashOwned[name] {
        binding = flashOwned.inspectorDescription
        source = "flash"
      }
      return [
        "action": name.rawValue, "binding": binding, "source": source, "claimed_by": claimedBy,
      ]
    }
  }
}

extension SourceActionFallback {
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
    command == other.command && hints.count == other.hints.count
      && zip(hints, other.hints).allSatisfy { new, old in
        new.label == old.label && new.target.frame == old.target.frame
          && new.target.role == old.target.role
          && new.target.accessibilityLabel == old.target.accessibilityLabel
          && new.target.entersInsertMode == old.target.entersInsertMode
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

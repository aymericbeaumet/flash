import AppKit
import Carbon.HIToolbox
import Darwin
import FlashCore
import Foundation

/// The plugin→host RPC surface: routing, capability guards, and the
/// implementations of every native API plugins may reach (AX broker, app
/// activation, synthesized input, host-side fetch and AppleScript). Split from
/// PluginManager so the manager owns only the plugin set and its indexes.
final class PluginHostRPC {
  /// Owns the single AX (Accessibility) grant and the handle registry that
  /// backs the `host.ax_*` RPCs. Plugins never touch AX directly; they reach
  /// it through this broker via `handleHostRequest`. A test substitutes one
  /// whose trees are fixtures, before any plugin starts.
  var axBroker = AXBroker()
  var appleScriptRunner: (String, TimeInterval) -> AppleScriptOutput = AppleScriptRunner.run
  /// The browsers `host.applescript` serves: the engines manifests declare.
  var browserEngines: () -> BrowserEngineTable = { BrowserEngines.declared.table }

  /// `pid` quit: the AX handles plugins hold into it are dropped.
  func appTerminated(pid: pid_t) {
    axBroker.appTerminated(pid: pid)
  }
  /// Resolver for the `host.normal_mode_target` RPC: returns the focused
  /// non-Flash app context (pid + bundle id) the host considers the
  /// normal-mode target. Plugins (notably `screenshot`) call this to name the
  /// app and window the user was working on when they ran the command
  /// — `core:focus.changed` alone is insufficient because Flash itself is
  /// the focused process while normal mode is active. Set by AppDelegate
  /// during plugin setup.
  /// `windowID` is the frontmost window's WindowServer number — metadata, not
  /// pixels. A plugin needs it to name a window to a capture tool without
  /// making the user click one.
  var onNormalModeTargetRequested: (() -> (pid: pid_t, bundleID: String, windowID: CGWindowID?)?)?
  /// Executor for the `host.post_keys` RPC: posts a short synthesized chord
  /// sequence to a pid at the given interval. Set by AppDelegate so the
  /// posting can register each chord with the mappings dispatcher first
  /// (`noteSyntheticKey`) — a `postToPid` event can loop back through the
  /// Carbon hotkey path and re-trigger the user's own binding for the combo.
  var onSyntheticKeysRequested: ((pid_t, [(key: CGKeyCode, flags: CGEventFlags)], Int) -> Void)?
  /// Host-owned Location/CoreWLAN provider for `host.wifi_info`. Set by
  /// AppDelegate so plugins never access either framework directly.
  var wifiInfoProvider: WiFiInfoProviding?
  /// CoreAudio for `host.audio_devices`: plugins never reach it themselves.
  var audioDevices: any AudioDeviceProviding = CoreAudioDevices()
  /// Every CoreAudio call is a synchronous audio-server request, so they
  /// run here, in order, off the main thread and off the plugin's queue.
  private let audioQueue = DispatchQueue(label: "flash.plugins.audio", qos: .userInitiated)
  /// The mechanisms behind `host.system_action`: plugins never lock, sleep
  /// or restart the Mac themselves. Nil until the resident wires its own at
  /// launch (`LiveSystemActions`), and nil inside the test runner unless a
  /// test injects one: an unwired host refuses every action.
  var systemActions: (any SystemActionPerforming)?
  /// The mechanism behind `host.process_signal`: plugins never signal a
  /// process themselves. Nil until the resident wires its own at launch
  /// (`LiveProcessSignals`), and nil inside the test runner unless a test
  /// injects one: an unwired host refuses every signal.
  var processSignals: (any ProcessSignalling)?
  /// libproc behind `host.process_table`: plugins never read another
  /// process themselves, and no sandbox profile lets one. Nil until the
  /// resident wires its own at launch (over `LibprocKernel`), and nil inside
  /// the test runner unless a test injects one over a scripted kernel: an
  /// unwired host answers every call with a failure.
  var processTable: HostProcessTable?
  /// EventKit behind `host.calendar_events`: plugins never read the calendar
  /// themselves, and the Calendars grant stays Flash's. Nil until the
  /// resident wires its own at launch (over `LiveCalendarEvents`), and nil
  /// inside the test runner unless a test injects one over a stub: an
  /// unwired host answers every call with a failure.
  var calendarEvents: HostCalendarEvents?
  /// Notes, Reminders and Contacts behind `host.notes`, `host.reminders` and
  /// `host.contacts`: plugins never reach those apps or their frameworks
  /// themselves, and the grants stay Flash's. Empty until the resident
  /// wires its own at launch (over `LiveAppItems`), and empty inside the
  /// test runner unless a test injects one over a stub: an unwired kind
  /// answers every call with a failure.
  var appItems: [HostAppItemKind: HostAppItems] = [:]

  // Testability seams for the arms whose production bodies fire
  // irreversible side effects (LaunchServices open). Tests swap these to
  // assert the decoded, capability-checked, validated call without opening
  // browsers or apps; the defaults ARE the production behavior.
  static var urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  /// The bundle id of the app LaunchServices hands `url` to; nil when no
  /// application is registered for it, which is what `if_handled` asks.
  static var urlHandler: (URL) -> String? = { url in
    NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
  }
  static var appOpener: (String, @escaping (String?) -> Void) -> Void = { bundleID, done in
    ApplicationLauncher.open(bundleID: bundleID, completion: done)
  }

  /// Routes a plugin→host RPC request to the matching core capability and
  /// delivers the JSON result via `reply`. This is the single entry point
  /// through which plugins reach native APIs the core owns (the AX broker,
  /// app activation, …) — plugins never touch those APIs directly. `reply`
  /// may be called asynchronously; AX methods hop to the main thread first.
  func handleHostRequest(
    method: String,
    params: [String: Any],
    pluginID: String,
    capabilities: Set<PluginCapability>,
    fetchURLs: [String] = [],
    fetchLimits: PluginFetchLimits = .standard,
    appleEventsTargets: [String] = [],
    scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard scope.isCurrent() else { return }
    guard let kind = PluginHostRequest.Method(rawValue: method) else {
      FlashLog.warn(
        "[plugin] unknown host method \(method) from \(pluginID)",
        fields: ["method": method, "plugin": pluginID])
      reply(["ok": false, "error": PluginProtocol.unknownMethodError(method)])
      return
    }
    // The capability guard runs before any param is read.
    if let capability = kind.capability, !capabilities.contains(capability) {
      reply(["ok": false, "error": PluginProtocol.capabilityDeniedError(capability.rawValue)])
      return
    }
    let request: PluginHostRequest
    do {
      request = try PluginHostRequest(kind, params: params)
    } catch {
      reply(["ok": false, "error": error.message])
      return
    }
    switch request {
    case .ping:
      // Round-trip validation of the bidirectional channel.
      reply(["ok": true])
    case .normalModeTarget:
      scope.enqueue(on: .main) { [weak self] in
        guard let target = self?.onNormalModeTargetRequested?() else {
          reply(["ok": true, "present": false])
          return
        }
        var payload: [String: Any] = [
          "ok": true,
          "present": true,
          "pid": Int(target.pid),
          "bundle_id": target.bundleID,
        ]
        if let windowID = target.windowID { payload["window_id"] = Int(windowID) }
        reply(payload)
      }
    case .activate(let pid):
      activatePluginApp(pid: pid, scope: scope, reply: reply)
    case .postKeys(let pid, let chords, let intervalMs):
      postSyntheticKeys(
        pid: pid, chords: chords, intervalMs: intervalMs, scope: scope, reply: reply)
    case .ax(let request):
      axBroker.handle(request, pluginID: pluginID, scope: scope, reply: reply)
    case .fetch(let url, let text):
      hostFetch(
        url: url, text: text, allowlist: fetchURLs, limits: fetchLimits, pluginID: pluginID,
        scope: scope, reply: reply)
    case .wifiInfo(let requestAuthorization):
      guard let wifiInfoProvider else {
        reply(["ok": true, "present": false])
        return
      }
      scope.enqueue(on: .main) {
        wifiInfoProvider.fetchSSID(requestAuthorization: requestAuthorization) { ssid in
          guard let ssid else {
            reply(["ok": true, "present": false])
            return
          }
          reply(["ok": true, "present": true, "ssid": ssid])
        }
      }
    case .open(let target):
      hostOpen(target, scope: scope, reply: reply)
    case .audio(let operation):
      hostAudioDevices(operation, scope: scope, reply: reply)
    case .systemAction(let action):
      hostSystemAction(action, pluginID: pluginID, scope: scope, reply: reply)
    case .processSignal(let pid, let signal):
      hostProcessSignal(signal, pid: pid, pluginID: pluginID, scope: scope, reply: reply)
    case .processTable(let operation):
      hostProcessTable(operation, pluginID: pluginID, scope: scope, reply: reply)
    case .calendar(let operation):
      hostCalendarEvents(operation, pluginID: pluginID, scope: scope, reply: reply)
    case .appItems(let kind, let operation):
      hostAppItems(kind, operation, pluginID: pluginID, scope: scope, reply: reply)
    case .appleScript(let params):
      PluginHostAppleScript.handle(
        params, targets: appleEventsTargets, browsers: browserEngines(), pluginID: pluginID,
        scope: scope, runner: appleScriptRunner, reply: reply)
    }
  }

  /// `host.fetch`: perform an HTTPS GET on the plugin's behalf. The allowlist
  /// is the manifest's `fetch_urls` prefixes and the URLs its `fetch_settings`
  /// hold; the response is UTF-8 text within the plugin's limits (1 MiB and
  /// 8 s unless its `fetch_limits` say otherwise), and the request runs
  /// entirely off the main thread on URLSession's delegate queue with a hard
  /// timeout — a slow remote can never touch tap responsiveness. Telemetry
  /// stays content-free (no URL/body).
  var hostFetchConfiguration = URLSessionConfiguration.ephemeral

  /// True when `url` sits inside the allowlisted `prefix` at a URL component
  /// boundary. A raw hasPrefix would let "https://api.example.com" also admit
  /// "https://api.example.com.attacker.tld/".
  static func urlIsAllowed(_ url: String, byPrefix prefix: String) -> Bool {
    PluginHostFetch.urlIsAllowed(url, byPrefix: prefix)
  }

  private func hostFetch(
    url: URL, text: String, allowlist: [String], limits: PluginFetchLimits, pluginID: String,
    scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard allowlist.contains(where: { Self.urlIsAllowed(text, byPrefix: $0) }) else {
      reply(["ok": false, "error": PluginHostFetch.Failure.disallowedURL.message])
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = Double(limits.timeoutMs) / 1_000
    let startedAt = DispatchTime.now()
    PluginHostFetch.start(
      request: request, allowlist: allowlist, limits: limits,
      configuration: hostFetchConfiguration
    ) { result in
      guard scope.isCurrent() else { return }
      let elapsedMs = Int(
        Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
      guard case .success(let payload) = result else {
        FlashLog.warn(
          "[plugin] host.fetch failed elapsed_ms=\(elapsedMs)",
          fields: ["plugin": pluginID, "elapsed_ms": "\(elapsedMs)"])
        if case .failure(let error) = result {
          reply(["ok": false, "error": error.message])
        }
        return
      }
      let status = payload.status
      let data = payload.data
      guard let body = String(data: data, encoding: .utf8) else {
        reply(["ok": false, "error": "response is not UTF-8 text"])
        return
      }
      FlashLog.debug(
        "[plugin] host.fetch ok status=\(status) elapsed_ms=\(elapsedMs)",
        fields: [
          "plugin": pluginID, "status": "\(status)", "elapsed_ms": "\(elapsedMs)",
          "bytes": "\(data.count)",
        ])
      reply(["ok": true, "status": status, "body": body])
    }
  }

  /// `host.open`: hand a URL or bundle id to LaunchServices host-side, so
  /// plugins never fork `/usr/bin/open` and keep fork-free profiles. A URL
  /// reply names the app that handles it (`bundle_id`), so a plugin can check
  /// that app still has focus before acting on it. With `if_handled`, a URL
  /// no application is registered for is not handed over at all: a plugin
  /// tries an app's own link (`zoommtg:`) before the web one.
  private func hostOpen(
    _ target: PluginHostRequest.OpenTarget,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: .main) {
      switch target {
      case .url(let url, let ifHandled):
        if ifHandled, Self.urlHandler(url) == nil {
          reply(["ok": false, "error": Self.unhandledURLError])
          return
        }
        // Response law: ok:false always carries a non-empty, content-free
        // error (a bare {"ok": false} is a spec violation).
        if Self.urlOpener(url) {
          var result: [String: Any] = ["ok": true]
          result["bundle_id"] = Self.urlHandler(url)
          reply(result)
        } else {
          reply(["ok": false, "error": "open failed"])
        }
      case .app(let bundleID):
        Self.appOpener(bundleID) { error in
          if let error {
            reply(["ok": false, "error": error])
          } else {
            reply(["ok": true])
          }
        }
      }
    }
  }

  static let unhandledURLError = "no application opens the URL"

  /// `host.audio_devices`: one CoreAudio operation on the audio queue. A
  /// CoreAudio failure is the reply's error.
  private func hostAudioDevices(
    _ operation: PluginHostRequest.Audio, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    let devices = audioDevices
    scope.enqueue(on: audioQueue) {
      do {
        switch operation {
        case .list(let direction):
          reply([
            "ok": true,
            "devices": try devices.list(direction: direction).map {
              ["uid": $0.uid, "name": $0.name, "default": $0.isDefault] as [String: Any]
            },
          ])
        case .select(let direction, let uid):
          try devices.select(uid: uid, direction: direction)
          reply(["ok": true])
        case .stepVolume(let ticks):
          reply(["ok": true, "percent": try devices.stepOutputVolume(ticks: ticks)])
        case .toggleMute:
          reply(["ok": true, "muted": try devices.toggleOutputMute()])
        case .volume:
          let volume = try devices.outputVolume()
          reply(["ok": true, "percent": volume.percent, "muted": volume.muted])
        }
      } catch {
        reply(["ok": false, "error": error.localizedDescription])
      }
    }
  }

  /// `host.system_action`: one machine or session action, carried out by the
  /// host's mechanisms. A destructive one runs only inside a perform the
  /// user confirmed, which it claims: outside one, or once that perform's
  /// consent is spent, it is refused before anything is asked of macOS.
  private func hostSystemAction(
    _ action: HostSystemAction, pluginID: String, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let systemActions else {
      reply(["ok": false, "error": "system actions unavailable"])
      return
    }
    if action.isDestructive, !scope.claimConfirmedPerform() {
      FlashLog.warn(
        "[plugin] system action refused: no confirmed perform in flight",
        fields: ["plugin": pluginID, "action": action.rawValue])
      reply(["ok": false, "error": PluginProtocol.confirmationRequiredError])
      return
    }
    let execution = action.execution
    scope.enqueue(on: HostSystemActions.queue(for: execution)) {
      guard let failure = systemActions.perform(execution) else {
        FlashLog.info(
          "[plugin] system action", fields: ["plugin": pluginID, "action": action.rawValue])
        reply(["ok": true])
        return
      }
      FlashLog.warn(
        "[plugin] system action failed: \(failure)",
        fields: ["plugin": pluginID, "action": action.rawValue])
      reply(["ok": false, "error": failure])
    }
  }

  /// `host.process_signal`: one signal to one process. Every signal runs
  /// only inside a perform the user confirmed, which it claims: outside
  /// one, or once that perform's consent is spent, it is refused before the
  /// kernel is asked anything. The resident, launchd and process groups are
  /// refused whatever the user confirmed, and spend no consent.
  private func hostProcessSignal(
    _ signal: HostProcessSignal, pid: pid_t, pluginID: String, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let processSignals else {
      reply(["ok": false, "error": "process signals unavailable"])
      return
    }
    if let refusal = HostProcessSignals.refusal(of: pid) {
      FlashLog.warn(
        "[plugin] process signal refused: \(refusal)",
        fields: ["plugin": pluginID, "signal": signal.rawValue])
      reply(["ok": false, "error": refusal])
      return
    }
    guard scope.claimConfirmedPerform() else {
      FlashLog.warn(
        "[plugin] process signal refused: no confirmed perform in flight",
        fields: ["plugin": pluginID, "signal": signal.rawValue])
      reply(["ok": false, "error": PluginProtocol.confirmationRequiredError])
      return
    }
    scope.enqueue(on: HostProcessSignals.queue) {
      guard let failure = processSignals.send(signal, to: pid) else {
        FlashLog.info(
          "[plugin] process signal",
          fields: ["plugin": pluginID, "signal": signal.rawValue, "pid": "\(pid)"])
        reply(["ok": true])
        return
      }
      FlashLog.warn(
        "[plugin] process signal failed: \(failure)",
        fields: ["plugin": pluginID, "signal": signal.rawValue, "pid": "\(pid)"])
      reply(["ok": false, "error": failure])
    }
  }

  /// `host.process_table`: every process the user may measure, some of
  /// them, or one process's tree, read on the table's own queue. A reply is
  /// figures, counts and executable names; nothing reads a process's
  /// arguments or its environment.
  private func hostProcessTable(
    _ operation: PluginHostRequest.ProcessTable, pluginID: String,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    guard let processTable else {
      reply(["ok": false, "error": "process table unavailable"])
      return
    }
    scope.enqueue(on: processTable.queue) {
      let snapshot: HostProcessTable.Snapshot
      switch operation {
      case .list(let pids): snapshot = processTable.list(pids: pids)
      case .tree(let pid): snapshot = processTable.tree(root: pid)
      }
      if snapshot.truncated {
        FlashLog.debug(
          "[plugin] process table truncated",
          fields: ["plugin": pluginID, "processes": "\(snapshot.processes.count)"])
      }
      reply(HostProcessTable.wire(snapshot))
    }
  }

  /// `host.calendar_events`: the access macOS grants Flash, a request for
  /// it, or the events of a window, each on the calendar queue. Nothing but
  /// `request_access` asks macOS, and only while the user is using the
  /// plugin: a prompt never comes up from a background refresh.
  private func hostCalendarEvents(
    _ operation: PluginHostRequest.Calendar, pluginID: String, scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let calendarEvents else {
      reply(["ok": false, "error": "calendar events unavailable"])
      return
    }
    scope.enqueue(on: calendarEvents.queue) {
      switch operation {
      case .access:
        reply(["ok": true, "access": calendarEvents.access().wireName])
      case .requestAccess:
        let access = calendarEvents.access()
        guard access == .undetermined else {
          reply(["ok": true, "access": access.wireName])
          return
        }
        guard scope.servesUser() else {
          FlashLog.warn(
            "[plugin] calendar access request refused: the user is not using the plugin",
            fields: ["plugin": pluginID])
          reply(["ok": false, "error": PluginProtocol.userRequestRequiredError])
          return
        }
        calendarEvents.requestAccess { access in
          reply(["ok": true, "access": access.wireName])
        }
      case .list(let start, let end, let calendars):
        switch calendarEvents.list(from: start, to: end, calendars: calendars) {
        case .events(let events, let truncated):
          var result: [String: Any] = [
            "ok": true, "access": GrantAccess.granted.wireName, "events": events,
          ]
          if truncated { result["truncated"] = true }
          FlashLog.debug(
            "[plugin] calendar events",
            fields: [
              "plugin": pluginID, "events": "\(events.count)", "truncated": "\(truncated)",
            ])
          reply(result)
        case .noAccess(let access):
          reply(["ok": true, "access": access.wireName])
        case .failed(let reason):
          reply(["ok": false, "error": reason])
        }
      }
    }
  }

  /// `host.notes`, `host.reminders` and `host.contacts`: the access macOS
  /// grants Flash to one app, a request for it or its items, each on that
  /// app's queue, or one of them shown, beside it. Nothing but
  /// `request_access` asks macOS, and only while the user is using the
  /// plugin: a prompt never comes up from a background refresh.
  private func hostAppItems(
    _ kind: HostAppItemKind, _ operation: PluginHostRequest.AppItems, pluginID: String,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    guard let items = appItems[kind] else {
      reply(["ok": false, "error": "\(kind.rawValue) unavailable"])
      return
    }
    // Read as the request arrives, in the order of the plugin's frames: the
    // search that made it ask may be answered before the app's queue runs.
    let servesUser = operation == .requestAccess && scope.servesUser()
    var queue = items.queue
    if case .show = operation { queue = HostAppItems.showQueue }
    scope.enqueue(on: queue) {
      switch operation {
      case .access:
        reply(["ok": true, "access": items.access().wireName])
      case .requestAccess:
        let access = items.access()
        // Nobody to ask about: Notes answers only while it runs.
        guard access == .undetermined, items.canRequestAccess() else {
          reply(["ok": true, "access": access.wireName])
          return
        }
        guard servesUser else {
          FlashLog.warn(
            "[plugin] \(kind.rawValue) access request refused: the user is not using the plugin",
            fields: ["plugin": pluginID])
          reply(["ok": false, "error": PluginProtocol.userRequestRequiredError])
          return
        }
        items.requestAccess { access in
          reply(["ok": true, "access": access.wireName])
        }
      case .list:
        let startedAt = DispatchTime.now()
        let listing = items.list()
        let elapsedMs = Int(
          (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
        switch listing {
        case .items(let listed, let truncated):
          var result: [String: Any] = [
            "ok": true, "access": GrantAccess.granted.wireName, "items": listed,
          ]
          if truncated { result["truncated"] = true }
          // The count and the time, never an item.
          let fields = [
            "plugin": pluginID, "items": "\(listed.count)", "truncated": "\(truncated)",
            "elapsed_ms": "\(elapsedMs)",
          ]
          FlashLog.debug("[plugin] \(kind.rawValue) listed", fields: fields)
          if elapsedMs >= HostAppItems.slowListMs {
            FlashLog.warn("[plugin] \(kind.rawValue) list slow", fields: fields)
          }
          reply(result)
        case .noAccess(let access):
          reply(["ok": true, "access": access.wireName])
        case .failed(let reason):
          reply(["ok": false, "error": reason])
        }
      case .show(let id):
        items.show(id: id) { failure in
          guard let failure else {
            reply(["ok": true])
            return
          }
          FlashLog.warn(
            "[plugin] \(kind.rawValue) show failed: \(failure)", fields: ["plugin": pluginID])
          reply(["ok": false, "error": failure])
        }
      }
    }
  }

  private func activatePluginApp(
    pid: pid_t, scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    scope.enqueue(on: .main) {
      guard let app = NSRunningApplication(processIdentifier: pid) else {
        reply(["ok": false, "error": "no running app for pid"])
        return
      }
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      reply(["ok": true])
    }
  }

  /// `host.post_keys`: post a short synthesized chord sequence to a pid
  /// (plugin fast paths like the browsers plugin's Firefox tab jump: ⌘8 + n×ctrl+PgDn).
  /// Modifier chords dispatch through the target's key-equivalent path, so
  /// the app does NOT need to be frontmost — that's the point: the switch
  /// runs in parallel with `host.activate`. Chord-only (every step names at
  /// least one modifier) and bounded by `PluginHostRequest`, so this can
  /// never be used to type text into the target.
  private func postSyntheticKeys(
    pid: pid_t, chords: [PluginHostRequest.Chord], intervalMs: Int?,
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    let intervalMs = min(max(intervalMs ?? 35, 8), 100)
    guard let post = onSyntheticKeysRequested else {
      reply(["ok": false, "error": "key posting unavailable"])
      return
    }
    scope.enqueue(on: .main) {
      post(pid, chords, intervalMs)
      reply(["ok": true])
    }
  }

}

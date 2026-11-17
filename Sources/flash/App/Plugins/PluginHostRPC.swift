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
  /// it through this broker via `handleHostRequest`.
  private let axBroker = AXBroker()
  var appleScriptRunner: (String, TimeInterval) -> AppleScriptOutput = AppleScriptRunner.run

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

  // Testability seams for the arms whose production bodies fire
  // irreversible side effects (LaunchServices open). Tests swap these to
  // assert the decoded, capability-checked, validated call without opening
  // browsers or apps; the defaults ARE the production behavior.
  static var urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  /// The bundle id of the app LaunchServices hands `url` to.
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
    appleEventsTargets: [String] = [],
    scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard scope.isCurrent() else { return }
    switch method {
    case "host.ping":
      // Round-trip validation of the bidirectional channel.
      reply(["ok": true, "echo": params])
    case "host.normal_mode_target":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("app_control")])
        return
      }
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
    case "host.activate":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("app_control")])
        return
      }
      activatePluginApp(params, scope: scope, reply: reply)
    case "host.post_keys":
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("accessibility")])
        return
      }
      postSyntheticKeys(params, scope: scope, reply: reply)
    case let method where method.hasPrefix("host.ax_"):
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("accessibility")])
        return
      }
      axBroker.handle(
        method: method, params: params, pluginID: pluginID, scope: scope, reply: reply)
    case "host.fetch":
      guard capabilities.contains(.networkFetch) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("network_fetch")])
        return
      }
      hostFetch(params, allowlist: fetchURLs, pluginID: pluginID, scope: scope, reply: reply)
    case "host.wifi_info":
      guard capabilities.contains(.wifiInfo) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("wifi_info")])
        return
      }
      guard
        let requestAuthorizationValue = params["request_authorization"] as? NSNumber,
        CFGetTypeID(requestAuthorizationValue) == CFBooleanGetTypeID()
      else {
        reply([
          "ok": false,
          "error": "host.wifi_info requires a boolean request_authorization param",
        ])
        return
      }
      let requestAuthorization = requestAuthorizationValue.boolValue
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
    case "host.open":
      guard capabilities.contains(.open) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("open")])
        return
      }
      hostOpen(params, scope: scope, reply: reply)
    case "host.applescript":
      guard capabilities.contains(.appleEvents) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("apple_events")])
        return
      }
      PluginHostAppleScript.handle(
        params, targets: appleEventsTargets, pluginID: pluginID, scope: scope,
        runner: appleScriptRunner, reply: reply)
    default:
      FlashLog.warn(
        "[plugin] unknown host method \(method) from \(pluginID)",
        fields: ["method": method, "plugin": pluginID])
      reply(["ok": false, "error": PluginProtocol.unknownMethodError(method)])
    }
  }

  /// `host.fetch`: perform an HTTPS GET on the plugin's behalf. The manifest's
  /// `fetch_urls` prefixes are the allowlist, the response is capped at 1 MiB
  /// of UTF-8 text, and the request runs entirely off the main thread on
  /// URLSession's delegate queue with a hard timeout — a slow remote can never
  /// touch tap responsiveness. Telemetry stays content-free (no URL/body).
  var hostFetchConfiguration = URLSessionConfiguration.ephemeral

  /// True when `url` sits inside the allowlisted `prefix` at a URL component
  /// boundary. A raw hasPrefix would let "https://api.example.com" also admit
  /// "https://api.example.com.attacker.tld/".
  static func urlIsAllowed(_ url: String, byPrefix prefix: String) -> Bool {
    PluginHostFetch.urlIsAllowed(url, byPrefix: prefix)
  }

  private func hostFetch(
    _ params: [String: Any], allowlist: [String], pluginID: String,
    scope: PluginHostRequestScope,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let urlString = params["url"] as? String,
      let url = URLParsing.url(urlString),
      url.scheme == "https"
    else {
      reply(["ok": false, "error": "host.fetch requires a valid https url param"])
      return
    }
    guard allowlist.contains(where: { Self.urlIsAllowed(urlString, byPrefix: $0) }) else {
      reply(["ok": false, "error": "url not in fetch_urls allowlist"])
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = Double(PluginProtocol.fetchTimeoutMs) / 1_000
    let startedAt = DispatchTime.now()
    PluginHostFetch.start(
      request: request, allowlist: allowlist, configuration: hostFetchConfiguration
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
  /// that app still has focus before acting on it.
  private func hostOpen(
    _ params: [String: Any],
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    if let urlString = params["url"] as? String,
      let url = URLParsing.url(urlString), url.scheme != nil
    {
      // Never a local file: a sandboxed plugin could write a `.command`,
      // a script or an app into its data directory, and LaunchServices
      // would run it outside the sandbox.
      guard url.scheme?.lowercased() != "file" else {
        reply(["ok": false, "error": "host.open does not open local files"])
        return
      }
      scope.enqueue(on: .main) {
        // Response law: ok:false always carries a non-empty, content-free
        // error (a bare {"ok": false} is a spec violation).
        if Self.urlOpener(url) {
          var result: [String: Any] = ["ok": true]
          result["bundle_id"] = Self.urlHandler(url)
          reply(result)
        } else {
          reply(["ok": false, "error": "open failed"])
        }
      }
      return
    }
    if let bundleID = params["bundle_id"] as? String {
      scope.enqueue(on: .main) {
        Self.appOpener(bundleID) { error in
          if let error {
            reply(["ok": false, "error": error])
          } else {
            reply(["ok": true])
          }
        }
      }
      return
    }
    reply(["ok": false, "error": "host.open requires url or bundle_id"])
  }

  private func activatePluginApp(
    _ params: [String: Any],
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = PluginJSON.pid(params["pid"]) else {
      reply(["ok": false, "error": "host.activate requires pid"])
      return
    }
    scope.enqueue(on: .main) {
      guard let app = NSRunningApplication(processIdentifier: pid) else {
        reply(["ok": false, "error": "no running app for pid"])
        return
      }
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      reply(["ok": true])
    }
  }

  private static let syntheticKeyModifierNames: [String: CGEventFlags] = [
    "command": .maskCommand,
    "control": .maskControl,
    "option": .maskAlternate,
    "shift": .maskShift,
  ]

  /// `host.post_keys`: post a short synthesized chord sequence to a pid
  /// (plugin fast paths like the browsers plugin's Firefox tab jump: ⌘8 + n×ctrl+PgDn).
  /// Modifier chords dispatch through the target's key-equivalent path, so
  /// the app does NOT need to be frontmost — that's the point: the switch
  /// runs in parallel with `host.activate`. Chord-only (every step must name
  /// at least one modifier) and bounded, so this can never be used to type
  /// text into the target.
  private func postSyntheticKeys(
    _ params: [String: Any],
    scope: PluginHostRequestScope, reply: @escaping ([String: Any]) -> Void
  ) {
    if let interval = params["interval_ms"], PluginJSON.integer(interval) == nil {
      reply(["ok": false, "error": "host.post_keys requires an integer interval_ms"])
      return
    }
    guard let pid = PluginJSON.pid(params["pid"]), pid > 0,
      let steps = params["keys"] as? [[String: Any]],
      !steps.isEmpty, steps.count <= 32
    else {
      reply(["ok": false, "error": "host.post_keys requires pid and 1-32 keys"])
      return
    }
    var chords: [(key: CGKeyCode, flags: CGEventFlags)] = []
    for step in steps {
      guard let rawCode = PluginJSON.integer(step["key_code"]), rawCode >= 0, rawCode < 0x80,
        let names = step["modifiers"] as? [String], !names.isEmpty
      else {
        reply(["ok": false, "error": "each key needs key_code and non-empty modifiers"])
        return
      }
      var flags: CGEventFlags = []
      for name in names {
        guard let flag = Self.syntheticKeyModifierNames[name.lowercased()] else {
          reply(["ok": false, "error": "unknown modifier: \(name)"])
          return
        }
        flags.insert(flag)
      }
      chords.append((key: CGKeyCode(rawCode), flags: flags))
    }
    let intervalMs = min(max(PluginJSON.integer(params["interval_ms"]) ?? 35, 8), 100)
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

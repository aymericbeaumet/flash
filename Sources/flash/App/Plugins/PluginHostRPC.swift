import AppKit
import Carbon.HIToolbox
import Darwin
import FlashCore
import Foundation

/// The plugin→host RPC surface: routing, capability guards, and the
/// implementations of every native API plugins may reach (AX broker, app
/// activation, synthesized input, host-side fetch). Split from
/// PluginManager so the manager owns only the plugin set and its indexes.
final class PluginHostRPC {
  /// Owns the single AX (Accessibility) grant and the handle registry that
  /// backs the `ax.*` host RPCs. Plugins never touch AX directly; they reach
  /// it through this broker via `handleHostRequest`.
  private let axBroker = AXBroker()
  /// Resolver for the `host.normal_mode_target` RPC: returns the focused
  /// non-Flash app context (pid + bundle id) the host considers the
  /// normal-mode target. Plugins (notably `marks`) call this to record or
  /// reactivate the app the user was working on when they typed `m<letter>`
  /// — `core:focus.changed` alone is insufficient because Flash itself is
  /// the focused process while normal mode is active. Set by AppDelegate
  /// during plugin setup.
  var onNormalModeTargetRequested: (() -> (pid: pid_t, bundleID: String)?)?
  /// Executor for the `input.post_keys` RPC: posts a short synthesized chord
  /// sequence to a pid at the given interval. Set by AppDelegate so the
  /// posting can register each chord with the mappings dispatcher first
  /// (`noteSyntheticKey`) — a `postToPid` event can loop back through the
  /// Carbon hotkey path and re-trigger the user's own binding for the combo.
  var onSyntheticKeysRequested: ((pid_t, [(key: CGKeyCode, flags: CGEventFlags)], Int) -> Void)?

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
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch method {
    case "host.ping":
      // Round-trip validation of the bidirectional channel.
      reply(["ok": true, "echo": params])
    case "host.normal_mode_target":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": "missing app_control capability"])
        return
      }
      DispatchQueue.main.async { [weak self] in
        guard let target = self?.onNormalModeTargetRequested?() else {
          reply(["ok": true, "present": false])
          return
        }
        reply([
          "ok": true,
          "present": true,
          "pid": Int(target.pid),
          "bundle_id": target.bundleID,
        ])
      }
    case "app.activate":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": "missing app_control capability"])
        return
      }
      activatePluginApp(params, reply: reply)
    case "input.replace_text_and_submit":
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": "missing accessibility capability"])
        return
      }
      replaceTextAndSubmit(params, reply: reply)
    case "input.post_keys":
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": "missing accessibility capability"])
        return
      }
      postSyntheticKeys(params, reply: reply)
    case let method where method.hasPrefix("ax."):
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": "missing accessibility capability"])
        return
      }
      axBroker.handle(method: method, params: params, reply: reply)
    case "host.fetch":
      guard capabilities.contains(.networkFetch) else {
        reply(["ok": false, "error": "missing network_fetch capability"])
        return
      }
      hostFetch(params, allowlist: fetchURLs, pluginID: pluginID, reply: reply)
    default:
      FlashLog.warn(
        "[plugin] unknown host method \(method) from \(pluginID)",
        fields: ["method": method, "plugin": pluginID])
      reply(["ok": false, "error": "unknown host method: \(method)"])
    }
  }

  /// `host.fetch`: perform an HTTPS GET on the plugin's behalf. The manifest's
  /// `fetch_urls` prefixes are the allowlist, the response is capped at 1 MiB
  /// of UTF-8 text, and the request runs entirely off the main thread on
  /// URLSession's delegate queue with a hard timeout — a slow remote can never
  /// touch tap responsiveness. Telemetry stays content-free (no URL/body).
  private static let hostFetchBodyCap = 1_048_576

  private func hostFetch(
    _ params: [String: Any], allowlist: [String], pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let urlString = params["url"] as? String,
      let url = URL(string: urlString),
      url.scheme == "https"
    else {
      reply(["ok": false, "error": "host.fetch requires a valid https url param"])
      return
    }
    guard allowlist.contains(where: { urlString.hasPrefix($0) }) else {
      reply(["ok": false, "error": "url not in fetch_urls allowlist"])
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    let startedAt = DispatchTime.now()
    URLSession.shared.dataTask(with: request) { data, response, error in
      let elapsedMs = Int(
        Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
      if let error {
        FlashLog.warn(
          "[plugin] host.fetch failed elapsed_ms=\(elapsedMs)",
          fields: ["plugin": pluginID, "elapsed_ms": "\(elapsedMs)"])
        reply(["ok": false, "error": String(describing: error)])
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let data = data ?? Data()
      guard data.count <= Self.hostFetchBodyCap else {
        reply(["ok": false, "error": "response exceeds the 1 MiB host.fetch cap"])
        return
      }
      guard let body = String(data: data, encoding: .utf8) else {
        reply(["ok": false, "error": "response is not UTF-8 text"])
        return
      }
      FlashLog.info(
        "[plugin] host.fetch ok status=\(status) elapsed_ms=\(elapsedMs)",
        fields: [
          "plugin": pluginID, "status": "\(status)", "elapsed_ms": "\(elapsedMs)",
          "bytes": "\(data.count)",
        ])
      reply(["ok": true, "status": status, "body": body])
    }.resume()
  }

  private func activatePluginApp(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init) else {
      reply(["ok": false, "error": "app.activate requires pid"])
      return
    }
    DispatchQueue.main.async {
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

  /// `input.post_keys`: post a short synthesized chord sequence to a pid
  /// (plugin fast paths like the firefox tab jump: ⌘8 + n×ctrl+PgDn).
  /// Modifier chords dispatch through the target's key-equivalent path, so
  /// the app does NOT need to be frontmost — that's the point: the switch
  /// runs in parallel with `app.activate`. Chord-only (every step must name
  /// at least one modifier) and bounded, so this can never be used to type
  /// text into the target.
  private func postSyntheticKeys(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init), pid > 0,
      let steps = params["keys"] as? [[String: Any]],
      !steps.isEmpty, steps.count <= 32
    else {
      reply(["ok": false, "error": "input.post_keys requires pid and 1-32 keys"])
      return
    }
    var chords: [(key: CGKeyCode, flags: CGEventFlags)] = []
    for step in steps {
      guard let rawCode = step["key_code"] as? Int, rawCode >= 0, rawCode < 0x80,
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
    let intervalMs = min(max((params["interval_ms"] as? Int) ?? 35, 8), 100)
    guard let post = onSyntheticKeysRequested else {
      reply(["ok": false, "error": "key posting unavailable"])
      return
    }
    DispatchQueue.main.async {
      post(pid, chords, intervalMs)
      reply(["ok": true])
    }
  }

  private func replaceTextAndSubmit(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init),
      let text = params["text"] as? String
    else {
      reply(["ok": false, "error": "input.replace_text_and_submit requires pid and text"])
      return
    }
    DispatchQueue.main.async {
      guard let app = NSRunningApplication(processIdentifier: pid) else {
        reply(["ok": false, "error": "no running app for pid"])
        return
      }
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      if let requiredRole = params["require_focused_role"] as? String,
        Self.focusedElementRole(pid: pid) != requiredRole
      {
        reply(["ok": false, "error": "focused element role mismatch"])
        return
      }
      let selectOK = NormalModeDispatcher.sendKey(
        virtualKey: CGKeyCode(kVK_ANSI_A),
        flags: .maskCommand,
        to: pid)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
        let typeOK = NormalModeDispatcher.typeText(text, to: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
          let submitOK = NormalModeDispatcher.sendKey(
            virtualKey: CGKeyCode(kVK_Return),
            to: pid)
          reply(["ok": selectOK && typeOK && submitOK])
        }
      }
    }
  }

  private static func focusedElementRole(pid: pid_t) -> String? {
    let app = AXApp.make(pid: pid)
    var focusedRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        == .success,
      let focusedRaw,
      CFGetTypeID(focusedRaw) == AXUIElementGetTypeID()
    else { return nil }
    var roleRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focusedRaw as! AXUIElement,
        kAXRoleAttribute as CFString,
        &roleRaw) == .success
    else { return nil }
    return roleRaw as? String
  }
}

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
  /// backs the `host.ax_*` RPCs. Plugins never touch AX directly; they reach
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
  /// Executor for the `host.post_keys` RPC: posts a short synthesized chord
  /// sequence to a pid at the given interval. Set by AppDelegate so the
  /// posting can register each chord with the mappings dispatcher first
  /// (`noteSyntheticKey`) — a `postToPid` event can loop back through the
  /// Carbon hotkey path and re-trigger the user's own binding for the combo.
  var onSyntheticKeysRequested: ((pid_t, [(key: CGKeyCode, flags: CGEventFlags)], Int) -> Void)?
  /// Executor for a single global modifier chord. Unlike `host.post_keys`,
  /// this enters the session event stream so macOS can own the shortcut.
  var onGlobalSyntheticKeyRequested: ((CGKeyCode, CGEventFlags) -> Bool)?
  /// Executor for the `host.notify` RPC: shows a transient banner with the
  /// given message and duration. Set by AppDelegate (routes to the overlay's
  /// banner surface).
  var onNotifyRequested: ((String, Int) -> Void)?
  /// Per-plugin timestamp of the last accepted `host.notify`, enforcing the
  /// 1-per-second rate limit. Main-thread only (notify hops to main).
  private var lastNotifyAt: [String: Date] = [:]

  // Testability seams for the three arms whose production bodies fire
  // irreversible side effects (LaunchServices open, HID media-key post,
  // SIGTERM). Tests swap these to assert the decoded, capability-checked,
  // validated call without opening browsers or signaling processes; the
  // defaults ARE the production behavior.
  static var urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  static var appOpener: (String, @escaping (String?) -> Void) -> Void = { bundleID, done in
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else {
      done("no app for bundle id \(bundleID)")
      return
    }
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      done(error.map { String(describing: $0) })
    }
  }
  static var mediaKeyPoster: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
  static var signalSender: (pid_t) -> Int32 = { kill($0, SIGTERM) }

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
    dataDir: URL? = nil,
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch method {
    case "host.ping":
      // Round-trip validation of the bidirectional channel.
      reply(["ok": true, "echo": params])
    case "host.normal_mode_target":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("app_control")])
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
    case "host.activate":
      guard capabilities.contains(.appControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("app_control")])
        return
      }
      activatePluginApp(params, reply: reply)
    case "host.post_keys":
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("accessibility")])
        return
      }
      postSyntheticKeys(params, reply: reply)
    case "host.post_global_key":
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("accessibility")])
        return
      }
      postGlobalSyntheticKey(params, reply: reply)
    case let method where method.hasPrefix("host.ax_"):
      guard capabilities.contains(.accessibility) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("accessibility")])
        return
      }
      axBroker.handle(method: method, params: params, pluginID: pluginID, reply: reply)
    case "host.fetch":
      guard capabilities.contains(.networkFetch) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("network_fetch")])
        return
      }
      hostFetch(params, allowlist: fetchURLs, pluginID: pluginID, reply: reply)
    case "host.open":
      guard capabilities.contains(.open) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("open")])
        return
      }
      hostOpen(params, reply: reply)
    case "host.post_media_key":
      guard capabilities.contains(.mediaKeys) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("media_keys")])
        return
      }
      postMediaKey(params, reply: reply)
    case "host.process_table":
      guard capabilities.contains(.processControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("process_control")])
        return
      }
      processTable(params, reply: reply)
    case "host.signal":
      guard capabilities.contains(.processControl) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("process_control")])
        return
      }
      signalProcess(params, reply: reply)
    case "host.clipboard_write":
      guard capabilities.contains(.clipboard) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("clipboard")])
        return
      }
      hostClipboardWrite(params, reply: reply)
    case "host.notify":
      guard capabilities.contains(.notify) else {
        reply(["ok": false, "error": PluginProtocol.capabilityDeniedError("notify")])
        return
      }
      hostNotify(params, pluginID: pluginID, reply: reply)
    case "host.storage_get":
      hostStorageGet(params, dataDir: dataDir, reply: reply)
    case "host.storage_set":
      hostStorageSet(params, dataDir: dataDir, reply: reply)
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
  private static let hostFetchBodyCap = PluginProtocol.maxFetchResponseBytes

  /// True when `url` sits inside the allowlisted `prefix` at a URL component
  /// boundary. A raw hasPrefix would let "https://api.example.com" also admit
  /// "https://api.example.com.attacker.tld/".
  static func urlIsAllowed(_ url: String, byPrefix prefix: String) -> Bool {
    guard !prefix.isEmpty, url.hasPrefix(prefix) else { return false }
    if url.count == prefix.count || prefix.hasSuffix("/") { return true }
    let next = url[url.index(url.startIndex, offsetBy: prefix.count)]
    return next == "/" || next == "?" || next == "#"
  }

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
    guard allowlist.contains(where: { Self.urlIsAllowed(urlString, byPrefix: $0) }) else {
      reply(["ok": false, "error": "url not in fetch_urls allowlist"])
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = Double(PluginProtocol.fetchTimeoutMs) / 1_000
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

  /// `host.clipboard_write`: replace the system clipboard with `text`. The
  /// host owns pasteboard access, so a sandboxed plugin needs no pasteboard
  /// entitlement of its own.
  static let maxClipboardWriteBytes = PluginProtocol.maxClipboardWriteBytes

  private func hostClipboardWrite(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let text = params["text"] as? String,
      text.utf8.count <= Self.maxClipboardWriteBytes
    else {
      reply(["ok": false, "error": "host.clipboard_write requires text under 1 MiB"])
      return
    }
    DispatchQueue.main.async {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      reply(["ok": true])
    }
  }

  /// `host.notify`: transient banner. Message capped at 1 KiB, duration
  /// clamped to 0.5–10 s, at most one accepted notify per plugin per second.
  static let maxNotifyMessageBytes = PluginProtocol.maxNotifyMessageBytes

  private func hostNotify(
    _ params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let message = params["message"] as? String,
      !message.isEmpty,
      message.utf8.count <= Self.maxNotifyMessageBytes
    else {
      reply(["ok": false, "error": "host.notify requires a message under 1 KiB"])
      return
    }
    let durationMs = min(max((params["duration_ms"] as? Int) ?? 3000, 500), 10_000)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let now = Date()
      if let last = self.lastNotifyAt[pluginID], now.timeIntervalSince(last) < 1 {
        reply(["ok": false, "error": "host.notify rate limit: 1 per second"])
        return
      }
      self.lastNotifyAt[pluginID] = now
      self.onNotifyRequested?(message, durationMs)
      reply(["ok": true])
    }
  }

  /// `host.storage_get` / `host.storage_set`: a tiny host-managed KV store in
  /// the plugin's own data directory (`storage.json`), so non-Rust plugins
  /// stop hand-rolling persistence. No capability: the file lives inside the
  /// directory the plugin's sandbox already grants it.
  static let maxStorageKeyBytes = PluginProtocol.maxStorageKeyBytes
  static let maxStorageValueBytes = PluginProtocol.maxStorageValueBytes
  static let maxStorageEntries = PluginProtocol.maxStorageEntries
  private static let storageQueue = DispatchQueue(label: "flash.plugin.storage", qos: .utility)

  static func readStorage(at url: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return object
  }

  /// Pure merge step for `host.storage_set`: nil `value` deletes. Returns nil
  /// when the write would violate a bound (oversized value, table full).
  static func applyingStorageEntry(
    key: String,
    value: String?,
    to store: [String: String]
  ) -> [String: String]? {
    var next = store
    guard let value else {
      next.removeValue(forKey: key)
      return next
    }
    guard value.utf8.count <= maxStorageValueBytes else { return nil }
    if next[key] == nil, next.count >= maxStorageEntries { return nil }
    next[key] = value
    return next
  }

  private func hostStorageGet(
    _ params: [String: Any],
    dataDir: URL?,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let dataDir else {
      reply(["ok": false, "error": "storage unavailable"])
      return
    }
    guard let key = params["key"] as? String,
      !key.isEmpty, key.utf8.count <= Self.maxStorageKeyBytes
    else {
      reply(["ok": false, "error": "host.storage_get requires a key under 128 bytes"])
      return
    }
    let url = dataDir.appendingPathComponent("storage.json")
    Self.storageQueue.async {
      let store = Self.readStorage(at: url)
      if let value = store[key] {
        reply(["ok": true, "present": true, "value": value])
      } else {
        reply(["ok": true, "present": false])
      }
    }
  }

  private func hostStorageSet(
    _ params: [String: Any],
    dataDir: URL?,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let dataDir else {
      reply(["ok": false, "error": "storage unavailable"])
      return
    }
    guard let key = params["key"] as? String,
      !key.isEmpty, key.utf8.count <= Self.maxStorageKeyBytes
    else {
      reply(["ok": false, "error": "host.storage_set requires a key under 128 bytes"])
      return
    }
    let value: String?
    if params["value"] == nil || params["value"] is NSNull {
      value = nil
    } else if let string = params["value"] as? String {
      value = string
    } else {
      reply(["ok": false, "error": "host.storage_set value must be a string or null"])
      return
    }
    let url = dataDir.appendingPathComponent("storage.json")
    Self.storageQueue.async {
      let store = Self.readStorage(at: url)
      guard let next = Self.applyingStorageEntry(key: key, value: value, to: store) else {
        reply([
          "ok": false,
          "error": "storage bound exceeded (64 KiB value, \(Self.maxStorageEntries) entries)",
        ])
        return
      }
      do {
        try FileManager.default.createDirectory(
          at: dataDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        reply(["ok": true])
      } catch {
        reply(["ok": false, "error": String(describing: error)])
      }
    }
  }

  /// `host.open`: hand a URL or bundle id to LaunchServices host-side, so
  /// plugins never fork `/usr/bin/open` and keep fork-free profiles.
  private func hostOpen(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    if let urlString = params["url"] as? String,
      let url = URL(string: urlString), url.scheme != nil
    {
      DispatchQueue.main.async {
        // Response law: ok:false always carries a non-empty, content-free
        // error (a bare {"ok": false} is a spec violation).
        if Self.urlOpener(url) {
          reply(["ok": true])
        } else {
          reply(["ok": false, "error": "open failed"])
        }
      }
      return
    }
    if let bundleID = params["bundle_id"] as? String {
      DispatchQueue.main.async {
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

  /// `host.post_media_key`: post an NX_SYSTEM_DEFINED key (play/pause 16,
  /// next 17, previous 18, …) as down+up. Runs host-side so no plugin needs
  /// the WindowServer/IOHID mach allowances (`hid`) — the widest seatbelt
  /// grant any bundled plugin used to hold.
  private func postMediaKey(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let keyCode = params["key_code"] as? Int, (0...31).contains(keyCode) else {
      reply(["ok": false, "error": "host.post_media_key requires key_code 0-31"])
      return
    }
    DispatchQueue.main.async {
      // NX_KEYDOWN (0x0A) then NX_KEYUP (0x0B), subtype 8
      // (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
      for state in [0x0A, 0x0B] {
        let data1 = (keyCode << 16) | (state << 8)
        guard
          let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1),
          let cgEvent = event.cgEvent
        else {
          reply(["ok": false, "error": "media key event synthesis failed"])
          return
        }
        Self.mediaKeyPoster(cgEvent)
      }
      reply(["ok": true])
    }
  }

  /// `host.process_table`: visible processes with an instantaneous CPU
  /// measurement over `sample_window_ms` (two libproc rusage snapshots
  /// bracketing a sleep). Host-side so process inspectors need no
  /// `process_info` seatbelt allowance and no second process model.
  private func processTable(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    let windowMs = min(max((params["sample_window_ms"] as? Int) ?? 150, 10), 2_000)
    let requestedPID: pid_t?
    if let rawPID = params["pid"] {
      guard let pid = rawPID as? Int, pid > 0 else {
        reply(["ok": false, "error": "host.process_table pid must be positive"])
        return
      }
      requestedPID = pid_t(pid)
    } else {
      requestedPID = nil
    }
    DispatchQueue.global(qos: .utility).async {
      let pids = requestedPID.map(Self.processTree(root:)) ?? Self.allPids()
      let first = Self.cpuTimeByPid(pids)
      Thread.sleep(forTimeInterval: Double(windowMs) / 1_000)
      let windowNs = Double(windowMs) * 1_000_000
      let totalMemory = Double(max(ProcessInfo.processInfo.physicalMemory, 1))
      var rows: [[String: Any]] = []
      if let rootPID = requestedPID {
        guard let comm = Self.executableBasename(rootPID) else {
          reply(["ok": true, "processes": rows])
          return
        }
        var cpuPercent = 0.0
        var residentBytes: UInt64 = 0
        var diskReadBytes: UInt64 = 0
        var diskWriteBytes: UInt64 = 0
        var processCount = 0
        var threadCount = 0
        var networkSocketCount = 0
        for pid in pids {
          guard let usage = Self.pidUsage(pid) else { continue }
          processCount += 1
          if let prior = first[pid] {
            cpuPercent += Double(usage.cpuNs &- min(prior, usage.cpuNs)) / windowNs * 100
          }
          residentBytes = Self.saturatingAdd(residentBytes, usage.residentBytes)
          diskReadBytes = Self.saturatingAdd(diskReadBytes, usage.diskReadBytes)
          diskWriteBytes = Self.saturatingAdd(diskWriteBytes, usage.diskWriteBytes)
          threadCount += Self.processThreadCount(pid)
          networkSocketCount += Self.networkSocketCount(pid)
        }
        guard processCount > 0 else {
          reply(["ok": true, "processes": rows])
          return
        }
        rows.append([
          "pid": Int(rootPID),
          "comm": comm,
          "cpu_percent": cpuPercent,
          "mem_percent": Double(residentBytes) / totalMemory * 100,
          "memory_bytes": Self.jsonInt(residentBytes),
          "disk_read_bytes": Self.jsonInt(diskReadBytes),
          "disk_write_bytes": Self.jsonInt(diskWriteBytes),
          "uptime_seconds": Self.processUptimeSeconds(rootPID),
          "process_count": processCount,
          "thread_count": threadCount,
          "network_socket_count": networkSocketCount,
        ])
      } else {
        for pid in pids {
          guard let usage = Self.pidUsage(pid), let comm = Self.executableBasename(pid) else {
            continue
          }
          let cpuPercent = first[pid].map {
            Double(usage.cpuNs &- min($0, usage.cpuNs)) / windowNs * 100
          }
          rows.append([
            "pid": Int(pid),
            "comm": comm,
            "cpu_percent": cpuPercent ?? 0,
            "mem_percent": Double(usage.residentBytes) / totalMemory * 100,
          ])
        }
      }
      reply(["ok": true, "processes": rows])
    }
  }

  /// `host.signal`: SIGTERM a pid without a `/bin/kill` subprocess. Errors
  /// carry the OS message (EPERM: not this uid's process; ESRCH: gone).
  private func signalProcess(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = params["pid"] as? Int, pid > 1 else {
      reply(["ok": false, "error": "host.signal requires pid > 1"])
      return
    }
    if Self.signalSender(pid_t(pid)) == 0 {
      reply(["ok": true])
    } else {
      reply(["ok": false, "error": String(cString: strerror(errno))])
    }
  }

  private static func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    let capacity = Int(count) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let filled = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
  }

  /// Snapshot the root process and every currently reachable descendant.
  /// Browser and Electron resource use lives primarily in helpers, so an
  /// exact root-only sample would materially under-report the focused app.
  private static func processTree(root: pid_t) -> [pid_t] {
    var ordered = [root]
    var seen: Set<pid_t> = [root]
    var index = 0
    while index < ordered.count {
      let parent = ordered[index]
      index += 1
      let count = proc_listchildpids(parent, nil, 0)
      guard count > 0 else { continue }
      let capacity = Int(count) + 16
      var children = [pid_t](repeating: 0, count: capacity)
      let filled = proc_listchildpids(
        parent, &children, Int32(capacity * MemoryLayout<pid_t>.size))
      guard filled > 0 else { continue }
      for child in children.prefix(Int(filled)) where child > 0 && seen.insert(child).inserted {
        ordered.append(child)
      }
    }
    return ordered
  }

  private static func cpuTimeByPid(_ pids: [pid_t]) -> [pid_t: UInt64] {
    var out: [pid_t: UInt64] = [:]
    for pid in pids {
      if let usage = pidUsage(pid) {
        out[pid] = usage.cpuNs
      }
    }
    return out
  }

  private struct PIDUsage {
    var cpuNs: UInt64
    var residentBytes: UInt64
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
  }

  private static func pidUsage(_ pid: pid_t) -> PIDUsage? {
    var info = rusage_info_current()
    let ok = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) == 0
      }
    }
    guard ok else { return nil }
    return PIDUsage(
      cpuNs: info.ri_user_time &+ info.ri_system_time,
      residentBytes: info.ri_resident_size,
      diskReadBytes: info.ri_diskio_bytesread,
      diskWriteBytes: info.ri_diskio_byteswritten)
  }

  private static func jsonInt(_ value: UInt64) -> Int {
    Int(min(value, UInt64(Int.max)))
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : sum
  }

  private static func processUptimeSeconds(_ pid: pid_t) -> Int {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
    }
    guard read == size else { return 0 }
    return max(0, Int(Date().timeIntervalSince1970) - jsonInt(info.pbi_start_tvsec))
  }

  private static func processThreadCount(_ pid: pid_t) -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
    }
    guard read == size else { return 0 }
    return max(0, Int(info.pti_threadnum))
  }

  /// Count live internet sockets without launching `nettop` (which takes a
  /// multi-second sample and would be inappropriate for a resident status
  /// provider). Unix-domain IPC sockets are deliberately excluded.
  private static func networkSocketCount(_ pid: pid_t) -> Int {
    let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard required > 0 else { return 0 }
    let stride = MemoryLayout<proc_fdinfo>.stride
    let capacity = Int(required) / stride + 16
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let filled = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(
        pid, PROC_PIDLISTFDS, 0, buffer.baseAddress,
        Int32(buffer.count))
    }
    guard filled > 0 else { return 0 }
    let count = min(Int(filled) / stride, descriptors.count)
    return descriptors.prefix(count).reduce(into: 0) { total, descriptor in
      guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return }
      var socket = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      let read = withUnsafeMutablePointer(to: &socket) {
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
      }
      guard read == size else { return }
      let family = socket.psi.soi_family
      if family == AF_INET || family == AF_INET6 { total += 1 }
    }
  }

  private static func executableBasename(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * 1024)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(cString: buffer)
    guard !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
  }

  private func activatePluginApp(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let pid = (params["pid"] as? Int).map(pid_t.init) else {
      reply(["ok": false, "error": "host.activate requires pid"])
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

  static func globalSyntheticKeyChord(
    from params: [String: Any]
  ) -> (key: CGKeyCode, flags: CGEventFlags)? {
    guard let rawCode = params["key_code"] as? Int, rawCode >= 0, rawCode < 0x80,
      let names = params["modifiers"] as? [String], !names.isEmpty
    else { return nil }
    var flags: CGEventFlags = []
    for name in names {
      guard let flag = syntheticKeyModifierNames[name.lowercased()] else { return nil }
      flags.insert(flag)
    }
    return (CGKeyCode(rawCode), flags)
  }

  private func postGlobalSyntheticKey(
    _ params: [String: Any],
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let chord = Self.globalSyntheticKeyChord(from: params) else {
      reply([
        "ok": false,
        "error": "host.post_global_key requires key_code and valid non-empty modifiers",
      ])
      return
    }
    guard let post = onGlobalSyntheticKeyRequested else {
      reply(["ok": false, "error": "global key posting unavailable"])
      return
    }
    DispatchQueue.main.async {
      if post(chord.key, chord.flags) {
        reply(["ok": true])
      } else {
        reply(["ok": false, "error": "global key event synthesis failed"])
      }
    }
  }

  /// `host.post_keys`: post a short synthesized chord sequence to a pid
  /// (plugin fast paths like the firefox tab jump: ⌘8 + n×ctrl+PgDn).
  /// Modifier chords dispatch through the target's key-equivalent path, so
  /// the app does NOT need to be frontmost — that's the point: the switch
  /// runs in parallel with `host.activate`. Chord-only (every step must name
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
      reply(["ok": false, "error": "host.post_keys requires pid and 1-32 keys"])
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

}

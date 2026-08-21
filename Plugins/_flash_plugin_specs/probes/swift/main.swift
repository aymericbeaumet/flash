// Conformance probe, in Swift. See ../README.md — the normative behavior
// contract all seven per-language probes follow. Test fixture only: driven
// by Scripts/plugin-protocol-spec.py --probes, never shipped.

import Foundation

let sourceName = "conformance.items"
let targetPID = 4242

let runtime = PluginRuntime()
let stateLock = NSLock()
var lastEventStorage = ""

func rememberEvent(_ name: String) {
  stateLock.lock()
  lastEventStorage = name
  stateLock.unlock()
}

func lastEvent() -> String {
  stateLock.lock()
  defer { stateLock.unlock() }
  return lastEventStorage
}

/// The message-field encoder: compact JSON (JSONSerialization keeps
/// non-ASCII raw; it escapes "/" — specs never assert on it in messages).
func jsonText(_ object: Any) -> String {
  let safe: Any
  if let map = object as? [String: Any?] {
    safe = map.mapValues { $0 ?? NSNull() }
  } else {
    safe = object
  }
  guard JSONSerialization.isValidJSONObject(safe),
    let data = try? JSONSerialization.data(withJSONObject: safe),
    let text = String(data: data, encoding: .utf8)
  else { return "{}" }
  return text
}

func conformanceConfig() -> [String: Any] {
  config()["conformance"] as? [String: Any] ?? [:]
}

func catalog() -> [[String: Any?]] {
  let conf = conformanceConfig()
  if conf["empty_catalog"] as? Bool == true { return [] }
  if let count = conf["catalog_rows"] as? Int, count > 0 {
    let pad = String(repeating: "x", count: conf["row_pad"] as? Int ?? 0)
    return (1...count).map { ["source": sourceName, "title": "row-\($0)\(pad)"] }
  }
  return [
    ["source": sourceName, "title": "alpha", "metadata": ["k": "v1"]],
    ["source": sourceName, "title": "béta ⚡ 名前"],
    [
      "source": sourceName, "title": "gamma", "url": "https://example.com/g",
      "effect": ["type": "open", "url": "https://example.com/g"],
    ],
  ]
}

func answer(_ title: String, subtitle: String? = nil) -> [String: Any?] {
  var out: [String: Any?] = ["title": title, "effect": ["type": "copy_text", "text": title]]
  if let subtitle { out["subtitle"] = subtitle }
  return out
}

func arg(_ args: [String], _ index: Int, _ fallback: String = "") -> String {
  index < args.count ? args[index] : fallback
}

func intArg(_ args: [String], _ index: Int, _ fallback: Int) -> Int {
  Int(arg(args, index)) ?? fallback
}

/// One host-RPC arm: canonical params per ../README.md, reply message =
/// verbatim host result as JSON. Nil when the subcommand is not an arm.
func hostArm(_ subcommand: String, _ args: [String]) -> [String: Any?]? {
  let call: (method: String, params: [String: Any?])
  switch subcommand {
  case "ping": call = ("host.ping", [:])
  case "fetch": call = ("host.fetch", ["url": arg(args, 0)])
  case "open": call = ("host.open", ["url": arg(args, 0)])
  case "clipboard": call = ("host.clipboard_write", ["text": arg(args, 0)])
  case "notify": call = ("host.notify", ["message": arg(args, 0)])
  case "storage-set": call = ("host.storage_set", ["key": arg(args, 0), "value": arg(args, 1)])
  case "storage-get": call = ("host.storage_get", ["key": arg(args, 0)])
  case "media": call = ("host.post_media_key", ["key_code": intArg(args, 0, 16)])
  case "ps": call = ("host.process_table", [:])
  case "signal": call = ("host.signal", ["pid": intArg(args, 0, targetPID)])
  case "keys":
    call = (
      "host.post_keys", ["pid": targetPID, "keys": [["key_code": 4, "modifiers": ["command"]]]]
    )
  case "global-key": call = ("host.post_global_key", ["key_code": 4, "modifiers": ["command"]])
  case "ax-snapshot": call = ("host.ax_snapshot", ["pid": targetPID, "roots": "app"])
  case "activate": call = ("host.activate", ["pid": targetPID])
  case "normal-mode-target": call = ("host.normal_mode_target", [:])
  default: return nil
  }
  let result = runtime.callHost(method: call.method, params: call.params)
  return ok(["message": jsonText(result)])
}

runtime.onStart = {
  if conformanceConfig()["skip_publish"] as? Bool == true { return }
  runtime.publish(catalog())
}

runtime.onEvent = { name, _ in rememberEvent(name) }

runtime.onEvaluate = { params in
  switch params["query"] as? String ?? "" {
  case "conf:one": return [answer("one", subtitle: "s")]
  case "conf:unicode": return [answer("héllo ⚡ 世界")]
  case "conf:many": return (1...17).map { answer("a\($0)") }
  default: return []
  }
}

runtime.onSearch = { params in
  let query = params["query"] as? String ?? ""
  return catalog().filter { (($0["title"] as? String) ?? "").contains(query) }
}

runtime.onHints = { _ in
  (
    [
      [
        "id": "t1", "frame": ["x": -10.5, "y": 20, "width": 30, "height": 40],
        "role": "AXLink", "label": "one",
      ],
      [
        "id": "t2", "frame": ["x": 0, "y": 0, "width": 10, "height": 10],
        "role": "FlashTerminalLink", "label": "two",
      ],
    ], nil
  )
}

runtime.onResolve = { params in
  let row = params["row"] as? [String: Any?] ?? [:]
  return row["title"] as? String == "alpha" ? ok(["target_pid": targetPID]) : unhandled()
}

runtime.onAction = { params in
  switch params["name"] as? String ?? "" {
  case "conf_performed": return ok(["target_pid": targetPID])
  case "conf_failed": return fail("conformance failure probe")
  default: return unhandled()
  }
}

runtime.onNavigate = { params in
  params["url"] as? String == "conformance://ok" ? ok() : unhandled()
}

runtime.onCommand = { params in
  let subcommand = params["subcommand"] as? String ?? ""
  let args = (params["args"] as? [Any] ?? []).map { "\($0)" }
  switch subcommand {
  case "echo":
    let payload: [String: Any] = [
      "args": params["args"] as? [Any] ?? [],
      "raw": params["raw"] as? String ?? "",
    ]
    return ok(["message": jsonText(payload)])
  case "env":
    return ok(["message": jsonText(ProcessInfo.processInfo.environment)])
  case "env-has":
    let present = ProcessInfo.processInfo.environment[arg(args, 0)] != nil
    return ok(["message": present ? "present" : "absent"])
  case "config":
    return ok(["message": jsonText(config())])
  case "state":
    return ok(["message": lastEvent()])
  case "target-pid":
    return ok(["target_pid": targetPID])
  case "toast":
    return ok(["message": "hello from conformance"])
  case "sleep":
    Thread.sleep(forTimeInterval: Double(intArg(args, 0, 0)) / 1000.0)
    return ok()
  case "crash":
    exit(Int32(intArg(args, 0, 1)))
  case "exit-after-reply":
    let code = Int32(intArg(args, 0, 0))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { exit(code) }
    return ok()
  case "stderr":
    FileHandle.standardError.write(
      Data(repeating: UInt8(ascii: "x"), count: intArg(args, 0, 0) * 1024))
    return ok()
  case "log":
    runtime.log(arg(args, 0, "info"), args.dropFirst().joined(separator: " "))
    return ok()
  case "status":
    runtime.status([arg(args, 0): arg(args, 1)])
    return ok()
  case "publish-extra":
    runtime.publish(catalog() + [["source": sourceName, "title": "delta"]])
    return ok()
  default:
    return hostArm(subcommand, args) ?? fail("unsupported subcommand: \(subcommand)")
  }
}

runtime.onShutdown = {
  runtime.log("info", "conformance shutdown")
}

runtime.serve()

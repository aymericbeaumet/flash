// macOS Shortcuts in the flashlight, in Swift (one of the deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Same shape as the reminders plugin: initialize is answered immediately
// and an AppleScript listing against the faceless "Shortcuts Events"
// service publishes the catalog whenever it lands (5-minute poll + config
// events + `:shortcuts refresh`; the poll republishes only on change).
// perform {kind: "resolve"} runs the picked shortcut through the same
// service (no Shortcuts.app window ever opens), and `:shortcuts open`
// raises the app via `host.open`. Unlike reminders, the target service is
// not a running app — the AppleEvent must *launch* Shortcuts Events, which
// the deny-default seatbelt profile cannot allow — so this plugin uses the
// unsandboxed `subprocess` capability shape like tmux.

import Foundation

let pollSeconds: Double = 300

let listScript = """
  tell application "Shortcuts Events"
    set output to name of every shortcut
  end tell
  set AppleScript's text item delimiters to linefeed
  return output as text
  """

func runScript(shortcutName: String) -> String {
  """
  tell application "Shortcuts Events"
    run shortcut named \(applescriptQuote(shortcutName))
  end tell
  """
}

let runtime = PluginRuntime()

func rows(fromNames names: [String]) -> [[String: Any?]] {
  names.map { name in
    [
      "source": "shortcuts.entries",
      "title": name,
      "metadata": [
        "kind": "shortcut",
        "subtitle": "Shortcut",
        "payload": name,
      ] as [String: Any?],
    ]
  }
}

// Serialized so poll ticks, events, and `:shortcuts refresh` never overlap;
// also guards lastPublished.
let refreshQueue = DispatchQueue(label: "shortcuts.refresh")
var lastPublished: [String]?

/// List and publish on change (publish IS the invalidation — an unchanged
/// listing stays silent). On failure, don't publish — the host keeps the
/// last-good catalog; a successful empty listing IS published.
@discardableResult
func refresh() -> Bool {
  refreshQueue.sync {
    let startedAt = Date()
    let result = runOsascript(listScript, timeoutSeconds: 30)
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    guard result.ok else {
      runtime.log(
        "warn", "[shortcuts] list failed: \(result.stderr.trimmingCharacters(in: .whitespaces))")
      runtime.log(
        "debug", "[shortcuts] refresh",
        fields: ["outcome": "failed", "rows": "0", "elapsed_ms": "\(elapsedMs)"])
      return false
    }
    var seen = Set<String>()
    let names = result.stdout.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
    if names != lastPublished {
      lastPublished = names
      runtime.publish(rows(fromNames: names))
    }
    runtime.log(
      "debug", "[shortcuts] refresh",
      fields: [
        "outcome": names.isEmpty ? "empty" : "ok",
        "rows": "\(names.count)",
        "elapsed_ms": "\(elapsedMs)",
      ])
    return true
  }
}

runtime.onStart = {
  // initialize was already answered; the first publish lands whenever the
  // AppleScript listing does.
  refresh()
  // 5-minute poll; refreshes are serialized on refreshQueue.
  let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  timer.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
  timer.setEventHandler { refresh() }
  timer.activate()
  _ = Unmanaged.passRetained(timer as AnyObject)  // keep the source alive for the process lifetime
}

runtime.onEvent = { name, _ in
  if name == "core:config.changed" {
    refresh()
  }
}

runtime.onCommand = { params in
  switch params["subcommand"] as? String ?? "" {
  case "open":
    // Fork-free: the host launches the app; reply only after its verdict.
    let result = runtime.callHost(
      method: "host.open", params: ["bundle_id": "com.apple.shortcuts"])
    return result["ok"] as? Bool == true ? ok() : fail("host.open failed")
  case "refresh":
    return refresh() ? ok(["message": "shortcuts refreshed"]) : fail("shortcuts refresh failed")
  case let other:
    return fail("unknown subcommand: \(other)")
  }
}

runtime.onResolve = { params in
  let row = params["row"] as? [String: Any?] ?? [:]
  let metadata = row["metadata"] as? [String: Any?] ?? [:]
  guard let name = metadata["payload"] as? String, !name.isEmpty else {
    return fail("row payload carries no shortcut name")
  }
  let result = runOsascript(runScript(shortcutName: name), timeoutSeconds: 30)
  return result.ok ? ok() : fail("shortcut run failed")
}

runtime.serve()

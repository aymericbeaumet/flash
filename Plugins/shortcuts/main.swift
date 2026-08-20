// macOS Shortcuts in the flashlight, in Swift (one of the deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Same shape as the reminders plugin: an AppleScript listing against the
// faceless "Shortcuts Events" service keeps the `plugin:shortcuts` warm
// catalog fresh (5-minute poll + config events + `:shortcuts refresh`),
// `candidate.resolve` runs the picked shortcut through the same service
// (no Shortcuts.app window ever opens), and `:shortcuts open` raises the
// app via `host.open`. Unlike reminders, the target service is not a
// running app — the AppleEvent must *launch* Shortcuts Events, which the
// deny-default seatbelt profile cannot allow — so this plugin uses the
// unsandboxed `subprocess` capability shape like tmux.

import Foundation

let sourceID = "plugin:shortcuts"
let pollSeconds: Double = 300
let startupRefreshBudget: Double = 8

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

func candidates(fromListing output: String) -> [[String: Any?]] {
  var seen = Set<String>()
  var rows: [[String: Any?]] = []
  for line in output.split(separator: "\n") {
    let name = line.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, seen.insert(name).inserted else { continue }
    rows.append([
      "title": name,
      "metadata": [
        "source": "shortcuts.entries",
        "kind": "shortcut",
        "subtitle": "Shortcut",
        "payload": name,
      ] as [String: Any?],
    ])
  }
  return rows
}

@discardableResult
func refreshCandidates() -> Bool {
  let startedAt = Date()
  let result = runOsascript(listScript, timeoutSeconds: 30)
  let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
  guard result.ok else {
    runtime.log(
      "warn", "[shortcuts] list failed: \(result.stderr.trimmingCharacters(in: .whitespaces))")
    runtime.log(
      "debug", "[shortcuts] warm refresh",
      fields: ["outcome": "failed", "candidates": "0", "elapsed_ms": "\(elapsedMs)"])
    return false
  }
  let rows = candidates(fromListing: result.stdout)
  runtime.setLocations(sourceID, rows)
  runtime.log(
    "debug", "[shortcuts] warm refresh",
    fields: [
      "outcome": rows.isEmpty ? "empty" : "ok",
      "candidates": "\(rows.count)",
      "elapsed_ms": "\(elapsedMs)",
    ])
  return true
}

runtime.onStart = {
  // Bounded startup: refresh on a worker with an 8s budget; on timeout or
  // failure publish a logged degraded-empty baseline (never overwriting a
  // last-good store — there is none at startup) and retry in the background.
  let done = DispatchSemaphore(value: 0)
  var succeeded = false
  DispatchQueue.global(qos: .userInitiated).async {
    succeeded = refreshCandidates()
    done.signal()
  }
  if done.wait(timeout: .now() + startupRefreshBudget) == .timedOut || !succeeded {
    if !runtime.hasLocations(sourceID) {
      runtime.log(
        "warn", "[shortcuts] initial warm catalog degraded",
        fields: ["outcome": "empty_without_last_good", "retry": "immediate_background"])
      runtime.setLocations(sourceID, [])
    }
    DispatchQueue.global(qos: .utility).async { refreshCandidates() }
  }
  // 5-minute poll, non-overlapping by construction (serial utility work).
  let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  timer.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
  timer.setEventHandler { refreshCandidates() }
  timer.activate()
  _ = Unmanaged.passRetained(timer as AnyObject)  // keep the source alive for the process lifetime
}

runtime.onEvent = { name, _ in
  if name == "core:config.changed" {
    refreshCandidates()
  }
}

runtime.onCommand = { params in
  switch params["subcommand"] as? String ?? "" {
  case "open":
    // Fork-free: the host launches the app (`host.open`).
    let done = DispatchSemaphore(value: 0)
    var opened = false
    runtime.callHost(method: "host.open", params: ["bundle_id": "com.apple.shortcuts"]) {
      result in
      opened = result["ok"] as? Bool == true
      done.signal()
    }
    _ = done.wait(timeout: .now() + 10)
    return opened ? ["ok": true] : ["ok": false, "error": "host.open failed"]
  case "refresh":
    return refreshCandidates()
      ? ["ok": true, "stdout": "shortcuts refreshed"]
      : ["ok": false, "error": "shortcuts refresh failed"]
  case let other:
    return ["ok": false, "error": "unknown subcommand: \(other)"]
  }
}

runtime.onResolve = { params in
  let candidate = params["candidate"] as? [String: Any?] ?? params
  let metadata = candidate["metadata"] as? [String: Any?] ?? [:]
  guard let name = metadata["payload"] as? String, !name.isEmpty else {
    return ["ok": false]
  }
  let result = runOsascript(runScript(shortcutName: name), timeoutSeconds: 30)
  return ["ok": result.ok]
}

runtime.serve()

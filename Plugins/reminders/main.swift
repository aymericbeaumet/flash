// macOS Reminders in the flashlight, in Swift (one of the deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Faithful port of the Rust implementation: an AppleScript listing keeps
// the `plugin:reminders` warm catalog fresh (60s poll + app lifecycle
// events), `candidate.resolve` re-opens the picked reminder by id, and
// `:reminders open|refresh` are the two commands. The listing script
// itself guards on Reminders.app running, so a stopped app yields an
// authoritative empty catalog.

import Foundation

let sourceID = "plugin:reminders"
let pollSeconds: Double = 60
let startupRefreshBudget: Double = 8

let listScript = """
  if application "Reminders" is not running then return ""
  tell application "Reminders"
    set output to {}
    repeat with l in lists
      try
        repeat with r in (reminders of l whose completed is false)
          set the end of output to ((id of r as text) & tab & (name of l as text) & tab & (name of r as text))
        end repeat
      end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    return output as text
  end tell
  """

func selectScript(reminderID: String) -> String {
  """
  tell application "Reminders"
    activate
    try
      show reminder id \(applescriptQuote(reminderID))
    end try
  end tell
  """
}

let runtime = PluginRuntime()

func candidates(fromListing output: String) -> [[String: Any?]] {
  var seen = Set<String>()
  var rows: [[String: Any?]] = []
  for line in output.split(separator: "\n") {
    let parts = line.trimmingCharacters(in: .whitespaces)
      .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { continue }
    let id = parts[0].trimmingCharacters(in: .whitespaces)
    let list = parts[1].trimmingCharacters(in: .whitespaces)
    let title = parts[2].trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { continue }
    let payload = try? JSONSerialization.data(
      withJSONObject: ["id": id, "list": list, "title": title])
    rows.append([
      "title": title,
      "metadata": [
        "source": "reminders.tasks",
        "source_id": sourceID,
        "kind": "reminder",
        "subtitle": "Reminder — \(list)",
        "payload": String(data: payload ?? Data(), encoding: .utf8) ?? "",
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
      "warn", "[reminders] list failed: \(result.stderr.trimmingCharacters(in: .whitespaces))")
    runtime.log(
      "debug", "[reminders] warm refresh",
      fields: ["outcome": "failed", "candidates": "0", "elapsed_ms": "\(elapsedMs)"])
    return false
  }
  let rows = candidates(fromListing: result.stdout)
  runtime.setLocations(sourceID, rows)
  runtime.log(
    "debug", "[reminders] warm refresh",
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
        "warn", "[reminders] initial warm catalog degraded",
        fields: ["outcome": "empty_without_last_good", "retry": "immediate_background"])
      runtime.setLocations(sourceID, [])
    }
    DispatchQueue.global(qos: .utility).async { refreshCandidates() }
  }
  // 60s poll, non-overlapping by construction (serial utility queue work).
  let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  timer.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
  timer.setEventHandler { refreshCandidates() }
  timer.activate()
  _ = Unmanaged.passRetained(timer as AnyObject)  // keep the source alive for the process lifetime
}

runtime.onEvent = { name, payload in
  let isReminders = payload["bundle_id"] as? String == "com.apple.reminders"
  if name == "core:apps.terminated" && isReminders {
    // Termination is authoritative and needs no AppleScript round trip.
    runtime.setLocations(sourceID, [])
  } else if (name == "core:apps.launched" && isReminders) || name == "core:config.changed" {
    refreshCandidates()
  }
}

runtime.onCommand = { params in
  switch params["subcommand"] as? String ?? "" {
  case "open":
    let result = runCommand(
      ["/usr/bin/open", "-b", "com.apple.reminders"], timeoutSeconds: 10)
    return result.ok
      ? ["ok": true]
      : ["ok": false, "error": result.stderr.trimmingCharacters(in: .whitespaces)]
  case "refresh":
    return refreshCandidates()
      ? ["ok": true, "stdout": "reminders refreshed"]
      : ["ok": false, "error": "reminders refresh failed"]
  case let other:
    return ["ok": false, "error": "unknown subcommand: \(other)"]
  }
}

runtime.onResolve = { params in
  let candidate = params["candidate"] as? [String: Any?] ?? params
  let metadata = candidate["metadata"] as? [String: Any?] ?? [:]
  guard
    let payload = (metadata["payload"] as? String)?.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
    let reminderID = object["id"] as? String, !reminderID.isEmpty
  else {
    return ["ok": false]
  }
  let result = runOsascript(selectScript(reminderID: reminderID), timeoutSeconds: 10)
  return ["ok": result.ok]
}

runtime.serve()

// macOS Reminders in the flashlight, in Swift (one of the deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Faithful port of the Rust implementation: initialize is answered
// immediately and an AppleScript listing publishes the catalog whenever it
// lands (60s poll + app lifecycle events; a Reminders.app termination is an
// authoritative empty published without a round trip). perform {kind:
// "resolve"} re-opens the picked reminder by id, and `:reminders
// open|refresh` arrive as perform {kind: "command"}. The listing script
// itself guards on Reminders.app running, so a stopped app yields an
// authoritative empty catalog.

import Foundation

let pollSeconds: Double = 60

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

func rows(fromListing output: String) -> [[String: Any?]] {
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
      "source": "reminders.tasks",
      "title": title,
      "metadata": [
        "kind": "reminder",
        "subtitle": "Reminder — \(list)",
        "payload": String(data: payload ?? Data(), encoding: .utf8) ?? "",
      ] as [String: Any?],
    ])
  }
  return rows
}

// Serialized so poll ticks, events, and `:reminders refresh` never overlap.
let refreshQueue = DispatchQueue(label: "reminders.refresh")

/// List and publish. On failure, don't publish — the host keeps the
/// last-good catalog; a successful empty listing IS published (Reminders
/// stopped or emptied is an authoritative empty).
@discardableResult
func refresh() -> Bool {
  refreshQueue.sync {
    let startedAt = Date()
    let result = runOsascript(listScript, timeoutSeconds: 30)
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    guard result.ok else {
      runtime.log(
        "warn", "[reminders] list failed: \(result.stderr.trimmingCharacters(in: .whitespaces))")
      runtime.log(
        "debug", "[reminders] refresh",
        fields: ["outcome": "failed", "rows": "0", "elapsed_ms": "\(elapsedMs)"])
      return false
    }
    let catalog = rows(fromListing: result.stdout)
    runtime.publish(catalog)
    runtime.log(
      "debug", "[reminders] refresh",
      fields: [
        "outcome": catalog.isEmpty ? "empty" : "ok",
        "rows": "\(catalog.count)",
        "elapsed_ms": "\(elapsedMs)",
      ])
    return true
  }
}

runtime.onStart = {
  // initialize was already answered; the first publish lands whenever the
  // AppleScript listing does.
  refresh()
  // 60s poll; refreshes are serialized on refreshQueue, never overlapping.
  let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  timer.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
  timer.setEventHandler { refresh() }
  timer.activate()
  _ = Unmanaged.passRetained(timer as AnyObject)  // keep the source alive for the process lifetime
}

runtime.onEvent = { name, payload in
  let isReminders = payload["bundle_id"] as? String == "com.apple.reminders"
  if name == "core:apps.terminated" && isReminders {
    // Termination is authoritative and needs no AppleScript round trip.
    runtime.publish([])
  } else if (name == "core:apps.launched" && isReminders) || name == "core:config.changed" {
    refresh()
  }
}

runtime.onCommand = { params in
  switch params["subcommand"] as? String ?? "" {
  case "open":
    // Fork-free: the host launches the app; reply only after its verdict.
    let result = runtime.callHost(
      method: "host.open", params: ["bundle_id": "com.apple.reminders"])
    return result["ok"] as? Bool == true ? ok() : fail("host.open failed")
  case "refresh":
    return refresh() ? ok(["message": "reminders refreshed"]) : fail("reminders refresh failed")
  case let other:
    return fail("unknown subcommand: \(other)")
  }
}

runtime.onResolve = { params in
  let row = params["row"] as? [String: Any?] ?? [:]
  let metadata = row["metadata"] as? [String: Any?] ?? [:]
  guard
    let payload = (metadata["payload"] as? String)?.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
    let reminderID = object["id"] as? String, !reminderID.isEmpty
  else {
    return fail("row payload carries no reminder id")
  }
  let result = runOsascript(selectScript(reminderID: reminderID), timeoutSeconds: 10)
  return result.ok ? ok() : fail("reminder selection failed")
}

runtime.serve()

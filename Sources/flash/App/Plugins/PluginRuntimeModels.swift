import CoreGraphics
import FlashCore
import Foundation

/// Runtime-side plugin models: process/lifecycle state, status reporting,
/// and events. None of this is manifest schema — the manifest file stays
/// decode-only.

/// One failure envelope for the whole plugin subsystem — the message is the
/// diagnosis; the phase it failed in is evident from the call site and log.
enum PluginError: Error, CustomStringConvertible {
  case failure(String)

  var description: String {
    switch self {
    case .failure(let message):
      return message
    }
  }
}

enum PluginOrigin: Equatable {
  case official
  case github(String)
  case file(String)

  var label: String {
    switch self {
    case .official:
      return "official"
    case .github(let ref), .file(let ref):
      return ref
    }
  }
}

/// The five-state lifecycle machine:
/// stopped → installing → launching → running → stopped, with `failed` the
/// parked terminal (no auto-restart; watchers stay armed). Manifest-only
/// plugins never enter the machine and report a static label instead.
enum PluginRuntimeState: String {
  case stopped
  case installing
  case launching
  case running
  case failed
}

/// How (and whether) a plugin's child process is scheduled. Derived from the
/// manifest alone.
enum PluginActivation: String {
  /// Spawned at startup and kept running: the manifest declares `sources`,
  /// `query`, `hints`, `status`, or `listen`.
  case resident
  /// Stays unspawned until its first `perform` (the perform deadline absorbs
  /// the startup budget), then remains running.
  case onDemand = "on_demand"
  /// No `exec`: no child process ever runs; the host serves the manifest's
  /// inline surfaces alone.
  case manifestOnly = "manifest_only"
}

struct PluginEvent {
  var name: String
  var payload: [String: Any]
  var bundleID: String?
  /// Front window frame (screen coordinates). Optional — only meaningful
  /// for app-scoped events like `focus.changed`, `ax.changed`. Passed
  /// through to plugins as `payload.front_window_frame`.
  var frontWindowFrame: CGRect?
  /// Process id of the focused app for the event. Some events embed this
  /// in `payload.pid` already.
  var pid: pid_t?
}

struct PluginStatus {
  var id: String
  var name: String
  var version: String
  var description: String
  var origin: String
  var root: String
  var state: String
  var activation: String
  var pid: Int?
  var uptimeMs: Int?
  var sourceCount: Int
  var commandCount: Int
  var restartCount: Int
  var lastError: String?
  var lastLog: String?
  /// Instantaneous CPU usage (% of one core) sampled from the plugin's
  /// own subprocess; `nil` until the second sample lets us compute a
  /// delta, or when the process isn't running.
  var cpuPercent: Double?
  /// Resident set size in bytes for the plugin subprocess.
  var memoryBytes: Int?
  /// Bundle identifiers the plugin's root selector is scoped to.
  var onlyBundleIDs: [String]
  /// Declared scheduling priority from the manifest.
  var priority: Int
  /// Registered commands (command / subcommand / description triples).
  var commands: [PluginCommandRegistration]
  /// Runtime status-bar segments keyed by the manifest-declared segment name.
  var statusSegments: [String: String]

  var jsonObject: [String: Any] {
    [
      "activation": activation,
      "command_count": commandCount,
      "commands": commands.map {
        ["command": $0.command, "subcommand": $0.subcommand, "description": $0.description]
      },
      "cpu_percent": cpuPercent ?? NSNull(),
      "description": description,
      "id": id,
      "last_error": lastError ?? NSNull(),
      "last_log": lastLog ?? NSNull(),
      "memory_bytes": memoryBytes ?? NSNull(),
      "name": name,
      "only_bundle_ids": onlyBundleIDs,
      "origin": origin,
      "pid": pid ?? NSNull(),
      "priority": priority,
      "restart_count": restartCount,
      "root": root,
      "source_count": sourceCount,
      "state": state,
      "status_segments": statusSegments,
      "uptime_ms": uptimeMs ?? NSNull(),
      "version": version,
    ]
  }
}

/// The four fields the status bar actually renders, published every clock
/// tick and focus change. Unlike `PluginStatus` this carries no rusage
/// sample and no commands copy — keep it allocation-light.
struct PluginStatusBarInfo {
  var id: String
  var state: String
  var hasError: Bool
  var statusSegments: [String: String]
}

/// One reply to the unified `perform` method: the universal trichotomy.
/// `unhandled` means "not my context" and the host MAY fall back; `failed`
/// means "mine, but it broke" and the host MUST NOT fall back (no reply,
/// timeout, and crash all coerce here — the action may still land late and a
/// keystroke fallback would double-fire).
enum PluginPerformOutcome: Equatable {
  case performed(pid: pid_t?, navigationURL: URL?, message: String?)
  case unhandled
  case failed(String)
}

struct PluginWireTarget {
  var id: String
  var frame: CGRect
  var role: String?
  var label: String?
  var url: String?
  var pid: pid_t?
  var entersInsertMode: Bool
  var sourceID: String
  /// Source-declared target salience. `.important` and `.urgent` render with
  /// the accent hint style.
  var priority: FlashPriority
}

import CoreGraphics
import FlashCore
import Foundation

/// Runtime-side plugin models: process/lifecycle state, status reporting,
/// events, and the hint-path discovery cache. None of this is manifest
/// schema — the manifest file stays decode-only.

enum PluginError: Error, CustomStringConvertible {
  case invalidManifest(String)
  case invalidReference(String)
  case processLaunch(String)

  var description: String {
    switch self {
    case .invalidManifest(let message), .invalidReference(let message), .processLaunch(let message):
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

enum PluginRuntimeState: String {
  case unloaded
  case installing
  case starting
  case ready
  case degraded
  case crashed
  case stopped
}

struct PluginEvent {
  var name: String
  var payload: [String: Any]
  var bundleID: String?
  var configPath: String?
  var focused: Bool?
  /// Front window frame (screen coordinates). Optional — only meaningful
  /// for app-scoped events like `focus.changed`, `ax.changed`. Passed
  /// through to plugins as `payload.front_window_frame`.
  var frontWindowFrame: CGRect?
  /// Process id of the focused app for the event. Some events embed this
  /// in `payload.pid` already; setting this here also lets PluginProcess
  /// scope its discovery to the right context.
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
  var pid: Int?
  var uptimeMs: Int?
  var heartbeatAgeMs: Int?
  var sourceCount: Int
  var commandCount: Int
  var targetCount: Int
  var discoveryAgeMs: Int?
  var restartCount: Int
  var lastError: String?
  var lastLog: String?
  /// Instantaneous CPU usage (% of one core) sampled from the plugin's
  /// own subprocess; `nil` until the second sample lets us compute a
  /// delta, or when the process isn't running.
  var cpuPercent: Double?
  /// Resident set size in bytes for the plugin subprocess.
  var memoryBytes: Int?
  /// Bundle identifiers / URL patterns the plugin's source is scoped to.
  var onlyBundleIDs: [String]
  var onlyURLs: [String]
  /// Whether the plugin reloads on file change.
  var volatile: Bool
  /// Declared scheduling priority from the manifest.
  var priority: Int
  /// Registered commands (command / subcommand / description triples).
  var commands: [PluginCommandRegistration]
  /// Runtime status-bar segments keyed by the manifest-declared segment name.
  var statusSegments: [String: String]

  var jsonObject: [String: Any] {
    [
      "only_bundle_ids": onlyBundleIDs,
      "only_urls": onlyURLs,
      "command_count": commandCount,
      "commands": commands.map {
        ["command": $0.command, "subcommand": $0.subcommand, "description": $0.description]
      },
      "cpu_percent": cpuPercent ?? NSNull(),
      "description": description,
      "heartbeat_age_ms": heartbeatAgeMs ?? NSNull(),
      "id": id,
      "last_error": lastError ?? NSNull(),
      "last_log": lastLog ?? NSNull(),
      "memory_bytes": memoryBytes ?? NSNull(),
      "name": name,
      "origin": origin,
      "pid": pid ?? NSNull(),
      "priority": priority,
      "restart_count": restartCount,
      "root": root,
      "discovery_age_ms": discoveryAgeMs ?? NSNull(),
      "source_count": sourceCount,
      "state": state,
      "status_segments": statusSegments,
      "target_count": targetCount,
      "uptime_ms": uptimeMs ?? NSNull(),
      "version": version,
      "volatile": volatile,
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

/// Per-plugin host-side state for the **hint** path (`f`) and status bar.
/// Candidates are NOT here: flashlight rows are pulled live from warm plugins
/// via `sources.snapshot`, never cached on the host (see `PluginFlashSource`).
struct PluginDiscovery {
  var targets: [PluginWireTarget] = []
  var statusSegments: [String: String] = [:]
  var contextPID: pid_t?
  var updatedAt: Date?
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

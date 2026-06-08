import AppKit
import Darwin
import FlashCore
import Foundation

struct PluginEventSubscription: Codable, Equatable {
  var match: String
  var bundleIDs: [String]
  var paths: [String]
  var focusedOnly: Bool
  var debounceMs: Int?

  init(
    match: String,
    bundleIDs: [String] = [],
    paths: [String] = [],
    focusedOnly: Bool = false,
    debounceMs: Int? = nil
  ) {
    self.match = match
    self.bundleIDs = bundleIDs
    self.paths = paths
    self.focusedOnly = focusedOnly
    self.debounceMs = debounceMs
  }

  init(from decoder: Decoder) throws {
    if let raw = try? decoder.singleValueContainer().decode(String.self) {
      self.init(match: raw)
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let match = try c.decode(String.self, forKey: .match)
    let bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    let paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    let focusedOnly = try c.decodeIfPresent(Bool.self, forKey: .focusedOnly) ?? false
    let debounceMs = try c.decodeIfPresent(Int.self, forKey: .debounceMs)
    self.init(
      match: match,
      bundleIDs: bundleIDs,
      paths: paths,
      focusedOnly: focusedOnly,
      debounceMs: debounceMs)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(match, forKey: .match)
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
    if !paths.isEmpty { try c.encode(paths, forKey: .paths) }
    if focusedOnly { try c.encode(focusedOnly, forKey: .focusedOnly) }
    if let debounceMs { try c.encode(debounceMs, forKey: .debounceMs) }
  }

  enum CodingKeys: String, CodingKey {
    case match
    case bundleIDs = "bundle_ids"
    case paths
    case focusedOnly = "focused_only"
    case debounceMs = "debounce_ms"
  }

  func matches(_ event: PluginEvent) -> Bool {
    guard Self.pattern(match, matches: event.name) else { return false }
    if !bundleIDs.isEmpty {
      guard let bundleID = event.bundleID, bundleIDs.contains(bundleID) else { return false }
    }
    if !paths.isEmpty {
      guard let path = event.configPath else { return false }
      guard paths.contains(where: { Self.pattern($0, matches: path) }) else { return false }
    }
    if focusedOnly, event.focused != true { return false }
    return true
  }

  private static func pattern(_ pattern: String, matches value: String) -> Bool {
    if pattern == "*" { return true }
    if pattern.hasSuffix(".*") {
      return value.hasPrefix(String(pattern.dropLast(1)))
    }
    return pattern == value
  }
}

/// One subcommand a plugin registers. A plugin exposes one or more
/// **commands** (the verb the user types after `:`, e.g. `spotify`),
/// and each command has one or more **subcommands** (e.g. `play`). This
/// row is the denormalized (command, subcommand) pair the command-line
/// completion engine and the dispatch index are built from.
struct PluginCommandRegistration: Codable, Hashable {
  var command: String
  var subcommand: String
  var description: String
}

struct PluginManifest: Codable, Equatable {
  var id: String
  var name: String
  var version: String
  var description: String
  var install: String
  var start: String
  var events: [PluginEventSubscription]
  var commands: [PluginCommandRegistration]
  var priority: Int
  var volatile: Bool
  /// Bundle identifiers the source applies to. When non-empty, restricts
  /// `supports()` and jump-target discovery to these apps. Mirrors the
  /// `bundle_ids` filter used on event subscriptions but applies even when
  /// the manifest doesn't subscribe to `focus.changed`.
  var bundleIDs: [String]

  enum CodingKeys: String, CodingKey {
    case id, name, version, description, install, start, events, commands, priority
    case volatile
    case bundleIDs = "bundle_ids"
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String, start: String,
    events: [PluginEventSubscription] = [],
    commands: [PluginCommandRegistration] = [],
    priority: Int = 25,
    volatile: Bool = false,
    bundleIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.install = install
    self.start = start
    self.events = events
    self.commands = commands
    self.priority = priority
    self.volatile = volatile
    self.bundleIDs = bundleIDs
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.version = try c.decode(String.self, forKey: .version)
    self.description = try c.decode(String.self, forKey: .description)
    self.install = try c.decode(String.self, forKey: .install)
    self.start = try c.decode(String.self, forKey: .start)
    self.events = try c.decodeIfPresent([PluginEventSubscription].self, forKey: .events) ?? []
    self.commands = try c.decodeIfPresent([PluginCommandRegistration].self, forKey: .commands) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.volatile = try c.decodeIfPresent(Bool.self, forKey: .volatile) ?? false
    self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(version, forKey: .version)
    try c.encode(description, forKey: .description)
    try c.encode(install, forKey: .install)
    try c.encode(start, forKey: .start)
    if !events.isEmpty { try c.encode(events, forKey: .events) }
    if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    try c.encode(priority, forKey: .priority)
    if volatile { try c.encode(volatile, forKey: .volatile) }
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
  }

  static func load(from root: URL) throws -> PluginManifest {
    let url = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()
    return manifest
  }

  func validate() throws {
    let required = [
      ("id", id),
      ("name", name),
      ("version", version),
      ("description", description),
      ("install", install),
      ("start", start),
    ]
    for (field, value) in required {
      if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw PluginError.invalidManifest("manifest.json field \(field) must not be empty")
      }
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard id.lowercased() == id,
      id.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw PluginError.invalidManifest("manifest.json id must be lowercase [a-z0-9._-]")
    }
    for command in commands {
      if command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || command.subcommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw PluginError.invalidManifest("plugin command and subcommand must not be empty")
      }
    }
  }
}

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
  /// scope its snapshot to the right context.
  var pid: pid_t?
}

struct PluginStatusSnapshot {
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
  var candidateCount: Int
  var snapshotAgeMs: Int?
  var restartCount: Int
  var lastError: String?
  var lastLog: String?
  /// Instantaneous CPU usage (% of one core) sampled from the plugin's
  /// own subprocess; `nil` until the second sample lets us compute a
  /// delta, or when the process isn't running.
  var cpuPercent: Double?
  /// Resident set size in bytes for the plugin subprocess.
  var memoryBytes: Int?
  /// Bundle identifiers the plugin's source is scoped to (empty = global).
  var bundleIDs: [String]
  /// Whether the plugin reloads on file change.
  var volatile: Bool
  /// Declared scheduling priority from the manifest.
  var priority: Int
  /// Registered commands (command / subcommand / description triples).
  var commands: [PluginCommandRegistration]

  var jsonObject: [String: Any] {
    [
      "bundle_ids": bundleIDs,
      "command_count": commandCount,
      "commands": commands.map {
        ["command": $0.command, "subcommand": $0.subcommand, "description": $0.description]
      },
      "candidate_count": candidateCount,
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
      "snapshot_age_ms": snapshotAgeMs ?? NSNull(),
      "source_count": sourceCount,
      "state": state,
      "target_count": targetCount,
      "uptime_ms": uptimeMs ?? NSNull(),
      "version": version,
      "volatile": volatile,
    ]
  }
}

struct PluginSnapshot {
  var targets: [PluginWireTarget] = []
  var candidates: [Candidate] = []
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
  var sourceID: String
}

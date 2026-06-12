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
  /// Apps this command is gated to (empty = every app). Mirrors
  /// ``PluginMappingRegistration/bundleIDs``: normally inherited from the
  /// owning `commands` provider's `bundle_ids` (folded in by
  /// ``PluginManifest/commands``), so a command only resolves while one of
  /// these apps is focused. The index gate uses the same predicate as
  /// mappings.
  var bundleIDs: [String]
  /// Arbitrary `_`-prefixed fields from the manifest entry. Flash itself
  /// ignores them; they are forwarded verbatim to the plugin on
  /// `command.invoke` so a plugin can keep per-subcommand data (e.g. `web`
  /// stores its URL template as `_url`) in the manifest instead of
  /// duplicating it in code.
  var meta: [String: String]

  init(
    command: String,
    subcommand: String,
    description: String,
    bundleIDs: [String] = [],
    meta: [String: String] = [:]
  ) {
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.bundleIDs = bundleIDs
    self.meta = meta
  }

  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    func string(_ key: String) -> String? {
      try? c.decode(String.self, forKey: DynamicKey(stringValue: key))
    }
    self.command = string("command") ?? ""
    self.subcommand = string("subcommand") ?? ""
    self.description = string("description") ?? ""
    self.bundleIDs =
      (try? c.decode([String].self, forKey: DynamicKey(stringValue: "bundle_ids"))) ?? []
    var meta: [String: String] = [:]
    for key in c.allKeys where key.stringValue.hasPrefix("_") {
      if let value = try? c.decode(String.self, forKey: key) {
        meta[key.stringValue] = value
      }
    }
    self.meta = meta
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    try c.encode(command, forKey: DynamicKey(stringValue: "command"))
    try c.encode(subcommand, forKey: DynamicKey(stringValue: "subcommand"))
    try c.encode(description, forKey: DynamicKey(stringValue: "description"))
    if !bundleIDs.isEmpty {
      try c.encode(bundleIDs, forKey: DynamicKey(stringValue: "bundle_ids"))
    }
    for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
      try c.encode(value, forKey: DynamicKey(stringValue: key))
    }
  }
}

/// One flashlight bang a plugin registers. When a flashlight submission
/// starts with `!<token>` (e.g. `!r cat`), core routes the remainder to the
/// owning `shebang` provider's `command`. A `token` of `"*"` is a catch-all:
/// the plugin claims every otherwise-unclaimed bang and resolves it itself —
/// how `searchengines` serves the full DuckDuckGo bang table without
/// enumerating thousands of entries in the manifest.
struct PluginShebangRegistration: Codable, Hashable {
  var token: String
  /// The plugin command this bang invokes. Normally inherited from the owning
  /// `shebang` provider's `command` (folded in by ``PluginManifest/shebangs``);
  /// an entry may override it. Dispatched as the `command` on `command.invoke`,
  /// with the bang `token` as the subcommand — so a `shebang` provider needs no
  /// matching `commands` entry.
  var command: String
  var description: String
  /// Apps this bang is gated to (empty = every app). Folded from the owning
  /// provider's `bundle_ids` by ``PluginManifest/shebangs``.
  var bundleIDs: [String]
  /// Arbitrary `_`-prefixed manifest fields forwarded verbatim on invoke, so a
  /// plugin can keep per-bang data (e.g. a URL template) in the manifest.
  var meta: [String: String]

  init(
    token: String,
    command: String = "",
    description: String = "",
    bundleIDs: [String] = [],
    meta: [String: String] = [:]
  ) {
    self.token = token
    self.command = command
    self.description = description
    self.bundleIDs = bundleIDs
    self.meta = meta
  }

  private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    func string(_ key: String) -> String? {
      try? c.decode(String.self, forKey: DynamicKey(stringValue: key))
    }
    self.token = string("token") ?? ""
    self.command = string("command") ?? ""
    self.description = string("description") ?? ""
    self.bundleIDs =
      (try? c.decode([String].self, forKey: DynamicKey(stringValue: "bundle_ids"))) ?? []
    var meta: [String: String] = [:]
    for key in c.allKeys where key.stringValue.hasPrefix("_") {
      if let value = try? c.decode(String.self, forKey: key) {
        meta[key.stringValue] = value
      }
    }
    self.meta = meta
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: DynamicKey.self)
    try c.encode(token, forKey: DynamicKey(stringValue: "token"))
    if !command.isEmpty { try c.encode(command, forKey: DynamicKey(stringValue: "command")) }
    if !description.isEmpty {
      try c.encode(description, forKey: DynamicKey(stringValue: "description"))
    }
    if !bundleIDs.isEmpty {
      try c.encode(bundleIDs, forKey: DynamicKey(stringValue: "bundle_ids"))
    }
    for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
      try c.encode(value, forKey: DynamicKey(stringValue: key))
    }
  }
}

/// One key mapping a plugin registers. Mirrors a `[mode.<scope>.mappings]`
/// config entry but is app- and priority-scoped: the binding applies only
/// while one of `bundleIDs` (defaulting to the plugin's manifest bundles) is
/// focused, and `priority` decides who wins when several mappings claim the
/// same key — plugin mappings default to the manifest priority (25), so they
/// override built-in defaults (priority 0); a negative priority defers to the
/// defaults. `command` is a `flash://…` URL resolved once at registration.
struct PluginMappingRegistration: Codable, Hashable {
  var key: String
  var mode: String
  var command: String
  var bundleIDs: [String]
  var priority: Int?

  init(
    key: String,
    mode: String = "normal",
    command: String,
    bundleIDs: [String] = [],
    priority: Int? = nil
  ) {
    self.key = key
    self.mode = mode
    self.command = command
    self.bundleIDs = bundleIDs
    self.priority = priority
  }

  enum CodingKeys: String, CodingKey {
    case key, mode, command
    case bundleIDs = "bundle_ids"
    case priority
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "normal"
    self.command = try c.decode(String.self, forKey: .command)
    self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key)
    if mode != "normal" { try c.encode(mode, forKey: .mode) }
    try c.encode(command, forKey: .command)
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
    if let priority { try c.encode(priority, forKey: .priority) }
  }

  /// `mode` string → `ModeScope`; an unknown value falls back to `.normal`
  /// (the common case — overriding `f`/nav keys lives in normal mode).
  var scope: ModeScope { ModeScope(rawValue: mode) ?? .normal }
}

/// One row in a plugin's unified `providers[]` table. Every surface a plugin
/// drives — hints, candidates, commands, mappings — is one entry here, tagged
/// by ``ProviderKind`` and gated by the same optional, symmetric conditions
/// (`bundle_ids`/`modes`/`priority`). Kind-specific payloads ride alongside: a
/// `commands` provider carries `commands[]`, a `mappings` provider carries
/// `mappings[]`; `hints`/`candidates` providers just declare the capability and
/// its conditions, then stream results at runtime over RPC.
struct PluginProvider: Codable, Equatable {
  var kind: ProviderKind
  /// Apps this provider is gated to (empty = every app). Folded into each
  /// `mappings` entry's own `bundle_ids` (the entry wins) and consumed directly
  /// for hints/candidates/commands gating.
  var bundleIDs: [String]
  /// Editor modes this provider is gated to (empty = every mode).
  var modes: [ProviderMode]
  /// Scheduling priority override; `nil` inherits the manifest priority.
  var priority: Int?
  /// Plugin command shared by every bang in a `shebang` provider's `shebangs`
  /// (an entry may still override it). Ignored by the other kinds.
  var command: String
  var commands: [PluginCommandRegistration]
  var mappings: [PluginMappingRegistration]
  var shebangs: [PluginShebangRegistration]

  init(
    kind: ProviderKind,
    bundleIDs: [String] = [],
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    command: String = "",
    commands: [PluginCommandRegistration] = [],
    mappings: [PluginMappingRegistration] = [],
    shebangs: [PluginShebangRegistration] = []
  ) {
    self.kind = kind
    self.bundleIDs = bundleIDs
    self.modes = modes
    self.priority = priority
    self.command = command
    self.commands = commands
    self.mappings = mappings
    self.shebangs = shebangs
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case bundleIDs = "bundle_ids"
    case modes, priority, command, commands, mappings, shebangs
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.kind = try c.decode(ProviderKind.self, forKey: .kind)
    self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    self.modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.commands =
      try c.decodeIfPresent([PluginCommandRegistration].self, forKey: .commands) ?? []
    self.mappings =
      try c.decodeIfPresent([PluginMappingRegistration].self, forKey: .mappings) ?? []
    self.shebangs =
      try c.decodeIfPresent([PluginShebangRegistration].self, forKey: .shebangs) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
    if !modes.isEmpty { try c.encode(modes, forKey: .modes) }
    if let priority { try c.encode(priority, forKey: .priority) }
    if !command.isEmpty { try c.encode(command, forKey: .command) }
    if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    if !mappings.isEmpty { try c.encode(mappings, forKey: .mappings) }
    if !shebangs.isEmpty { try c.encode(shebangs, forKey: .shebangs) }
  }

  /// The shared activation gate this provider declares.
  var conditions: ProviderConditions {
    ProviderConditions(bundleIDs: Set(bundleIDs), modes: Set(modes))
  }
}

struct PluginManifest: Codable, Equatable {
  var id: String
  var name: String
  var version: String
  var description: String
  var install: String
  var start: String
  /// Host events this plugin subscribes to (manifest key `subscriptions`; the
  /// legacy key `events` still decodes). Empty means "every event".
  var subscriptions: [PluginEventSubscription]
  /// Every surface the plugin drives, as one unified table — see
  /// ``PluginProvider``. The per-kind views below (`commands`, `mappings`,
  /// `providesHints`) are derived from this so the rest of the host keeps
  /// reading flat lists.
  var providers: [PluginProvider]
  var priority: Int
  var volatile: Bool
  /// Bundle identifiers the source applies to. When non-empty, restricts
  /// `supports()` and jump-target discovery to these apps. Mirrors the
  /// `bundle_ids` filter used on event subscriptions but applies even when
  /// the manifest doesn't subscribe to `focus.changed`.
  var bundleIDs: [String]
  /// Per-request RPC timeout in milliseconds. Plugins that fan out to the
  /// network (e.g. GitHub) can raise this above the 2000ms default so a slow
  /// response isn't dropped. `nil` uses the default.
  var requestTimeoutMs: Int?

  /// Denormalized (command, subcommand) rows across every `commands` provider,
  /// with the provider's shared `bundle_ids` folded into each entry (the entry's
  /// own value wins) so command-index gating sees a flat, app-scoped list — the
  /// same shape `mappings` exposes.
  var commands: [PluginCommandRegistration] {
    providers.filter { $0.kind == .commands }.flatMap { provider in
      provider.commands.map { entry in
        var entry = entry
        if entry.bundleIDs.isEmpty { entry.bundleIDs = provider.bundleIDs }
        return entry
      }
    }
  }

  /// Mapping registrations across every `mappings` provider, with the
  /// provider's shared `bundle_ids`/`modes`/`priority` folded into each entry
  /// (the entry's own value wins) so downstream resolution sees a flat list.
  var mappings: [PluginMappingRegistration] {
    providers.filter { $0.kind == .mappings }.flatMap { provider in
      provider.mappings.map { entry in
        var entry = entry
        if entry.bundleIDs.isEmpty { entry.bundleIDs = provider.bundleIDs }
        if entry.priority == nil { entry.priority = provider.priority }
        if entry.mode == "normal", provider.modes.count == 1 {
          entry.mode = provider.modes[0].rawValue
        }
        return entry
      }
    }
  }

  /// Bang registrations across every `shebang` provider, each carrying its
  /// provider's `command` and (folded-in) `bundle_ids` so the flashlight `!`
  /// dispatch index sees a flat, app-scoped list. The token `"*"` marks a
  /// catch-all that claims every otherwise-unclaimed bang.
  var shebangs: [PluginShebangRegistration] {
    providers.filter { $0.kind == .shebang }.flatMap { provider in
      provider.shebangs.map { entry in
        var entry = entry
        if entry.command.isEmpty { entry.command = provider.command }
        if entry.bundleIDs.isEmpty { entry.bundleIDs = provider.bundleIDs }
        return entry
      }
    }
  }

  /// True when any provider opts the plugin in as a hints provider. Hint
  /// selection is exclusive (highest-priority provider supporting the focused
  /// app wins, no fallback), so a plugin only advertises `.jumpTargets` when it
  /// declares a `hints` provider.
  var providesHints: Bool {
    providers.contains { $0.kind == .hints }
  }

  /// True when any provider opts the plugin into the candidate/flashlight
  /// surface. Gates the candidate-adjacent capabilities (`.candidates`, plus the
  /// app-activation and tab operations that act on candidate-like entities) so a
  /// commands-only plugin isn't consulted on every flashlight query. The
  /// candidates surface stays global+additive — plugins self-limit their
  /// snapshot via focus events — so this is a capability toggle, not an
  /// app/mode gate.
  var providesCandidates: Bool {
    providers.contains { $0.kind == .candidates }
  }

  enum CodingKeys: String, CodingKey {
    case id, name, version, description, install, start, subscriptions, providers, priority
    case volatile
    /// Legacy alias for `subscriptions`, still accepted on decode.
    case events
    case bundleIDs = "bundle_ids"
    case requestTimeoutMs = "request_timeout_ms"
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String, start: String,
    subscriptions: [PluginEventSubscription] = [],
    providers: [PluginProvider] = [],
    priority: Int = 25,
    volatile: Bool = false,
    bundleIDs: [String] = [],
    requestTimeoutMs: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.install = install
    self.start = start
    self.subscriptions = subscriptions
    self.providers = providers
    self.priority = priority
    self.volatile = volatile
    self.bundleIDs = bundleIDs
    self.requestTimeoutMs = requestTimeoutMs
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.version = try c.decode(String.self, forKey: .version)
    self.description = try c.decode(String.self, forKey: .description)
    self.install = try c.decode(String.self, forKey: .install)
    self.start = try c.decode(String.self, forKey: .start)
    self.subscriptions =
      try c.decodeIfPresent([PluginEventSubscription].self, forKey: .subscriptions)
      ?? c.decodeIfPresent([PluginEventSubscription].self, forKey: .events)
      ?? []
    self.providers = try c.decodeIfPresent([PluginProvider].self, forKey: .providers) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.volatile = try c.decodeIfPresent(Bool.self, forKey: .volatile) ?? false
    self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
    self.requestTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutMs)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(version, forKey: .version)
    try c.encode(description, forKey: .description)
    try c.encode(install, forKey: .install)
    try c.encode(start, forKey: .start)
    if !subscriptions.isEmpty { try c.encode(subscriptions, forKey: .subscriptions) }
    if !providers.isEmpty { try c.encode(providers, forKey: .providers) }
    try c.encode(priority, forKey: .priority)
    if volatile { try c.encode(volatile, forKey: .volatile) }
    if !bundleIDs.isEmpty { try c.encode(bundleIDs, forKey: .bundleIDs) }
    if let requestTimeoutMs { try c.encode(requestTimeoutMs, forKey: .requestTimeoutMs) }
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
      // An empty subcommand registers a *top-level* command (`:copy`), and
      // `"*"` registers a wildcard that consumes the remainder (`:calc 2 + 2`).
      // Only the command verb itself is mandatory.
      if command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw PluginError.invalidManifest("plugin command must not be empty")
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
  var entersInsertMode: Bool
  var sourceID: String
  /// Plugin opt-in: when true the host drops the `target.action` RPC
  /// path (which returns optimistically) and synthesizes a real mouse
  /// click instead. Used by the tmux plugin's pane targets so a fast
  /// follow-up keystroke can't race a still-in-flight `select-pane`.
  var preferHostClick: Bool
  /// Marks a target as structurally important inside its source so
  /// the hint renderer paints it in the accent style. Tmux uses this
  /// for pane chips (vs. link chips); firefox uses it for tab chips
  /// (vs. element chips).
  var important: Bool
}

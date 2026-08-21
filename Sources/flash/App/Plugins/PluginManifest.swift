import AppKit
import Darwin
import FlashCore
import Foundation

/// Sensitive host capabilities a plugin must explicitly request in its
/// `manifest.json` to receive. Default-deny: if the manifest doesn't list a
/// capability here, the host filters out any host events / RPC paths gated by
/// it. The registry is frozen: additions are allowed, renames never
/// (parity-tested against `protocol.json`).
enum PluginCapability: String, Codable, CaseIterable, Equatable {
  /// Subscribe to `core:clipboard.changed`, which carries the full clipboard
  /// text, and call `host.clipboard_write`.
  case clipboard
  /// Call the host's Accessibility broker (`host.ax_snapshot`,
  /// `host.ax_perform`, `host.ax_set`, `host.ax_select_child`) and the
  /// synthesized-input RPCs. The core owns the single AX permission grant
  /// and handle registry; plugins own app-specific interpretation of the
  /// returned nodes.
  case accessibility
  /// Make outbound network connections. Plugins WITHOUT this run under a
  /// seatbelt profile that denies network, so a compromised or buggy plugin
  /// can't exfiltrate.
  case network
  /// Fetch specific URLs through the host (`host.fetch`): the host performs
  /// the request itself against the manifest's `fetch_urls` allowlist with a
  /// hard timeout and 1 MiB response cap, so the plugin needs no network
  /// access of its own and keeps a fully network-denied sandbox.
  case networkFetch = "network_fetch"
  /// Exec privileged helper binaries the network sandbox can't run — notably
  /// setgid `/bin/ps`, which seatbelt refuses. Implies the plugin spawns
  /// unsandboxed; used by process inspectors (`processes`, `tmux`).
  case subprocess
  /// Read the host's current normal-mode target pid/bundle
  /// (`host.normal_mode_target`) and raise an app by pid (`host.activate`).
  case appControl = "app_control"
  /// Open a URL or launch an app by bundle id through the host
  /// (`host.open`): LaunchServices runs host-side, so the plugin keeps a
  /// fork-free profile.
  case open
  /// Post a media key (play/pause, next, …) as an NX_SYSTEM_DEFINED event
  /// through the host (`host.post_media_key`).
  case mediaKeys = "media_keys"
  /// Read the host's process table (`host.process_table`) and signal a pid
  /// (`host.signal`).
  case processControl = "process_control"
  /// Show a transient host banner (`host.notify`). Capability-gated (and
  /// rate-limited host-side) so an arbitrary plugin cannot spam UI.
  case notify
}

extension PluginCapability {
  /// Sensitive event names that require an explicit capability declaration
  /// before the host delivers them to a plugin's `event` stream.
  static func required(for eventName: String) -> PluginCapability? {
    switch eventName {
    case "core:clipboard.changed":
      return .clipboard
    default:
      return nil
    }
  }
}

/// Glob matcher for event-name `listen` patterns; `*` is the only wildcard.
struct PluginPattern: Hashable, Equatable {
  let raw: String
  private let parts: [String]
  private let hasLeadingWildcard: Bool
  private let hasTrailingWildcard: Bool

  init(_ raw: String) {
    let raw = raw.trimmed
    self.raw = raw
    self.parts = raw.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    self.hasLeadingWildcard = raw.hasPrefix("*")
    self.hasTrailingWildcard = raw.hasSuffix("*")
  }

  static func matches(_ pattern: String, _ value: String) -> Bool {
    PluginPattern(pattern).matches(value)
  }

  func matches(_ value: String) -> Bool {
    guard !raw.isEmpty else { return false }
    if raw == "*" { return true }
    if !raw.contains("*") { return raw == value }

    var searchStart = value.startIndex
    var index = 0

    if !hasLeadingWildcard {
      let first = parts[0]
      guard value.hasPrefix(first) else { return false }
      searchStart = value.index(value.startIndex, offsetBy: first.count)
      index = 1
    }

    let endBefore = hasTrailingWildcard ? parts.count : max(parts.count - 1, index)
    while index < endBefore {
      let part = parts[index]
      index += 1
      guard !part.isEmpty else { continue }
      guard let range = value.range(of: part, range: searchStart..<value.endIndex) else {
        return false
      }
      searchStart = range.upperBound
    }

    if !hasTrailingWildcard, let last = parts.last, !last.isEmpty {
      return value[searchStart...].hasSuffix(last)
    }
    return true
  }
}

/// Decode-only active-window selector data: the manifest root and mapping
/// entries may scope with `only_bundle_ids`. All matching goes through
/// ``CompiledPluginSelector``.
struct PluginSelector: Decodable, Hashable, Equatable {
  var onlyBundleIDs: [String]

  init(onlyBundleIDs: [String] = []) {
    self.onlyBundleIDs = onlyBundleIDs
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case onlyBundleIDs = "only_bundle_ids"
  }
}

struct PluginSelectorContext: Equatable {
  var bundleID: String?

  init(bundleID: String? = nil) {
    self.bundleID = bundleID
  }

  var cacheKey: String {
    bundleID ?? ""
  }
}

struct CompiledPluginSelector: Hashable, Equatable {
  private let onlyBundleIDs: Set<String>

  init(_ selector: PluginSelector) {
    self.onlyBundleIDs = Set(selector.onlyBundleIDs)
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty
  }

  func matches(_ context: PluginSelectorContext) -> Bool {
    if !onlyBundleIDs.isEmpty {
      guard let bundleID = context.bundleID, onlyBundleIDs.contains(bundleID) else {
        return false
      }
    }
    return true
  }

  /// Scoped-beats-unscoped: a matching bundle-scoped selector outranks an
  /// unscoped one; there is no finer gradient.
  func specificity(in context: PluginSelectorContext) -> Int? {
    guard matches(context) else { return nil }
    return onlyBundleIDs.isEmpty ? 0 : 1
  }
}

struct PluginSelectorStack: Hashable, Equatable {
  private var selectors: [CompiledPluginSelector]

  init(_ selectors: [PluginSelector] = []) {
    self.selectors = selectors.map(CompiledPluginSelector.init).filter { !$0.isEmpty }
  }

  func matches(_ context: PluginSelectorContext) -> Bool {
    selectors.allSatisfy { $0.matches(context) }
  }

  func specificity(in context: PluginSelectorContext) -> Int? {
    var score = 0
    for selector in selectors {
      guard let selectorScore = selector.specificity(in: context) else { return nil }
      score += selectorScore
    }
    return score
  }
}

/// One subcommand a plugin registers. A plugin exposes one or more
/// **commands** (the verb the user types after `:`, e.g. `spotify`),
/// and each command has one or more **subcommands** (e.g. `play`). This
/// row is the denormalized (command, subcommand) pair the command-line
/// completion engine and the dispatch index are built from.
struct PluginCommandRegistration: Decodable, Hashable {
  var command: String
  var subcommand: String
  var description: String
  /// Per-entry `perform` deadline override in milliseconds. Interactive
  /// commands (`spotify login` runs a 300 s device-auth flow) declare it
  /// here; everything else inherits the 10 s perform deadline.
  var timeoutMs: Int?

  init(
    command: String,
    subcommand: String = "",
    description: String = "",
    timeoutMs: Int? = nil
  ) {
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.timeoutMs = timeoutMs
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case command, subcommand, description
    case timeoutMs = "timeout_ms"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand) ?? ""
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }
}

/// One flashlight bang a plugin registers. When a flashlight submission
/// starts with `!<token>` (e.g. `!r cat`), core routes the remainder to the
/// owning plugin as `perform {kind: "command"}` with the bang token as the
/// subcommand. A `token` of `"*"` is a catch-all: the plugin claims every
/// otherwise-unclaimed bang and resolves it itself — how `searchengines`
/// serves the full DuckDuckGo bang table without enumerating thousands of
/// entries in the manifest.
struct PluginBangRegistration: Decodable, Hashable {
  var token: String
  var description: String
  /// Candidate source label this bang draws its selectable rows from. When
  /// the user confirms `!<token> `, the flashlight pool swaps to this
  /// source's candidates; Return on a row dispatches the bang. Empty means
  /// the bang has no candidate list — typing the bang submits the typed
  /// remainder.
  var source: String?

  init(token: String, description: String = "", source: String? = nil) {
    self.token = token
    self.description = description
    self.source = source
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case token, description, source
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.source = try c.decodeIfPresent(String.self, forKey: .source)
  }
}

/// The manifest `bangs` block: the command every bang dispatches through,
/// plus its entries.
struct PluginBangs: Decodable, Equatable {
  var command: String
  var items: [PluginBangRegistration]

  init(command: String = "", items: [PluginBangRegistration] = []) {
    self.command = command
    self.items = items
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case command, items
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.items = try c.decodeIfPresent([PluginBangRegistration].self, forKey: .items) ?? []
  }
}

/// One verb a plugin registers. `name` is the verb users type in mappings or
/// pass to `flash <name> [k=v]...`. When `keystrokes` is populated, the host
/// short-circuits the round-trip and synthesizes the per-bundle keystroke
/// directly — keeps `app_save`-class verbs latency-flat. Otherwise the host
/// dispatches `perform {kind: "command"}` with the configured `subcommand`
/// (defaulting to `name`).
struct PluginVerbRegistration: Decodable, Equatable {
  var name: String
  var command: String
  var subcommand: String
  var description: String
  /// Per-bundle keystroke table consumed before any RPC dispatch. Map entries
  /// use bundle id → "cmd+s"-style hotkey. The empty string key (`""`) is the
  /// default applied when no bundle-specific entry matches; missing entirely
  /// means "no fallback, fall through to RPC".
  var keystrokes: [String: String]

  init(
    name: String,
    command: String = "",
    subcommand: String = "",
    description: String = "",
    keystrokes: [String: String] = [:]
  ) {
    self.name = name
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.keystrokes = keystrokes
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name, command, subcommand, description, keystrokes
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand) ?? ""
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.keystrokes =
      try c.decodeIfPresent([String: String].self, forKey: .keystrokes) ?? [:]
  }
}

/// One key mapping a plugin registers. Mirrors a `[mode.<scope>.mappings]`
/// config entry plus an optional bundle selector. `priority` decides who
/// wins when several mappings claim the same key; selector specificity is
/// added at resolution time, so a bundle-scoped mapping beats an unscoped
/// mapping at the same declared priority. `command` is an argv array
/// matching the mapping syntax: `["flash", "<verb>", "k=v" ...]` for
/// in-process verbs, anything else for argv exec.
struct PluginMappingRegistration: Decodable, Hashable {
  var key: String
  var mode: String
  var command: [String]
  var selector: PluginSelector
  var priority: Int?

  init(
    key: String,
    mode: String = "normal",
    command: [String],
    selector: PluginSelector = PluginSelector(),
    priority: Int? = nil
  ) {
    self.key = key
    self.mode = mode
    self.command = command
    self.selector = selector
    self.priority = priority
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case key, mode, command
    case onlyBundleIDs = "only_bundle_ids"
    case priority
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "normal"
    self.command = try c.decode([String].self, forKey: .command)
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [])
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
  }

  /// `mode` string → `ModeScope`. Loaded manifests validate the value before
  /// registrations are exposed; the fallback only protects programmatic test
  /// construction from trapping.
  var scope: ModeScope { ModeScope(rawValue: mode) ?? .normal }
}

/// One help topic a plugin contributes to `:help`. Aggregated by
/// `HelpDocs.allTopics` alongside the host's own topics. The body is
/// rendered as Markdown.
struct PluginHelpTopic: Decodable, Equatable {
  var name: String
  var title: String
  var summary: String
  var body: String
  var aliases: [String]

  init(name: String, title: String, summary: String, body: String, aliases: [String] = []) {
    self.name = name
    self.title = title
    self.summary = summary
    self.body = body
    self.aliases = aliases
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name, title, summary, body, aliases
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
    self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
    self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

/// Plugin-declared help block. Each entry shows up in `:help` next to the
/// host's built-in topics.
struct PluginHelp: Decodable, Equatable {
  var topics: [PluginHelpTopic]

  init(topics: [PluginHelpTopic] = []) {
    self.topics = topics
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case topics
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.topics = try c.decodeIfPresent([PluginHelpTopic].self, forKey: .topics) ?? []
  }
}

/// Opts the plugin in as a hint provider (always a live `hints` request;
/// there is no cached-discovery path).
struct PluginHints: Decodable, Equatable {
  /// Empty means the plugin does not own the focused context, so the host may
  /// continue to the next lower-priority hints provider. This is for dynamic
  /// providers such as tmux, whose applicability comes from live process/PTY
  /// ancestry rather than a static bundle-id selector.
  var fallbackOnEmpty: Bool

  init(fallbackOnEmpty: Bool = false) {
    self.fallbackOnEmpty = fallbackOnEmpty
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case fallbackOnEmpty = "fallback_on_empty"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.fallbackOnEmpty = try c.decodeIfPresent(Bool.self, forKey: .fallbackOnEmpty) ?? false
  }
}

/// Registers the per-input evaluator (`evaluate`). This is intentionally
/// only a surface registration: the plugin owns parsing and decides whether
/// an input matches. The host never executes plugin-supplied regular
/// expressions. Evaluator ordering is the manifest root `priority`, ties
/// broken by plugin id.
struct PluginQuery: Decodable, Equatable {
  /// Exact literal markers (never regexes) that route matching flashlight
  /// input only to this evaluator; without one, evaluators are additive.
  var prefixes: [String]

  init(prefixes: [String] = []) {
    self.prefixes = prefixes
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case prefixes
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.prefixes = try c.decodeIfPresent([String].self, forKey: .prefixes) ?? []
  }
}

/// Deny-default sandbox spec. Declaring `"sandbox": {}` (even empty) opts
/// the plugin into the generated deny-default seatbelt profile — everything
/// is denied except loading the binary, broad reads minus secrets, and
/// writes inside the plugin's data dir. Absence keeps the legacy
/// network-deny-only behavior until every bundled plugin has migrated.
struct PluginSandboxSpec: Decodable, Equatable {
  /// Executable paths (absolute, or bare tool names resolved through
  /// `mise which`/login-PATH at spawn) the plugin may `process-exec`.
  var exec: [String]
  /// Allow sending AppleEvents (osascript-driven plugins): opens the
  /// AppleEvents/LaunchServices/TCC mach services and appleevent-send.
  var appleEvents: Bool
  /// Allow signalling other processes — needed when an exec'd tool (e.g.
  /// system's `killall`) signals beyond the plugin's own process group.
  /// Plugin-side signalling itself goes through `host.signal`.
  var signal: Bool
  /// Extra mach service names the plugin's tools need — e.g. pmset requires
  /// powerd's com.apple.PowerManagement.control. Explicit per plugin; the
  /// generator never widens mach-lookup beyond named services.
  var mach: [String]

  init(
    exec: [String] = [], appleEvents: Bool = false, signal: Bool = false, mach: [String] = []
  ) {
    self.exec = exec
    self.appleEvents = appleEvents
    self.signal = signal
    self.mach = mach
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.exec = try c.decodeIfPresent([String].self, forKey: .exec) ?? []
    self.appleEvents = try c.decodeIfPresent(Bool.self, forKey: .appleevents) ?? false
    self.signal = try c.decodeIfPresent(Bool.self, forKey: .signal) ?? false
    self.mach = try c.decodeIfPresent([String].self, forKey: .mach) ?? []
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case exec, appleevents, signal, mach
  }
}

struct PluginManifest: Decodable, Equatable {
  var id: String
  var name: String
  var version: String
  var description: String
  /// Shell string run sandboxed from the plugin root before first start.
  /// Third-party-only: official plugins ship prebuilt and omit it.
  var install: String?
  /// Argv array that starts the plugin child process, exec'd directly with
  /// the scrubbed plugin environment — no shell wrap, so login-shell rc
  /// files can never re-widen the env allowlist. A relative first element
  /// resolves against the plugin root. `nil` declares a manifest-only
  /// plugin: no process ever runs, and `validate()` restricts the manifest
  /// to surfaces the host can serve alone (mappings, help, and verbs whose
  /// every entry declares a default keystroke).
  var exec: [String]?
  /// Deny-default sandbox opt-in; see ``PluginSandboxSpec``.
  var sandbox: PluginSandboxSpec?
  /// HTTPS URL prefixes the plugin may request through `host.fetch`.
  /// Requires the `network_fetch` capability; the host rejects any request
  /// whose URL doesn't start with one of these.
  var fetchURLs: [String]
  /// Host event-name patterns this plugin listens to. `*` is the only
  /// wildcard. Declaring `listen` makes the plugin resident.
  var listen: [String]
  var hints: PluginHints?
  var query: PluginQuery?
  var commands: [PluginCommandRegistration]
  var mappings: [PluginMappingRegistration]
  /// Status-bar segment names fed by the `status` notification, rendered as
  /// `#{plugin:<id>.<segment>}`.
  var status: [String]
  var bangsBlock: PluginBangs?
  /// Durable route schemes restorable from movement history, dispatched as
  /// `perform {kind: "navigate"}`.
  var navigation: [String]
  var verbs: [PluginVerbRegistration]
  var priority: Int
  /// Global active-window selector for this plugin, compounded with
  /// mapping-entry selectors.
  var selector: PluginSelector
  /// Candidate source descriptors this plugin contributes to `:flashlight`.
  /// `name` is the label rows carry in their first-class `source` field;
  /// `kind` is the semantic source class used for default ranking;
  /// `live: true` marks a live (pull) source served by `search`.
  var sources: [CandidateSourceDescriptor]
  /// Source-owned normal-mode action names, dispatched as
  /// `perform {kind: "action"}`.
  var actions: [String]
  /// Sensitive host capabilities the plugin requests. Default-deny.
  var capabilities: Set<PluginCapability>
  /// Help topics this plugin contributes to `:help`.
  var help: PluginHelp

  var onlyBundleIDs: [String] { selector.onlyBundleIDs }

  /// Bang registrations, each carrying the block's `command` so the
  /// flashlight `!` dispatch index sees a flat list.
  var bangs: [PluginBangRegistration] {
    bangsBlock?.items ?? []
  }

  var bangCommand: String {
    bangsBlock?.command ?? ""
  }

  func supportsAction(_ action: String, context: PluginSelectorContext) -> Bool {
    let requested = action.trimmed
    guard !requested.isEmpty, actions.contains(requested) else { return false }
    return CompiledPluginSelector(selector).matches(context)
  }

  var navigationSchemes: [String] {
    var seen = Set<String>()
    var out: [String] = []
    for scheme in navigation {
      let trimmed = scheme.trimmed.lowercased()
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      out.append(trimmed)
    }
    return out
  }

  var candidateSources: [String] {
    sources.map(\.name)
  }

  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    sources
  }

  var statusSegments: [String] { status }

  /// True when the manifest opts in as a hint provider. Hint selection is
  /// exclusive (highest-priority provider supporting the focused app wins,
  /// no fallback), so a plugin only advertises `.jumpTargets` when it
  /// declares `hints`.
  var providesHints: Bool {
    hints != nil
  }

  var providesQueryEvaluation: Bool {
    query != nil
  }

  /// True when the plugin contributes candidate sources to the flashlight.
  /// The candidates surface stays global+additive — plugins self-limit their
  /// published catalog via focus events — so this is a capability toggle,
  /// not an app/mode gate.
  var providesCandidates: Bool {
    !sources.isEmpty
  }

  /// A plugin is resident — spawned at startup and kept running — iff its
  /// manifest declares `sources`, `query`, `hints`, `status`, or `listen`.
  /// On-demand surfaces alone (`commands`, `bangs`, `verbs`, `navigation`)
  /// defer the spawn to the first `perform`. No `exec` means no process
  /// ever.
  var activation: PluginActivation {
    if exec == nil { return .manifestOnly }
    let resident =
      !sources.isEmpty || query != nil || hints != nil || !status.isEmpty || !listen.isEmpty
    return resident ? .resident : .onDemand
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name, version, description, install, exec, sandbox, listen, priority
    case fetchURLs = "fetch_urls"
    case onlyBundleIDs = "only_bundle_ids"
    case capabilities, help
    case hints, query, commands, mappings, status, bangs
    case actions
    case sources
    case navigation, verbs
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String? = nil, exec: [String]? = nil,
    sandbox: PluginSandboxSpec? = nil,
    fetchURLs: [String] = [],
    listen: [String] = [],
    hints: PluginHints? = nil,
    query: PluginQuery? = nil,
    commands: [PluginCommandRegistration] = [],
    mappings: [PluginMappingRegistration] = [],
    status: [String] = [],
    bangsBlock: PluginBangs? = nil,
    navigation: [String] = [],
    verbs: [PluginVerbRegistration] = [],
    priority: Int = 25,
    selector: PluginSelector = PluginSelector(),
    sources: [CandidateSourceDescriptor] = [],
    actions: [String] = [],
    capabilities: Set<PluginCapability> = [],
    help: PluginHelp = PluginHelp()
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.install = install
    self.exec = exec
    self.sandbox = sandbox
    self.fetchURLs = Self.uniqueTrimmed(fetchURLs)
    self.listen = Self.uniqueTrimmed(listen)
    self.hints = hints
    self.query = query
    self.commands = commands
    self.mappings = mappings
    self.status = Self.uniqueTrimmed(status)
    self.bangsBlock = bangsBlock
    self.navigation = navigation
    self.verbs = verbs
    self.priority = priority
    self.selector = selector
    self.sources = Self.uniqueSourceDescriptors(sources)
    self.actions = Self.uniqueTrimmed(actions)
    self.capabilities = capabilities
    self.help = help
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.version = try c.decode(String.self, forKey: .version)
    self.description = try c.decode(String.self, forKey: .description)
    self.install = try c.decodeIfPresent(String.self, forKey: .install)
    self.exec = try c.decodeIfPresent([String].self, forKey: .exec)
    self.sandbox = try c.decodeIfPresent(PluginSandboxSpec.self, forKey: .sandbox)
    self.fetchURLs = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .fetchURLs) ?? [])
    self.listen = Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .listen) ?? [])
    self.hints = try c.decodeIfPresent(PluginHints.self, forKey: .hints)
    self.query = try c.decodeIfPresent(PluginQuery.self, forKey: .query)
    self.commands =
      try c.decodeIfPresent([PluginCommandRegistration].self, forKey: .commands) ?? []
    self.mappings =
      try c.decodeIfPresent([PluginMappingRegistration].self, forKey: .mappings) ?? []
    self.status = Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .status) ?? [])
    self.bangsBlock = try c.decodeIfPresent(PluginBangs.self, forKey: .bangs)
    self.navigation = try c.decodeIfPresent([String].self, forKey: .navigation) ?? []
    self.verbs = try c.decodeIfPresent([PluginVerbRegistration].self, forKey: .verbs) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [])
    self.sources =
      Self.uniqueSourceDescriptors(
        try c.decodeIfPresent([CandidateSourceDescriptor].self, forKey: .sources) ?? [])
    self.actions =
      Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .actions) ?? [])
    let caps = try c.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
    self.capabilities = Set(caps)
    self.help = try c.decodeIfPresent(PluginHelp.self, forKey: .help) ?? PluginHelp()
  }

  private static func uniqueTrimmed(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in values {
      let trimmed = value.trimmed
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      out.append(trimmed)
    }
    return out
  }

  private static func uniqueSourceDescriptors(
    _ values: [CandidateSourceDescriptor]
  ) -> [CandidateSourceDescriptor] {
    var seen = Set<String>()
    var out: [CandidateSourceDescriptor] = []
    for value in values {
      var descriptor = value
      descriptor.name = descriptor.name.trimmed
      let key = descriptor.name.lowercased()
      guard !descriptor.name.isEmpty, seen.insert(key).inserted else { continue }
      out.append(descriptor)
    }
    return out
  }

  static func load(from root: URL) throws -> PluginManifest {
    let url = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    try rejectUnknownManifestKeys(in: data)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()
    return manifest
  }

  /// Strict unknown-key rejection, derived uniformly from each schema type's
  /// `CodingKeys` — new manifest surface only ever arrives together with a
  /// protocol change, so "unknown key" always means "typo or stale host",
  /// never ambiguity.
  private static func rejectUnknownManifestKeys(in data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else { return }

    func keys<K: CodingKey & CaseIterable>(_ type: K.Type) -> Set<String> {
      Set(K.allCases.map(\.stringValue))
    }

    try rejectUnknownKeys(
      in: dictionary, allowed: keys(CodingKeys.self), path: "manifest.json")
    try rejectObject(
      dictionary["sandbox"], allowed: keys(PluginSandboxSpec.CodingKeys.self),
      path: "manifest.json sandbox")
    try rejectObject(
      dictionary["hints"], allowed: keys(PluginHints.CodingKeys.self),
      path: "manifest.json hints")
    try rejectObject(
      dictionary["query"], allowed: keys(PluginQuery.CodingKeys.self),
      path: "manifest.json query")
    try rejectArrayObjects(
      dictionary["commands"], allowed: keys(PluginCommandRegistration.CodingKeys.self),
      path: "manifest.json commands")
    try rejectArrayObjects(
      dictionary["mappings"], allowed: keys(PluginMappingRegistration.CodingKeys.self),
      path: "manifest.json mappings")
    try rejectArrayObjects(
      dictionary["verbs"], allowed: keys(PluginVerbRegistration.CodingKeys.self),
      path: "manifest.json verbs")
    try rejectArrayObjects(
      dictionary["sources"], allowed: keys(CandidateSourceDescriptor.CodingKeys.self),
      path: "manifest.json sources")
    if let bangs = dictionary["bangs"] as? [String: Any] {
      try rejectUnknownKeys(
        in: bangs, allowed: keys(PluginBangs.CodingKeys.self), path: "manifest.json bangs")
      try rejectArrayObjects(
        bangs["items"], allowed: keys(PluginBangRegistration.CodingKeys.self),
        path: "manifest.json bangs.items")
    }
    if let help = dictionary["help"] as? [String: Any] {
      try rejectUnknownKeys(
        in: help, allowed: keys(PluginHelp.CodingKeys.self), path: "manifest.json help")
      try rejectArrayObjects(
        help["topics"], allowed: keys(PluginHelpTopic.CodingKeys.self),
        path: "manifest.json help.topics")
    }
  }

  private static func rejectObject(
    _ value: Any?,
    allowed: Set<String>,
    path: String
  ) throws {
    guard let object = value as? [String: Any] else { return }
    try rejectUnknownKeys(in: object, allowed: allowed, path: path)
  }

  private static func rejectArrayObjects(
    _ value: Any?,
    allowed: Set<String>,
    path: String
  ) throws {
    guard let objects = value as? [[String: Any]] else { return }
    for (index, object) in objects.enumerated() {
      try rejectUnknownKeys(
        in: object,
        allowed: allowed,
        path: "\(path)[\(index)]")
    }
  }

  private static func rejectUnknownKeys(
    in object: [String: Any],
    allowed: Set<String>,
    path: String
  ) throws {
    let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
    if !unknown.isEmpty {
      // All of them at once — an author with three typos fixes three typos,
      // not one per load attempt.
      throw PluginError.failure(
        "\(path) unknown field\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", "))")
    }
  }

  func validate() throws {
    let required = [
      ("id", id),
      ("name", name),
      ("version", version),
      ("description", description),
    ]
    for (field, value) in required {
      if value.trimmed.isEmpty {
        throw PluginError.failure("manifest.json field \(field) must not be empty")
      }
    }
    if let install, install.trimmed.isEmpty {
      throw PluginError.failure("manifest.json field install must not be empty")
    }
    if capabilities.contains(.networkFetch) != !fetchURLs.isEmpty {
      throw PluginError.failure(
        "manifest.json network_fetch capability and fetch_urls must be declared together")
    }
    for prefix in fetchURLs where !prefix.hasPrefix("https://") {
      throw PluginError.failure(
        "manifest.json fetch_urls entries must be https:// prefixes: \(prefix)")
    }
    // Live sources never join the default pool or the first paint, so they
    // cannot be `locations`. And because one plugin serves one adapter, its
    // sources are all-warm or all-live — mixing has no wire representation.
    for descriptor in sources where descriptor.live && descriptor.kind == .locations {
      throw PluginError.failure(
        "manifest.json sources entry \(descriptor.name): live cannot combine with "
          + "kind \"locations\"")
    }
    let liveCount = sources.filter(\.live).count
    if liveCount > 0 && liveCount != sources.count {
      throw PluginError.failure(
        "manifest.json sources must be all-warm or all-live; mixing modes in one plugin "
          + "is not supported")
    }
    if let sandbox {
      // Absolute paths pass through; bare tool names (no slash) resolve
      // through mise/login-PATH at spawn. Relative paths are neither.
      for path in sandbox.exec where !path.hasPrefix("/") && path.contains("/") {
        throw PluginError.failure(
          "manifest.json sandbox.exec entries must be absolute paths or bare tool names: \(path)")
      }
    }
    if let exec {
      if exec.isEmpty || exec.contains(where: { $0.trimmed.isEmpty }) {
        throw PluginError.failure(
          "manifest.json field exec must be a non-empty argv array without empty elements")
      }
    } else {
      // Manifest-only plugin: no child process ever runs, so any surface
      // that would need RPC into (or events delivered to) the plugin is
      // invalid. Mappings, help topics, and verbs whose every dispatch
      // resolves to a host-synthesized keystroke are the complete allowed
      // surface.
      let processBound: [(String, Bool)] = [
        ("listen", !listen.isEmpty),
        ("hints", hints != nil),
        ("query", query != nil),
        ("commands", !commands.isEmpty),
        ("status", !status.isEmpty),
        ("bangs", bangsBlock != nil),
        ("navigation", !navigation.isEmpty),
        ("sources", !sources.isEmpty),
        ("actions", !actions.isEmpty),
        ("capabilities", !capabilities.isEmpty),
        ("sandbox", sandbox != nil),
        ("fetch_urls", !fetchURLs.isEmpty),
      ]
      if let field = processBound.first(where: { $0.1 })?.0 {
        throw PluginError.failure(
          "manifest.json without exec cannot declare \(field) — it requires a plugin process")
      }
      for verb in verbs where (verb.keystrokes[""] ?? "").trimmed.isEmpty {
        throw PluginError.failure(
          "manifest.json without exec requires verb \(verb.name) to declare a default"
            + " keystroke")
      }
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    // Reject `.`/`..`/anything containing `..`: the id becomes the plugin's
    // FLASH_PLUGIN_DATA_DIR component (baseDataDir/<id>), so `..` would escape
    // the data root. Only reachable via a `file:` plugin, but cheap to close.
    guard id.lowercased() == id, id != ".", id != "..", !id.contains(".."),
      id.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw PluginError.failure(
        "manifest.json id must be lowercase [a-z0-9._-] and not contain \"..\"")
    }
    for command in commands {
      // An empty subcommand registers a *top-level* command (`:copy`), and
      // `"*"` registers a wildcard that consumes the remainder (`:calc 2 + 2`).
      // Only the command verb itself is mandatory.
      if command.command.trimmed.isEmpty {
        throw PluginError.failure("plugin command must not be empty")
      }
    }
    for bang in bangs {
      if bang.token.trimmed.isEmpty {
        throw PluginError.failure("plugin bang token must not be empty")
      }
      // A bang's completion source must be one this plugin actually serves —
      // a typo here would silently swap the pool to nothing.
      if let source = bang.source, !source.isEmpty, !candidateSources.contains(source) {
        throw PluginError.failure(
          "plugin bang \(bang.token) source \(source) must name a declared sources[] entry")
      }
    }
    for mapping in mappings {
      guard ModeScope(rawValue: mapping.mode) != nil else {
        throw PluginError.failure(
          "plugin mapping mode \(mapping.mode) must be all, normal, or insert")
      }
    }
    for prefix in query?.prefixes ?? [] {
      guard !prefix.isEmpty, prefix.trimmed == prefix,
        !prefix.contains(where: { $0.isWhitespace })
      else {
        throw PluginError.failure(
          "plugin query prefix must be a non-whitespace literal")
      }
    }
    let statusAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
    for segment in statusSegments {
      guard segment.lowercased() == segment,
        segment.unicodeScalars.allSatisfy({ statusAllowed.contains($0) })
      else {
        throw PluginError.failure(
          "plugin status segment \(segment) must be lowercase [a-z0-9_-]")
      }
    }
  }
}

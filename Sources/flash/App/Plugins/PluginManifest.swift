import AppKit
import Darwin
import FlashCore
import Foundation

/// Sensitive host capabilities a plugin must explicitly request in its
/// `manifest.json` to receive. Default-deny: if the manifest doesn't list a
/// capability here, the host refuses every RPC gated by it. The registry is
/// frozen: additions are allowed, renames never (parity-tested against
/// `protocol.json`).
enum PluginCapability: String, Codable, CaseIterable, Equatable {
  /// Call the host's Accessibility broker (`host.ax_snapshot`,
  /// `host.ax_perform`, `host.ax_set`, `host.ax_select_child`) and the
  /// synthesized-input RPCs. The core owns the single AX permission grant
  /// and handle registry; plugins own app-specific interpretation of the
  /// returned nodes.
  case accessibility
  /// Make outbound network connections: composes `network-outbound` into the
  /// deny-default profile, which otherwise denies network so a compromised
  /// or buggy plugin can't exfiltrate. Only a sandboxed plugin declares it.
  case network
  /// Fetch specific URLs through the host (`host.fetch`): the host performs
  /// the request itself against the manifest's `fetch_urls` allowlist with a
  /// hard timeout and 1 MiB response cap, so the plugin needs no network
  /// access of its own and keeps a fully network-denied sandbox.
  case networkFetch = "network_fetch"
  /// Read the host's current normal-mode target pid/bundle
  /// (`host.normal_mode_target`) and raise an app by pid (`host.activate`).
  case appControl = "app_control"
  /// Open a URL or launch an app by bundle id through the host
  /// (`host.open`): LaunchServices runs host-side, so the plugin keeps a
  /// fork-free profile.
  case open
  /// Read the current Wi-Fi SSID through the host (`host.wifi_info`). The
  /// host owns the Location authorization prompt and CoreWLAN access.
  case wifiInfo = "wifi_info"
  /// Run fixed AppleScript operations in the resident (`host.applescript`) against the apps
  /// the manifest's `apple_events_targets` name. The host compiles and runs
  /// the script, so the plugin loads no AppleScript runtime, keeps its
  /// sandbox (macOS refuses Apple Events from a sandboxed sender), and macOS
  /// attributes the Automation request to Flash.
  case appleEvents = "apple_events"
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
/// entries may scope with `only_bundle_ids` and/or `only_terminals` (the
/// declared `TerminalEmulators`, so a plugin never carries its own terminal
/// allowlist). All matching goes through ``CompiledPluginSelector``.
struct PluginSelector: Decodable, Hashable, Equatable {
  var onlyBundleIDs: [String]
  var onlyTerminals: Bool

  init(onlyBundleIDs: [String] = [], onlyTerminals: Bool = false) {
    self.onlyBundleIDs = onlyBundleIDs
    self.onlyTerminals = onlyTerminals
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty && !onlyTerminals
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case onlyBundleIDs = "only_bundle_ids"
    case onlyTerminals = "only_terminals"
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
  private let onlyTerminals: Bool

  init(_ selector: PluginSelector) {
    self.onlyBundleIDs = Set(selector.onlyBundleIDs)
    self.onlyTerminals = selector.onlyTerminals
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty && !onlyTerminals
  }

  func matches(_ context: PluginSelectorContext) -> Bool {
    if !onlyBundleIDs.isEmpty {
      guard let bundleID = context.bundleID, onlyBundleIDs.contains(bundleID) else {
        return false
      }
    }
    if onlyTerminals {
      guard TerminalEmulators.contains(context.bundleID) else { return false }
    }
    return true
  }

  /// Scoped-beats-unscoped: a matching scoped selector outranks an unscoped
  /// one; there is no finer gradient.
  func specificity(in context: PluginSelectorContext) -> Int? {
    guard matches(context) else { return nil }
    return isEmpty ? 0 : 1
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

/// One `commands[]` entry. Outside Flash's topics it is one of the plugin's
/// own **commands** (the first word the user types after `:`, e.g.
/// `spotify`) with one of its **subcommands** (e.g. `play`): the
/// denormalized pair the command-line completion engine and the dispatch
/// index are built from. Under one of Flash's topics (`tab close`) it is a
/// core command the plugin performs where its selector matches; `confirm`
/// is the question the host asks first when that is destructive.
struct PluginCommandRegistration: Decodable, Hashable {
  var command: String
  var subcommand: String
  var description: String
  var confirm: String?

  init(command: String, subcommand: String = "", description: String = "", confirm: String? = nil) {
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.confirm = confirm
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case command, subcommand, description, confirm
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand) ?? ""
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.confirm = try c.decodeIfPresent(String.self, forKey: .confirm)
  }

  /// Whether this entry declares a core command (a Flash topic) rather than
  /// one of the plugin's own.
  var isCoreCommand: Bool { URLEventHandler.isTopic(command) }

  var name: CommandName { CommandName(command, subcommand) }
}

/// One flashlight bang a plugin registers (an entry of manifest `bangs`).
/// When a flashlight submission starts with `!<token>` (e.g. `!r cat`), core
/// routes the remainder to the owning plugin as `perform {kind: "command"}`
/// with the plugin id as the command and the bang token as the subcommand.
/// A `token` of `"*"` is a catch-all: the plugin claims every
/// otherwise-unclaimed bang and resolves it itself — how `searchproviders`
/// serves the DuckDuckGo and Kagi bang lists without enumerating thousands of
/// entries in the manifest.
struct PluginBangRegistration: Decodable, Hashable {
  var token: String
  var description: String
  /// Candidate source name this bang draws its selectable rows from. When
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

/// One key mapping a plugin registers. Mirrors a `[mode.<scope>.mappings]`
/// config entry plus an optional bundle selector. `priority` decides who
/// wins when several mappings claim the same key; selector specificity is
/// added at resolution time, so a bundle-scoped mapping beats an unscoped
/// mapping at the same declared priority. `command` is an argv array
/// matching the mapping syntax: `["flash", "<topic>", "<action>", "--k=v" ...]`
/// for in-process commands, anything else for argv exec.
struct PluginMappingRegistration: Decodable, Hashable {
  var key: String
  var mode: String
  var command: [String]
  var selector: PluginSelector
  var priority: Int?
  /// Pressing the sequence's final key again repeats it, as `repeat = true`
  /// does for a config mapping.
  var repeatsOnFinalKey: Bool

  init(
    key: String,
    mode: String = "normal",
    command: [String],
    selector: PluginSelector = PluginSelector(),
    priority: Int? = nil,
    repeatsOnFinalKey: Bool = false
  ) {
    self.key = key
    self.mode = mode
    self.command = command
    self.selector = selector
    self.priority = priority
    self.repeatsOnFinalKey = repeatsOnFinalKey
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case key, mode, command
    case onlyBundleIDs = "only_bundle_ids"
    case onlyTerminals = "only_terminals"
    case priority
    case repeatsOnFinalKey = "repeat"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "normal"
    self.command = try c.decode([String].self, forKey: .command)
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [],
      onlyTerminals: try c.decodeIfPresent(Bool.self, forKey: .onlyTerminals) ?? false)
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.repeatsOnFinalKey = try c.decodeIfPresent(Bool.self, forKey: .repeatsOnFinalKey) ?? false
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

  init(name: String, title: String, summary: String, body: String) {
    self.name = name
    self.title = title
    self.summary = summary
    self.body = body
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case name, title, summary, body
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
    self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
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

/// The allowances a plugin's deny-default seatbelt profile adds. Everything
/// else is denied except loading the binary, broad reads minus secrets, and
/// writes inside the plugin's data dir. A manifest without `sandbox` gets the
/// empty spec.
struct PluginSandboxSpec: Decodable, Equatable {
  /// Extra mach service names the plugin needs — e.g. IOPowerSources
  /// requires powerd's com.apple.PowerManagement.control. Explicit per
  /// plugin; the generator never widens mach-lookup beyond named services.
  var mach: [String]

  init(mach: [String] = []) {
    self.mach = mach
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.mach = try c.decodeIfPresent([String].self, forKey: .mach) ?? []
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case mach
  }
}

/// A manifest's `sandbox` field: an object of allowances for the
/// deny-default profile, or `false`, which runs the plugin unsandboxed — for
/// a plugin whose helpers or Apple Events no profile can carry.
enum PluginSandboxDeclaration: Decodable, Equatable {
  case spec(PluginSandboxSpec)
  case disabled

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let enabled = try? container.decode(Bool.self) {
      guard !enabled else {
        throw PluginError.failure("manifest.json sandbox must be an object or false")
      }
      self = .disabled
    } else {
      self = .spec(try container.decode(PluginSandboxSpec.self))
    }
  }
}

/// The manifest `lifecycle` key: how the child's run ends. Absent, the
/// surfaces decide (`PluginManifest.activation`); the default has no
/// spelling, so any other value is a typo.
enum PluginLifecycleDeclaration: String, CaseIterable, Decodable {
  /// A catalog-only plugin whose run is `on_start`: it publishes and exits
  /// 0, the host keeps the catalog and runs it again only when its data
  /// can have changed.
  case publishThenExit = "publish_then_exit"

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let raw = try? container.decode(String.self), let value = Self(rawValue: raw) else {
      throw PluginError.failure(
        "manifest.json lifecycle must be \"publish_then_exit\" (or absent: the surfaces decide)")
    }
    self = value
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
  /// to surfaces the host can serve alone (mappings, help and bindings).
  var exec: [String]?
  /// The declared `sandbox` field, nil when absent; ``sandboxSpec`` is what
  /// the process runs under.
  var sandbox: PluginSandboxDeclaration?
  /// HTTPS URL prefixes the plugin may request through `host.fetch`.
  /// Requires the `network_fetch` capability; the host rejects any request
  /// whose URL doesn't start with one of these.
  var fetchURLs: [String]
  /// Bundle ids of the apps the plugin's fixed operations may address through
  /// `host.applescript`. Requires the
  /// `apple_events` capability; the host refuses a script naming any other
  /// app. Plugin-provided source code is never accepted.
  var appleEventsTargets: [String]
  /// Host event-name patterns this plugin listens to. `*` is the only
  /// wildcard. Declaring `listen` makes the plugin resident.
  var listen: [String]
  /// `lifecycle`: nil unless the manifest declares how the run ends.
  var lifecycle: PluginLifecycleDeclaration?
  /// `watch_settings`: names of `[plugins.<id>]` settings whose string
  /// value is a file path the host watches; a change runs a
  /// `publish_then_exit` plugin again. Needs that lifecycle.
  var watchSettings: [String]
  var hints: PluginHints?
  var query: PluginQuery?
  /// Every `commands[]` entry: the plugin's own commands (``pluginCommands``)
  /// and the core commands it performs (``sourceCommands``).
  var commands: [PluginCommandRegistration]
  var mappings: [PluginMappingRegistration]
  /// Status-bar segment names fed by the `status` notification, rendered as
  /// `#{flash.plugin.<id>.<segment>}`.
  var status: [String]
  /// Flashlight bangs, each dispatched as `perform {kind: "command"}` with
  /// the plugin id as the command and the typed token as the subcommand.
  var bangs: [PluginBangRegistration]
  /// Durable route schemes restorable from movement history, dispatched as
  /// `perform {kind: "navigate"}`.
  var navigation: [String]
  /// What each app does for Flash's commands: binding key (`"tab new"`,
  /// `"app reload --force"`) → bundle id (`""` for every app the plugin's
  /// selector matches) → binding. The host dispatches the binding when no
  /// source performs the command in that app, so app knowledge lives in the
  /// plugin that knows the app, never in the host.
  var bindings: [CommandBindingKey: [String: CommandBindingSpec]]
  /// Bundle ids of apps this plugin declares as terminal emulators; the
  /// union across plugins is `TerminalEmulators`.
  var terminalEmulators: [String]
  /// Bundle ids of apps whose accessibility tree is too costly to warm in the
  /// background; the union across plugins is `OnDemandHintApps`.
  var onDemandHints: [String]
  /// Bundle ids of apps with their own modal editing or partial
  /// Accessibility text, which NORMAL never engages; the union across
  /// plugins is `OwnTextEditingApps`.
  var ownTextEditing: [String]
  var priority: Int
  /// Global active-window selector for this plugin, compounded with
  /// mapping-entry selectors.
  var selector: PluginSelector
  /// Candidate source descriptors this plugin contributes to `:flashlight`.
  /// `name` is the label rows carry in their first-class `source` field;
  /// `kind` is the semantic source class used for default ranking. Every
  /// plugin source is warm: a complete catalog the plugin publishes.
  var sources: [CandidateSourceDescriptor]
  /// Sensitive host capabilities the plugin requests. Default-deny.
  var capabilities: Set<PluginCapability>
  /// Help topics this plugin contributes to `:help`.
  var help: PluginHelp

  var onlyBundleIDs: [String] { selector.onlyBundleIDs }

  /// The core commands this plugin performs where its selector matches: the
  /// `commands[]` entries under one of Flash's topics, dispatched as
  /// `perform {kind: "command"}` with the focused app as `context`.
  var sourceCommands: Set<CommandName> {
    Set(commands.filter(\.isCoreCommand).map(\.name))
  }

  /// The plugin's own commands: every `commands[]` entry outside Flash's
  /// topics, the ones that register for dispatch and completion.
  var pluginCommands: [PluginCommandRegistration] {
    commands.filter { !$0.isCoreCommand }
  }

  /// The question the host asks before a core command this plugin performs
  /// destructively (`confirm` on the entry): command → prompt. The host
  /// shows it as a confirmation in the apps the plugin's selector matches,
  /// and dispatches the command only on `y`; the plugin then performs it
  /// without a prompt of its own.
  var confirmations: [CommandName: String] {
    commands.reduce(into: [:]) { table, entry in
      guard entry.isCoreCommand, let prompt = entry.confirm?.trimmed, !prompt.isEmpty else {
        return
      }
      table[entry.name] = prompt
    }
  }

  /// Whether this plugin performs `name` in `context`: it declares the core
  /// command and its selector matches the app.
  func performs(_ name: CommandName, in context: PluginSelectorContext) -> Bool {
    sourceCommands.contains(name) && CompiledPluginSelector(selector).matches(context)
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

  /// The allowances of the deny-default profile the plugin's process runs
  /// under, or nil when the manifest declares `"sandbox": false`. An absent
  /// declaration is the empty spec.
  var sandboxSpec: PluginSandboxSpec? {
    switch sandbox {
    case .spec(let spec): spec
    case .disabled: nil
    case nil: PluginSandboxSpec()
    }
  }

  /// A plugin is resident — spawned at startup and kept running — iff its
  /// manifest declares `sources`, `query`, `hints`, `status`, or `listen`.
  /// On-demand surfaces alone (`commands`, `bangs`, `navigation`)
  /// defer the spawn to the first `perform`, or to the settled-startup
  /// prewarm when a configured mapping runs one of the plugin's commands
  /// (`PluginWarmPolicy`). No `exec` means no process ever.
  var activation: PluginActivation {
    if exec == nil { return .manifestOnly }
    if lifecycle == .publishThenExit { return .publishThenExit }
    let resident =
      !sources.isEmpty || query != nil || hints != nil || !status.isEmpty || !listen.isEmpty
    return resident ? .resident : .onDemand
  }

  /// A plugin whose only resident surface is `status` — its `listen`
  /// subscriptions, if any, feed those segments. Nothing reads the segments
  /// unless the enabled bar, one of its popups or a desktop widget shows one,
  /// so such a plugin is resident only while observed and otherwise waits for
  /// its first `perform` like an on-demand plugin, or is warmed like one when
  /// a configured mapping runs one of its commands.
  var isStatusBound: Bool {
    !status.isEmpty && sources.isEmpty && query == nil && hints == nil
  }

  /// `activation`, given whether a status surface shows this plugin's segments.
  func activation(statusObserved: Bool) -> PluginActivation {
    isStatusBound && !statusObserved ? .onDemand : activation
  }

  /// The surfaces a live child serves, which a `publish_then_exit` plugin
  /// cannot declare (`protocol.json` `lifecycle.publish_then_exit.forbids`),
  /// in the contract's order.
  static let publishThenExitForbiddenSurfaces = [
    "hints", "query", "status", "listen", "commands", "bangs", "navigation",
  ]

  /// Which of the forbidden surfaces this manifest declares.
  private var publishThenExitSurfacesDeclared: [String] {
    let declared: [String: Bool] = [
      "hints": hints != nil, "query": query != nil, "status": !status.isEmpty,
      "listen": !listen.isEmpty, "commands": !commands.isEmpty, "bangs": !bangs.isEmpty,
      "navigation": !navigation.isEmpty,
    ]
    return Self.publishThenExitForbiddenSurfaces.filter { declared[$0] == true }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name, version, description, install, exec, sandbox, listen, priority, lifecycle
    case watchSettings = "watch_settings"
    case fetchURLs = "fetch_urls"
    case appleEventsTargets = "apple_events_targets"
    case onlyBundleIDs = "only_bundle_ids"
    case onlyTerminals = "only_terminals"
    case capabilities, help
    case hints, query, commands, mappings, status, bangs
    case sources
    case navigation
    case bindings
    case terminalEmulators = "terminal_emulators"
    case onDemandHints = "on_demand_hints"
    case ownTextEditing = "own_text_editing"
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String? = nil, exec: [String]? = nil,
    sandbox: PluginSandboxDeclaration? = nil,
    fetchURLs: [String] = [],
    appleEventsTargets: [String] = [],
    listen: [String] = [],
    lifecycle: PluginLifecycleDeclaration? = nil,
    watchSettings: [String] = [],
    hints: PluginHints? = nil,
    query: PluginQuery? = nil,
    commands: [PluginCommandRegistration] = [],
    mappings: [PluginMappingRegistration] = [],
    status: [String] = [],
    bangs: [PluginBangRegistration] = [],
    navigation: [String] = [],
    bindings: [CommandBindingKey: [String: CommandBindingSpec]] = [:],
    terminalEmulators: [String] = [],
    onDemandHints: [String] = [],
    ownTextEditing: [String] = [],
    priority: Int = 25,
    selector: PluginSelector = PluginSelector(),
    sources: [CandidateSourceDescriptor] = [],
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
    self.appleEventsTargets = Self.uniqueTrimmed(appleEventsTargets)
    self.listen = Self.uniqueTrimmed(listen)
    self.lifecycle = lifecycle
    self.watchSettings = Self.uniqueTrimmed(watchSettings)
    self.hints = hints
    self.query = query
    self.commands = commands
    self.mappings = mappings
    self.status = Self.uniqueTrimmed(status)
    self.bangs = bangs
    self.navigation = navigation
    self.bindings = bindings
    self.terminalEmulators = Self.uniqueTrimmed(terminalEmulators)
    self.onDemandHints = Self.uniqueTrimmed(onDemandHints)
    self.ownTextEditing = Self.uniqueTrimmed(ownTextEditing)
    self.priority = priority
    self.selector = selector
    self.sources = Self.uniqueSourceDescriptors(sources)
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
    self.sandbox = try c.decodeIfPresent(PluginSandboxDeclaration.self, forKey: .sandbox)
    self.fetchURLs = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .fetchURLs) ?? [])
    let rawTargets = try c.decodeIfPresent([String].self, forKey: .appleEventsTargets) ?? []
    guard !rawTargets.contains(where: { $0.trimmed.isEmpty }) else {
      throw PluginError.failure("manifest.json apple_events_targets entries must be bundle ids")
    }
    self.appleEventsTargets = Self.uniqueTrimmed(rawTargets)
    self.listen = Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .listen) ?? [])
    self.lifecycle = try c.decodeIfPresent(PluginLifecycleDeclaration.self, forKey: .lifecycle)
    self.watchSettings = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .watchSettings) ?? [])
    self.hints = try c.decodeIfPresent(PluginHints.self, forKey: .hints)
    self.query = try c.decodeIfPresent(PluginQuery.self, forKey: .query)
    self.commands =
      try c.decodeIfPresent([PluginCommandRegistration].self, forKey: .commands) ?? []
    self.mappings =
      try c.decodeIfPresent([PluginMappingRegistration].self, forKey: .mappings) ?? []
    self.status = Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .status) ?? [])
    self.bangs = try c.decodeIfPresent([PluginBangRegistration].self, forKey: .bangs) ?? []
    self.navigation = try c.decodeIfPresent([String].self, forKey: .navigation) ?? []
    let bindings =
      try c.decodeIfPresent([String: [String: CommandBindingSpec]].self, forKey: .bindings) ?? [:]
    self.bindings = try bindings.reduce(into: [:]) { table, entry in
      // A key is the command line a mapping writes, with its bool flags:
      // the retired `tab_new` spelling, a value argument or a command Flash
      // performs itself is not one.
      guard let key = CommandBindingKey(entry.key), Self.bindableKeys.contains(key) else {
        throw PluginError.failure(
          "manifest.json bindings: \(entry.key) is not a command Flash asks of the focused app")
      }
      table[key] = entry.value
    }
    self.terminalEmulators = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .terminalEmulators) ?? [])
    self.onDemandHints = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .onDemandHints) ?? [])
    self.ownTextEditing = Self.uniqueTrimmed(
      try c.decodeIfPresent([String].self, forKey: .ownTextEditing) ?? [])
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [],
      onlyTerminals: try c.decodeIfPresent(Bool.self, forKey: .onlyTerminals) ?? false)
    self.sources =
      Self.uniqueSourceDescriptors(
        try c.decodeIfPresent([CandidateSourceDescriptor].self, forKey: .sources) ?? [])
    let caps = try c.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
    self.capabilities = Set(caps)
    self.help = try c.decodeIfPresent(PluginHelp.self, forKey: .help) ?? PluginHelp()
  }

  /// Every key a `bindings` entry may use.
  private static let bindableKeys = Set(URLEventHandler.sourceCommandBindingKeys)

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
      dictionary["sources"], allowed: keys(CandidateSourceDescriptor.CodingKeys.self),
      path: "manifest.json sources")
    try rejectArrayObjects(
      dictionary["bangs"], allowed: keys(PluginBangRegistration.CodingKeys.self),
      path: "manifest.json bangs")
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
    for (key, bindings) in self.bindings {
      for (bundle, binding) in bindings {
        if let error = binding.validationError(for: key) {
          throw PluginError.failure("manifest.json bindings \(key) for \"\(bundle)\": \(error)")
        }
      }
    }
    if lifecycle == .publishThenExit {
      guard exec != nil else {
        throw PluginError.failure("manifest.json lifecycle publish_then_exit needs exec")
      }
      guard !sources.isEmpty else {
        throw PluginError.failure("manifest.json lifecycle publish_then_exit needs sources")
      }
      let declared = publishThenExitSurfacesDeclared
      if !declared.isEmpty {
        throw PluginError.failure(
          "manifest.json lifecycle publish_then_exit allows sources alone: remove "
            + declared.joined(separator: ", "))
      }
    } else if !watchSettings.isEmpty {
      throw PluginError.failure("manifest.json watch_settings needs lifecycle publish_then_exit")
    }
    if let exec {
      if exec.isEmpty || exec.contains(where: { $0.trimmed.isEmpty }) {
        throw PluginError.failure(
          "manifest.json field exec must be a non-empty argv array without empty elements")
      }
    } else {
      // Manifest-only plugin: no child process ever runs, so any surface
      // that would need RPC into (or events delivered to) the plugin is
      // invalid. Mappings, help topics, bindings and app declarations
      // (terminal emulators, on-demand hints, own text editing) are the
      // complete allowed surface; a core `commands[]` entry needs a process
      // like any other.
      let processBound: [(String, Bool)] = [
        ("listen", !listen.isEmpty),
        ("hints", hints != nil),
        ("query", query != nil),
        ("commands", !commands.isEmpty),
        ("status", !status.isEmpty),
        ("bangs", !bangs.isEmpty),
        ("navigation", !navigation.isEmpty),
        ("sources", !sources.isEmpty),
        ("capabilities", !capabilities.isEmpty),
        ("sandbox", sandbox != nil),
        ("fetch_urls", !fetchURLs.isEmpty),
        ("apple_events_targets", !appleEventsTargets.isEmpty),
      ]
      if let field = processBound.first(where: { $0.1 })?.0 {
        throw PluginError.failure(
          "manifest.json without exec cannot declare \(field) — it requires a plugin process")
      }
    }
    // A host-performed capability comes with the allowlist it is checked
    // against, and only with it.
    if capabilities.contains(.networkFetch) != !fetchURLs.isEmpty {
      throw PluginError.failure(
        "manifest.json network_fetch capability and fetch_urls must be declared together")
    }
    for prefix in fetchURLs where !prefix.hasPrefix("https://") {
      throw PluginError.failure(
        "manifest.json fetch_urls entries must be https:// prefixes: \(prefix)")
    }
    if capabilities.contains(.appleEvents) != !appleEventsTargets.isEmpty {
      throw PluginError.failure(
        "manifest.json apple_events capability and apple_events_targets must be declared together"
      )
    }
    for target in appleEventsTargets where !ConfigLoader.isValidBundleID(target) {
      throw PluginError.failure(
        "manifest.json apple_events_targets entries must be bundle ids: \(target)")
    }
    // `network` composes `network-outbound` into the deny-default profile and
    // grants nothing else; an unsandboxed process has no profile to widen.
    if capabilities.contains(.network), sandboxSpec == nil {
      throw PluginError.failure(
        "manifest.json network capability only composes the sandbox profile; an unsandboxed "
          + "plugin cannot declare it")
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
    // `[plugins.<id>]` holds a plugin's settings beside `[plugins]`' own.
    guard !ConfigLoader.pluginsSettingKeys.contains(id) else {
      throw PluginError.failure("manifest.json id \(id) is a [plugins] setting")
    }
    // A plugin command is always `flash <command> <subcommand>`, two words of
    // `[a-z][a-z0-9_]*` like every Flash command (`*` is the wildcard
    // subcommand). A command with no subcommand is rejected here so it cannot
    // be registered. An entry under one of Flash's topics is a core command
    // the plugin performs, so it must name one Flash asks of the focused app.
    for command in commands {
      if command.command.trimmed.isEmpty {
        throw PluginError.failure("plugin command must not be empty")
      }
      let subcommand = command.subcommand
      if subcommand.trimmed.isEmpty {
        throw PluginError.commandConflict(
          "plugin \(id) failed to load: flash \(command.command) requires a subcommand "
            + "(flash \(command.command) <subcommand>)")
      }
      if subcommand != subcommand.trimmed || subcommand.contains(where: { $0.isWhitespace }) {
        throw PluginError.failure(
          "plugin command \(command.command) subcommand must be a single token")
      }
      guard CommandName.isWord(command.command),
        subcommand == "*" || CommandName.isWord(subcommand)
      else {
        throw PluginError.commandConflict(
          "plugin \(id) failed to load: flash \(command.command) \(subcommand) must be two "
            + "words of [a-z][a-z0-9_]* (or the * subcommand)")
      }
      if command.isCoreCommand {
        guard subcommand != "*",
          URLEventHandler.sourceCommandNames.contains(CommandName(command.command, subcommand))
        else {
          throw PluginError.failure(
            "plugin \(id) failed to load: flash \(command.command) \(subcommand) is not a command "
              + "Flash asks of the focused app")
        }
        if let confirm = command.confirm, confirm.trimmed.isEmpty {
          throw PluginError.failure(
            "manifest.json commands \(command.command) \(subcommand) confirm needs a non-empty "
              + "prompt")
        }
      } else if command.confirm != nil {
        // The host gates only what it dispatches itself: a plugin's own
        // command asks nothing through Flash.
        throw PluginError.failure(
          "manifest.json commands \(command.command) \(subcommand): confirm belongs to a core "
            + "command the plugin performs, not to its own command")
      }
    }
    if let conflict = Self.commandClaimFailures([self])[id] {
      throw PluginError.commandConflict(conflict)
    }
    // Every source declares one resource type, the word `@<type>` filters by
    // (`ResourceTypes`): not one Flash feeds, and of its contract's kind.
    for source in sources {
      if let reason = ResourceTypes.pluginRejection(type: source.type, kind: source.kind) {
        throw PluginError.failure("plugin source \(source.name) \(reason)")
      }
    }
    for bang in bangs {
      if bang.token.trimmed.isEmpty {
        throw PluginError.failure("plugin bang token must not be empty")
      }
      if CoreBangs.bang(token: bang.token) != nil {
        throw PluginError.failure("plugin bang \(bang.token) is one of Flash's own bangs")
      }
      // A bang's completion source must be one this plugin actually serves —
      // a typo here would silently swap the pool to nothing.
      if let source = bang.source, !source.isEmpty, !candidateSources.contains(source) {
        throw PluginError.failure(
          "plugin bang \(bang.token) source \(source) must name a declared sources[] entry")
      }
    }
    for mapping in mappings {
      guard let scope = ModeScope(rawValue: mapping.mode) else {
        throw PluginError.failure(
          "plugin mapping mode \(mapping.mode) must be all, normal, insert, terminal, command, "
            + "hyper, hold, text or visual")
      }
      // The config's rule: the command line reads only native chords.
      if scope == .command, ModeMapping.parseNativeHotkey(mapping.key) == nil {
        throw PluginError.failure(
          "plugin mapping \(mapping.key) in command mode must be a single modified key")
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

  /// Plugin command names that cannot be shared. A plugin command is
  /// `flash <command> <subcommand>`; a command name another plugin's own
  /// command uses fails every plugin that claims it. An entry under one of
  /// Flash's topics declares a core command and claims no name: `validate()`
  /// holds it to the commands Flash asks of the focused app.
  static func commandClaimFailures(_ manifests: [PluginManifest]) -> [String: String] {
    struct Claim {
      var pluginID: String
    }
    var owners: [String: [Claim]] = [:]
    var failures: [String: String] = [:]
    func note(_ id: String, _ message: String) {
      if let existing = failures[id] {
        failures[id] = existing + "; " + message
      } else {
        failures[id] = message
      }
    }
    for manifest in manifests {
      var commandNames = Set<String>()
      var pairs = Set<String>()
      for command in manifest.commands {
        let name = command.command.trimmed.lowercased()
        guard !name.isEmpty else { continue }
        let subcommand = command.subcommand.trimmed.lowercased()
        if !pairs.insert(name + "\u{1f}" + subcommand).inserted {
          note(
            manifest.id,
            "plugin \(manifest.id) failed to load: flash \(name) \(subcommand) conflicts — "
              + "declared more than once")
        }
        guard !URLEventHandler.isTopic(name) else { continue }
        if commandNames.insert(name).inserted {
          owners[name, default: []].append(Claim(pluginID: manifest.id))
        }
      }
    }
    for (token, claims) in owners {
      let plugins = Array(Set(claims.map(\.pluginID))).sorted()
      guard plugins.count > 1 else { continue }
      for id in plugins {
        note(
          id,
          "plugin \(id) failed to load: flash \(token) conflicts — \(token) is declared by "
            + plugins.joined(separator: ", "))
      }
    }
    return failures
  }
}

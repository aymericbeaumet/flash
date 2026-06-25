import AppKit
import Darwin
import FlashCore
import Foundation

/// Sensitive host capabilities a plugin must explicitly request in its
/// `manifest.json` to receive. Default-deny: if the manifest doesn't list a
/// capability here, the host filters out any host events / RPC paths gated by
/// it. Bundled plugins opt in by adding the capability to their manifest in
/// the same change as the host gating.
enum PluginCapability: String, Codable, CaseIterable, Equatable {
  /// Subscribe to `core:clipboard.changed`, which carries the full clipboard
  /// text. Most plugins do not need this; password managers, paste history,
  /// and clipboard transformers do.
  case clipboard
  /// Call the host's Accessibility broker (`ax.snapshot`, `ax.perform`,
  /// `ax.set`). The core owns the single AX permission grant and handle
  /// registry; plugins own app-specific interpretation of the returned nodes.
  case accessibility
  /// Make outbound network connections. Plugins WITHOUT this run under a
  /// seatbelt profile (`sandbox-exec`) that denies network, so a compromised or
  /// buggy plugin can't exfiltrate. Declare it when the plugin reaches the
  /// network directly or via a child process (e.g. `curl`, an API client).
  case network
  /// Exec privileged helper binaries the network sandbox can't run — notably
  /// setgid `/bin/ps`, which seatbelt refuses (and which no profile can permit
  /// without also letting children escape the network deny). Implies the plugin
  /// spawns unsandboxed; used by process inspectors (`processes`, `tmux`).
  case subprocess
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

struct PluginPattern: Hashable, Equatable {
  let raw: String
  private let parts: [String]
  private let hasLeadingWildcard: Bool
  private let hasTrailingWildcard: Bool
  let specificity: Int

  init(_ raw: String) {
    let raw = raw.trimmed
    self.raw = raw
    self.parts = raw.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    self.hasLeadingWildcard = raw.hasPrefix("*")
    self.hasTrailingWildcard = raw.hasSuffix("*")
    let literalCount = raw.filter { $0 != "*" }.count
    let componentCount = raw.split(separator: "/").filter { !$0.isEmpty && $0 != "*" }.count
    self.specificity = literalCount + componentCount * 25
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

struct CompiledPluginSelector: Hashable, Equatable {
  private let onlyBundleIDs: Set<String>
  private let onlyURLPatterns: [PluginPattern]

  init(_ selector: PluginSelector) {
    self.onlyBundleIDs = Set(selector.onlyBundleIDs)
    self.onlyURLPatterns = selector.onlyURLs.map(PluginPattern.init)
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty && onlyURLPatterns.isEmpty
  }

  var usesURL: Bool {
    !onlyURLPatterns.isEmpty
  }

  func matches(_ context: PluginSelectorContext) -> Bool {
    if !onlyBundleIDs.isEmpty {
      guard let bundleID = context.bundleID, onlyBundleIDs.contains(bundleID) else {
        return false
      }
    }
    if !onlyURLPatterns.isEmpty {
      guard let url = context.url, onlyURLPatterns.contains(where: { $0.matches(url) })
      else {
        return false
      }
    }
    return true
  }

  func specificity(in context: PluginSelectorContext) -> Int? {
    guard matches(context) else { return nil }
    var score = 0
    if !onlyBundleIDs.isEmpty { score += 1_000 }
    if !onlyURLPatterns.isEmpty {
      let bestURL =
        context.url.map { url in
          onlyURLPatterns
            .filter { $0.matches(url) }
            .map(\.specificity)
            .max() ?? 0
        } ?? 0
      score += 1_000 + bestURL
    }
    return score
  }
}

struct PluginSelectorContext: Equatable {
  var bundleID: String?
  var url: String?

  init(bundleID: String? = nil, url: String? = nil) {
    self.bundleID = bundleID
    self.url = url
  }

  var cacheKey: String {
    "\(bundleID ?? "")\u{1f}\(url ?? "")"
  }
}

struct PluginSelector: Codable, Hashable, Equatable {
  var onlyBundleIDs: [String]
  var onlyURLs: [String]

  init(onlyBundleIDs: [String] = [], onlyURLs: [String] = []) {
    self.onlyBundleIDs = onlyBundleIDs
    self.onlyURLs = onlyURLs
  }

  var isEmpty: Bool {
    onlyBundleIDs.isEmpty && onlyURLs.isEmpty
  }

  var usesURL: Bool {
    !onlyURLs.isEmpty
  }

  enum CodingKeys: String, CodingKey {
    case onlyBundleIDs = "only_bundle_ids"
    case onlyURLs = "only_urls"
  }

  func matches(_ context: PluginSelectorContext) -> Bool {
    if !onlyBundleIDs.isEmpty {
      guard let bundleID = context.bundleID, onlyBundleIDs.contains(bundleID) else {
        return false
      }
    }
    if !onlyURLs.isEmpty {
      guard let url = context.url, onlyURLs.contains(where: { PluginPattern.matches($0, url) })
      else {
        return false
      }
    }
    return true
  }

  func specificity(in context: PluginSelectorContext) -> Int? {
    guard matches(context) else { return nil }
    var score = 0
    if !onlyBundleIDs.isEmpty { score += 1_000 }
    if !onlyURLs.isEmpty {
      let bestURL =
        onlyURLs
        .filter { pattern in context.url.map { PluginPattern.matches(pattern, $0) } ?? false }
        .map { PluginPattern($0).specificity }
        .max() ?? 0
      score += 1_000 + bestURL
    }
    return score
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !onlyBundleIDs.isEmpty { try c.encode(onlyBundleIDs, forKey: .onlyBundleIDs) }
    if !onlyURLs.isEmpty { try c.encode(onlyURLs, forKey: .onlyURLs) }
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

  var usesURL: Bool {
    selectors.contains(where: \.usesURL)
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
struct PluginCommandRegistration: Codable, Hashable {
  var command: String
  var subcommand: String
  var description: String
  /// Active-window selector for this command. Empty means it inherits only the
  /// manifest-level selector.
  var selector: PluginSelector
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
    selector: PluginSelector = PluginSelector(),
    meta: [String: String] = [:]
  ) {
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.selector = selector
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
    self.selector = PluginSelector(
      onlyBundleIDs: (try? c.decode(
        [String].self, forKey: DynamicKey(stringValue: "only_bundle_ids"))) ?? [],
      onlyURLs: (try? c.decode([String].self, forKey: DynamicKey(stringValue: "only_urls")))
        ?? [])
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
    if !selector.onlyBundleIDs.isEmpty {
      try c.encode(selector.onlyBundleIDs, forKey: DynamicKey(stringValue: "only_bundle_ids"))
    }
    if !selector.onlyURLs.isEmpty {
      try c.encode(selector.onlyURLs, forKey: DynamicKey(stringValue: "only_urls"))
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
  /// Active-window selector for this bang. Empty means it inherits only the
  /// manifest-level selector.
  var selector: PluginSelector
  /// Candidate source label this bang draws its selectable rows from. When the
  /// user confirms `!<token> `, the flashlight pool swaps to this source's
  /// candidates; Return on a row dispatches the bang. Empty means the bang has
  /// no candidate list — typing the bang submits the typed remainder.
  var candidateSource: String?
  /// Arbitrary `_`-prefixed manifest fields forwarded verbatim on invoke, so a
  /// plugin can keep per-bang data (e.g. a URL template) in the manifest.
  var meta: [String: String]

  init(
    token: String,
    command: String = "",
    description: String = "",
    selector: PluginSelector = PluginSelector(),
    candidateSource: String? = nil,
    meta: [String: String] = [:]
  ) {
    self.token = token
    self.command = command
    self.description = description
    self.selector = selector
    self.candidateSource = candidateSource
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
    self.selector = PluginSelector(
      onlyBundleIDs: (try? c.decode(
        [String].self, forKey: DynamicKey(stringValue: "only_bundle_ids"))) ?? [],
      onlyURLs: (try? c.decode([String].self, forKey: DynamicKey(stringValue: "only_urls")))
        ?? [])
    self.candidateSource = string("candidate_source")
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
    if !selector.onlyBundleIDs.isEmpty {
      try c.encode(selector.onlyBundleIDs, forKey: DynamicKey(stringValue: "only_bundle_ids"))
    }
    if !selector.onlyURLs.isEmpty {
      try c.encode(selector.onlyURLs, forKey: DynamicKey(stringValue: "only_urls"))
    }
    if let candidateSource, !candidateSource.isEmpty {
      try c.encode(candidateSource, forKey: DynamicKey(stringValue: "candidate_source"))
    }
    for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
      try c.encode(value, forKey: DynamicKey(stringValue: key))
    }
  }
}

/// One verb a plugin registers. `name` is the verb users type in mappings or
/// pass to `flash <name> [k=v]...`. The host dispatches it to the owning plugin
/// as `command.invoke` with the configured `subcommand` (defaulting to `name`)
/// and the verb's args. When `inlineKeystrokes` is populated, the host short-
/// circuits the round-trip and synthesizes the per-bundle keystroke directly —
/// keeps `app_save`-class verbs latency-flat.
struct PluginVerbRegistration: Codable, Equatable {
  var name: String
  var command: String
  var subcommand: String
  var description: String
  /// Per-bundle keystroke table consumed before any RPC dispatch. Map entries
  /// use bundle id → "cmd+s"-style hotkey. The empty string key (`""`) is the
  /// default applied when no bundle-specific entry matches; missing entirely
  /// means "no fallback, fall through to RPC". Empty map disables the
  /// shortcut entirely.
  var inlineKeystrokes: [String: String]
  /// Active-window selector for this verb. Empty means it inherits only the
  /// manifest-level selector.
  var selector: PluginSelector

  init(
    name: String,
    command: String = "",
    subcommand: String = "",
    description: String = "",
    inlineKeystrokes: [String: String] = [:],
    selector: PluginSelector = PluginSelector()
  ) {
    self.name = name
    self.command = command
    self.subcommand = subcommand
    self.description = description
    self.inlineKeystrokes = inlineKeystrokes
    self.selector = selector
  }

  enum CodingKeys: String, CodingKey {
    case name, command, subcommand, description
    case inlineKeystrokes = "inline_keystrokes"
    case onlyBundleIDs = "only_bundle_ids"
    case onlyURLs = "only_urls"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand) ?? ""
    self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    self.inlineKeystrokes =
      try c.decodeIfPresent([String: String].self, forKey: .inlineKeystrokes) ?? [:]
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [],
      onlyURLs: try c.decodeIfPresent([String].self, forKey: .onlyURLs) ?? [])
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    if !command.isEmpty { try c.encode(command, forKey: .command) }
    if !subcommand.isEmpty { try c.encode(subcommand, forKey: .subcommand) }
    if !description.isEmpty { try c.encode(description, forKey: .description) }
    if !inlineKeystrokes.isEmpty {
      try c.encode(inlineKeystrokes, forKey: .inlineKeystrokes)
    }
    if !selector.onlyBundleIDs.isEmpty {
      try c.encode(selector.onlyBundleIDs, forKey: .onlyBundleIDs)
    }
    if !selector.onlyURLs.isEmpty { try c.encode(selector.onlyURLs, forKey: .onlyURLs) }
  }
}

/// One key mapping a plugin registers. Mirrors a `[mode.<scope>.mappings]`
/// config entry plus an optional active-window selector. `priority` decides
/// who wins when several mappings claim the same key; selector specificity is
/// added at resolution time, so a bundle+URL-scoped mapping beats a
/// bundle-only mapping at the same declared priority. `command` is an argv
/// array matching the mapping syntax:
/// `["flash", "<verb>", "k=v" ...]` for in-process verbs, anything else for
/// argv exec.
struct PluginMappingRegistration: Codable, Hashable {
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

  enum CodingKeys: String, CodingKey {
    case key, mode, command
    case onlyBundleIDs = "only_bundle_ids"
    case onlyURLs = "only_urls"
    case priority
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "normal"
    self.command = try c.decode([String].self, forKey: .command)
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [],
      onlyURLs: try c.decodeIfPresent([String].self, forKey: .onlyURLs) ?? [])
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key)
    if mode != "normal" { try c.encode(mode, forKey: .mode) }
    try c.encode(command, forKey: .command)
    if !selector.onlyBundleIDs.isEmpty {
      try c.encode(selector.onlyBundleIDs, forKey: .onlyBundleIDs)
    }
    if !selector.onlyURLs.isEmpty { try c.encode(selector.onlyURLs, forKey: .onlyURLs) }
    if let priority { try c.encode(priority, forKey: .priority) }
  }

  /// `mode` string → `ModeScope`; an unknown value falls back to `.normal`
  /// (the common case — overriding `f`/nav keys lives in normal mode).
  var scope: ModeScope { ModeScope(rawValue: mode) ?? .normal }
}

/// One help topic a plugin contributes to `:help`. Surfaces via
/// ``PluginManifest/help`` and is aggregated by `HelpDocs.allTopics`
/// alongside the host's own topics. The body is rendered as Markdown.
struct PluginHelpTopic: Codable, Equatable {
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

  enum CodingKeys: String, CodingKey {
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

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(title, forKey: .title)
    if !summary.isEmpty { try c.encode(summary, forKey: .summary) }
    if !body.isEmpty { try c.encode(body, forKey: .body) }
    if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
  }
}

/// Plugin-declared help block. Each entry shows up in `:help` next to the
/// host's built-in topics.
struct PluginHelp: Codable, Equatable {
  var topics: [PluginHelpTopic]

  init(topics: [PluginHelpTopic] = []) {
    self.topics = topics
  }

  enum CodingKeys: String, CodingKey {
    case topics
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.topics = try c.decodeIfPresent([PluginHelpTopic].self, forKey: .topics) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !topics.isEmpty { try c.encode(topics, forKey: .topics) }
  }
}

/// Shared optional gates for a top-level manifest provider section.
struct PluginProviderGate: Codable, Equatable {
  /// Editor modes this provider section is gated to (empty = every mode).
  var modes: [ProviderMode]
  /// Scheduling priority override; `nil` inherits the manifest priority.
  var priority: Int?

  init(modes: [ProviderMode] = [], priority: Int? = nil) {
    self.modes = modes
    self.priority = priority
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !modes.isEmpty { try c.encode(modes, forKey: .modes) }
    if let priority { try c.encode(priority, forKey: .priority) }
  }

  var conditions: ProviderConditions {
    ProviderConditions(modes: Set(modes))
  }

  func matches(mode: ProviderMode? = nil) -> Bool {
    conditions.matches(bundleID: nil, mode: mode)
  }
}

struct PluginHintsProvider: Codable, Equatable {
  var gate: PluginProviderGate

  init(modes: [ProviderMode] = [], priority: Int? = nil) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
  }

  init(from decoder: Decoder) throws {
    self.gate = try PluginProviderGate(from: decoder)
  }

  func encode(to encoder: Encoder) throws {
    try gate.encode(to: encoder)
  }
}

struct PluginCommandsProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var items: [PluginCommandRegistration]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    items: [PluginCommandRegistration] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, items
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.items = try c.decodeIfPresent([PluginCommandRegistration].self, forKey: .items) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !items.isEmpty { try c.encode(items, forKey: .items) }
  }
}

struct PluginMappingsProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var items: [PluginMappingRegistration]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    items: [PluginMappingRegistration] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, items
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.items = try c.decodeIfPresent([PluginMappingRegistration].self, forKey: .items) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !items.isEmpty { try c.encode(items, forKey: .items) }
  }
}

struct PluginShebangProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var command: String
  var items: [PluginShebangRegistration]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    command: String = "",
    items: [PluginShebangRegistration] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.command = command
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, command, items
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.items = try c.decodeIfPresent([PluginShebangRegistration].self, forKey: .items) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !command.isEmpty { try c.encode(command, forKey: .command) }
    if !items.isEmpty { try c.encode(items, forKey: .items) }
  }
}

struct PluginNavigationProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var schemes: [String]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    schemes: [String] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.schemes = schemes
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, schemes
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.schemes = try c.decodeIfPresent([String].self, forKey: .schemes) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !schemes.isEmpty { try c.encode(schemes, forKey: .schemes) }
  }
}

struct PluginStatusProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var segments: [String]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    segments: [String] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.segments = segments
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, segments
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.segments = try c.decodeIfPresent([String].self, forKey: .segments) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !segments.isEmpty { try c.encode(segments, forKey: .segments) }
  }
}

struct PluginVerbsProvider: Codable, Equatable {
  var gate: PluginProviderGate
  var command: String
  var items: [PluginVerbRegistration]

  init(
    modes: [ProviderMode] = [],
    priority: Int? = nil,
    command: String = "",
    items: [PluginVerbRegistration] = []
  ) {
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.command = command
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case modes, priority, command, items
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let modes = try c.decodeIfPresent([ProviderMode].self, forKey: .modes) ?? []
    let priority = try c.decodeIfPresent(Int.self, forKey: .priority)
    self.gate = PluginProviderGate(modes: modes, priority: priority)
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.items = try c.decodeIfPresent([PluginVerbRegistration].self, forKey: .items) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !gate.modes.isEmpty { try c.encode(gate.modes, forKey: .modes) }
    if let priority = gate.priority { try c.encode(priority, forKey: .priority) }
    if !command.isEmpty { try c.encode(command, forKey: .command) }
    if !items.isEmpty { try c.encode(items, forKey: .items) }
  }
}

struct PluginManifest: Codable, Equatable {
  var id: String
  var name: String
  var version: String
  var description: String
  var install: String
  var start: String
  /// Host event-name patterns this plugin listens to. `*` is the only wildcard.
  var listen: [String]
  var hintsProvider: PluginHintsProvider?
  var commandProvider: PluginCommandsProvider?
  var mappingProvider: PluginMappingsProvider?
  var statusProvider: PluginStatusProvider?
  var shebangProvider: PluginShebangProvider?
  var navigationProvider: PluginNavigationProvider?
  var verbsProvider: PluginVerbsProvider?
  var priority: Int
  var volatile: Bool
  /// Global active-window selector for this plugin. Entry-level selectors in
  /// commands, shebangs, mappings, and verbs are compounded with it.
  var selector: PluginSelector
  /// Candidate source descriptors this plugin contributes to `:flashlight`.
  /// `name` is the label candidates emit in metadata; `kind` is the semantic
  /// source class used for default ranking.
  var sources: [CandidateSourceDescriptor]
  /// Source-owned normal-mode commands this plugin can handle.
  var sourceActions: [String]
  /// Per-request RPC timeout in milliseconds. Plugins that fan out to the
  /// network (e.g. GitHub) can raise this above the 2000ms default so a slow
  /// response isn't dropped. `nil` uses the default.
  var requestTimeoutMs: Int?
  /// Sensitive host capabilities the plugin requests. Default-deny: omitting
  /// a capability here means the host filters out any event / RPC path gated
  /// by it. See ``PluginCapability``.
  var capabilities: Set<PluginCapability>
  /// Help topics this plugin contributes to `:help`. Each entry appears as a
  /// `:help <name>` topic alongside the host's built-in topics. Empty by
  /// default; plugins authoritative for a domain (spotify, slack, …) typically
  /// declare one topic, while a multi-surface plugin can ship several.
  var help: PluginHelp

  var onlyBundleIDs: [String] { selector.onlyBundleIDs }
  var onlyURLs: [String] { selector.onlyURLs }

  /// Denormalized (command, subcommand) rows across the `commands` provider.
  var commands: [PluginCommandRegistration] {
    commandProvider?.items ?? []
  }

  /// Mapping registrations across every `mappings` provider, with the
  /// provider's shared `modes`/`priority` folded into each entry so downstream
  /// resolution sees a flat list.
  var mappings: [PluginMappingRegistration] {
    guard let provider = mappingProvider else { return [] }
    return provider.items.map { entry in
      var entry = entry
      if entry.priority == nil { entry.priority = provider.gate.priority }
      if entry.mode == "normal", provider.gate.modes.count == 1 {
        entry.mode = provider.gate.modes[0].rawValue
      }
      return entry
    }
  }

  /// Bang registrations across every `shebang` provider, each carrying its
  /// provider's `command` so the flashlight `!` dispatch index sees a flat
  /// list. The token `"*"` marks a catch-all that claims every otherwise-
  /// unclaimed bang.
  var shebangs: [PluginShebangRegistration] {
    guard let provider = shebangProvider else { return [] }
    return provider.items.map { entry in
      var entry = entry
      if entry.command.isEmpty { entry.command = provider.command }
      return entry
    }
  }

  func supportsSourceAction(_ action: String, context: PluginSelectorContext) -> Bool {
    let requested = action.trimmed
    guard !requested.isEmpty, sourceActions.contains(requested) else { return false }
    return selector.matches(context)
  }

  var navigationSchemes: [String] {
    var seen = Set<String>()
    var out: [String] = []
    for scheme in navigationProvider?.schemes ?? [] {
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

  /// Verbs every loaded plugin registers. Used by URL dispatch to route
  /// `flash <verb>` to the right plugin.
  var verbs: [PluginVerbRegistration] {
    guard let provider = verbsProvider else { return [] }
    return provider.items.map { entry in
      var entry = entry
      if entry.command.isEmpty { entry.command = provider.command }
      if entry.subcommand.isEmpty { entry.subcommand = entry.name }
      return entry
    }
  }

  var statusSegments: [String] {
    var seen = Set<String>()
    var out: [String] = []
    for segment in statusProvider?.segments ?? [] {
      let trimmed = segment.trimmed
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      out.append(trimmed)
    }
    return out
  }

  /// True when any provider opts the plugin in as a hints provider. Hint
  /// selection is exclusive (highest-priority provider supporting the focused
  /// app wins, no fallback), so a plugin only advertises `.jumpTargets` when it
  /// declares a `hints` provider.
  var providesHints: Bool {
    hintsProvider != nil
  }

  /// True when any provider opts the plugin into the candidate/flashlight
  /// surface. Gates the candidate-adjacent capabilities (`.candidates`, plus the
  /// app-activation and tab operations that act on candidate-like entities) so a
  /// commands-only plugin isn't consulted on every flashlight query. The
  /// candidates surface stays global+additive — plugins self-limit their
  /// snapshot via focus events — so this is a capability toggle, not an
  /// app/mode gate.
  var providesCandidates: Bool {
    !sources.isEmpty
  }

  var usesURLSelector: Bool {
    if selector.usesURL { return true }
    if commands.contains(where: { $0.selector.usesURL }) { return true }
    if mappings.contains(where: { $0.selector.usesURL }) { return true }
    if shebangs.contains(where: { $0.selector.usesURL }) { return true }
    if verbs.contains(where: { $0.selector.usesURL }) { return true }
    return false
  }

  func providerSupports(context: PluginSelectorContext) -> Bool {
    guard selector.matches(context) else { return false }
    return hintsProvider != nil
      || !sourceActions.isEmpty
      || navigationProvider != nil
      || !sources.isEmpty
  }

  func listens(to event: PluginEvent) -> Bool {
    listen.contains { PluginPattern.matches($0, event.name) }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name, version, description, install, start, listen, priority
    case volatile
    case onlyBundleIDs = "only_bundle_ids"
    case onlyURLs = "only_urls"
    case requestTimeoutMs = "request_timeout_ms"
    case capabilities, help
    case hints, commands, mappings, status, shebangs
    case sourceActions = "source_actions"
    case sources
    case navigation, verbs
  }

  init(
    id: String, name: String, version: String, description: String,
    install: String, start: String,
    listen: [String] = [],
    hintsProvider: PluginHintsProvider? = nil,
    commandProvider: PluginCommandsProvider? = nil,
    mappingProvider: PluginMappingsProvider? = nil,
    statusProvider: PluginStatusProvider? = nil,
    shebangProvider: PluginShebangProvider? = nil,
    navigationProvider: PluginNavigationProvider? = nil,
    verbsProvider: PluginVerbsProvider? = nil,
    priority: Int = 25,
    volatile: Bool = false,
    selector: PluginSelector = PluginSelector(),
    sources: [CandidateSourceDescriptor] = [],
    sourceActions: [String] = [],
    requestTimeoutMs: Int? = nil,
    capabilities: Set<PluginCapability> = [],
    help: PluginHelp = PluginHelp()
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.install = install
    self.start = start
    self.listen = Self.uniqueTrimmed(listen)
    self.hintsProvider = hintsProvider
    self.commandProvider = commandProvider
    self.mappingProvider = mappingProvider
    self.statusProvider = statusProvider
    self.shebangProvider = shebangProvider
    self.navigationProvider = navigationProvider
    self.verbsProvider = verbsProvider
    self.priority = priority
    self.volatile = volatile
    self.selector = selector
    self.sources = Self.uniqueSourceDescriptors(sources)
    self.sourceActions = Self.uniqueTrimmed(sourceActions)
    self.requestTimeoutMs = requestTimeoutMs
    self.capabilities = capabilities
    self.help = help
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.name = try c.decode(String.self, forKey: .name)
    self.version = try c.decode(String.self, forKey: .version)
    self.description = try c.decode(String.self, forKey: .description)
    self.install = try c.decode(String.self, forKey: .install)
    self.start = try c.decode(String.self, forKey: .start)
    self.listen = Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .listen) ?? [])
    self.hintsProvider = try c.decodeIfPresent(PluginHintsProvider.self, forKey: .hints)
    self.commandProvider = try c.decodeIfPresent(PluginCommandsProvider.self, forKey: .commands)
    self.mappingProvider = try c.decodeIfPresent(PluginMappingsProvider.self, forKey: .mappings)
    self.statusProvider = try c.decodeIfPresent(PluginStatusProvider.self, forKey: .status)
    self.shebangProvider = try c.decodeIfPresent(PluginShebangProvider.self, forKey: .shebangs)
    self.navigationProvider =
      try c.decodeIfPresent(PluginNavigationProvider.self, forKey: .navigation)
    self.verbsProvider = try c.decodeIfPresent(PluginVerbsProvider.self, forKey: .verbs)
    self.priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 25
    self.volatile = try c.decodeIfPresent(Bool.self, forKey: .volatile) ?? false
    self.selector = PluginSelector(
      onlyBundleIDs: try c.decodeIfPresent([String].self, forKey: .onlyBundleIDs) ?? [],
      onlyURLs: try c.decodeIfPresent([String].self, forKey: .onlyURLs) ?? [])
    self.sources =
      Self.uniqueSourceDescriptors(
        try c.decodeIfPresent([CandidateSourceDescriptor].self, forKey: .sources) ?? [])
    self.sourceActions =
      Self.uniqueTrimmed(try c.decodeIfPresent([String].self, forKey: .sourceActions) ?? [])
    self.requestTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutMs)
    let caps = try c.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
    self.capabilities = Set(caps)
    self.help = try c.decodeIfPresent(PluginHelp.self, forKey: .help) ?? PluginHelp()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(version, forKey: .version)
    try c.encode(description, forKey: .description)
    try c.encode(install, forKey: .install)
    try c.encode(start, forKey: .start)
    if !listen.isEmpty { try c.encode(listen, forKey: .listen) }
    if let hintsProvider { try c.encode(hintsProvider, forKey: .hints) }
    if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
    if let commandProvider { try c.encode(commandProvider, forKey: .commands) }
    if let mappingProvider { try c.encode(mappingProvider, forKey: .mappings) }
    if let statusProvider { try c.encode(statusProvider, forKey: .status) }
    if let shebangProvider { try c.encode(shebangProvider, forKey: .shebangs) }
    if !sourceActions.isEmpty { try c.encode(sourceActions, forKey: .sourceActions) }
    if let navigationProvider { try c.encode(navigationProvider, forKey: .navigation) }
    if let verbsProvider { try c.encode(verbsProvider, forKey: .verbs) }
    try c.encode(priority, forKey: .priority)
    if volatile { try c.encode(volatile, forKey: .volatile) }
    if !selector.onlyBundleIDs.isEmpty {
      try c.encode(selector.onlyBundleIDs, forKey: .onlyBundleIDs)
    }
    if !selector.onlyURLs.isEmpty { try c.encode(selector.onlyURLs, forKey: .onlyURLs) }
    if let requestTimeoutMs { try c.encode(requestTimeoutMs, forKey: .requestTimeoutMs) }
    if !capabilities.isEmpty {
      try c.encode(capabilities.sorted(by: { $0.rawValue < $1.rawValue }), forKey: .capabilities)
    }
    if !help.topics.isEmpty {
      try c.encode(help, forKey: .help)
    }
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
    try rejectUnknownTopLevelKeys(in: data)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()
    return manifest
  }

  private static func rejectUnknownTopLevelKeys(in data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else { return }
    let allowed = Set(CodingKeys.allCases.map(\.stringValue))
    let unknown = Set(dictionary.keys).subtracting(allowed)
    if let key = unknown.sorted().first {
      throw PluginError.invalidManifest("manifest.json unknown field \(key)")
    }
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
      if value.trimmed.isEmpty {
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
      if command.command.trimmed.isEmpty {
        throw PluginError.invalidManifest("plugin command must not be empty")
      }
    }
    let statusAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
    for segment in statusSegments {
      guard segment.lowercased() == segment,
        segment.unicodeScalars.allSatisfy({ statusAllowed.contains($0) })
      else {
        throw PluginError.invalidManifest(
          "plugin status segment \(segment) must be lowercase [a-z0-9_-]")
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

/// Per-plugin host-side state for the **hint** path (`f`) and status bar.
/// Candidates are NOT here: flashlight rows are pulled live from warm plugins
/// via `candidateQuery`, never cached on the host (see `PluginFlashSource`).
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
  /// Plugin opt-in: when true the host drops the `target.action` RPC
  /// path (which returns optimistically) and synthesizes a real mouse
  /// click instead. Used by the tmux plugin's pane targets so a fast
  /// follow-up keystroke can't race a still-in-flight `select-pane`.
  var preferHostClick: Bool
  /// Source-declared target salience. `.critical` renders with the accent hint
  /// style.
  var priority: FlashPriority
}

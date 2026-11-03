import AppKit

public enum FlashSourceReadinessPolicy: Sendable {
  /// Safe to keep prepared from AX/workspace invalidation while the app
  /// is focused.
  case continuous
  /// Run only when the user activates Flash.
  case activationOnly
  /// Results depend on external state Flash cannot observe reliably.
  case volatile
}

public enum FlashSourceActivationPolicy: Equatable, Sendable {
  /// Source is always available. Used by the generic AX and application
  /// sources.
  case always
  /// Source is enabled when at least one matching bundle id is running.
  case bundleIDs(Set<String>)
  /// Source is enabled when at least one known terminal app is running.
  case terminalBundles
}

public struct FlashSourceCapabilities: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let jumpTargets = FlashSourceCapabilities(rawValue: 1 << 0)
  public static let candidates = FlashSourceCapabilities(rawValue: 1 << 1)
  public static let documentURL = FlashSourceCapabilities(rawValue: 1 << 2)
  public static let appActivation = FlashSourceCapabilities(rawValue: 1 << 3)
  /// Source can restore movement-history entries addressed by URL-like
  /// schemes it registered, e.g. `tmux://window/<target>`.
  public static let navigationRoutes = FlashSourceCapabilities(rawValue: 1 << 4)

  /// Human-readable list of the flags this set carries, for trace logs.
  /// Order is stable so log lines diff cleanly between runs.
  public var traceDescription: String {
    var names: [String] = []
    if contains(.jumpTargets) { names.append("jumpTargets") }
    if contains(.candidates) { names.append("candidates") }
    if contains(.documentURL) { names.append("documentURL") }
    if contains(.appActivation) { names.append("appActivation") }
    if contains(.navigationRoutes) { names.append("navigationRoutes") }
    return names.isEmpty ? "none" : names.joined(separator: "|")
  }
}

public enum CandidateScope: Sendable {
  case running
  case all
}

public enum CandidateKind: Sendable, Equatable {
  case app
  /// Any non-app candidate, tagged by its source's wire-kind string
  /// (e.g. "browser_tab", "note", "tmux_window"). Both native
  /// sources and stdio plugins funnel through this single case so the
  /// runtime carries no per-integration kinds.
  case plugin(String)
}

public enum CandidateSourceKind: String, Codable, Sendable, Equatable, Hashable {
  /// Ordinary candidate source. Hidden from the default flashlight pool unless
  /// the user names the source explicitly or config gives it custom behavior.
  case standard = "default"
  /// Navigable locations surfaced in the default flashlight pool and suitable
  /// for movement-history traversal. Apps, tabs, tmux windows, and third-party
  /// plugin destinations all use this shared source kind.
  case locations
}

/// One flashlight source: its internal `name` (the label its rows carry, for
/// routing, ranking and bang bindings) and the one-word resource `type` users
/// filter by with `@<type>` (`tabs`, `history`, `emojis`). Every source of a
/// type yields rows of that type's shape; see the flash module's
/// `ResourceTypes` for the rules a type follows.
public struct CandidateSourceDescriptor: Codable, Hashable, Sendable {
  public var name: String
  /// The resource type. Empty only for a manifest that omitted it, which
  /// plugin validation rejects.
  public var type: String
  public var kind: CandidateSourceKind
  public var priority: FlashPriority

  public init(
    name: String,
    type: String,
    kind: CandidateSourceKind = .standard,
    priority: FlashPriority = .normal
  ) {
    self.name = name
    self.type = type
    self.kind = kind
    self.priority = priority
  }

  public enum CodingKeys: String, CodingKey, CaseIterable {
    case name, type, kind, priority
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try c.decode(String.self, forKey: .name)
    // Decoded leniently so validation can name the source missing it.
    self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
    self.kind = try c.decodeIfPresent(CandidateSourceKind.self, forKey: .kind) ?? .standard
    self.priority = try c.decodeIfPresent(FlashPriority.self, forKey: .priority) ?? .normal
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(type, forKey: .type)
    if kind != .standard {
      try c.encode(kind, forKey: .kind)
    }
    if priority != .normal {
      try c.encode(priority, forKey: .priority)
    }
  }
}

// @unchecked Sendable: All stored fields are value types or `URL` (Sendable).
// `Candidate` is built once on the source's queue and read from
// `CandidateFinder`'s ranking queue; consumers treat it as immutable for the
// lifetime of a flashlight query.
//
// Schema is intentionally small: a primary `title` (the highest-precedence
// ranking field), an openable `url`, a free-form `metadata` map, and an optional
// closed `effect` union validated and executed by the host only after explicit
// selection. The matcher indexes metadata at a low tier for fuzzy search.
public struct Candidate: @unchecked Sendable {
  public var title: String
  public var url: URL?
  public var metadata: [String: String]
  /// A host-owned, explicitly user-triggered effect. Plugins describe the
  /// effect; the resident validates and performs it when this row is selected.
  /// Merely evaluating or rendering a candidate never executes the effect.
  public var effect: CandidateEffect?
  // Derived ranking caches populated by `CandidateFinder.prepare`; not part of
  // the public per-candidate contract.
  public var displayTitle: String
  public var normalizedSearchText: String
  public var normalizedScoringFields: NormalizedScoringFields
  public var sortKey: String
  public var scoringMask: UInt64
  public var wordStartMask: UInt64
  /// `source` lowercased, for the precedence table's per-match lookups.
  public var loweredSource: String
  /// The frecency item key, or "" when the row has none; "" also while the
  /// row is unprepared (`sortKey` empty).
  public var frecencyKey: String
  /// The row's place in its source's own order, lowest first: the last
  /// ranking tie-break before the stable key, so a source that lists newest
  /// first (clipboard history) keeps that order among equal matches and for
  /// an empty query. `Int.max` for a source without an order of its own.
  public var sourceOrder: Int

  public init(
    title: String,
    url: URL? = nil,
    metadata: [String: String] = [:],
    effect: CandidateEffect? = nil,
    displayTitle: String = "",
    normalizedSearchText: String = "",
    normalizedScoringFields: NormalizedScoringFields = NormalizedScoringFields(),
    sortKey: String = "",
    scoringMask: UInt64 = 0,
    wordStartMask: UInt64 = 0,
    loweredSource: String = "",
    frecencyKey: String = "",
    sourceOrder: Int = .max
  ) {
    self.title = title
    self.url = url
    self.metadata = metadata
    self.effect = effect
    self.displayTitle = displayTitle
    self.normalizedSearchText = normalizedSearchText
    self.normalizedScoringFields = normalizedScoringFields
    self.sortKey = sortKey
    self.scoringMask = scoringMask
    self.wordStartMask = wordStartMask
    self.loweredSource = loweredSource
    self.frecencyKey = frecencyKey
    self.sourceOrder = sourceOrder
  }
}

public enum CandidateEffect: Sendable, Equatable {
  /// Replace the system clipboard with `text`.
  case copyText(String)
  /// Type `text` into the focused app after selection. The host performs the
  /// insertion; the plugin never posts keystrokes.
  case insertText(String)
  /// Hand a URL to LaunchServices after selection.
  case openURL(String)
  /// Launch/activate the application with this bundle identifier after
  /// selection.
  case openApplication(String)
}

public struct NormalizedScoringFields: Sendable {
  public var title: String
  /// Pre-tokenized title words, each entry already normalized. Used by
  /// source-specific fast paths that need token-level typo checks
  /// without splitting the same title on every keystroke.
  public var titleTokens: [String]
  /// Secondary searchable text such as browser URLs or source-provided
  /// subtitles. Ranked below the primary title.
  public var secondary: String
  /// Canonical source label only, e.g. `tmux.windows` or `firefox.tabs`.
  /// Ranked above secondary/url fields so a source-name query surfaces
  /// that source's rows before unrelated fuzzy hits.
  public var source: String
  public var sourceTitle: String
  public var url: String
  public var displayTitle: String
  /// Pre-tokenized alias list, each entry already normalized. Stored as
  /// an array (not a joined string) so the live ranker doesn't split it
  /// per candidate per keystroke. Scored on its own tier so a literal
  /// alias hit (`pray` → `🙏`) outranks UCD-name prefixes (`prayer
  /// beads`).
  public var aliases: [String]

  public init(
    title: String = "",
    titleTokens: [String] = [],
    secondary: String = "",
    source: String = "",
    sourceTitle: String = "",
    url: String = "",
    displayTitle: String = "",
    aliases: [String] = []
  ) {
    self.title = title
    self.titleTokens = titleTokens
    self.secondary = secondary
    self.source = source
    self.sourceTitle = sourceTitle
    self.url = url
    self.displayTitle = displayTitle
    self.aliases = aliases
  }
}

public struct FlashSourceEnvironment {
  public let runningApplications: [NSRunningApplication]

  public init(runningApplications: [NSRunningApplication]) {
    self.runningApplications = runningApplications
  }
}

public struct CandidateResolution: Sendable {
  public let targetPID: pid_t?
  public let didResolve: Bool
  public let navigationURL: URL?

  public init(targetPID: pid_t?, didResolve: Bool, navigationURL: URL? = nil) {
    self.targetPID = targetPID
    self.didResolve = didResolve
    self.navigationURL = navigationURL
  }

  public static let unresolved = CandidateResolution(targetPID: nil, didResolve: false)
  public static func resolved(pid: pid_t?, navigationURL: URL? = nil) -> CandidateResolution {
    CandidateResolution(targetPID: pid, didResolve: true, navigationURL: navigationURL)
  }
}

/// A command Flash asks the focused app to perform, dispatched through
/// ``FlashSource`` to the sources that declare it and otherwise to the app's
/// plugin-declared binding. The words are exactly what a mapping writes after
/// `flash <topic> <action>`: value arguments `--key=value`, bool flags
/// `--flag`, nothing else. `app reload --force` is the `app reload` command
/// with its flag in `arguments`; only its binding key keeps the flag.
public struct SourceCommand: Hashable, Sendable, CustomStringConvertible {
  public let name: CommandName
  /// The words after the two command words, as a mapping writes them:
  /// `["--index=3"]`, `["--force"]`, `[]`.
  public let arguments: [String]

  public init(name: CommandName, arguments: [String] = []) {
    self.name = name
    self.arguments = arguments
  }

  /// The value of `--<key>=<value>` among the arguments (`"--index=3"` →
  /// `"3"`), or nil.
  public func argument(_ key: String) -> String? {
    let prefix = "--\(key)="
    for word in arguments where word.hasPrefix(prefix) {
      return String(word.dropFirst(prefix.count))
    }
    return nil
  }

  /// Whether the bare flag `--<key>` is among the arguments.
  public func flag(_ key: String) -> Bool {
    arguments.contains("--\(key)")
  }

  /// The bare flags among the arguments, sorted, without their dashes.
  public var flags: [String] {
    arguments.compactMap { word in
      guard word.hasPrefix("--"), !word.contains("=") else { return nil }
      return String(word.dropFirst(2))
    }.sorted()
  }

  /// The key a manifest `bindings` entry uses for this command: the name plus
  /// its bool flags, value arguments dropped (`"tab select"`,
  /// `"app reload --force"`).
  public var bindingKey: String {
    ([name.description] + flags.map { "--\($0)" }).joined(separator: " ")
  }

  /// The command line: `tab select --index=3`.
  public var description: String {
    ([name.description] + arguments).joined(separator: " ")
  }
}

public struct SourceCommandResult: Sendable {
  public enum Disposition: Sendable {
    /// The source performed the command.
    case performed
    /// The source owns this command for the context but could not complete
    /// it (command error, plugin crash, RPC timeout). Callers must not run
    /// a generic keystroke fallback after this — if the claim was a
    /// timeout the real command may still land, and the synthesized key
    /// would double-fire (e.g. tmux `new-window` *and* ⌘N).
    case failed
    /// No source claim: the next source in the chain (or the caller's
    /// keystroke fallback) may run.
    case unhandled
  }

  public let targetPID: pid_t?
  public let disposition: Disposition
  public let navigationURL: URL?
  /// Why a claimed command failed, as the source reported it (content-free).
  public let failureReason: String?
  /// The source that performed or failed the command, set by the registry.
  public private(set) var source: String?

  public init(
    targetPID: pid_t?, disposition: Disposition, navigationURL: URL? = nil,
    failureReason: String? = nil
  ) {
    self.targetPID = targetPID
    self.disposition = disposition
    self.navigationURL = navigationURL
    self.failureReason = failureReason
  }

  /// This result, attributed to the source that produced it.
  public func attributed(to source: String) -> SourceCommandResult {
    var result = self
    result.source = source
    return result
  }

  public static let unhandled = SourceCommandResult(targetPID: nil, disposition: .unhandled)
  public static func failed(reason: String?) -> SourceCommandResult {
    SourceCommandResult(targetPID: nil, disposition: .failed, failureReason: reason)
  }
  public static func performed(pid: pid_t?, navigationURL: URL? = nil) -> SourceCommandResult {
    SourceCommandResult(targetPID: pid, disposition: .performed, navigationURL: navigationURL)
  }
}

public protocol FlashSource: AnyObject {
  var identifier: String { get }
  var displayName: String { get }
  var priority: Int { get }
  /// Contextual priority for focused-window chains. Defaults to ``priority``;
  /// sources with active-window selectors can add selector specificity here.
  func priority(in context: AppContext) -> Int
  /// Capabilities this source contributes. A source can expose hints,
  /// flashlight items, document URL resolution, app activation, or any
  /// combination of those without separate registration paths.
  var capabilities: FlashSourceCapabilities { get }
  /// The core commands this source performs in a context it owns (`tab
  /// select` for the Accessibility tab strip, a plugin's core `commands[]`
  /// entries). The registry's chain asks only the sources declaring the
  /// command. Default: none.
  var commands: Set<CommandName> { get }
  /// Cheap process-level activation gate. The registry instantiates and
  /// refreshes non-`always` sources only while this matches the current
  /// running application snapshot.
  var activationPolicy: FlashSourceActivationPolicy { get }
  /// How AppMonitor is allowed to prepare this source's jump targets.
  var readinessPolicy: FlashSourceReadinessPolicy { get }
  /// When true, this source's jump targets depend on state that isn't
  /// observable via `AXObserver` notifications, so caching them would
  /// silently serve stale hints. Activation skips prepared-model lookup
  /// and writes for any focused-app context where a volatile provider
  /// applies. Default: false.
  ///
  /// Set this on providers that read external state — e.g.,
  /// `TmuxSource` shells out to `tmux capture-pane`, whose content
  /// changes from terminal output and async tmux activity that the
  /// host terminal doesn't expose to AX at all.
  var resultsAreVolatile: Bool { get }
  /// When true, an empty discovery result means "this provider does not own
  /// the focused context" and the next lower-priority hint provider may run.
  /// Keep this false for authoritative providers where an empty result really
  /// means that `f` should stay silent.
  var fallsBackOnEmptyDiscovery: Bool { get }
  /// The flashlight sources this provider owns: each one's internal name
  /// (matched against `Candidate.source` for ranking and bang bindings), its
  /// resource type (what `@<type>` filters by), and its `kind`, the semantic
  /// category the host ranks by without hardcoding plugin ids or browsers.
  var candidateSourceDescriptors: [CandidateSourceDescriptor] { get }
  /// URL schemes this source can restore for movement history. Schemes are
  /// case-insensitive and should be short stable identifiers such as `tmux`.
  var navigationSchemes: Set<String> { get }
  func supports(_ context: AppContext) -> Bool
  /// Return a complete deterministic target set for the current UI state.
  /// Providers must not deadline-truncate results; a slow complete walk is
  /// preferable to serving a partial, activation-dependent hint set.
  func discover(in context: AppContext) throws -> [JumpTarget]
  /// Return complete, deterministic flashlight/search items for this source's
  /// current enabled environment. The command bar freezes this synchronous
  /// snapshot when `:flashlight` opens; keep it warm in memory and
  /// never rely on a visible session to fetch candidates later.
  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate]
  /// Pull this source's complete warm snapshot. The command bar may call this
  /// only while its initial candidate barrier is hidden, then reveals one
  /// frozen aggregate. It must never merge a reply into an already-displayed
  /// list. Implementations perform no I/O on this path. A source may await an
  /// already-running startup prewarm, but this call must never initiate one.
  func snapshotCandidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  )
  /// Whether this source answers per-query `liveCandidates` pulls instead of
  /// keeping a warm catalog: catalogs that cannot be kept warm, such as the
  /// frontmost app's menus or file search. Only built-in sources are live.
  /// Live sources are excluded from the default pool, the warm fan-outs, and
  /// the first-paint barrier.
  var servesLiveCandidates: Bool { get }
  /// Whether `liveCandidates` reads its `text`. A source that answers every
  /// query with the same in-memory rows returns false: the flashlight then
  /// pulls it once per scope rather than on every keystroke, so its rows stay
  /// on screen, and the ranker's caches stay warm, while the user types.
  /// Default: true.
  var liveCandidatesDependOnText: Bool { get }
  /// Fetch candidates for one explicit query against this source. Called per
  /// flashlight keystroke, only when the query is scoped to this source
  /// (`@<type>` / a bang's `source`). The source bounds its own work; the
  /// aggregator drops replies to superseded queries. Implementations
  /// complete on the main queue.
  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  )
  /// Resolve a previously returned candidate. The completion must be
  /// called on the main queue.
  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  )
  /// Resolve a user-provided target, such as `app open --name=`.
  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate?
  /// Resolve a document URL for the supplied focused context.
  func documentURL(in context: AppContext) -> String?
  /// Perform a core command (tab navigation, a scroll edge, a reorder, …)
  /// against the focused app. The registry's chain walk asks only the
  /// sources whose ``commands`` declare the command's name. A source that
  /// does not own the command in this context returns
  /// ``SourceCommandResult/unhandled`` so the next source (or the host's
  /// binding fallback) can run.
  func perform(
    _ command: SourceCommand,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  )
  /// Restore a movement-history route whose scheme this source registered.
  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  )
}

extension FlashSource {
  public var displayName: String { identifier }
  public func priority(in context: AppContext) -> Int { priority }
  public var capabilities: FlashSourceCapabilities { [.jumpTargets] }
  public var commands: Set<CommandName> { [] }
  public var activationPolicy: FlashSourceActivationPolicy { .always }
  public var readinessPolicy: FlashSourceReadinessPolicy { .activationOnly }
  public var resultsAreVolatile: Bool { readinessPolicy == .volatile }
  public var fallsBackOnEmptyDiscovery: Bool { false }
  public var candidateSourceDescriptors: [CandidateSourceDescriptor] { [] }
  public var navigationSchemes: Set<String> { [] }
  public func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    []
  }
  public func snapshotCandidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    completion(candidates(in: environment, scope: scope))
  }
  public var servesLiveCandidates: Bool { false }
  public var liveCandidatesDependOnText: Bool { true }
  public func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    DispatchQueue.main.async { completion([]) }
  }
  public func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    DispatchQueue.main.async { completion(.unresolved) }
  }
  public func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    nil
  }
  public func documentURL(in context: AppContext) -> String? { nil }
  public func perform(
    _ command: SourceCommand,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
  public func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceCommandResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
}

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
  public static let tabSelection = FlashSourceCapabilities(rawValue: 1 << 4)
  public static let tabCreation = FlashSourceCapabilities(rawValue: 1 << 5)
  public static let tabNavigation = FlashSourceCapabilities(rawValue: 1 << 6)
  public static let tabClosing = FlashSourceCapabilities(rawValue: 1 << 7)
  /// Source handles `gg`/`G` (scroll-to-top / scroll-to-bottom). Used by
  /// providers whose target app cannot be driven by a synthesized wheel
  /// edge — tmux is the canonical case: wheel-down at the bottom of a
  /// live buffer is a no-op, so `G` needs `tmux send-keys -X cancel`
  /// (exit copy mode) rather than another wheel tick.
  public static let scrollExtremes = FlashSourceCapabilities(rawValue: 1 << 8)
  /// Source handles `[m`/`]m` (move the focused-window's current tab
  /// left/right). Tmux runs `swap-window -t -1`/`+1`; browsers have no
  /// portable shortcut so they don't claim this capability.
  public static let tabReorder = FlashSourceCapabilities(rawValue: 1 << 9)
  /// Source handles `T` (reopen the most recently closed tab). Browsers
  /// claim this via their ⌘⇧T fallback; tmux returns `.unhandled` (no
  /// equivalent gesture).
  public static let tabReopen = FlashSourceCapabilities(rawValue: 1 << 10)

  /// Human-readable list of the flags this set carries, for trace logs.
  /// Order is stable so log lines diff cleanly between runs.
  public var traceDescription: String {
    var names: [String] = []
    if contains(.jumpTargets) { names.append("jumpTargets") }
    if contains(.candidates) { names.append("candidates") }
    if contains(.documentURL) { names.append("documentURL") }
    if contains(.appActivation) { names.append("appActivation") }
    if contains(.tabSelection) { names.append("tabSelection") }
    if contains(.tabCreation) { names.append("tabCreation") }
    if contains(.tabNavigation) { names.append("tabNavigation") }
    if contains(.tabClosing) { names.append("tabClosing") }
    if contains(.scrollExtremes) { names.append("scrollExtremes") }
    if contains(.tabReorder) { names.append("tabReorder") }
    if contains(.tabReopen) { names.append("tabReopen") }
    return names.isEmpty ? "none" : names.joined(separator: "|")
  }
}

extension SourceAction {
  /// Short tag used in source-action trace logs (`tab_next`, `scroll_top`, …).
  public var traceTag: String { wireName }
}

public enum SourceTabDirection: Sendable {
  case next
  case previous
}

public enum CandidateScope: Sendable {
  case running
  case all
}

public enum CandidateKind: Sendable, Equatable {
  case app
  /// Any non-app candidate, tagged by its source's wire-kind string
  /// (e.g. "browser_tab", "slack_channel", "tmux_window"). Both native
  /// sources and stdio plugins funnel through this single case so the
  /// runtime carries no per-integration kinds.
  case plugin(String)
}

// @unchecked Sendable: All stored fields are value types or `URL` (which is
// `Sendable`). `Candidate` is built once on the source's queue and read from
// CandidateFinder's ranking queue; consumers treat it as immutable for the
// lifetime of a flashlight query, so no synchronization is needed.
public struct Candidate: @unchecked Sendable {
  public var kind: CandidateKind
  /// Stable source id used for routing resolution back to the source.
  public var sourceID: String
  /// Short user-facing source name, such as "app", "tmux", or "firefox".
  public var source: String
  public var pid: pid_t?
  /// Primary searchable name. Candidate presentation and matching are built
  /// around the source/name/url contract.
  public var name: String
  public var subtitle: String
  public var bundleIdentifier: String
  /// Openable destination whenever one exists. App candidates must use an
  /// absolute file URL to the .app bundle; browser tabs and other external
  /// resources should use their canonical URL.
  public var url: URL?
  public var sourcePayload: String?
  /// Extra space-separated tokens folded into the host's search index
  /// for this candidate (e.g. emoji Slack-style shortcodes like
  /// `pray prayer thanks`). Empty when the plugin didn't attach any.
  public var searchAliases: String
  /// Source-owned hint that selecting this row from the command bar is
  /// already specific enough to perform immediately on Return. Plain
  /// candidates default to insert-first; users can still force with
  /// Command-Return.
  public var finishesCommand: Bool
  public var displayTitle: String
  public var normalizedSearchText: String
  /// Per-field normalized forms cached during preparation so the
  /// hot per-keystroke ranking path skips re-normalizing the same
  /// strings hundreds of times. Populated by
  /// `CandidateFinder.prepare`. Empty arrays read as "not yet
  /// prepared" — `score` falls back to on-the-fly normalization.
  public var normalizedScoringFields: NormalizedScoringFields
  /// Stable, lowercased tie-break key precomputed during `prepare`.
  /// `sortedMatches` compares this with a plain `<` instead of
  /// `localizedCaseInsensitiveCompare`, which is locale-aware and far
  /// too slow when an empty query leaves a large pool (e.g. ~2k emojis)
  /// fully tied on score.
  public var sortKey: String
  /// a–z0–9 presence bitmask OR'd across every field the live ranker
  /// scores (the normalized scoring fields + searchText). Populated by
  /// `CandidateFinder.prepare`. Used as a cheap, *sound* prefilter: a
  /// candidate whose mask is missing more distinct query characters
  /// than the fuzzy matcher's edit budget allows can never score, so
  /// the hot path skips the full scorer. Stays consistent with the
  /// normalized fields because both are computed together in `prepare`.
  public var scoringMask: UInt64

  public init(
    kind: CandidateKind,
    sourceID: String,
    source: String,
    pid: pid_t?,
    name: String,
    subtitle: String,
    bundleIdentifier: String,
    url: URL?,
    sourcePayload: String? = nil,
    searchAliases: String = "",
    finishesCommand: Bool = false,
    displayTitle: String = "",
    normalizedSearchText: String = "",
    normalizedScoringFields: NormalizedScoringFields = NormalizedScoringFields(),
    sortKey: String = "",
    scoringMask: UInt64 = 0
  ) {
    self.kind = kind
    self.sourceID = sourceID
    self.source = source
    self.pid = pid
    self.name = name
    self.subtitle = subtitle
    self.bundleIdentifier = bundleIdentifier
    self.url = url
    self.sourcePayload = sourcePayload
    self.searchAliases = searchAliases
    self.finishesCommand = finishesCommand
    self.displayTitle = displayTitle
    self.normalizedSearchText = normalizedSearchText
    self.normalizedScoringFields = normalizedScoringFields
    self.sortKey = sortKey
    self.scoringMask = scoringMask
  }
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
    sourceTitle: String = "",
    url: String = "",
    displayTitle: String = "",
    aliases: [String] = []
  ) {
    self.title = title
    self.titleTokens = titleTokens
    self.secondary = secondary
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

public struct CandidateQuery: Sendable {
  public let scope: CandidateScope
  public let text: String

  public init(scope: CandidateScope, text: String) {
    self.scope = scope
    self.text = text
  }
}

public struct CandidateResolution: Sendable {
  public let targetPID: pid_t?
  public let didResolve: Bool

  public init(targetPID: pid_t?, didResolve: Bool) {
    self.targetPID = targetPID
    self.didResolve = didResolve
  }

  public static let unresolved = CandidateResolution(targetPID: nil, didResolve: false)
  public static func resolved(pid: pid_t?) -> CandidateResolution {
    CandidateResolution(targetPID: pid, didResolve: true)
  }
}

/// Discrete source actions the host can dispatch through ``FlashSource``.
/// Each case carries the parameters the action needs and knows which
/// ``FlashSourceCapabilities`` flag gates participation, so a single
/// dispatch method on the SPI covers what used to be 12 parallel
/// per-action methods.
public enum SourceAction: Sendable, Equatable {
  case tabSelect(index: Int)
  case tabNext
  case tabPrev
  case tabFirst
  case tabLast
  case tabNew
  case tabClose
  case tabMovePrev
  case tabMoveNext
  case tabReopen
  case scrollTop
  case scrollBottom

  /// Capability flag a source must advertise to be considered for this action.
  public var requiredCapability: FlashSourceCapabilities {
    switch self {
    case .tabSelect: return .tabSelection
    case .tabNext, .tabPrev, .tabFirst, .tabLast: return .tabNavigation
    case .tabNew: return .tabCreation
    case .tabClose: return .tabClosing
    case .tabMovePrev, .tabMoveNext: return .tabReorder
    case .tabReopen: return .tabReopen
    case .scrollTop, .scrollBottom: return .scrollExtremes
    }
  }

  /// Wire-protocol name plugins receive in `SourceActionRequest.name`.
  public var wireName: String {
    switch self {
    case .tabSelect: return "tab_select"
    case .tabNext: return "tab_next"
    case .tabPrev: return "tab_prev"
    case .tabFirst: return "tab_first"
    case .tabLast: return "tab_last"
    case .tabNew: return "tab_new"
    case .tabClose: return "tab_close"
    case .tabMovePrev: return "tab_move_previous"
    case .tabMoveNext: return "tab_move_next"
    case .tabReopen: return "tab_reopen"
    case .scrollTop: return "scroll_top"
    case .scrollBottom: return "scroll_bottom"
    }
  }

  /// Extra wire-protocol fields the plugin needs to dispatch this action.
  /// Only ``tabSelect`` currently carries one (the 1-based tab index).
  public var wireExtras: [String: Any] {
    switch self {
    case .tabSelect(let index): return ["index": index]
    default: return [:]
    }
  }
}

public struct SourceActionResult: Sendable {
  public enum Disposition: Sendable {
    /// The source performed the action.
    case performed
    /// The source owns this action for the context but could not complete
    /// it (command error, plugin crash, RPC timeout). Callers must not run
    /// a generic keystroke fallback after this — if the claim was a
    /// timeout the real action may still land, and the synthesized key
    /// would double-fire (e.g. tmux `new-window` *and* ⌘N).
    case failed
    /// No source claim: the next source in the chain (or the caller's
    /// keystroke fallback) may run.
    case unhandled
  }

  public let targetPID: pid_t?
  public let disposition: Disposition

  public init(targetPID: pid_t?, disposition: Disposition) {
    self.targetPID = targetPID
    self.disposition = disposition
  }

  public var didPerform: Bool { disposition == .performed }

  public static let unhandled = SourceActionResult(targetPID: nil, disposition: .unhandled)
  public static let failed = SourceActionResult(targetPID: nil, disposition: .failed)
  public static func performed(pid: pid_t?) -> SourceActionResult {
    SourceActionResult(targetPID: pid, disposition: .performed)
  }
}

public protocol FlashSource: AnyObject {
  var identifier: String { get }
  var displayName: String { get }
  var priority: Int { get }
  /// Capabilities this source contributes. A source can expose hints,
  /// `:open` items, document URL resolution, app activation, or any
  /// combination of those without separate registration paths.
  var capabilities: FlashSourceCapabilities { get }
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
  /// User-facing source labels this provider owns for `@<source>` completion
  /// and source-scoped candidate queries. Labels should be canonical dotted
  /// source names such as `firefox.tabs` or `tmux.windows`; short prefixes are
  /// inferred by the host filter matcher.
  var candidateSourceLabels: [String] { get }
  func supports(_ context: AppContext) -> Bool
  /// Return a complete deterministic target set for the current UI state.
  /// Providers must not deadline-truncate results; a slow complete walk is
  /// preferable to serving a partial, activation-dependent hint set.
  func discover(in context: AppContext) throws -> [JumpTarget]
  /// Return complete, deterministic open/search items for this source's
  /// current enabled environment.
  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate]
  /// Query this source on demand for flashlight candidates. The default uses
  /// the source's synchronous snapshot on a utility queue; plugins can override
  /// to refresh or return a cached snapshot over their own RPC.
  func queryCandidates(
    in environment: FlashSourceEnvironment,
    request: CandidateQuery,
    completion: @escaping ([Candidate]) -> Void
  )
  /// Resolve a previously returned candidate. The completion must be
  /// called on the main queue.
  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  )
  /// Resolve a user-provided target, such as the `app_open name=` verb.
  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate?
  /// Resolve a document URL for the supplied focused context.
  func documentURL(in context: AppContext) -> String?
  /// Dispatch a discrete source action (tab navigation, scroll extreme,
  /// reorder, etc.) against the focused app. Sources opt in per action via
  /// their ``capabilities`` flags — the registry's chain walk skips any
  /// source whose ``FlashSourceCapabilities`` doesn't include
  /// ``SourceAction/requiredCapability``. Sources that don't own the
  /// action return ``SourceActionResult/unhandled`` so the next source
  /// (or the host keystroke fallback) can run.
  func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  )
}

extension FlashSource {
  public var displayName: String { identifier }
  public var capabilities: FlashSourceCapabilities { [.jumpTargets] }
  public var activationPolicy: FlashSourceActivationPolicy { .always }
  public var readinessPolicy: FlashSourceReadinessPolicy { .activationOnly }
  public var resultsAreVolatile: Bool { readinessPolicy == .volatile }
  public var candidateSourceLabels: [String] { [] }
  public func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    []
  }
  public func queryCandidates(
    in environment: FlashSourceEnvironment,
    request: CandidateQuery,
    completion: @escaping ([Candidate]) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let items = self.candidates(in: environment, scope: request.scope)
      DispatchQueue.main.async {
        completion(items)
      }
    }
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
  public func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    DispatchQueue.main.async { completion(.unhandled) }
  }
}

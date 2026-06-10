import FlashCore
import Foundation

struct CandidateMatch {
  var candidate: Candidate
  var score: Int
}

struct CommandLineCompletionMatch {
  var completion: NormalModeDispatcher.CommandLineCompletion
  var score: Int
}

enum CandidateFinder {
  static func displayTitle(source: String, name: String) -> String {
    "[\(source)] \(name)"
  }

  static let browserTabKind = CandidateKind.plugin("browser_tab")
  static let emojiKind = CandidateKind.plugin("emoji")
  /// Synthetic flashlight rows for registered plugin bangs (`!<token>`);
  /// selecting one dispatches the bang instead of resolving a candidate.
  static let bangKind = CandidateKind.plugin("bang")

  /// Candidates whose "open" action inserts their payload as text rather than
  /// activating an app or target. `app_open?name=` matching must skip these:
  /// otherwise an emoji whose searchable name contains the query would get
  /// typed into the focused field instead of switching apps.
  static func insertsText(_ candidate: Candidate) -> Bool {
    candidate.kind == emojiKind
  }

  static func displayTitle(_ candidate: Candidate) -> String {
    if candidate.kind == bangKind {
      return bangDisplayTitle(candidate)
    }
    guard candidate.kind == browserTabKind else {
      return displayTitle(source: candidate.source, name: candidate.name)
    }
    return browserTabDisplayTitle(candidate)
  }

  /// `[bang] !token (description)` — the description rides in `subtitle`
  /// and is purely cosmetic; the dispatchable token lives in
  /// `sourcePayload`.
  private static func bangDisplayTitle(_ candidate: Candidate) -> String {
    let description = candidate.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = description.isEmpty ? candidate.name : "\(candidate.name) (\(description))"
    return displayTitle(source: candidate.source, name: name)
  }

  /// Parse a flashlight query of the form `<...>!<token>[<...>]`. The
  /// first `!` anywhere in the (trimmed) query is the bang; the token
  /// is everything after that `!` up to the next whitespace OR the next
  /// `!`. Pre-bang text and post-token text both join the remainder so
  /// the dispatcher sees them as one query — the bang applies to the
  /// whole input regardless of where the user typed it.
  ///
  /// Returns nil when:
  ///   * the query has no `!`, OR
  ///   * the first character after the first `!` is whitespace or
  ///     another `!` (a bare `!`, `! foo`, `!!foo` — empty token).
  ///
  /// Examples:
  ///   `!cla rust` → ("cla", "rust")
  ///   `foo !bar baz` → ("bar", "foo baz")   — bang anywhere
  ///   `!cla foo bar` → ("cla", "foo bar")
  ///   `!cla!u` → ("cla", "!u")              — second `!` literal
  ///   `!cla !test query` → ("cla", "!test query")
  ///   `!cla\tfoo` → ("cla", "foo")
  ///   `!` → nil
  ///   `! foo` → nil
  ///   `!!foo` → nil
  static func parseBang(_ query: String) -> (token: String, remainder: String)? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard let bangIndex = trimmed.firstIndex(of: "!") else { return nil }
    let afterBang = trimmed.index(after: bangIndex)
    guard afterBang < trimmed.endIndex else { return nil }
    var tokenEnd = afterBang
    while tokenEnd < trimmed.endIndex {
      let ch = trimmed[tokenEnd]
      if ch.isWhitespace || ch == "!" { break }
      tokenEnd = trimmed.index(after: tokenEnd)
    }
    let token = String(trimmed[afterBang..<tokenEnd])
    guard !token.isEmpty else { return nil }
    // Stitch the remainder from the parts around the bang:
    //   pre-bang text + post-token text, each trimmed, joined by a
    //   single space. A `!` immediately after the token is preserved
    //   (so `!cla!u` keeps `!u` as literal text in the remainder).
    let preBang = String(trimmed[..<bangIndex]).trimmingCharacters(in: .whitespaces)
    let postStart: String.Index
    if tokenEnd < trimmed.endIndex, trimmed[tokenEnd].isWhitespace {
      postStart = trimmed.index(after: tokenEnd)
    } else {
      postStart = tokenEnd
    }
    let postToken = String(trimmed[postStart...]).trimmingCharacters(in: .whitespaces)
    let parts = [preBang, postToken].filter { !$0.isEmpty }
    return (token, parts.joined(separator: " "))
  }

  /// Like `parseBang`, plus a `confirmed` flag set when the user typed
  /// (or tab-completed) a whitespace right after the bang token. Once
  /// confirmed, the flashlight should stop offering candidates — the
  /// query semantically belongs to the chosen bang — and the UI should
  /// underline `!<token>` to acknowledge the lock-in.
  ///
  /// Detection works against the raw (un-trimmed) query because the
  /// trailing space is the signal we care about — `parseBang`'s trim
  /// erases it.
  static func parseBangState(_ query: String)
    -> (token: String, remainder: String, confirmed: Bool, bangRange: Range<String.Index>)?
  {
    guard let parsed = parseBang(query) else { return nil }
    guard let bangIndex = query.firstIndex(of: "!") else { return nil }
    var tokenEnd = query.index(after: bangIndex)
    while tokenEnd < query.endIndex {
      let ch = query[tokenEnd]
      if ch.isWhitespace || ch == "!" { break }
      tokenEnd = query.index(after: tokenEnd)
    }
    let confirmed = tokenEnd < query.endIndex && query[tokenEnd].isWhitespace
    return (parsed.token, parsed.remainder, confirmed, bangIndex..<tokenEnd)
  }

  static func prepare(
    _ candidates: [Candidate],
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> [Candidate] {
    candidates.map { prepare($0, normalize: normalize) }
  }

  static func prepare(
    _ candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> Candidate {
    var prepared = candidate
    let display = displayTitle(candidate)
    prepared.displayTitle = display
    let normalizedSearchText = normalize(searchText(candidate))
    prepared.normalizedSearchText = normalizedSearchText
    let normalizedTitle = normalize(candidate.name)
    let normalizedSourceTitle = normalize("\(candidate.source) \(candidate.name)")
    let normalizedURL = normalize(urlSearchText(candidate))
    let normalizedDisplay = normalize(display)
    prepared.normalizedScoringFields = NormalizedScoringFields(
      title: normalizedTitle,
      sourceTitle: normalizedSourceTitle,
      url: normalizedURL,
      displayTitle: normalizedDisplay)
    // Union of the a–z0–9 presence bits across every field `score`
    // reads. Computed here, once, so the per-keystroke prefilter is a
    // few integer ops instead of re-scanning strings.
    prepared.scoringMask =
      presenceMask(normalizedTitle)
      | presenceMask(normalizedSourceTitle)
      | presenceMask(normalizedURL)
      | presenceMask(normalizedDisplay)
      | presenceMask(normalizedSearchText)
    // Cheap, locale-free tie-break key. Mirrors the old comparator
    // chain (name → source → displayTitle → sourceID) but as one plain
    // string so `sortedMatches` avoids `localizedCaseInsensitiveCompare`
    // on every tied pair.
    prepared.sortKey = [
      normalizedTitle,
      candidate.source.lowercased(),
      display.lowercased(),
      candidate.sourceID.lowercased(),
    ].joined(separator: "\u{1f}")
    return prepared
  }

  /// a–z0–9 presence bitmask of a normalized (lowercased) string.
  /// Non-alphanumerics — spaces, `#`, any non-ASCII — set no bit, which
  /// keeps the prefilter conservative: an unmasked character can never
  /// trigger a false rejection.
  static func presenceMask(_ normalized: String) -> UInt64 {
    var mask: UInt64 = 0
    for scalar in normalized.unicodeScalars {
      let v = scalar.value
      if v >= 97, v <= 122 {  // a–z
        mask |= 1 << UInt64(v - 97)
      } else if v >= 48, v <= 57 {  // 0–9
        mask |= 1 << UInt64(v - 48 + 26)
      }
    }
    return mask
  }

  /// Per-keystroke prefilter key: the query's a–z0–9 presence mask plus
  /// the fuzzy matcher's edit budget for this query length. Computed
  /// once per query, then matched against each candidate's `scoringMask`
  /// via `passesPrefilter`.
  struct QueryPrefilter {
    var mask: UInt64
    var maxEdits: Int
  }

  static func queryPrefilter(normalizedQuery: String) -> QueryPrefilter {
    var mask: UInt64 = 0
    var compactCount = 0
    for scalar in normalizedQuery.unicodeScalars {
      let v = scalar.value
      if v == 32 { continue }  // space — the matcher strips these before counting
      compactCount += 1
      if v >= 97, v <= 122 {
        mask |= 1 << UInt64(v - 97)
      } else if v >= 48, v <= 57 {
        mask |= 1 << UInt64(v - 48 + 26)
      }
      // Other searchable scalars (e.g. `#`) still count toward the edit
      // budget — matching the matcher — but set no mask bit. Omitting
      // them only makes the prefilter more permissive, never wrongly
      // rejecting.
    }
    return QueryPrefilter(mask: mask, maxEdits: allowedTypoCount(compactCount))
  }

  /// Sound rejection test: the number of *distinct* query characters
  /// absent from the candidate is a lower bound on the edits the fuzzy
  /// matcher would need, so a candidate missing more than the budget
  /// can never score. Exact/prefix/substring/subsequence matches leave
  /// zero query characters absent, so they always pass.
  @inline(__always)
  static func passesPrefilter(_ prefilter: QueryPrefilter, candidateMask: UInt64) -> Bool {
    (prefilter.mask & ~candidateMask).nonzeroBitCount <= prefilter.maxEdits
  }

  /// Mirror of `FuzzyMatcher.allowedTypoCount` (which is private). Kept
  /// in sync so the prefilter's budget never undershoots the matcher's,
  /// which would let it reject a candidate the matcher accepts.
  private static func allowedTypoCount(_ length: Int) -> Int {
    if length <= 2 { return 0 }
    if length <= 5 { return 1 }
    return 2
  }

  static func score(
    query: String,
    candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText,
    fuzzyScore: (String, String) -> Int? = NormalModeDispatcher.fuzzyScore(
      normalizedQuery:normalizedCandidate:)
  ) -> Int? {
    let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    return score(normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)
  }

  /// Hot path used by the live ranker. The caller pre-normalizes the
  /// query once and reuses the candidate's pre-normalized scoring
  /// fields (populated in `prepare`). Saves O(fields × candidates)
  /// `normalizedSearchText` calls per keystroke; matters at ~1k
  /// candidates with notes/contacts/reminders all in the pool.
  static func score(
    normalizedQuery: String,
    candidate: Candidate,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    if normalizedQuery.isEmpty { return 0 }
    let fields = candidate.normalizedScoringFields
    var best: Int?
    if let titleScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.title, base: 10_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? titleScore, titleScore)
    }
    if let sourceTitleScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.sourceTitle, base: 8_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? sourceTitleScore, sourceTitleScore)
    }
    if let urlScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.url, base: 9_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? urlScore, urlScore)
    }
    if let displayScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.displayTitle, base: 7_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? displayScore, displayScore)
    }
    if let searchScore = fuzzyScore(normalizedQuery, candidate.normalizedSearchText) {
      best = max(best ?? searchScore, searchScore)
    }
    return best
  }

  /// Live-ranker entry point: score a prepared pool against a normalized
  /// query. Applies the cheap presence-mask prefilter before the full
  /// scorer, and fans large pools (e.g. the ~2k emoji set) out across
  /// cores. Small pools stay sequential to dodge dispatch overhead.
  /// `score` is pure, so concurrent evaluation is safe.
  static func scoreMatches(
    pool: [Candidate],
    normalizedQuery: String,
    fuzzyScore: (String, String) -> Int?
  ) -> [CandidateMatch] {
    if normalizedQuery.isEmpty {
      return pool.map { CandidateMatch(candidate: $0, score: 0) }
    }
    let prefilter = queryPrefilter(normalizedQuery: normalizedQuery)
    if pool.count >= parallelScoreThreshold {
      let scored = [CandidateMatch?](unsafeUninitializedCapacity: pool.count) {
        buffer, initializedCount in
        DispatchQueue.concurrentPerform(iterations: pool.count) { index in
          let match = scoreMatch(
            candidate: pool[index], prefilter: prefilter,
            normalizedQuery: normalizedQuery, fuzzyScore: fuzzyScore)
          buffer.baseAddress!.advanced(by: index).initialize(to: match)
        }
        initializedCount = pool.count
      }
      return scored.compactMap { $0 }
    }
    return pool.compactMap { candidate in
      scoreMatch(
        candidate: candidate, prefilter: prefilter,
        normalizedQuery: normalizedQuery, fuzzyScore: fuzzyScore)
    }
  }

  private static let parallelScoreThreshold = 600

  @inline(__always)
  private static func scoreMatch(
    candidate: Candidate,
    prefilter: QueryPrefilter,
    normalizedQuery: String,
    fuzzyScore: (String, String) -> Int?
  ) -> CandidateMatch? {
    guard passesPrefilter(prefilter, candidateMask: candidate.scoringMask) else { return nil }
    guard
      let score = score(
        normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)
    else { return nil }
    return CandidateMatch(candidate: candidate, score: score)
  }

  private static let browserSourceNames: Set<String> = [
    "firefox", "firefox-dev", "safari", "chrome", "chromium",
    "brave", "edge", "arc", "vivaldi", "opera",
  ]

  static func isAlive(_ candidate: Candidate) -> Bool {
    candidate.pid != nil
  }

  /// Whether a candidate belongs to the source the user pinned via the
  /// `:flashlight --<source>` flag. `filter` is already lowercased.
  /// Matching is lenient: exact source name, a source-name prefix
  /// (`--fire` → firefox, `--note` → notes), and a small set of group
  /// aliases (`--browser`/`--tabs`, `--apps`).
  static func candidateMatchesSourceFilter(_ candidate: Candidate, filter: String) -> Bool {
    let source = candidate.source.lowercased()
    if source == filter || source.hasPrefix(filter) { return true }
    switch filter {
    case "browser", "browsers", "tab", "tabs":
      return browserSourceNames.contains(source)
    case "apps":
      return source == "app"
    default:
      return false
    }
  }

  /// One pre-compiled attribute pattern. The wildcard parse runs once at
  /// query time so the hot per-candidate match is a single `String`
  /// equality / prefix / suffix / contains check — every attribute
  /// filter pays parsing cost exactly once regardless of pool size.
  struct CompiledAttributeFilter {
    let field: Field
    let needle: String  // lowercased
    let kind: Kind

    enum Field: Equatable {
      case source
      case kind
      case name
      case url
      case bundle
      case subtitle
      case unknown  // Field name the user typed that we don't expose; never matches.
    }

    enum Kind: Equatable {
      case any  // `*`
      case exact  // `firefox`
      case prefix  // `fire*`
      case suffix  // `*fox`
      case contains  // `*goog*`
    }

    static func parse(field: String, pattern: String) -> CompiledAttributeFilter {
      let normalizedField: Field
      switch field {
      case "source": normalizedField = .source
      case "kind": normalizedField = .kind
      case "name", "title": normalizedField = .name
      case "url": normalizedField = .url
      case "bundle", "bundle_id", "bundleidentifier", "bundleid":
        normalizedField = .bundle
      case "subtitle", "description":
        normalizedField = .subtitle
      default: normalizedField = .unknown
      }
      let raw = pattern.lowercased()
      let kind: Kind
      let needle: String
      let leading = raw.hasPrefix("*")
      let trailing = raw.hasSuffix("*")
      let stripped = String(raw.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0))
      switch (leading, trailing) {
      case (true, true) where stripped.isEmpty:
        kind = .any
        needle = ""
      case (true, true):
        kind = .contains
        needle = stripped
      case (true, false):
        kind = .suffix
        needle = stripped
      case (false, true):
        kind = .prefix
        needle = stripped
      case (false, false):
        kind = .exact
        needle = raw
      }
      return CompiledAttributeFilter(field: normalizedField, needle: needle, kind: kind)
    }

    /// Match against `candidate`. Returns `false` for `.unknown` fields
    /// so a typo (`@srouce:firefox`) yields no results rather than the
    /// full pool — explicit failure is the safer default.
    func matches(_ candidate: Candidate) -> Bool {
      guard field != .unknown else { return false }
      let value = value(of: candidate).lowercased()
      switch kind {
      case .any:
        return true
      case .exact:
        return value == needle
      case .prefix:
        return value.hasPrefix(needle)
      case .suffix:
        return value.hasSuffix(needle)
      case .contains:
        return value.contains(needle)
      }
    }

    private func value(of candidate: Candidate) -> String {
      switch field {
      case .source: return candidate.source
      case .kind: return candidateKindString(candidate.kind)
      case .name: return candidate.name
      case .url: return candidate.url?.absoluteString ?? ""
      case .bundle: return candidate.bundleIdentifier
      case .subtitle: return candidate.subtitle
      case .unknown: return ""
      }
    }
  }

  /// Stringify `CandidateKind` so attribute filters can match on it
  /// without leaking the enum case syntax.
  static func candidateKindString(_ kind: CandidateKind) -> String {
    switch kind {
    case .app: return "app"
    case .plugin(let tag): return tag
    }
  }

  /// Apply a compiled filter set: group by field, OR within each
  /// field, AND across fields. Empty input passes everything through.
  static func applyAttributeFilters(
    _ candidates: [Candidate],
    filters: [CompiledAttributeFilter]
  ) -> [Candidate] {
    guard !filters.isEmpty else { return candidates }
    var byField: [CompiledAttributeFilter.Field: [CompiledAttributeFilter]] = [:]
    for filter in filters {
      byField[filter.field, default: []].append(filter)
    }
    return candidates.filter { candidate in
      for group in byField.values {
        guard group.contains(where: { $0.matches(candidate) }) else { return false }
      }
      return true
    }
  }

  /// Decorated record so each candidate's tier / alive / key fields are
  /// computed once, not on every comparator call. With ~2k tied emojis
  /// the comparator fires ~20k times; recomputing `source.lowercased()`
  /// and the fallback display title inside it dominated the cost.
  private struct SortRecord {
    var index: Int
    var score: Int
    var tier: Int
    var alive: Bool
    var key: String
    var sourceID: String
  }

  static func sortedMatches(_ matches: [CandidateMatch]) -> [CandidateMatch] {
    let records = matches.enumerated().map { offset, match -> SortRecord in
      let key = match.candidate.sortKey.isEmpty
        ? fallbackSortKey(match.candidate) : match.candidate.sortKey
      return SortRecord(
        index: offset,
        score: match.score,
        tier: sourcePrecedenceTierIndex(for: match.candidate),
        alive: isAlive(match.candidate),
        key: key,
        sourceID: match.candidate.sourceID)
    }
    // Two-band design:
    //
    // 1. Bangs (`!<token>`) are a strict top band. A user typing a
    //    registered bang has expressed an explicit dispatch intent; we
    //    must surface it above anything else regardless of how the
    //    fuzzy match would score.
    //
    // 2. Everything else is ranked by match quality first. The earlier
    //    strict-tier sort buried exact prefix matches on app names under
    //    weak fuzzy hits on browser tabs (e.g. `:flashlight safari`
    //    surfaced unrelated Firefox pages but not Safari.app). Tier is
    //    kept only as a tiebreaker — bumps clustered scores in the
    //    intuitive direction (tmux > browser tabs > active apps > …)
    //    without overriding the matcher.
    let sorted = records.sorted { lhs, rhs in
      let lhsIsBang = lhs.tier == 0
      let rhsIsBang = rhs.tier == 0
      if lhsIsBang != rhsIsBang { return lhsIsBang }

      if lhs.score != rhs.score { return lhs.score > rhs.score }

      // Score-tied tiebreakers: source tier, alive vs dead, then the
      // stable composite key.
      if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
      if lhs.alive != rhs.alive { return lhs.alive }
      if lhs.key != rhs.key { return lhs.key < rhs.key }
      return lhs.sourceID < rhs.sourceID
    }
    return sorted.map { matches[$0.index] }
  }

  /// Mirrors `Candidate.sortKey` for candidates that skipped `prepare`.
  private static func fallbackSortKey(_ candidate: Candidate) -> String {
    let display = candidate.displayTitle.isEmpty
      ? displayTitle(candidate) : candidate.displayTitle
    return [
      candidate.name.lowercased(),
      candidate.source.lowercased(),
      display.lowercased(),
      candidate.sourceID.lowercased(),
    ].joined(separator: "\u{1f}")
  }

  /// Tier index used by `sortedMatches` as the primary ordering. Lower is
  /// higher priority. The "app" source splits into two tiers — running
  /// apps (pid set) outrank installed-but-not-running apps — so the
  /// flashlight order is: bangs (0) > tmux (1) > browser tabs (2) >
  /// active apps (3) > inactive apps (4) > the rest (5: slack, notes,
  /// reminders, …).
  static func sourcePrecedenceTierIndex(for candidate: Candidate) -> Int {
    if candidate.kind == bangKind { return 0 }
    let lowered = candidate.source.lowercased()
    if lowered == "tmux" { return 1 }
    if browserSourceNames.contains(lowered) { return 2 }
    if lowered == "app" { return candidate.pid != nil ? 3 : 4 }
    return 5
  }

  private static func browserTabDisplayTitle(_ candidate: Candidate) -> String {
    let candidateTitle = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = browserTabURLString(candidate) ?? ""
    let title: String
    if candidateTitle.isEmpty || candidateTitle == url {
      title = url.isEmpty ? candidateTitle : url
    } else if url.isEmpty {
      title = candidateTitle
    } else {
      // `·`-joined trailing metadata matches the tmux candidate
      // convention (`scratch:2 flash · claude · ~/workspace/...`) so
      // every flashlight row reads with the same rhythm.
      title = "\(candidateTitle) · \(url)"
    }
    return displayTitle(source: candidate.source, name: title)
  }

  private static func browserTabURLString(_ candidate: Candidate) -> String? {
    guard candidate.kind == browserTabKind else { return nil }
    if let url = candidate.url?.absoluteString, !url.isEmpty {
      return url
    }
    let payload = candidate.sourcePayload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return payload.isEmpty ? nil : payload
  }

  private static func searchText(_ candidate: Candidate) -> String {
    "\(candidate.source) \(candidate.name) \(urlSearchText(candidate)) \(browserTabTitleDomainAliases(candidate))"
  }

  private static func urlSearchText(_ candidate: Candidate) -> String {
    if let url = browserTabURLString(candidate), !url.isEmpty {
      return url
    }
    guard let url = candidate.url else { return "" }
    if candidate.kind == .app, url.isFileURL {
      let appName = url.deletingPathExtension().lastPathComponent
      return "\(appName) \(candidate.bundleIdentifier)"
    }
    return url.isFileURL ? url.path : url.absoluteString
  }

  private static func browserTabTitleDomainAliases(_ candidate: Candidate) -> String {
    guard
      candidate.kind == browserTabKind,
      let url = candidate.url,
      let host = url.host
    else { return "" }
    let parts = host.split(separator: ".")
    guard let suffix = parts.last, suffix.count >= 2 else { return "" }
    let separators = CharacterSet.alphanumerics.inverted
    let tokens = candidate.name
      .components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return tokens.map { "\($0).\(suffix)" }.joined(separator: " ")
  }

  private static func fieldScore(
    query: String,
    field: String,
    base: Int,
    normalize: (String) -> String,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    fieldScoreNormalized(
      query: query, normalized: normalize(field), base: base, fuzzyScore: fuzzyScore)
  }

  /// Same scoring rules as `fieldScore`, but the caller has already
  /// normalized the field. Used by the live ranking path.
  ///
  /// Match quality is the primary sort key in `sortedMatches` (with
  /// registered `!<bang>` candidates pinned above everything else). The
  /// motivating case: typing `mes` must surface the `Messages` app
  /// (full-string prefix on the app name) ahead of a browser tab that
  /// happens to contain `mes` somewhere — and typing `safari` must
  /// surface Safari.app above an unrelated Firefox tab.
  ///
  /// Tier layout:
  ///   - Equal              base + 5000
  ///   - String prefix      base + 3000  ("messages" matches `mes`)
  ///   - Word prefix        base + 1500  ("iOS Messages" matches `mes`)
  ///   - Substring          base +  800
  ///   - Fuzzy              base +  500 max
  private static func fieldScoreNormalized(
    query: String,
    normalized: String,
    base: Int,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    guard !normalized.isEmpty else { return nil }
    if normalized == query { return base + 5_000 }
    if normalized.hasPrefix(query) {
      return base + 3_000 - min(500, normalized.count - query.count)
    }
    if hasWordPrefix(normalized: normalized, query: query) {
      return base + 1_500 - min(300, normalized.count - query.count)
    }
    if let range = normalized.range(of: query) {
      let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
      return base + 800 - min(300, offset * 4) - min(120, normalized.count - query.count)
    }
    guard let fuzzy = fuzzyScore(query, normalized) else { return nil }
    return base + min(500, fuzzy)
  }

  /// True when `query` starts at the head of some word inside
  /// `normalized` — but not at offset 0 (that's the `hasPrefix` tier
  /// above). Word boundaries are the common app-name / URL
  /// punctuation: whitespace, `-`, `_`, `/`, `.`, `:`, parentheses.
  private static func hasWordPrefix(normalized: String, query: String) -> Bool {
    guard !query.isEmpty else { return false }
    var afterBoundary = false
    var idx = normalized.startIndex
    while idx < normalized.endIndex {
      if afterBoundary,
        normalized[idx...].hasPrefix(query)
      {
        return true
      }
      afterBoundary = wordBoundaryCharacters.contains(normalized[idx])
      idx = normalized.index(after: idx)
    }
    return false
  }

  private static let wordBoundaryCharacters: Set<Character> = [
    " ", "\t", "-", "_", "/", ".", ":", "(", ")", "[", "]",
  ]

  static func mergeAppCandidates(
    running: [Candidate],
    installed: [Candidate]
  ) -> [Candidate] {
    var byIdentifier: [String: Candidate] = [:]
    var byPath: [String: Candidate] = [:]

    for candidate in running {
      if !candidate.bundleIdentifier.isEmpty {
        byIdentifier[candidate.bundleIdentifier] = candidate
      } else if let path = candidate.url?.path {
        byPath[path] = candidate
      }
    }

    for candidate in installed {
      if !candidate.bundleIdentifier.isEmpty {
        if byIdentifier[candidate.bundleIdentifier]?.pid == nil {
          byIdentifier[candidate.bundleIdentifier] = candidate
        }
      } else if let path = candidate.url?.path {
        byPath[path] = candidate
      }
    }

    return (Array(byIdentifier.values) + Array(byPath.values)).sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }
}

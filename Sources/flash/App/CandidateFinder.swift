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
  /// Synthetic flashlight rows for `@<source>` source-filter completion.
  /// Selecting one rewrites the buffer with the canonical `@source `
  /// token; it never "opens" anything on its own. Mirrors the bang
  /// completion flow so `<tab>`/`<cr>`/`<cmd+cr>` stay consistent
  /// across both completion surfaces.
  static let sourceKind = CandidateKind.plugin("source")

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
    if candidate.kind == sourceKind {
      return displayTitle(source: candidate.source, name: candidate.name)
    }
    if candidate.kind == browserTabKind {
      return browserTabDisplayTitle(candidate)
    }
    if candidate.kind == .plugin("tmux_window") {
      return tmuxWindowDisplayTitle(candidate)
    }
    return displayTitle(source: candidate.source, name: candidate.name)
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

  /// Detect "in-progress `@<source>` completion": the last `@` in the
  /// query is not yet followed by whitespace, so the user is still
  /// typing the source token and wants completion suggestions. The
  /// caller swaps the candidate pool for a list of known sources. A
  /// confirmed `@source ` (trailing whitespace already present) is
  /// the normal source-filter case and falls through this check —
  /// the existing filter parser applies it to the data candidates.
  static func parseAtSourceCompletion(_ query: String)
    -> (token: String, atRange: Range<String.Index>)?
  {
    guard let atIndex = query.lastIndex(of: "@") else { return nil }
    var tokenEnd = query.index(after: atIndex)
    while tokenEnd < query.endIndex,
      !query[tokenEnd].isWhitespace, query[tokenEnd] != "@", query[tokenEnd] != "!"
    {
      tokenEnd = query.index(after: tokenEnd)
    }
    // Already confirmed (whitespace or another sigil follows) — not a
    // completion state.
    if tokenEnd < query.endIndex { return nil }
    let token = String(query[query.index(after: atIndex)..<tokenEnd])
    return (token, atIndex..<tokenEnd)
  }

  static func sourceCompletionState(query: String, emojiMode: Bool)
    -> (token: String, atRange: Range<String.Index>)?
  {
    guard !emojiMode, parseBang(query) == nil else { return nil }
    guard let completion = parseAtSourceCompletion(query) else { return nil }
    guard !completion.token.contains(":") else { return nil }
    return completion
  }

  /// Detect an in-progress `!<bang>` token, including a bare trailing
  /// `!`. `parseBang` intentionally rejects a bare bang because it
  /// cannot be dispatched; this state is only for the completion UI.
  static func bangCompletionState(query: String, emojiMode: Bool)
    -> (token: String, bangRange: Range<String.Index>)?
  {
    guard !emojiMode else { return nil }
    guard let bangIndex = query.firstIndex(of: "!") else { return nil }
    let tokenStart = query.index(after: bangIndex)
    if tokenStart == query.endIndex {
      return ("", bangIndex..<tokenStart)
    }
    guard !query[tokenStart].isWhitespace, query[tokenStart] != "!" else { return nil }
    var tokenEnd = tokenStart
    while tokenEnd < query.endIndex {
      let ch = query[tokenEnd]
      if ch.isWhitespace || ch == "!" { break }
      tokenEnd = query.index(after: tokenEnd)
    }
    guard tokenEnd == query.endIndex else { return nil }
    return (String(query[tokenStart..<tokenEnd]), bangIndex..<tokenEnd)
  }

  static func selectedBangMatchesTypedToken(query: String, selectedToken: String) -> Bool {
    guard let typed = parseBang(query) else { return false }
    return typed.token.localizedCaseInsensitiveCompare(selectedToken) == .orderedSame
  }

  /// Build a synthetic completion candidate for a `@<source>` token.
  /// Mirrors the shape of the bang completion rows so the same render
  /// path (`displayTitle`, `bangDisplayTitle`-style label) shows
  /// `[source] @firefox.tabs` in the flashlight list.
  static func sourceCompletionCandidate(_ source: String) -> Candidate {
    Candidate(
      kind: sourceKind,
      sourceID: "source:\(source)",
      source: "source",
      pid: nil,
      name: "@\(source)",
      subtitle: "",
      bundleIdentifier: "",
      url: nil,
      sourcePayload: source)
  }

  /// Expand a `[flashlight.aliases]` shorthand in the command-line
  /// buffer. Aliases match a full space-delimited word literally —
  /// the key carries any leading sigil the user wants (`!g`, `@ft`,
  /// even bare words). When the character at `cursorIndex - 1` is
  /// whitespace and the immediately-preceding word equals a
  /// registered alias key, the buffer is rewritten in place and the
  /// cursor is shifted by the length delta. Returns `nil` when no
  /// expansion fires.
  static func expandFlashlightAlias(
    text: String,
    cursorIndex: Int,
    aliases: [String: String]
  ) -> (text: String, cursorIndex: Int)? {
    guard !aliases.isEmpty, cursorIndex > 0 else { return nil }
    let chars = Array(text)
    guard cursorIndex <= chars.count else { return nil }
    guard chars[cursorIndex - 1].isWhitespace else { return nil }
    // Walk back to the previous word boundary. wordStart..<wordEnd
    // is the word immediately preceding the just-typed whitespace.
    var wordStart = cursorIndex - 1
    while wordStart > 0, !chars[wordStart - 1].isWhitespace {
      wordStart -= 1
    }
    let wordEnd = cursorIndex - 1
    guard wordStart < wordEnd else { return nil }
    let word = String(chars[wordStart..<wordEnd])
    guard let expansion = aliases[word], !expansion.isEmpty else { return nil }
    // No-op when the alias already resolves to itself (lets users
    // re-type a canonical token without it being rewritten again).
    if expansion == word { return nil }
    let prefix = String(chars[..<wordStart])
    let suffix = String(chars[wordEnd...])  // whitespace + everything after
    let newText = prefix + expansion + suffix
    let delta = expansion.count - word.count
    return (newText, cursorIndex + delta)
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
    let titleTokens: [String] =
      normalizedTitle.isEmpty
      ? []
      : normalizedTitle.split(separator: " ").map(String.init)
    let normalizedSourceTitle = normalize("\(candidate.source) \(candidate.name)")
    let normalizedURL = normalize(urlSearchText(candidate))
    let normalizedSecondary = normalize(secondarySearchText(candidate))
    let normalizedDisplay = normalize(display)
    let normalizedAliases = normalize(candidate.searchAliases)
    let aliasTokens: [String] =
      normalizedAliases.isEmpty
      ? []
      : normalizedAliases.split(separator: " ").map(String.init)
    prepared.normalizedScoringFields = NormalizedScoringFields(
      title: normalizedTitle,
      titleTokens: titleTokens,
      secondary: normalizedSecondary,
      sourceTitle: normalizedSourceTitle,
      url: normalizedURL,
      displayTitle: normalizedDisplay,
      aliases: aliasTokens)
    // Union of the a–z0–9 presence bits across every field `score`
    // reads. Computed here, once, so the per-keystroke prefilter is a
    // few integer ops instead of re-scanning strings.
    prepared.scoringMask =
      presenceMask(normalizedTitle)
      | presenceMask(normalizedSourceTitle)
      | presenceMask(normalizedURL)
      | presenceMask(normalizedSecondary)
      | presenceMask(normalizedDisplay)
      | presenceMask(normalizedAliases)
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
    // Aliases score on a dedicated tier above the title so a literal
    // shortcode hit (`pray` → `🙏`) outranks UCD-name prefixes like
    // `prayer beads`. The match is per token (aliases are pre-tokenized
    // at prepare time) so an exact token equality earns the full `equal`
    // bonus instead of the `prefix` tier that joining would otherwise
    // force.
    var aliasBest: Int?
    for token in fields.aliases {
      if let tokenScore = fieldScoreNormalized(
        query: normalizedQuery, normalized: token, base: 11_000, fuzzyScore: fuzzyScore)
      {
        aliasBest = max(aliasBest ?? tokenScore, tokenScore)
      }
    }
    if let aliasBest {
      best = max(best ?? aliasBest, aliasBest)
    }
    if let sourceTitleScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.sourceTitle, base: 3_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? sourceTitleScore, sourceTitleScore)
    }
    if let secondaryScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.secondary, base: 4_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? secondaryScore, secondaryScore)
    }
    if let urlScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.url, base: 4_000, fuzzyScore: fuzzyScore)
    {
      best = max(best ?? urlScore, urlScore)
    }
    if let displayScore = fieldScoreNormalized(
      query: normalizedQuery, normalized: fields.displayTitle, base: 2_000, fuzzyScore: fuzzyScore)
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
    fuzzyScore: (String, String) -> Int?,
    allowParallel: Bool = true
  ) -> [CandidateMatch] {
    if normalizedQuery.isEmpty {
      return pool.map { CandidateMatch(candidate: $0, score: 0) }
    }
    let prefilter = queryPrefilter(normalizedQuery: normalizedQuery)
    if allowParallel, pool.count >= parallelScoreThreshold {
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

  /// Emoji-mode fast path. The emoji pool is static, small enough for a
  /// linear scan, and semantically searches only the Unicode name plus
  /// shortcode aliases. Avoid the generic multi-field fuzzy scorer
  /// (source/title/url/display/searchText) so each keystroke can render
  /// the visible list in the same main-thread turn.
  static func emojiMatches(
    pool: [Candidate],
    normalizedQuery: String,
    limit: Int
  ) -> [CandidateMatch] {
    guard limit > 0 else { return [] }
    if normalizedQuery.isEmpty {
      return sortedMatches(
        pool.map { CandidateMatch(candidate: $0, score: 0) },
        limit: limit)
    }
    let prefilter = queryPrefilter(normalizedQuery: normalizedQuery)
    var matches: [CandidateMatch] = []
    matches.reserveCapacity(min(pool.count, limit * 2))
    for candidate in pool {
      guard passesPrefilter(prefilter, candidateMask: candidate.scoringMask) else { continue }
      guard let score = emojiScore(normalizedQuery: normalizedQuery, candidate: candidate) else {
        continue
      }
      matches.append(CandidateMatch(candidate: candidate, score: score))
    }
    return sortedMatches(matches, limit: limit)
  }

  private static func emojiScore(normalizedQuery: String, candidate: Candidate) -> Int? {
    let fields = candidate.normalizedScoringFields
    var best: Int?

    for alias in fields.aliases {
      if let score = emojiFieldScore(query: normalizedQuery, normalized: alias, base: 20_000) {
        best = max(best ?? score, score)
      }
    }

    if let titleScore = emojiFieldScore(
      query: normalizedQuery, normalized: fields.title, base: 10_000)
    {
      best = max(best ?? titleScore, titleScore)
    }

    // The token edit-distance pass is only a fallback. For ordinary
    // typing (`f`, `fi`, `fire`) the exact/prefix/word-prefix ladder
    // above already found a good score, and running typo checks across
    // every emoji title token is visible in the UI.
    guard best == nil else { return best }

    let compactQuery = normalizedQuery.filter { !$0.isWhitespace }
    if compactQuery.count >= 3 {
      for alias in fields.aliases {
        if let score = emojiTypoScore(query: compactQuery, token: alias, base: 20_000) {
          best = max(best ?? score, score)
        }
      }
      for token in fields.titleTokens {
        if let score = emojiTypoScore(query: compactQuery, token: token, base: 10_000) {
          best = max(best ?? score, score)
        }
      }
    }

    return best
  }

  /// Same exact/prefix/word-prefix/substring ladder as the generic
  /// field scorer, minus expensive generic fuzzy fallback.
  private static func emojiFieldScore(query: String, normalized: String, base: Int) -> Int? {
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
    return nil
  }

  private static func emojiTypoScore(query: String, token: String, base: Int) -> Int? {
    guard !query.isEmpty, !token.isEmpty else { return nil }
    let maxEdits = allowedTypoCount(query.count)
    guard maxEdits > 0, query.count <= token.count + maxEdits else { return nil }
    let prefixLength = min(token.count, query.count + maxEdits)
    let prefix = String(token.prefix(prefixLength))
    guard let distance = boundedASCIIDistance(query, prefix, maxDistance: maxEdits) else {
      return nil
    }
    return base + 450 - distance * 24 - abs(prefix.count - query.count) * 3
      - max(0, token.count - query.count) / 4
  }

  private static func boundedASCIIDistance(
    _ lhs: String,
    _ rhs: String,
    maxDistance: Int
  ) -> Int? {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    if abs(a.count - b.count) > maxDistance { return nil }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      var rowMin = current[0]
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        let insertion = current[j - 1] + 1
        let deletion = previous[j] + 1
        current[j] = min(substitution, insertion, deletion)
        rowMin = min(rowMin, current[j])
      }
      if rowMin > maxDistance { return nil }
      swap(&previous, &current)
    }
    return previous[b.count] <= maxDistance ? previous[b.count] : nil
  }

  /// Browser-tab plugin namespaces under the new `<plugin>.<subsource>`
  /// convention. The group filter (`--tabs`) folds across all of
  /// these regardless of which subsource the tab came from.
  private static let browserSourcePrefixes: [String] = [
    "firefox", "safari", "chrome", "chromium",
    "brave", "edge", "arc", "vivaldi", "opera",
  ]

  static func isAlive(_ candidate: Candidate) -> Bool {
    candidate.pid != nil
  }

  /// Whether a candidate belongs to the source the user pinned via
  /// `@<filter>` / `--<filter>`. The filter is already lowercased.
  /// Matching rules, in priority order:
  ///   1. Exact match against `candidate.source`.
  ///   2. Dotted-prefix match — `@firefox` matches `firefox.tabs`,
  ///      `firefox.bookmarks`, … but not an unrelated `firefoxx`
  ///      that happens to start with `firefox`. The check requires
  ///      either an exact equality or a `.` right after the filter.
  ///   3. Group aliases: `tabs`/`browsers` fold the browser plugin
  ///      namespaces; `apps` folds the core app source.
  static func candidateMatchesSourceFilter(_ candidate: Candidate, filter: String) -> Bool {
    let source = candidate.source.lowercased()
    if source == filter { return true }
    if source.hasPrefix(filter + ".") { return true }
    switch filter {
    case "browser", "browsers", "tab", "tabs":
      for prefix in browserSourcePrefixes {
        if source == prefix || source.hasPrefix(prefix + ".") { return true }
      }
      return false
    case "apps":
      return source == "core.apps"
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
    /// Precedence weight from `PrecedenceTable`. Higher is better.
    /// Bangs carry the sentinel `bangWeight` so the comparator can
    /// fast-path the strict top band without a separate flag.
    var weight: Int
    var alive: Bool
    var key: String
    var sourceID: String
  }

  static func sortedMatches(
    _ matches: [CandidateMatch],
    precedence: PrecedenceTable = .default,
    limit: Int? = nil
  ) -> [CandidateMatch] {
    if let limit, limit <= 0 { return [] }
    let records = matches.enumerated().map { offset, match -> SortRecord in
      let key = match.candidate.sortKey.isEmpty
        ? fallbackSortKey(match.candidate) : match.candidate.sortKey
      return SortRecord(
        index: offset,
        score: match.score,
        weight: precedence.weight(for: match.candidate),
        alive: isAlive(match.candidate),
        key: key,
        sourceID: match.candidate.sourceID)
    }
    let sorted: [SortRecord]
    if let limit, records.count > limit {
      sorted = topRecords(records, limit: limit)
    } else {
      sorted = records.sorted(by: recordPrecedes)
    }
    return sorted.map { matches[$0.index] }
  }

  private static func topRecords(_ records: [SortRecord], limit: Int) -> [SortRecord] {
    var best: [SortRecord] = []
    best.reserveCapacity(limit)
    for record in records {
      if best.count < limit {
        insertRecord(record, into: &best)
      } else if let worst = best.last, recordPrecedes(record, worst) {
        insertRecord(record, into: &best)
        best.removeLast()
      }
    }
    return best
  }

  private static func insertRecord(_ record: SortRecord, into records: inout [SortRecord]) {
    var index = records.count
    while index > 0, recordPrecedes(record, records[index - 1]) {
      index -= 1
    }
    records.insert(record, at: index)
  }

  private static func recordPrecedes(_ lhs: SortRecord, _ rhs: SortRecord) -> Bool {
    // Two-band design:
    //
    // 1. Bangs (`!<token>`) are a strict top band — they carry the
    //    sentinel `bangWeight` so they're easy to detect. A user
    //    typing a registered bang has expressed an explicit dispatch
    //    intent; we surface it above anything else regardless of
    //    how the fuzzy match would score.
    //
    // 2. Everything else is ranked by match quality first. The
    //    precedence weight is the tiebreaker once scores cluster —
    //    enough to bump the order in the intuitive direction (tmux
    //    > browser tabs > active apps > …) without overriding the
    //    matcher. Configured via `[flashlight.precedence]` so users
    //    can re-weight the table without touching the code.
    let lhsIsBang = lhs.weight == PrecedenceTable.bangWeight
    let rhsIsBang = rhs.weight == PrecedenceTable.bangWeight
    if lhsIsBang != rhsIsBang { return lhsIsBang }

    if lhs.score != rhs.score { return lhs.score > rhs.score }

    // Score-tied tiebreakers: precedence weight (higher first),
    // alive vs dead, then the stable composite key.
    if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
    if lhs.alive != rhs.alive { return lhs.alive }
    if lhs.key != rhs.key { return lhs.key < rhs.key }
    return lhs.sourceID < rhs.sourceID
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

  /// Source-precedence weight table built from
  /// `Config.Flashlight.precedence`. Lookup is a single linear scan
  /// over the entries (sorted longest-pattern first so the most
  /// specific match wins). Used by `sortedMatches` as the tiebreaker
  /// when match scores cluster. Higher weight = ranks earlier.
  struct PrecedenceTable: Sendable {
    private let entries: [(pattern: String, weight: Int)]
    public let aliveBonus: Int

    public init(weights: [String: Int], aliveBonus: Int) {
      self.entries = weights
        .map { ($0.key.lowercased(), $0.value) }
        .sorted { lhs, rhs in
          if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
          return lhs.0 < rhs.0  // deterministic tie-break for equal-length patterns
        }
      self.aliveBonus = aliveBonus
    }

    /// Compute the total precedence weight for a candidate. Bangs
    /// short-circuit to a sentinel max so they always lead the
    /// list; everything else is `base + (alive ? bonus : 0)`.
    public func weight(for candidate: Candidate) -> Int {
      if candidate.kind == bangKind { return Self.bangWeight }
      let lowered = candidate.source.lowercased()
      var base = 0
      for entry in entries {
        if lowered == entry.pattern || lowered.hasPrefix(entry.pattern + ".") {
          base = entry.weight
          break
        }
      }
      let bonus = candidate.pid != nil ? aliveBonus : 0
      return base + bonus
    }

    /// Sentinel ceiling reserved for bang rows so the comparator
    /// can detect them without a separate boolean. Far above any
    /// reasonable user-configured weight.
    public static let bangWeight = Int.max

    /// Hard-coded fallback used by tests and any code path that
    /// scores candidates without going through the live config.
    public static let `default` = PrecedenceTable(
      weights: Self.defaultWeights,
      aliveBonus: 10)

    public static let defaultWeights: [String: Int] = [
      "tmux": 100,
      "firefox": 80,
      "safari": 80,
      "chrome": 80,
      "chromium": 80,
      "brave": 80,
      "edge": 80,
      "arc": 80,
      "vivaldi": 80,
      "opera": 80,
      "core.apps": 40,
    ]
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

  private static func tmuxWindowDisplayTitle(_ candidate: Candidate) -> String {
    let title = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = candidate.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let display: String
    if title.isEmpty {
      display = secondary
    } else if secondary.isEmpty {
      display = title
    } else {
      display = "\(title) · \(secondary)"
    }
    return displayTitle(source: candidate.source, name: display)
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
    "\(candidate.source) \(candidate.name) \(secondarySearchText(candidate)) \(candidate.searchAliases)"
  }

  private static func secondarySearchText(_ candidate: Candidate) -> String {
    if candidate.kind == browserTabKind {
      return "\(urlSearchText(candidate)) \(browserTabTitleDomainAliases(candidate))"
    }
    return "\(candidate.subtitle) \(urlSearchText(candidate))"
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

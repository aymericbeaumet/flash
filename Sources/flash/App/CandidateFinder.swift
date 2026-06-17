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
  /// token; it never "opens" anything on its own.
  static let sourceKind = CandidateKind.plugin("source")

  /// Candidates whose "open" action inserts their payload as text rather than
  /// activating an app or target. `app_open?name=` matching must skip these:
  /// otherwise an emoji whose searchable name contains the query would get
  /// typed into the focused field instead of switching apps.
  static func insertsText(_ candidate: Candidate) -> Bool {
    candidate.kind == emojiKind
  }

  static func commandInsertionText(_ candidate: Candidate) -> String {
    if candidate.kind == bangKind, let token = candidate.sourcePayload, !token.isEmpty {
      return "!\(token) "
    }
    if candidate.kind == sourceKind, let source = candidate.sourcePayload, !source.isEmpty {
      return "@\(source) "
    }
    if candidate.kind == emojiKind, let glyph = candidate.sourcePayload, !glyph.isEmpty {
      return glyph
    }
    let name = candidate.title.trimmed
    let source =
      candidate.kind == .app
      ? "apps"
      : candidate.source.trimmed
    if !source.isEmpty, !name.isEmpty {
      return "@\(source) \(name) "
    }
    if !name.isEmpty {
      return "\(name) "
    }
    return candidate.displayTitle.trimmed
  }

  static func selectionFinishes(
    _ candidate: Candidate,
    query: String,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> Bool {
    if candidate.kind == sourceKind { return false }
    if isFinalDestination(candidate) { return true }
    if candidate.finishesCommand || insertsText(candidate) { return true }
    let parsed = NormalModeDispatcher.candidateFinderSourceFilter(query)
    let normalizedQuery = normalize(parsed.text.trimmed)
    guard !normalizedQuery.isEmpty else { return false }
    return normalizedQuery == normalize(candidate.title)
  }

  static func selectionSubmits(
    _ candidate: Candidate,
    query: String,
    submit: Bool,
    allowFinisher: Bool = true,
    submitFinalDestinations: Bool = false
  ) -> Bool {
    submit
      || (submitFinalDestinations && isFinalDestination(candidate))
      || (allowFinisher && selectionFinishes(candidate, query: query))
  }

  static func isFinalDestination(_ candidate: Candidate) -> Bool {
    switch candidate.kind {
    case .app:
      return true
    case .plugin(let kind):
      return kind == "browser_tab" || kind == "tmux_window"
    }
  }

  static func defaultFlashlightSourceRank(_ candidate: Candidate) -> Int? {
    PrecedenceTable.default.defaultFlashlightSourceRank(for: candidate)
  }

  static func isDefaultFlashlightCandidate(
    _ candidate: Candidate,
    precedence: PrecedenceTable = .default
  ) -> Bool {
    precedence.defaultFlashlightSourceRank(for: candidate) != nil
  }

  static func displayTitle(_ candidate: Candidate) -> String {
    if candidate.kind == bangKind {
      return bangDisplayTitle(candidate)
    }
    if candidate.kind == sourceKind {
      return displayTitle(source: candidate.source, name: candidate.title)
    }
    if candidate.kind == browserTabKind {
      return browserTabDisplayTitle(candidate)
    }
    if candidate.kind == .plugin("tmux_window") {
      return tmuxWindowDisplayTitle(candidate)
    }
    return displayTitle(source: candidate.source, name: candidate.title)
  }

  /// `[bang] !token (description)` — the description rides in `subtitle`
  /// and is purely cosmetic; the dispatchable token lives in
  /// `sourcePayload`.
  private static func bangDisplayTitle(_ candidate: Candidate) -> String {
    let description = candidate.subtitle.trimmed
    let name = description.isEmpty ? candidate.title : "\(candidate.title) (\(description))"
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

  static func sourceCompletionState(query: String)
    -> (token: String, atRange: Range<String.Index>)?
  {
    guard parseBang(query) == nil else { return nil }
    guard let completion = parseAtSourceCompletion(query) else { return nil }
    guard !completion.token.contains(":") else { return nil }
    return completion
  }

  /// Detect an in-progress `!<bang>` token, including a bare trailing
  /// `!`. `parseBang` intentionally rejects a bare bang because it
  /// cannot be dispatched; this state is only for the completion UI.
  static func bangCompletionState(query: String)
    -> (token: String, bangRange: Range<String.Index>)?
  {
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

  /// Decide whether `candidate.source` satisfies a `@<source>` narrow. Exact
  /// match wins; otherwise the typed token is treated as a prefix on dotted
  /// source labels (`firefox` matches `firefox.tabs`), so a user can narrow
  /// by short name without having to type the full canonical label.
  static func candidateMatchesSourceFilter(_ candidate: Candidate, filter: String) -> Bool {
    let needle = filter.lowercased()
    guard !needle.isEmpty else { return true }
    let source = candidate.source.lowercased()
    if source == needle { return true }
    if source.hasPrefix(needle + ".") { return true }
    if candidate.kind == .app, needle == "apps" { return true }
    return false
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
      title: "@\(source)",
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
    let normalizedTitle = normalize(candidate.title)
    let titleTokens: [String] =
      normalizedTitle.isEmpty
      ? []
      : normalizedTitle.split(separator: " ").map(String.init)
    let normalizedSource = normalize(candidate.source)
    let normalizedSourceTitle = normalize("\(candidate.source) \(candidate.title)")
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
      source: normalizedSource,
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
      | presenceMask(normalizedSource)
      | presenceMask(normalizedURL)
      | presenceMask(normalizedSecondary)
      | presenceMask(normalizedDisplay)
      | presenceMask(normalizedAliases)
      | presenceMask(normalizedSearchText)
    // Algolia-style typeahead gate: bits for the first character of
    // every token across the user-searchable fields. A short query
    // (1–2 chars) whose first character is missing here can never
    // produce a useful early-typing match, so `scoreMatch` skips the
    // candidate without paying for the full fuzzy ladder. Long queries
    // bypass the gate so substring-only hits (`fox` → `Firefox`) still
    // land.
    var wordStarts: UInt64 = 0
    for token in titleTokens { wordStarts |= firstCharBit(token) }
    for token in aliasTokens { wordStarts |= firstCharBit(token) }
    wordStarts |= firstCharBit(normalizedSource)
    wordStarts |= firstCharBit(normalizedSourceTitle)
    wordStarts |= firstCharBit(normalizedSecondary)
    wordStarts |= firstCharBit(normalizedDisplay)
    // Multi-word secondary/display strings deserve their interior word
    // starts too — the source title is "core.apps", but matching on
    // "apps" should still gate-pass.
    for token in normalizedSourceTitle.split(separator: " ") {
      wordStarts |= firstCharBit(String(token))
    }
    for token in normalizedSource.split(separator: " ") {
      wordStarts |= firstCharBit(String(token))
    }
    for token in normalizedSecondary.split(separator: " ") {
      wordStarts |= firstCharBit(String(token))
    }
    for token in normalizedDisplay.split(separator: " ") {
      wordStarts |= firstCharBit(String(token))
    }
    prepared.wordStartMask = wordStarts
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

  /// Single-character a–z0–9 bit. Returns 0 for the empty string or any
  /// leading non-alphanumeric (the `wordStartMask` gate then conservatively
  /// passes the candidate — no false rejection).
  static func firstCharBit(_ normalized: String) -> UInt64 {
    guard let scalar = normalized.unicodeScalars.first else { return 0 }
    let v = scalar.value
    if v >= 97, v <= 122 { return 1 << UInt64(v - 97) }
    if v >= 48, v <= 57 { return 1 << UInt64(v - 48 + 26) }
    return 0
  }

  /// Per-keystroke prefilter key: the query's a–z0–9 presence mask plus
  /// the fuzzy matcher's edit budget for this query length. Computed
  /// once per query, then matched against each candidate's `scoringMask`
  /// via `passesPrefilter`.
  struct QueryPrefilter {
    var mask: UInt64
    var maxEdits: Int
  }

  /// Short-query typeahead gate. Returns true when the candidate
  /// passes the word-start bitmap check — used by `scoreMatch` to skip
  /// the full fuzzy ladder on early keystrokes when the candidate
  /// can't possibly be a useful match. The gate engages only for
  /// 1–2 character queries; from 3 chars on, the existing fuzzy
  /// ladder runs unconditionally so substring-only hits (`fox` →
  /// `Firefox`) still surface.
  static func passesWordStartGate(
    normalizedQuery: String,
    wordStartMask: UInt64
  ) -> Bool {
    guard normalizedQuery.count <= 2 else { return true }
    let bit = firstCharBit(normalizedQuery)
    if bit == 0 { return true }  // Non-alphanumeric leader: don't gate.
    return wordStartMask & bit != 0
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
    let normalizedQuery = normalize(query.trimmed)
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
    // Algolia-style typeahead gate (1–2 char queries only). When the
    // user has barely started typing, prune candidates that don't have
    // a word starting with the query's first character — they can't
    // produce a useful match at this length. Long queries fall through
    // so substring-only hits (`fox` → `Firefox`) still surface.
    guard
      passesWordStartGate(
        normalizedQuery: normalizedQuery, wordStartMask: candidate.wordStartMask)
    else { return nil }
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
    if let sourceScore = sourceScoreNormalized(
      query: normalizedQuery,
      normalizedSource: fields.source,
      fuzzyScore: fuzzyScore)
    {
      best = max(best ?? sourceScore, sourceScore)
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
    // `score` applies the word-start gate, so a short query that misses
    // the candidate's word-start bitmap short-circuits inside the scorer.
    guard
      let score = score(
        normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)
    else { return nil }
    return CandidateMatch(candidate: candidate, score: score)
  }

  static func isAlive(_ candidate: Candidate) -> Bool {
    candidate.pid != nil
  }

  /// Decorated record so each candidate's tier / alive / key fields are
  /// computed once, not on every comparator call. With ~2k tied emojis
  /// the comparator fires ~20k times; recomputing `source.lowercased()`
  /// and the fallback display title inside it dominated the cost.
  private struct SortRecord {
    var index: Int
    var score: Int
    var defaultFlashlightSourceRank: Int?
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
      let key =
        match.candidate.sortKey.isEmpty
        ? fallbackSortKey(match.candidate) : match.candidate.sortKey
      return SortRecord(
        index: offset,
        score: match.score,
        defaultFlashlightSourceRank: precedence.defaultFlashlightSourceRank(for: match.candidate),
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

  static func displayAndIncrementalMatches(
    _ matches: [CandidateMatch],
    precedence: PrecedenceTable = .default,
    limit: Int
  ) -> (display: [CandidateMatch], incremental: [CandidateMatch]) {
    (
      display: sortedMatches(matches, precedence: precedence, limit: limit),
      incremental: matches
    )
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
    // 2. The default flashlight source families are a strict band:
    //    tmux windows/tabs > browser tabs > apps > Slack channels.
    //    Match quality is authoritative only inside the same band. Other
    //    sources are normally hidden from the default pool, but when
    //    sorted explicitly (for example through `@source`) they stay below
    //    default families unless the compared rows are all outside the band.
    //
    // 3. Everything inside the same band is ranked by match quality first.
    //    The precedence weight is the tiebreaker once scores cluster.
    let lhsIsBang = lhs.weight == PrecedenceTable.bangWeight
    let rhsIsBang = rhs.weight == PrecedenceTable.bangWeight
    if lhsIsBang != rhsIsBang { return lhsIsBang }

    switch (lhs.defaultFlashlightSourceRank, rhs.defaultFlashlightSourceRank) {
    case (let l?, let r?) where l != r:
      return l > r
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      break
    }

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
    let display =
      candidate.displayTitle.isEmpty
      ? displayTitle(candidate) : candidate.displayTitle
    return [
      candidate.title.lowercased(),
      candidate.source.lowercased(),
      display.lowercased(),
      candidate.sourceID.lowercased(),
    ].joined(separator: "\u{1f}")
  }

  /// Source-precedence weight table built from registered source descriptors
  /// plus optional config overrides. Lookup is a single linear scan over the
  /// entries (sorted longest-pattern first so the most specific match wins).
  /// Used by `sortedMatches` as the tiebreaker when match scores cluster.
  /// Higher weight = ranks earlier.
  struct PrecedenceTable: Sendable {
    private struct Entry: Sendable {
      var pattern: String
      var weight: Int
      /// Non-nil only for registry-declared sources. Override-only entries
      /// can change ranking weight, but cannot opt hidden sources into default
      /// flashlight visibility.
      var kind: CandidateSourceKind?
    }

    private let entries: [Entry]
    public let aliveBonus: Int

    public init(
      sources: [CandidateSourceDescriptor],
      overrides: [String: Int],
      aliveBonus: Int
    ) {
      var records: [String: (weight: Int, kind: CandidateSourceKind?)] = [:]
      for source in sources {
        let pattern = source.name.trimmed.lowercased()
        guard !pattern.isEmpty else { continue }
        records[pattern] = (Self.defaultWeight(for: source.kind), source.kind)
      }
      for (pattern, weight) in overrides {
        let pattern = pattern.trimmed.lowercased()
        guard !pattern.isEmpty else { continue }
        if let existing = records[pattern] {
          records[pattern] = (weight, existing.kind)
        } else {
          records[pattern] = (weight, nil)
        }
      }
      self.entries = Self.sortedEntries(records)
      self.aliveBonus = aliveBonus
    }

    /// Compute the total precedence weight for a candidate. Bangs
    /// short-circuit to a sentinel max so they always lead the
    /// list; everything else is `base + (alive ? bonus : 0)`.
    public func weight(for candidate: Candidate) -> Int {
      if candidate.kind == bangKind { return Self.bangWeight }
      let lowered = candidate.source.lowercased()
      var base: Int?
      for entry in entries {
        if lowered == entry.pattern || lowered.hasPrefix(entry.pattern + ".") {
          base = entry.weight
          break
        }
      }
      let resolvedBase = base ?? Self.defaultWeight(for: Self.fallbackSourceKind(for: candidate))
      let bonus = candidate.pid != nil ? aliveBonus : 0
      return resolvedBase + bonus
    }

    /// Strict default flashlight family rank. Live source descriptors are the
    /// primary signal; semantic candidate kinds cover offline tests and sources
    /// that have not registered descriptors.
    public func defaultFlashlightSourceRank(for candidate: Candidate) -> Int? {
      let lowered = candidate.source.lowercased()
      for entry in entries {
        guard lowered == entry.pattern || lowered.hasPrefix(entry.pattern + ".") else {
          continue
        }
        guard let kind = entry.kind else { continue }
        return Self.defaultFlashlightSourceRank(for: kind)
      }
      return Self.fallbackDefaultFlashlightSourceRank(for: candidate)
    }

    /// Sentinel ceiling reserved for bang rows so the comparator
    /// can detect them without a separate boolean. Far above any
    /// reasonable user-configured weight.
    public static let bangWeight = Int.max

    /// Fallback used by tests and any code path that scores candidates without
    /// going through the live registry. This still derives from semantic
    /// candidate kinds, not source-name tables.
    public static let `default` = PrecedenceTable(
      sources: [],
      overrides: [:],
      aliveBonus: 10)

    private static func sortedEntries(
      _ records: [String: (weight: Int, kind: CandidateSourceKind?)]
    ) -> [Entry] {
      records
        .map { Entry(pattern: $0.key, weight: $0.value.weight, kind: $0.value.kind) }
        .sorted { lhs, rhs in
          if lhs.pattern.count != rhs.pattern.count {
            return lhs.pattern.count > rhs.pattern.count
          }
          return lhs.pattern < rhs.pattern  // deterministic tie-break for equal-length patterns
        }
    }

    private static func defaultWeight(for kind: CandidateSourceKind) -> Int {
      switch kind {
      case .tmuxTabs:
        return 100
      case .browserTabs:
        return 80
      case .apps:
        return 40
      case .standard:
        return 0
      }
    }

    private static func defaultFlashlightSourceRank(for kind: CandidateSourceKind) -> Int? {
      switch kind {
      case .tmuxTabs:
        return 4
      case .browserTabs:
        return 3
      case .apps:
        return 2
      case .standard:
        return nil
      }
    }

    private static func fallbackSourceKind(for candidate: Candidate) -> CandidateSourceKind {
      switch candidate.kind {
      case .app:
        return .apps
      case .plugin(let kind):
        switch kind {
        case "tmux_window":
          return .tmuxTabs
        case "browser_tab":
          return .browserTabs
        default:
          return .standard
        }
      }
    }

    private static func fallbackDefaultFlashlightSourceRank(for candidate: Candidate) -> Int? {
      switch candidate.kind {
      case .app:
        return 2
      case .plugin(let kind):
        switch kind {
        case "tmux_window":
          return 4
        case "browser_tab":
          return 3
        case "slack_channel":
          return 1
        default:
          break
        }
      }
      let source = candidate.source.lowercased()
      if source == "slack.channels" || source.hasPrefix("slack.channels.") {
        return 1
      }
      return nil
    }
  }

  private static func browserTabDisplayTitle(_ candidate: Candidate) -> String {
    let candidateTitle = candidate.title.trimmed
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
    let title = candidate.title.trimmed
    let secondary = candidate.subtitle.trimmed
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
    let payload = candidate.sourcePayload?.trimmed ?? ""
    return payload.isEmpty ? nil : payload
  }

  private static func searchText(_ candidate: Candidate) -> String {
    "\(candidate.source) \(candidate.title) \(secondarySearchText(candidate)) \(candidate.searchAliases)"
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
    let tokens = candidate.title
      .components(separatedBy: separators)
      .map { $0.trimmed }
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

  /// Direct source-label matches are more intentional than generic title
  /// matches from unrelated sources. This is especially important for dotted
  /// source families such as `tmux.windows`: typing `tmux` should surface rows
  /// from that source even when another source has an exact title `tmux`.
  ///
  /// Plain exact source labels stay just below exact title matches so an app
  /// named `Finder` can still beat a hypothetical source literally named
  /// `finder`.
  private static func sourceScoreNormalized(
    query: String,
    normalizedSource: String,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    guard !normalizedSource.isEmpty else { return nil }
    if normalizedSource == query { return 14_900 }
    let firstComponent = normalizedSource.split(separator: " ").first.map(String.init) ?? ""
    if firstComponent == query, normalizedSource.contains(" ") {
      return 16_000 - min(300, normalizedSource.count - query.count)
    }
    return fieldScoreNormalized(
      query: query,
      normalized: normalizedSource,
      base: 8_000,
      fuzzyScore: fuzzyScore)
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
      lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }
}

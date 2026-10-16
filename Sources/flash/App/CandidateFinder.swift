import FlashCore
import Foundation

struct CandidateMatch {
  var candidate: Candidate
  var score: Int
  /// How the query hit the candidate's own name. Compared before every other
  /// signal in `CandidateFinder.sortedMatches`, so an exact tab title beats a
  /// partial app match whatever their sources weigh.
  var tier: CandidateFinder.MatchTier = .none
}

struct CommandLineCompletionMatch {
  var completion: NormalModeDispatcher.CommandLineCompletion
  var score: Int
}

enum CandidateFinder {
  /// Coarse match quality against the candidate's own name (title and
  /// aliases) or its source label. Strictly ordered ahead of source
  /// precedence and score: a row whose name is what the user typed is the
  /// deliberate hit, whichever category it belongs to.
  enum MatchTier: Int, Comparable, Sendable {
    /// Matched only through secondary text (URL, subtitle, display label) or
    /// the typo-tolerant fuzzy ladder; also the empty query.
    case none = 0
    /// The query appears inside the name, not at a word start.
    case contains
    /// The query starts a word inside the name, or every query word starts a
    /// word of the name (any order).
    case word
    /// The name, or an alias, starts with the query.
    case prefix
    /// The name or an alias equals the query, or the query names the source
    /// (`tmux` for `tmux.windows`).
    case exact

    static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  static func displayTitle(source: String, name: String) -> String {
    "[\(source)] \(name)"
  }

  static let browserTabKind = CandidateKind.plugin("browser_tab")
  static let tmuxWindowKind = CandidateKind.plugin("tmux_window")
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
    candidate.isLocation || candidate.effect != nil
  }

  static func isDefaultFlashlightCandidate(
    _ candidate: Candidate,
    precedence: PrecedenceTable = .default
  ) -> Bool {
    precedence.isDefaultFlashlightSource(candidate)
  }

  /// The half-open slice of `count` matches a display surface shows: at most
  /// `windowSize` rows, following the selection (kept centred once it scrolls
  /// past the middle) and clamped at both ends. Shared by the flashlight
  /// finder and the `:` completion list so arrow keys scroll both the same
  /// way.
  static func displayWindow(count: Int, selectedIndex: Int, windowSize: Int) -> Range<Int> {
    guard count > 0, windowSize > 0 else { return 0..<0 }
    let maxStart = max(0, count - windowSize)
    let start = min(max(0, selectedIndex - windowSize / 2), maxStart)
    let end = min(count, start + windowSize)
    return start..<end
  }

  static func displayTitle(_ candidate: Candidate) -> String {
    if candidate.effect != nil {
      return candidate.title
    }
    if candidate.kind == bangKind {
      return bangDisplayTitle(candidate)
    }
    if candidate.kind == sourceKind {
      return displayTitle(source: candidate.source, name: candidate.title)
    }
    if candidate.kind == browserTabKind {
      return browserTabDisplayTitle(candidate)
    }
    if candidate.kind == tmuxWindowKind {
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
    sourceLabel(candidate.source, matchesFilter: filter)
      || (candidate.kind == .app && filter.lowercased() == "apps")
  }

  /// Source-label form of ``candidateMatchesSourceFilter``. Snapshot routing
  /// uses manifest-declared labels before any candidate rows have crossed the
  /// plugin boundary, so it needs the exact same dotted-prefix semantics
  /// without manufacturing a throwaway `Candidate`.
  static func sourceLabel(_ label: String, matchesFilter filter: String) -> Bool {
    let needle = filter.lowercased()
    guard !needle.isEmpty else { return true }
    let source = label.lowercased()
    if source == needle { return true }
    if source.hasPrefix(needle + ".") { return true }
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

  static func prepare(_ candidates: [Candidate]) -> [Candidate] {
    guard candidates.count >= parallelPrepareThreshold else {
      return candidates.map { candidate in
        candidate.sortKey.isEmpty ? prepare(candidate) : candidate
      }
    }
    // Preparation is pure and each output slot depends on exactly one input.
    // Large immutable catalogs (installed apps, emoji) spend most of their
    // first-paint time normalizing independent strings, so preserve input order
    // while distributing that CPU work across cores.
    return [Candidate](unsafeUninitializedCapacity: candidates.count) {
      buffer, initializedCount in
      DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
        let candidate = candidates[index]
        let prepared = candidate.sortKey.isEmpty ? prepare(candidate) : candidate
        buffer.baseAddress!.advanced(by: index).initialize(to: prepared)
      }
      initializedCount = candidates.count
    }
  }

  private static let parallelPrepareThreshold = 64

  static func prepare(
    _ candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> Candidate {
    var prepared = candidate
    prepared.loweredSource = candidate.source.lowercased()
    prepared.frecencyKey = FrecencyMapper.itemKey(for: candidate) ?? ""
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

  static func tier(
    query: String,
    candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText,
    fuzzyScore: (String, String) -> Int? = NormalModeDispatcher.fuzzyScore(
      normalizedQuery:normalizedCandidate:)
  ) -> MatchTier? {
    evaluate(
      normalizedQuery: normalize(query.trimmed), candidate: candidate, fuzzyScore: fuzzyScore
    )?.tier
  }

  static func score(
    normalizedQuery: String,
    candidate: Candidate,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    evaluate(normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)?.score
  }

  /// Hot path used by the live ranker. The caller pre-normalizes the
  /// query once and reuses the candidate's pre-normalized scoring
  /// fields (populated in `prepare`). Saves O(fields × candidates)
  /// `normalizedSearchText` calls per keystroke; matters at ~1k
  /// candidates with notes/contacts/reminders all in the pool.
  ///
  /// Returns the fine-grained score plus the coarse `MatchTier` of the best
  /// name-level hit. Only the title, its aliases and the source label can
  /// raise the tier; secondary fields (URL, subtitle, display label) and the
  /// fuzzy ladder stay at `.none` however well they score.
  static func evaluate(
    normalizedQuery: String,
    candidate: Candidate,
    fuzzyScore: (String, String) -> Int?
  ) -> (score: Int, tier: MatchTier)? {
    if normalizedQuery.isEmpty { return (0, .none) }
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
    var tier = MatchTier.none
    func consider(_ match: (score: Int, tier: MatchTier)?) {
      guard let match else { return }
      best = max(best ?? match.score, match.score)
      tier = max(tier, match.tier)
    }
    consider(
      fieldMatch(
        query: normalizedQuery, normalized: fields.title, base: 10_000, fuzzyScore: fuzzyScore))
    // Aliases score on a dedicated tier above the title so a literal
    // shortcode hit (`pray` → `🙏`) outranks UCD-name prefixes like
    // `prayer beads`. The match is per token (aliases are pre-tokenized
    // at prepare time) so an exact token equality earns the full `equal`
    // bonus instead of the `prefix` tier that joining would otherwise
    // force.
    for token in fields.aliases {
      consider(
        fieldMatch(query: normalizedQuery, normalized: token, base: 11_000, fuzzyScore: fuzzyScore)
      )
    }
    // Multi-word queries name the row by its words in any order: `flash
    // github` finds `GitHub - aymericbeaumet/flash`. Every query word must
    // start a title word or alias; the match ranks as a word hit, below a
    // literal word-prefix of the whole query and above a mid-word substring.
    let queryTokens: [Substring] =
      normalizedQuery.contains(" ") ? normalizedQuery.split(separator: " ") : []
    if queryTokens.count >= 2, tier < .word,
      tokensCover(queryTokens: queryTokens, tokens: fields.titleTokens + fields.aliases)
    {
      consider(
        (
          10_000 + 1_200 - min(300, max(0, fields.title.count - normalizedQuery.count)),
          .word
        ))
    }
    consider(
      fieldMatch(
        query: normalizedQuery, normalized: fields.sourceTitle, base: 3_000,
        fuzzyScore: fuzzyScore
      ).map { ($0.score, .none) })
    consider(
      sourceMatch(query: normalizedQuery, normalizedSource: fields.source, fuzzyScore: fuzzyScore))
    consider(
      fieldMatch(
        query: normalizedQuery, normalized: fields.secondary, base: 4_000, fuzzyScore: fuzzyScore
      ).map { ($0.score, .none) })
    consider(
      fieldMatch(
        query: normalizedQuery, normalized: fields.url, base: 4_000, fuzzyScore: fuzzyScore
      ).map { ($0.score, .none) })
    consider(
      fieldMatch(
        query: normalizedQuery, normalized: fields.displayTitle, base: 2_000,
        fuzzyScore: fuzzyScore
      ).map { ($0.score, .none) })
    if queryTokens.count >= 2, best.map({ $0 < 4_000 + 1_200 }) ?? true {
      // Same any-order word cover over the whole searchable text (URL,
      // subtitle, source): `aymericbeaumet pulls` still finds the tab, just
      // not as a name hit.
      let tokens =
        fields.titleTokens + fields.aliases
        + fields.secondary.split(separator: " ").map(String.init)
        + fields.source.split(separator: " ").map(String.init)
      if tokensCover(queryTokens: queryTokens, tokens: tokens) {
        consider((4_000 + 1_200, .none))
      }
    }
    if let searchScore = fuzzyScore(normalizedQuery, candidate.normalizedSearchText) {
      consider((searchScore, .none))
    }
    guard let best else { return nil }
    return (best, tier)
  }

  /// True when every query token is a prefix of some token in `tokens`.
  /// Order-free: the user types the words they remember, not the title.
  static func tokensCover(queryTokens: [Substring], tokens: [String]) -> Bool {
    guard !queryTokens.isEmpty else { return false }
    for query in queryTokens {
      guard tokens.contains(where: { $0.hasPrefix(query) }) else { return false }
    }
    return true
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
    let parallelThreshold: Int
    if pool.first?.kind == emojiKind {
      parallelThreshold = emojiParallelScoreThreshold
    } else if normalizedQuery.count >= 3 {
      parallelThreshold = complexQueryParallelScoreThreshold
    } else {
      parallelThreshold = parallelScoreThreshold
    }
    if allowParallel, pool.count >= parallelThreshold {
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
  /// Emoji rows have aliases plus long Unicode names and therefore do more
  /// fuzzy-field work than ordinary location rows, even while the one/two-char
  /// word-start gate is active. Their explicit source pool is homogeneous, so
  /// fan out a narrowed emoji result set before it consumes a full frame.
  private static let emojiParallelScoreThreshold = 64
  /// At three characters the short-query word-start gate disengages and the
  /// typo ladder gains its first edit, making each surviving candidate much
  /// more expensive. Emoji aliases hit this boundary especially hard: after
  /// incremental narrowing, ~100–200 rows can still consume a full frame when
  /// scored serially. Fan that heavier work out sooner while keeping cheap
  /// one/two-character pools sequential.
  private static let complexQueryParallelScoreThreshold = 64

  @inline(__always)
  private static func scoreMatch(
    candidate: Candidate,
    prefilter: QueryPrefilter,
    normalizedQuery: String,
    fuzzyScore: (String, String) -> Int?
  ) -> CandidateMatch? {
    guard passesPrefilter(prefilter, candidateMask: candidate.scoringMask) else { return nil }
    // `evaluate` applies the word-start gate, so a short query that misses
    // the candidate's word-start bitmap short-circuits inside the scorer.
    guard
      let match = evaluate(
        normalizedQuery: normalizedQuery, candidate: candidate, fuzzyScore: fuzzyScore)
    else { return nil }
    return CandidateMatch(candidate: candidate, score: match.score, tier: match.tier)
  }

  static func isAlive(_ candidate: Candidate) -> Bool {
    candidate.pid != nil
  }

  /// Decorated record so each candidate's tier / band / weight fields are
  /// computed once, not on every comparator call. With ~2k tied emojis
  /// the comparator fires ~20k times; recomputing `source.lowercased()`
  /// and the fallback display title inside it dominated the cost.
  private struct SortRecord {
    var index: Int
    var score: Int
    /// How the query hit the row's own name; see `MatchTier`.
    var tier: MatchTier
    /// The row belongs to the default flashlight pool (a location source).
    /// Only matters for mixed pools: explicit `@source` sets are homogeneous.
    var inDefaultBand: Bool
    /// Precedence weight from `PrecedenceTable`: source kind + manifest
    /// `sources[].priority` + `[flashlight.precedence]` override + alive
    /// bonus. Higher is better. Bangs carry the sentinel `bangWeight` so the
    /// comparator can fast-path the strict top band without a separate flag.
    var weight: Int
    /// Source-provided same-score nudge. This is deliberately below match
    /// quality and source precedence so salient rows never outrank a better
    /// textual match.
    var priority: FlashPriority
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
        tier: match.tier,
        inDefaultBand: precedence.isDefaultFlashlightSource(match.candidate),
        weight: precedence.weight(for: match.candidate),
        priority: match.candidate.priority,
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
    // Banded design, every band strict over the next:
    //
    // 1. Bangs (`!<token>`) carry the sentinel `bangWeight`. A user typing
    //    a registered bang has expressed an explicit dispatch intent; it
    //    surfaces above anything else regardless of how the fuzzy match
    //    would score.
    //
    // 2. Match tier: how the query hit the row's own name (exact > prefix >
    //    word > contains > secondary/fuzzy). An exact tab title beats every
    //    partial app match; `mes` still puts Messages.app (prefix) above a
    //    tab that merely contains "mes".
    //
    // 3. Default-band rows (locations) lead rows from hidden sources when a
    //    pool mixes them.
    //
    // 4. Source precedence: the `PrecedenceTable` weight. Within one tier
    //    this is where bundled manifests and `[flashlight.precedence]` order
    //    tmux windows, running apps, tabs and installed apps.
    //
    // 5. Match score (fine-grained field tiers plus frecency), then the
    //    row's own `priority`, alive before dead, and the stable key.
    let lhsIsBang = lhs.weight == PrecedenceTable.bangWeight
    let rhsIsBang = rhs.weight == PrecedenceTable.bangWeight
    if lhsIsBang != rhsIsBang { return lhsIsBang }
    if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
    if lhs.inDefaultBand != rhs.inDefaultBand { return lhs.inDefaultBand }
    if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
    if lhs.score != rhs.score { return lhs.score > rhs.score }
    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
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
      /// `pattern + "."`, built once: the table is consulted per match per
      /// keystroke.
      var prefix: String
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
        records[pattern] = (
          Self.defaultWeight(for: source.kind) + source.priority.rankingWeight,
          source.kind
        )
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
      let lowered = Self.loweredSource(of: candidate)
      var base: Int?
      for entry in entries {
        if lowered == entry.pattern || lowered.hasPrefix(entry.prefix) {
          base = entry.weight
          break
        }
      }
      let resolvedBase = base ?? Self.defaultWeight(for: Self.fallbackSourceKind(for: candidate))
      let bonus = candidate.pid != nil ? aliveBonus : 0
      return resolvedBase + bonus
    }

    /// Default flashlight band membership. Live source descriptors are the
    /// primary signal; location metadata covers offline tests and sources that
    /// have not registered descriptors. Location-kind sources are in the band;
    /// standard sources are hidden until named with `@source`.
    public func isDefaultFlashlightSource(_ candidate: Candidate) -> Bool {
      let lowered = Self.loweredSource(of: candidate)
      for entry in entries {
        guard lowered == entry.pattern || lowered.hasPrefix(entry.prefix) else {
          continue
        }
        guard let kind = entry.kind else { continue }
        switch kind {
        case .locations:
          return true
        case .standard:
          return false
        }
      }
      return candidate.isLocation
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

    /// The prepared lowercase source, or the lowercasing for an unprepared row.
    private static func loweredSource(of candidate: Candidate) -> String {
      candidate.loweredSource.isEmpty ? candidate.source.lowercased() : candidate.loweredSource
    }

    private static func sortedEntries(
      _ records: [String: (weight: Int, kind: CandidateSourceKind?)]
    ) -> [Entry] {
      records
        .map {
          Entry(
            pattern: $0.key, prefix: $0.key + ".", weight: $0.value.weight, kind: $0.value.kind)
        }
        .sorted { lhs, rhs in
          if lhs.pattern.count != rhs.pattern.count {
            return lhs.pattern.count > rhs.pattern.count
          }
          return lhs.pattern < rhs.pattern  // deterministic tie-break for equal-length patterns
        }
    }

    private static func defaultWeight(for kind: CandidateSourceKind) -> Int {
      switch kind {
      case .locations:
        return 50
      case .standard:
        return 0
      }
    }

    private static func fallbackSourceKind(for candidate: Candidate) -> CandidateSourceKind {
      if candidate.isLocation { return .locations }
      switch candidate.kind {
      case .app:
        return .locations
      case .plugin:
        return .standard
      }
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
      return
        "\(urlSearchText(candidate)) \(browserTabTitleDomainAliases(candidate))"
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

  /// Score one pre-normalized field and report the coarse tier of the hit.
  /// Used by the live ranking path.
  ///
  /// The tier is the primary sort key in `sortedMatches` (with registered
  /// `!<bang>` candidates pinned above everything else) when the field is
  /// the row's own name. The motivating case: typing `mes` must surface the
  /// `Messages` app (full-string prefix on the app name) ahead of a browser
  /// tab that happens to contain `mes` somewhere — and typing a tab's exact
  /// title must surface that tab above every partial app match.
  ///
  /// Tier layout:
  ///   - Equal              base + 5000  `.exact`
  ///   - String prefix      base + 3000  `.prefix`   ("messages" matches `mes`)
  ///   - Word prefix        base + 1500  `.word`     ("iOS Messages" matches `mes`)
  ///   - Substring          base +  800  `.contains`
  ///   - Fuzzy              base +  500 max  `.none`
  private static func fieldMatch(
    query: String,
    normalized: String,
    base: Int,
    fuzzyScore: (String, String) -> Int?
  ) -> (score: Int, tier: MatchTier)? {
    guard !normalized.isEmpty else { return nil }
    if normalized == query { return (base + 5_000, .exact) }
    if normalized.hasPrefix(query) {
      return (base + 3_000 - min(500, normalized.count - query.count), .prefix)
    }
    if hasWordPrefix(normalized: normalized, query: query) {
      return (base + 1_500 - min(300, normalized.count - query.count), .word)
    }
    if let range = normalized.range(of: query) {
      let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
      return (
        base + 800 - min(300, offset * 4) - min(120, normalized.count - query.count), .contains
      )
    }
    guard let fuzzy = fuzzyScore(query, normalized) else { return nil }
    return (base + min(500, fuzzy), .none)
  }

  /// Naming a source is a deliberate hit on all of its rows: typing `tmux`
  /// ranks every `tmux.windows` row in the `.exact` tier, so the source's
  /// precedence weight orders them against other exact hits. The score stays
  /// just below an exact title so `firefox` opens Firefox.app first and lists
  /// its tabs right after, and an app named `Finder` beats a hypothetical
  /// source literally named `finder`.
  private static func sourceMatch(
    query: String,
    normalizedSource: String,
    fuzzyScore: (String, String) -> Int?
  ) -> (score: Int, tier: MatchTier)? {
    guard !normalizedSource.isEmpty else { return nil }
    if normalizedSource == query { return (14_900, .exact) }
    let firstComponent = normalizedSource.split(separator: " ").first.map(String.init) ?? ""
    if firstComponent == query, normalizedSource.contains(" ") {
      return (14_950 - min(300, normalizedSource.count - query.count), .exact)
    }
    return fieldMatch(
      query: query,
      normalized: normalizedSource,
      base: 8_000,
      fuzzyScore: fuzzyScore
    ).map { ($0.score, .none) }
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

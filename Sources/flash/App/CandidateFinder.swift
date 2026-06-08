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
  private static let aliveTieBreakScoreMargin = 500

  static func displayTitle(source: String, name: String) -> String {
    "[\(source)] \(name)"
  }

  static let browserTabKind = CandidateKind.plugin("browser_tab")
  static let emojiKind = CandidateKind.plugin("emoji")
  static let clipboardKind = CandidateKind.plugin("clipboard")

  static func displayTitle(_ candidate: Candidate) -> String {
    guard candidate.kind == browserTabKind else {
      return displayTitle(source: candidate.source, name: candidate.name)
    }
    return browserTabDisplayTitle(candidate)
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
    prepared.normalizedSearchText = normalize(searchText(candidate))
    let normalizedTitle = normalize(candidate.name)
    prepared.normalizedScoringFields = NormalizedScoringFields(
      title: normalizedTitle,
      sourceTitle: normalize("\(candidate.source) \(candidate.name)"),
      url: normalize(urlSearchText(candidate)),
      displayTitle: normalize(display))
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
    guard var resolved = best else { return nil }
    resolved += sourcePrecedenceBonus(for: candidate)
    return resolved
  }

  /// Tier bonus the user asked for: when two candidates fuzzy-match
  /// equally well, prefer tmux windows > browser tabs > active apps >
  /// inactive apps > the rest (slack / notes / reminders / contacts).
  /// The bonus is a small fixed offset per tier, well below the
  /// inter-base spacing (`titleScore` jumps by 1k between
  /// exact/prefix/contains), so it only breaks ties without overriding
  /// strong content matches.
  static func sourcePrecedenceBonus(for candidate: Candidate) -> Int {
    (sourcePrecedenceTierCount - sourcePrecedenceTierIndex(for: candidate)) * 40
  }

  private static let browserSourceNames: Set<String> = [
    "firefox", "firefox-dev", "safari", "chrome", "chromium",
    "brave", "edge", "arc", "vivaldi", "opera",
  ]

  /// Number of distinct precedence tiers (0…N-1), used to scale the
  /// tie-break bonus. Keep in sync with `sourcePrecedenceTierIndex`.
  private static let sourcePrecedenceTierCount = 5

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
    let sorted = records.sorted { lhs, rhs in
      let scoreDelta = lhs.score - rhs.score
      if abs(scoreDelta) >= aliveTieBreakScoreMargin {
        return lhs.score > rhs.score
      }

      // Strict tier tie-break first: when two scores are close enough
      // to land here (delta < `aliveTieBreakScoreMargin`), prefer the
      // higher-priority source tier. This is what enforces the user's
      // ordering — tmux windows > browser tabs > active apps > inactive
      // apps > the rest — and it must run *before* the generic
      // alive/dead check, otherwise a live app would leapfrog a tmux
      // window or browser tab (which often carry no pid of their own).
      if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }

      // Within a tier, an alive candidate still wins over a dead one.
      if lhs.alive != rhs.alive { return lhs.alive }

      if lhs.score != rhs.score { return lhs.score > rhs.score }

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

  /// Tier index used by `sortedMatches` as a strict tie-break. Lower is
  /// higher priority. The "app" source splits into two tiers — running
  /// apps (pid set) outrank installed-but-not-running apps — so the
  /// flashlight order is: tmux (0) > browser tabs (1) > active apps (2)
  /// > inactive apps (3) > the rest (4: slack, notes, reminders, …).
  static func sourcePrecedenceTierIndex(for candidate: Candidate) -> Int {
    let lowered = candidate.source.lowercased()
    if lowered == "tmux" { return 0 }
    if browserSourceNames.contains(lowered) { return 1 }
    if lowered == "app" { return candidate.pid != nil ? 2 : 3 }
    return 4
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
      title = "\(candidateTitle) (\(url))"
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
  /// Score tiers are spaced **far** above the source tier bonus
  /// (max ~200, see `sourcePrecedenceBonus`) so that match quality
  /// dominates source priority. The motivating case: typing `mes`
  /// must surface the `Messages` app (full-string prefix on the app
  /// name) ahead of a browser tab that happens to contain `mes`
  /// somewhere — even though browser tabs out-rank apps on tier ties.
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

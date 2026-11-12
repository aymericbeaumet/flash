import FlashCore
import Foundation

/// The `!` completion list's prepared rows with their trigger words sorted
/// once per bang catalog. A keystroke binary-searches the rows whose trigger
/// (or alias) starts with the typed token instead of running the flashlight
/// scorer over every bang. Those rows are the exact and prefix tiers, which
/// `CandidateFinder.sortedMatches` ranks above every other bang, so when they
/// fill the displayed list it is the list the full scorer would show;
/// otherwise the caller completes it with the full scorer off the main thread.
struct BangCompletionIndex {
  /// Prepared rows, in catalog order.
  let rows: [Candidate]
  /// Every row's normalized trigger and alias tokens, UTF-8, sorted
  /// bytewise so all keys sharing a prefix are one contiguous run.
  private let keys: [[UInt8]]
  private let keyRows: [Int]
  /// Lowercased tokens a confirmed `!token` can name: what the bang list
  /// would dispatch.
  let tokens: Set<String>
  /// The list a bare `!` shows: every row unscored, in display order.
  let unscored: [CandidateMatch]

  init(candidates: [Candidate], precedence: CandidateFinder.PrecedenceTable, limit: Int) {
    let rows = CandidateFinder.prepare(candidates)
    var entries: [(key: [UInt8], row: Int)] = []
    entries.reserveCapacity(rows.count)
    var tokens = Set<String>()
    for (index, row) in rows.enumerated() {
      let fields = row.normalizedScoringFields
      if !fields.title.isEmpty { entries.append((Array(fields.title.utf8), index)) }
      for alias in fields.aliases where !alias.isEmpty {
        entries.append((Array(alias.utf8), index))
      }
      if let payload = row.sourcePayload, !payload.isEmpty { tokens.insert(payload.lowercased()) }
    }
    entries.sort { lhs, rhs in
      lhs.key.lexicographicallyPrecedes(rhs.key) || (lhs.key == rhs.key && lhs.row < rhs.row)
    }
    self.rows = rows
    self.keys = entries.map(\.key)
    self.keyRows = entries.map(\.row)
    self.tokens = tokens
    self.unscored = CandidateFinder.sortedMatches(
      rows.map { CandidateMatch(candidate: $0, score: 0) }, precedence: precedence, limit: limit)
  }

  /// The rows a trigger or alias of starts with `normalizedToken`, each once,
  /// in catalog order.
  func prefixRows(_ normalizedToken: String) -> [Int] {
    let prefix = Array(normalizedToken.utf8)
    guard !prefix.isEmpty else { return [] }
    var low = 0
    var high = keys.count
    while low < high {
      let middle = (low + high) / 2
      if keys[middle].lexicographicallyPrecedes(prefix) { low = middle + 1 } else { high = middle }
    }
    var seen = Set<Int>()
    var found: [Int] = []
    var index = low
    while index < keys.count, keys[index].starts(with: prefix) {
      if seen.insert(keyRows[index]).inserted { found.append(keyRows[index]) }
      index += 1
    }
    return found.sorted()
  }

  /// What a typed token lists without scoring every bang: the prefix-tier
  /// rows, ranked, and whether they are the whole displayed list (`final`).
  /// When they are not, a lower-tier row could still reach the list, so the
  /// caller scores the full `rows` to complete it.
  func matches(
    normalizedToken: String, precedence: CandidateFinder.PrecedenceTable, limit: Int
  ) -> (matches: [CandidateMatch], final: Bool) {
    guard !normalizedToken.isEmpty else { return (unscored, true) }
    let scored = prefixRows(normalizedToken).compactMap { index -> CandidateMatch? in
      let row = rows[index]
      guard let match = Self.prefixScore(normalizedToken, row.normalizedScoringFields) else {
        return nil
      }
      return CandidateMatch(candidate: row, score: match.score, tier: match.tier)
    }
    return (
      CandidateFinder.sortedMatches(scored, precedence: precedence, limit: limit),
      scored.count >= limit
    )
  }

  /// A prefix row's score as `CandidateFinder.evaluate` computes it: the best
  /// of its trigger's and aliases' exact or prefix hits. A bang scores no
  /// source or display text, its secondary fields top out at 9,000 and the
  /// fuzzy ladder at a few hundred, so neither reaches a prefix hit (12,500
  /// and up) for any token a bang list is typed with.
  static func prefixScore(_ token: String, _ fields: NormalizedScoringFields)
    -> (score: Int, tier: CandidateFinder.MatchTier)?
  {
    var best: (score: Int, tier: CandidateFinder.MatchTier)?
    func consider(_ name: String, base: Int) {
      let hit: (score: Int, tier: CandidateFinder.MatchTier)
      if name == token {
        hit = (base + 5_000, .exact)
      } else if name.hasPrefix(token) {
        hit = (base + 3_000 - min(500, name.count - token.count), .prefix)
      } else {
        return
      }
      if let current = best {
        best = (max(current.score, hit.score), max(current.tier, hit.tier))
      } else {
        best = hit
      }
    }
    consider(fields.title, base: 10_000)
    for alias in fields.aliases { consider(alias, base: 11_000) }
    return best
  }
}

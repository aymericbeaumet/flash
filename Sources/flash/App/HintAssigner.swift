import FlashCore
import Foundation
import os

struct AssignedHint {
  let target: JumpTarget
  /// Canonical, lowercase label — what the alphabet produced.
  let label: String
  /// Pre-uppercased copy used by every render and every per-keystroke
  /// prefix match. Computed once at assign time, never per-frame.
  let display: String

  init(target: JumpTarget, label: String) {
    self.target = target
    self.label = label
    self.display = label.uppercased()
  }
}

enum HintAssigner {
  /// Label `targets` with the prefix-free set for their count, best labels
  /// first. With `previous` hints (a `--multi` session discovering again after
  /// a click), a target that matches a previous one keeps its label when that
  /// label is still in the set, and the rest take the remaining labels in
  /// order — the same deterministic result for the same two inputs.
  static func assign(
    targets: [JumpTarget],
    alphabet: [Character],
    leftHand: Set<Character> = [],
    keyScores: [Character: Int] = [:],
    keyRows: [Character: Int] = [:],
    minLength: Int = 1,
    preserving previous: [AssignedHint] = []
  ) -> [AssignedHint] {
    let labels = generateLabels(
      count: targets.count,
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      minLength: minLength
    )
    guard !previous.isEmpty else {
      var out: [AssignedHint] = []
      out.reserveCapacity(targets.count)
      for (t, l) in zip(targets, labels) {
        out.append(AssignedHint(target: t, label: l))
      }
      return out
    }
    return relabel(targets: targets, labels: labels, previous: previous)
  }

  /// What makes a target the same control across two walks: walk ids are
  /// ordinals, so match on what it is and where it sits.
  private struct Identity: Hashable {
    let providerID: String
    let pid: pid_t?
    let role: String?
    let label: String?
    let url: String?
    let contextID: String?
    let frame: [Int]

    init(_ target: JumpTarget) {
      providerID = target.providerID
      pid = target.pid
      role = target.role
      label = target.accessibilityLabel
      url = target.url
      contextID = target.contextID
      let frame = target.frame
      self.frame = [frame.minX, frame.minY, frame.width, frame.height].map {
        $0.isFinite ? Int($0.rounded()) : 0
      }
    }
  }

  private static func relabel(
    targets: [JumpTarget], labels: [String], previous: [AssignedHint]
  ) -> [AssignedHint] {
    let available = Set(labels)
    var previousLabels: [Identity: [String]] = [:]
    for hint in previous {
      previousLabels[Identity(hint.target), default: []].append(hint.label)
    }
    var taken = Set<String>()
    var kept = [String?](repeating: nil, count: targets.count)
    for (index, target) in targets.enumerated() {
      let identity = Identity(target)
      guard var queue = previousLabels[identity], !queue.isEmpty else { continue }
      let label = queue.removeFirst()
      previousLabels[identity] = queue
      if available.contains(label), taken.insert(label).inserted {
        kept[index] = label
      }
    }
    var free = labels.lazy.filter { !taken.contains($0) }.makeIterator()
    var out: [AssignedHint] = []
    out.reserveCapacity(targets.count)
    for (target, label) in zip(targets, kept) {
      guard let label = label ?? free.next() else { break }
      out.append(AssignedHint(target: target, label: label))
    }
    return out
  }

  /// Generate `count` prefix-free labels, packing the cheapest (shortest)
  /// labels first so the user can commit a hint with a single keypress
  /// whenever the target count allows.
  ///
  /// Layout policy:
  ///   - If `count ≤ alphabet.count` (and `minLength == 1`): all labels
  ///     are single chars in layout-score order. The user types one key
  ///     per target, and the strongest keys are assigned first.
  ///   - Otherwise: pack as many single-char labels as possible while
  ///     keeping the rest 2-char and prefix-free. Concretely we pick
  ///     X singles + (count − X) two-char labels where the two-char
  ///     labels never start with any of the X reserved single chars
  ///     (otherwise typing the single char would be ambiguous).
  ///     X is the largest value satisfying X + (K−X)*K ≥ count.
  ///   - If the user pinned `minLength ≥ 2`, every label uses uniform
  ///     length L (smallest L with K^L ≥ count and L ≥ minLength) —
  ///     the original uniform-length behaviour.
  ///
  /// Within a length class, labels are sorted by an ergonomic score.
  /// A hand change outranks every row jump. Less travel between physical
  /// rows then outranks key ease, graded by how many rows the fingers
  /// move. Key ease is `Alphabet.physicalKeyScore`: home row, then bottom,
  /// then top. Same-key repeats rank last. A key with no row adds no
  /// travel penalty, so a literal alphabet keeps its written order. Ties
  /// keep alphabet order.
  ///
  /// Single-character labels stay in front, but only while the keys held
  /// back as prefixes can still spell the remaining labels as left/right
  /// alternations. Reserving every strong key as a single forces those
  /// pairs onto the leftover prefixes and fills the screen with same-hand
  /// bigrams.
  static func generateLabels(
    count: Int,
    alphabet: [Character],
    leftHand: Set<Character> = [],
    keyScores: [Character: Int] = [:],
    keyRows: [Character: Int] = [:],
    minLength: Int = 1
  ) -> [String] {
    guard count > 0 else { return [] }
    guard alphabet.count >= 2 else {
      return (0..<count).map { _ in String(alphabet.first ?? "a") }
    }
    let k = alphabet.count
    let minLen = max(1, minLength)

    // Mixed-length path: singles first, then 2-char labels whose first
    // char isn't a reserved single. Only available when the user hasn't
    // forced longer labels via `minLength`.
    if minLen == 1 {
      if count <= k {
        return (0..<count).map { String(alphabet[$0]) }
      }
      if let alternating = alternatingMixedLabels(
        count: count,
        alphabet: alphabet,
        leftHand: leftHand,
        keyScores: keyScores,
        keyRows: keyRows
      ) {
        return alternating
      }
      // Max X such that the remaining count fits in 2-char labels with
      // a prefix-free constraint:
      //   X + (K − X) * K ≥ count
      //   X(K − 1) ≤ K² − count
      // Used when one hand cannot cover the rest, or the alphabet has no
      // hand split. The two-character tail is still score order, so
      // alternations come before same-hand pairs.
      let cap = (k * k - count) / max(1, k - 1)
      let singlesCount = max(0, min(k - 1, cap))
      if singlesCount > 0 {
        let singles = (0..<singlesCount).map { String(alphabet[$0]) }
        let reservedPrefixes = Set(alphabet[0..<singlesCount])
        let multi = sortedCandidates(
          alphabet: alphabet,
          leftHand: leftHand,
          keyScores: keyScores,
          keyRows: keyRows,
          length: 2
        )
        .lazy.filter {
          guard let first = $0.first else { return false }
          return !reservedPrefixes.contains(first)
        }
        return singles + Array(multi.prefix(count - singlesCount))
      }
      // No room for singles (extremely large count). Fall through to
      // the uniform-length path below.
    }

    // Uniform-length path: every label shares L = smallest length that
    // fits, floored at `minLength`. Used when the caller pins a min
    // length, or when count is so large that there's no room for any
    // single-char labels.
    var length = minLen
    var bound = intPow(k, length)
    while bound < count {
      length += 1
      bound *= k
    }
    if length == 1 {
      return (0..<count).map { String(alphabet[$0]) }
    }
    let sorted = sortedCandidates(
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      length: length
    )
    if sorted.count >= count {
      return Array(sorted.prefix(count))
    }
    return sorted
  }

  /// Returns the full K^L candidate space sorted by ergonomic score
  /// (descending), with a deterministic key-order tiebreak. Memoised by
  /// `(alphabet, leftHand, keyScores, keyRows, length)` via a bounded LRU.
  ///
  /// In steady state the user runs one alphabet preset, so cache hits
  /// dominate; the LRU cap (`cacheCapacity`) keeps memory bounded even
  /// across config-reload-driven score permutations.
  static func sortedCandidates(
    alphabet: [Character],
    leftHand: Set<Character>,
    keyScores: [Character: Int] = [:],
    keyRows: [Character: Int] = [:],
    length: Int
  ) -> [String] {
    let key = CacheKey(
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      length: length
    )
    os_unfair_lock_lock(&cacheLock)
    if let cached = cache.value(for: key) {
      os_unfair_lock_unlock(&cacheLock)
      return cached
    }
    os_unfair_lock_unlock(&cacheLock)

    let computed = computeSortedCandidates(
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      length: length
    )

    os_unfair_lock_lock(&cacheLock)
    cache.set(key, value: computed)
    os_unfair_lock_unlock(&cacheLock)
    return computed
  }

  /// Hashable cache key. Replaces the previous String-based key that
  /// allocated a fresh `String` on every lookup. Set membership is
  /// captured by a sorted `[Character]` so two calls with the same
  /// inputs hash identically without going through a `String`.
  private struct CacheKey: Hashable {
    let alphabet: [Character]
    let leftHandSorted: [Character]
    let scoresSorted: [Int]
    let scoreChars: [Character]
    let rowChars: [Character]
    let rowsSorted: [Int]
    let length: Int

    init(
      alphabet: [Character],
      leftHand: Set<Character>,
      keyScores: [Character: Int],
      keyRows: [Character: Int],
      length: Int
    ) {
      self.alphabet = alphabet
      self.leftHandSorted = leftHand.sorted()
      // Sort keys for determinism; pack chars and scores in parallel
      // arrays so Hashable produces a stable hash.
      let sortedKeys = keyScores.keys.sorted()
      self.scoreChars = sortedKeys
      self.scoresSorted = sortedKeys.map { keyScores[$0] ?? 0 }
      let sortedRows = keyRows.keys.sorted()
      self.rowChars = sortedRows
      self.rowsSorted = sortedRows.map { keyRows[$0] ?? 0 }
      self.length = length
    }
  }

  /// Tiny LRU. The expected working set is one or two entries per
  /// session (the active alphabet preset at L=2 and L=3), so a
  /// capacity of 8 covers every realistic workload while preventing
  /// an unbounded grow under exotic config reloads.
  private struct LRU {
    let capacity: Int
    private var dict: [CacheKey: [String]] = [:]
    private var order: [CacheKey] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func value(for key: CacheKey) -> [String]? {
      guard let value = dict[key] else { return nil }
      if let idx = order.firstIndex(of: key) {
        order.remove(at: idx)
        order.append(key)
      }
      return value
    }

    mutating func set(_ key: CacheKey, value: [String]) {
      if dict[key] != nil {
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
      } else if order.count >= capacity, let oldest = order.first {
        order.removeFirst()
        dict.removeValue(forKey: oldest)
      }
      dict[key] = value
      order.append(key)
    }
  }

  private static let cacheCapacity = 8
  private static var cache = LRU(capacity: cacheCapacity)
  private static var cacheLock = os_unfair_lock_s()

  private enum Score {
    static let keyWeight = 10
    /// One row of travel. Larger than the whole key-ease total of a label
    /// of up to `maxPackedLength` keys (10 × 331 × 12 = 39_720).
    static let rowStep = 40_000
    /// One hand change. Larger than every row of travel on that label
    /// (11 steps × 3 rows × `rowStep` = 1_320_000).
    static let handAlternation = 1_400_000
    static let sameHand = -1_400_000
    /// Worse than a same-hand transition plus a full three-row jump.
    static let sameKey = -4_000_000
  }

  /// Score of one step. `rowDistance` is nil when either key has no
  /// physical row, so a literal alphabet pays nothing for travel.
  private static func transitionScore(sameKey: Bool, changesHand: Bool, rowDistance: Int?) -> Int {
    if sameKey { return Score.sameKey }
    var score = changesHand ? Score.handAlternation : Score.sameHand
    if let rowDistance {
      score -= rowDistance * Score.rowStep
    }
    return score
  }

  private static func rowDistance(_ previous: Int, _ next: Int) -> Int? {
    guard previous >= 0, next >= 0 else { return nil }
    return abs(previous - next)
  }

  /// Maximum supported label length when packing indices into a UInt64.
  /// Five bits per position lets the alphabet hold up to 32 characters
  /// (more than any real hint preset). Twelve positions × 5 bits = 60
  /// bits, well under the 64-bit ceiling.
  private static let maxPackedLength = 12

  private static func computeSortedCandidates(
    alphabet: [Character],
    leftHand: Set<Character>,
    keyScores: [Character: Int],
    keyRows: [Character: Int],
    length: Int
  ) -> [String] {
    let k = alphabet.count
    let total = intPow(k, length)

    // Left-hand membership precomputed per alphabet index — saves a
    // Set hash lookup inside the inner score loop.
    var leftByIndex = [Bool](repeating: false, count: k)
    for (i, ch) in alphabet.enumerated() { leftByIndex[i] = leftHand.contains(ch) }
    var keyScoreByIndex = [Int](repeating: 0, count: k)
    for (i, ch) in alphabet.enumerated() { keyScoreByIndex[i] = keyScores[ch] ?? 0 }
    var rowByIndex = [Int](repeating: -1, count: k)
    for (i, ch) in alphabet.enumerated() {
      if let row = keyRows[ch] { rowByIndex[i] = row }
    }

    // When length fits in our packed UInt64 (and the alphabet fits
    // in 5 bits per slot) we sort a single `[(score, packedIndices)]`
    // array and never allocate per-candidate `[Int]` storage. Falls
    // back to the boxed form only for exotic configurations.
    if length <= maxPackedLength, k <= 32 {
      var candidates = [(score: Int, packed: UInt64, ordinal: UInt64)]()
      candidates.reserveCapacity(total)
      var indices = [Int](repeating: 0, count: length)
      for n in 0..<total {
        var value = n
        for pos in (0..<length).reversed() {
          indices[pos] = value % k
          value /= k
        }
        var score = 0
        for i in 0..<length {
          score += keyScoreByIndex[indices[i]] * Score.keyWeight
        }
        for i in 1..<length {
          let previous = indices[i - 1]
          let next = indices[i]
          score += transitionScore(
            sameKey: previous == next,
            changesHand: leftByIndex[previous] != leftByIndex[next],
            rowDistance: rowDistance(rowByIndex[previous], rowByIndex[next])
          )
        }
        var packed: UInt64 = 0
        for i in 0..<length {
          packed |= UInt64(indices[i] & 0x1F) << (UInt64(i) * 5)
        }
        // Ordinal preserves the deterministic key-order tiebreak — the
        // earlier-generated permutation wins on score ties.
        candidates.append((score: score, packed: packed, ordinal: UInt64(n)))
      }

      candidates.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        return a.ordinal < b.ordinal
      }

      var labels = [String]()
      labels.reserveCapacity(total)
      var buf: [Character] = Array(repeating: alphabet[0], count: length)
      for c in candidates {
        for i in 0..<length {
          let idx = Int((c.packed >> (UInt64(i) * 5)) & 0x1F)
          buf[i] = alphabet[idx]
        }
        labels.append(String(buf))
      }
      return labels
    }

    // Fallback path for L > 12 or K > 32 (no realistic config hits
    // this, but keep the unpacked sort so behaviour stays identical).
    struct Candidate {
      var indices: [Int]
      var score: Int
    }
    var candidates = [Candidate]()
    candidates.reserveCapacity(total)
    var indices = [Int](repeating: 0, count: length)
    for n in 0..<total {
      var value = n
      for pos in (0..<length).reversed() {
        indices[pos] = value % k
        value /= k
      }
      var score = 0
      for i in 0..<length {
        score += keyScoreByIndex[indices[i]] * Score.keyWeight
      }
      for i in 1..<length {
        let previous = indices[i - 1]
        let next = indices[i]
        score += transitionScore(
          sameKey: previous == next,
          changesHand: leftByIndex[previous] != leftByIndex[next],
          rowDistance: rowDistance(rowByIndex[previous], rowByIndex[next])
        )
      }
      candidates.append(Candidate(indices: indices, score: score))
    }

    candidates.sort { a, b in
      if a.score != b.score { return a.score > b.score }
      for i in 0..<length where a.indices[i] != b.indices[i] {
        return a.indices[i] < b.indices[i]
      }
      return false
    }

    var labels = [String]()
    labels.reserveCapacity(total)
    var buf: [Character] = Array(repeating: alphabet[0], count: length)
    for c in candidates {
      for i in 0..<length { buf[i] = alphabet[c.indices[i]] }
      labels.append(String(buf))
    }
    return labels
  }

  static func scoreLabel(
    _ label: String,
    leftHand: Set<Character>,
    keyScores: [Character: Int],
    keyRows: [Character: Int] = [:]
  ) -> Int {
    let chars = Array(label)
    guard !chars.isEmpty else { return 0 }
    var score = 0
    for ch in chars {
      score += (keyScores[ch] ?? 0) * Score.keyWeight
    }
    if chars.count < 2 { return score }
    for i in 1..<chars.count {
      let previous = chars[i - 1]
      let next = chars[i]
      score += transitionScore(
        sameKey: previous == next,
        changesHand: leftHand.contains(previous) != leftHand.contains(next),
        rowDistance: rowDistance(keyRows[previous] ?? -1, keyRows[next] ?? -1)
      )
    }
    return score
  }

  /// Largest set of one-key labels whose withheld prefixes can spell the
  /// rest as alternating two-key labels. Nil when a hand is missing or
  /// there are not enough alternating pairs: the caller then keeps the
  /// shorter labels and allows same-hand pairs.
  private static func alternatingMixedLabels(
    count: Int,
    alphabet: [Character],
    leftHand: Set<Character>,
    keyScores: [Character: Int],
    keyRows: [Character: Int]
  ) -> [String]? {
    let k = alphabet.count
    guard count > k else { return nil }
    var left: [Character] = []
    var right: [Character] = []
    left.reserveCapacity(k)
    right.reserveCapacity(k)
    for character in alphabet {
      if leftHand.contains(character) {
        left.append(character)
      } else {
        right.append(character)
      }
    }
    guard !left.isEmpty, !right.isEmpty else { return nil }

    let sorted = sortedCandidates(
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      keyRows: keyRows,
      length: 2
    )
    var scoreOf: [String: Int] = [:]
    scoreOf.reserveCapacity(sorted.count)
    for label in sorted {
      scoreOf[label] = scoreLabel(
        label, leftHand: leftHand, keyScores: keyScores, keyRows: keyRows)
    }

    for prefixCount in 1..<k {
      let needed = count - (k - prefixCount)
      guard needed > 0, prefixCount * k >= needed else { continue }
      var winner: (singles: [Character], bigrams: [String])?
      for rightCount in 0...min(prefixCount, right.count) {
        let leftCount = prefixCount - rightCount
        guard leftCount >= 0, leftCount <= left.count else { continue }
        let capacity = rightCount * left.count + leftCount * right.count
        guard capacity >= needed else { continue }
        var prefixes = Set<Character>(minimumCapacity: prefixCount)
        for character in right.prefix(rightCount) { prefixes.insert(character) }
        for character in left.prefix(leftCount) { prefixes.insert(character) }
        var bigrams: [String] = []
        bigrams.reserveCapacity(needed)
        for label in sorted {
          guard let first = label.first, prefixes.contains(first) else { continue }
          let chars = Array(label)
          guard chars.count == 2, leftHand.contains(chars[0]) != leftHand.contains(chars[1])
          else { continue }
          bigrams.append(label)
          if bigrams.count == needed { break }
        }
        guard bigrams.count == needed else { continue }
        let singles = alphabet.filter { !prefixes.contains($0) }
        if let current = winner,
          !planBeats(
            singles, bigrams,
            current.singles, current.bigrams,
            keyScores: keyScores,
            scoreOf: scoreOf
          )
        {
          continue
        }
        winner = (singles, bigrams)
      }
      if let winner {
        return winner.singles.map(String.init) + winner.bigrams
      }
    }
    return nil
  }

  /// True when the first plan is the better label sequence. Both plans
  /// have the same number of singles; the earlier label decides, and a
  /// one-key label is compared by its key score.
  private static func planBeats(
    _ singles: [Character],
    _ bigrams: [String],
    _ otherSingles: [Character],
    _ otherBigrams: [String],
    keyScores: [Character: Int],
    scoreOf: [String: Int]
  ) -> Bool {
    for (lhs, rhs) in zip(singles, otherSingles) {
      let leftScore = keyScores[lhs] ?? 0
      let rightScore = keyScores[rhs] ?? 0
      if leftScore != rightScore { return leftScore > rightScore }
    }
    for (lhs, rhs) in zip(bigrams, otherBigrams) {
      let leftScore = scoreOf[lhs] ?? 0
      let rightScore = scoreOf[rhs] ?? 0
      if leftScore != rightScore { return leftScore > rightScore }
    }
    return false
  }

  private static func intPow(_ base: Int, _ exp: Int) -> Int {
    var r = 1
    for _ in 0..<exp { r *= base }
    return r
  }
}

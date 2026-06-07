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
  static func assign(
    targets: [JumpTarget],
    alphabet: [Character],
    leftHand: Set<Character> = [],
    keyScores: [Character: Int] = [:],
    minLength: Int = 1
  ) -> [AssignedHint] {
    let labels = generateLabels(
      count: targets.count,
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
      minLength: minLength
    )
    var out: [AssignedHint] = []
    out.reserveCapacity(targets.count)
    for (t, l) in zip(targets, labels) {
      out.append(AssignedHint(target: t, label: l))
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
  /// Within a length class, labels are sorted by an ergonomic score
  /// that favours left/right hand alternation first, rewards high-value
  /// layout keys inside the same hand pattern, penalises same-key repeats,
  /// then falls back to deterministic key order.
  static func generateLabels(
    count: Int,
    alphabet: [Character],
    leftHand: Set<Character> = [],
    keyScores: [Character: Int] = [:],
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
      // Max X such that the remaining count fits in 2-char labels with
      // a prefix-free constraint:
      //   X + (K − X) * K ≥ count
      //   X(K − 1) ≤ K² − count
      let cap = (k * k - count) / max(1, k - 1)
      let singlesCount = max(0, min(k - 1, cap))
      if singlesCount > 0 {
        let singles = (0..<singlesCount).map { String(alphabet[$0]) }
        let reservedPrefixes = Set(alphabet[0..<singlesCount])
        let multi = sortedCandidates(
          alphabet: alphabet,
          leftHand: leftHand,
          keyScores: keyScores,
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
      length: length
    )
    if sorted.count >= count {
      return Array(sorted.prefix(count))
    }
    return sorted
  }

  /// Returns the full K^L candidate space sorted by ergonomic score
  /// (descending), with a deterministic key-order tiebreak. Memoised by
  /// `(alphabet, leftHand, keyScores, length)` via a bounded LRU.
  ///
  /// In steady state the user runs one alphabet preset, so cache hits
  /// dominate; the LRU cap (`cacheCapacity`) keeps memory bounded even
  /// across config-reload-driven score permutations.
  static func sortedCandidates(
    alphabet: [Character],
    leftHand: Set<Character>,
    keyScores: [Character: Int] = [:],
    length: Int
  ) -> [String] {
    let key = CacheKey(
      alphabet: alphabet,
      leftHand: leftHand,
      keyScores: keyScores,
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
    let length: Int

    init(
      alphabet: [Character],
      leftHand: Set<Character>,
      keyScores: [Character: Int],
      length: Int
    ) {
      self.alphabet = alphabet
      self.leftHandSorted = leftHand.sorted()
      // Sort keys for determinism; pack chars and scores in parallel
      // arrays so Hashable produces a stable hash.
      let sortedKeys = keyScores.keys.sorted()
      self.scoreChars = sortedKeys
      self.scoresSorted = sortedKeys.map { keyScores[$0] ?? 0 }
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
    static let handAlternation = 10_000
    static let sameHand = -10_000
    static let sameKey = -50_000
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
          let a = indices[i - 1]
          let b = indices[i]
          if a == b {
            score += Score.sameKey
          } else if leftByIndex[a] != leftByIndex[b] {
            score += Score.handAlternation
          } else {
            score += Score.sameHand
          }
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
        let a = indices[i - 1]
        let b = indices[i]
        if a == b {
          score += Score.sameKey
        } else if leftByIndex[a] != leftByIndex[b] {
          score += Score.handAlternation
        } else {
          score += Score.sameHand
        }
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

  /// Higher is better. Favours adjacent-character pairs that alternate between
  /// left and right hand, then rewards high-value layout keys; penalises
  /// same-key repeats and same-hand pairs. Kept for tests / external callers;
  /// the fast path lives in `computeSortedCandidates`.
  static func scoreLabel(_ label: String, leftHand: Set<Character>) -> Int {
    scoreLabel(label, leftHand: leftHand, keyScores: [:])
  }

  static func scoreLabel(
    _ label: String,
    leftHand: Set<Character>,
    keyScores: [Character: Int]
  ) -> Int {
    let chars = Array(label)
    guard !chars.isEmpty else { return 0 }
    var score = 0
    for ch in chars {
      score += (keyScores[ch] ?? 0) * Score.keyWeight
    }
    if chars.count < 2 { return score }
    for i in 1..<chars.count {
      if chars[i] == chars[i - 1] {
        score += Score.sameKey
      } else {
        let prevLeft = leftHand.contains(chars[i - 1])
        let currLeft = leftHand.contains(chars[i])
        score += prevLeft != currLeft ? Score.handAlternation : Score.sameHand
      }
    }
    return score
  }

  private static func intPow(_ base: Int, _ exp: Int) -> Int {
    var r = 1
    for _ in 0..<exp { r *= base }
    return r
  }
}

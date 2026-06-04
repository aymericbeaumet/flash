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
    minLength: Int = 1
  ) -> [AssignedHint] {
    let labels = generateLabels(
      count: targets.count,
      alphabet: alphabet,
      leftHand: leftHand,
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
  ///     are single chars in the alphabet's declared order. The user
  ///     types one key per target.
  ///   - Otherwise: pack as many single-char labels as possible while
  ///     keeping the rest 2-char and prefix-free. Concretely we pick
  ///     X singles + (count − X) two-char labels where the two-char
  ///     labels never start with any of the X reserved single chars
  ///     (otherwise typing the single char would be ambiguous).
  ///     X is the largest value satisfying X + (K−X)*K ≥ count.
  ///   - If the user pinned `minLength ≥ 2`, every label uses uniform
  ///     length L (smallest L with K^L ≥ count and L ≥ minLength) —
  ///     the original Vimium-style uniform-length behaviour.
  ///
  /// Within a length class, labels are sorted by an ergonomic score
  /// that rewards hand-alternation and penalises same-finger repeats,
  /// then by lexicographic position as a deterministic tiebreaker.
  static func generateLabels(
    count: Int,
    alphabet: [Character],
    leftHand: Set<Character> = [],
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
        let multi = sortedCandidates(alphabet: alphabet, leftHand: leftHand, length: 2)
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
    let sorted = sortedCandidates(alphabet: alphabet, leftHand: leftHand, length: length)
    if sorted.count >= count {
      return Array(sorted.prefix(count))
    }
    return sorted
  }

  /// Returns the full K^L candidate space sorted by ergonomic score
  /// (descending), with a deterministic lexicographic tiebreak. Memoised by
  /// (alphabet identity, length, leftHand identity) — for the typical
  /// `<qwerty>` preset and L=2/3 this cache is populated once per session
  /// and every subsequent activation skips the sort entirely.
  static func sortedCandidates(
    alphabet: [Character],
    leftHand: Set<Character>,
    length: Int
  ) -> [String] {
    let key = makeCacheKey(alphabet: alphabet, leftHand: leftHand, length: length)
    os_unfair_lock_lock(&cacheLock)
    if let cached = cache[key] {
      os_unfair_lock_unlock(&cacheLock)
      return cached
    }
    os_unfair_lock_unlock(&cacheLock)

    let computed = computeSortedCandidates(alphabet: alphabet, leftHand: leftHand, length: length)

    os_unfair_lock_lock(&cacheLock)
    cache[key] = computed
    os_unfair_lock_unlock(&cacheLock)
    return computed
  }

  private static var cache: [String: [String]] = [:]
  private static var cacheLock = os_unfair_lock_s()

  private static func makeCacheKey(alphabet: [Character], leftHand: Set<Character>, length: Int)
    -> String
  {
    var key = ""
    key.reserveCapacity(alphabet.count + leftHand.count + 8)
    key.append(contentsOf: alphabet)
    key.append("|")
    // Iterate the set in sorted order for a stable identity.
    for c in leftHand.sorted() { key.append(c) }
    key.append("|")
    key.append(String(length))
    return key
  }

  private static func computeSortedCandidates(
    alphabet: [Character],
    leftHand: Set<Character>,
    length: Int
  ) -> [String] {
    let k = alphabet.count
    let total = intPow(k, length)

    // Direct character→rank lookup; rank only needs the alphabet
    // positions, not the full 128-entry ASCII table.
    var rank = [Character: Int](minimumCapacity: k)
    for (i, ch) in alphabet.enumerated() { rank[ch] = i }

    // Left-hand membership precomputed per alphabet index — saves a
    // Set hash lookup inside the inner score loop.
    var leftByIndex = [Bool](repeating: false, count: k)
    for (i, ch) in alphabet.enumerated() { leftByIndex[i] = leftHand.contains(ch) }

    struct Candidate {
      var indices: [Int]  // alphabet positions, length L
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
      for i in 1..<length {
        let a = indices[i - 1]
        let b = indices[i]
        if a == b {
          score -= 10
        } else if leftByIndex[a] != leftByIndex[b] {
          score += 5
        } else {
          score -= 1
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

  /// Higher is better. Rewards adjacent-character pairs that alternate
  /// between left and right hand; penalises same-key repeats and same-hand
  /// pairs (different finger). Final score for an L-char label is the
  /// sum of (L-1) pairwise scores. Kept for tests / external callers; the
  /// fast path lives in `computeSortedCandidates`.
  static func scoreLabel(_ label: String, leftHand: Set<Character>) -> Int {
    let chars = Array(label)
    if chars.count < 2 { return 0 }
    var score = 0
    for i in 1..<chars.count {
      if chars[i] == chars[i - 1] {
        score -= 10
      } else {
        let prevLeft = leftHand.contains(chars[i - 1])
        let currLeft = leftHand.contains(chars[i])
        if prevLeft != currLeft { score += 5 } else { score -= 1 }
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

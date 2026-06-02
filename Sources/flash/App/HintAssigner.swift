import Foundation
import os
import FlashCore

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

    /// Generate `count` prefix-free labels of uniform length, ordered so that
    /// labels typed by *alternating* hands come before labels typed entirely
    /// on one hand. The same-finger case (e.g. "AA") is penalised hardest.
    ///
    /// Every label still shares the same length L (smallest L with
    /// `alphabet.count ** L >= count`, floored at `minLength`), so the
    /// commit path knows exactly how many characters to expect.
    ///
    /// Determinism: when two candidate labels tie on score, we use the
    /// lexicographic order on (chars in alphabet position) as the tiebreaker.
    /// Two runs on identical input produce identical output.
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
        var length = max(1, minLength)
        var bound = intPow(k, length)
        while bound < count {
            length += 1
            bound *= k
        }

        // Single-char labels: no alternation possible (one keypress each).
        // Just consume the alphabet in its declared order — that order is
        // already optimised for ergonomics by the preset (home row first).
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

    private static func makeCacheKey(alphabet: [Character], leftHand: Set<Character>, length: Int) -> String {
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
            var indices: [Int]   // alphabet positions, length L
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
                if prevLeft != currLeft { score += 5 }
                else { score -= 1 }
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

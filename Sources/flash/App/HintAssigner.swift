import Foundation
import FlashCore

struct AssignedHint {
    let target: JumpTarget
    let label: String
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
        return zip(targets, labels).map { AssignedHint(target: $0.0, label: $0.1) }
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
        while pow(Double(k), Double(length)) < Double(count) {
            length += 1
        }

        // Single-char labels: no alternation possible (one keypress each).
        // Just consume the alphabet in its declared order — that order is
        // already optimised for ergonomics by the preset (home row first).
        if length == 1 {
            return (0..<count).map { String(alphabet[$0]) }
        }

        // Multi-char: enumerate all K^L candidates, score each, sort by
        // score desc with a deterministic lex tiebreak, take the best
        // `count`. K^L is small enough to brute-force for realistic alphabet
        // sizes (~22 chars, L=2 → 484 candidates; L=3 → ~10k).
        let total = Int(pow(Double(k), Double(length)))
        // Per-character position-in-alphabet for the lex tiebreaker.
        var rank = [Character: Int](minimumCapacity: k)
        for (i, ch) in alphabet.enumerated() { rank[ch] = i }

        var candidates = Array<(label: String, score: Int, rankKey: [Int])>()
        candidates.reserveCapacity(total)
        for n in 0..<total {
            let label = numberToLabel(n, alphabet: alphabet, length: length)
            let score = scoreLabel(label, leftHand: leftHand)
            let rankKey = label.map { rank[$0] ?? 0 }
            candidates.append((label, score, rankKey))
        }
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            // Stable, total order tiebreak — compares position-in-alphabet
            // tuple lexicographically.
            for i in 0..<a.rankKey.count where a.rankKey[i] != b.rankKey[i] {
                return a.rankKey[i] < b.rankKey[i]
            }
            return false
        }
        return Array(candidates.prefix(count).map(\.label))
    }

    /// Higher is better. Rewards adjacent-character pairs that alternate
    /// between left and right hand; penalises same-key repeats and same-hand
    /// pairs (different finger). Final score for an L-char label is the
    /// sum of (L-1) pairwise scores.
    private static func scoreLabel(_ label: String, leftHand: Set<Character>) -> Int {
        let chars = Array(label)
        if chars.count < 2 { return 0 }
        var score = 0
        for i in 1..<chars.count {
            if chars[i] == chars[i - 1] {
                score -= 10                       // same finger, very bad
            } else {
                let prevLeft = leftHand.contains(chars[i - 1])
                let currLeft = leftHand.contains(chars[i])
                if prevLeft != currLeft {
                    score += 5                    // alternating hands — best
                } else {
                    score -= 1                    // same hand, different finger
                }
            }
        }
        return score
    }

    private static func numberToLabel(_ n: Int, alphabet: [Character], length: Int) -> String {
        var s = ""
        var value = n
        for _ in 0..<length {
            s = String(alphabet[value % alphabet.count]) + s
            value /= alphabet.count
        }
        return s
    }
}

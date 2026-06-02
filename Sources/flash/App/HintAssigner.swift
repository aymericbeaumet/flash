import Foundation
import FlashCore

struct AssignedHint {
    let target: JumpTarget
    let label: String
}

enum HintAssigner {
    static func assign(targets: [JumpTarget], alphabet: [Character], minLength: Int = 1) -> [AssignedHint] {
        let labels = generateLabels(count: targets.count, alphabet: alphabet, minLength: minLength)
        return zip(targets, labels).map { AssignedHint(target: $0.0, label: $0.1) }
    }

    /// Generate a prefix-free set of labels of the minimum length needed to encode `count` items
    /// using `alphabet` characters. Algorithm matches vimium-style hint allocation: shorter labels
    /// go to earlier items; longer prefixes are reserved as needed.
    static func generateLabels(count: Int, alphabet: [Character], minLength: Int = 1) -> [String] {
        guard count > 0 else { return [] }
        guard alphabet.count >= 2 else {
            return (0..<count).map { _ in String(alphabet.first ?? "a") }
        }
        let k = alphabet.count
        var length = max(1, minLength)
        while pow(Double(k), Double(length)) < Double(count) {
            length += 1
        }
        // Number of "long" (length) labels needed vs "short" (length-1) we can promote.
        // Vimium trick: take prefixes from the end of the alphabet for the long codes
        // so the most common short labels stay on the strongest keys.
        let total = Int(pow(Double(k), Double(length)))
        let shortLen = max(minLength, length - 1)
        let shortCount = Int(pow(Double(k), Double(shortLen)))
        let needed = count
        // longCount = number of length-`length` codes we need; each long prefix consumes one short slot.
        let longPrefixes: Int
        if needed <= shortCount {
            longPrefixes = 0
        } else {
            // remaining = needed - (shortCount - p), and each prefix gives k long codes,
            // so p * k >= needed - (shortCount - p) → p * (k-1) >= needed - shortCount → p = ceil((needed-shortCount)/(k-1))
            longPrefixes = (needed - shortCount + (k - 2)) / (k - 1)
        }
        let shortLabels = shortCount - longPrefixes
        var out: [String] = []
        out.reserveCapacity(needed)
        // Emit shortLen-length labels first (skipping the last `longPrefixes` of them).
        for i in 0..<shortLabels {
            if out.count >= needed { return out }
            out.append(numberToLabel(i, alphabet: alphabet, length: shortLen))
        }
        // Then emit length-length labels by combining each reserved prefix with each alphabet char.
        for p in 0..<longPrefixes {
            let prefixIndex = shortCount - longPrefixes + p
            let prefix = numberToLabel(prefixIndex, alphabet: alphabet, length: shortLen)
            for j in 0..<k {
                if out.count >= needed { return out }
                out.append(prefix + String(alphabet[j]))
            }
        }
        _ = total
        return out
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

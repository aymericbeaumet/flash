import Foundation

enum Alphabet {
    struct Resolved {
        let chars: [Character]
        /// Characters typed by the left hand on the user's effective layout.
        /// Used by HintAssigner to favour hand-alternating label pairs.
        let leftHand: Set<Character>
        let warning: String?
    }

    private struct Preset {
        let chars: [Character]
        let leftHand: Set<Character>
    }

    private static let presets: [String: Preset] = [
        "colemak": Preset(
            chars: Array("arstneiogfplmuywvbckxjqzdh"),
            // Colemak left-hand keys (physical positions q/w/e/r/t/a/s/d/f/g/z/x/c/v/b
            // which under Colemak emit q/w/f/p/g/a/r/s/t/d/z/x/c/v/b).
            leftHand: Set("qwfpgarstdzxcvb")
        ),
        "qwerty": Preset(
            chars: Array("sadfjklewcmpghvtbynruo"),
            leftHand: Set("qwertasdfgzxcvb")
        ),
        "dvorak": Preset(
            chars: Array("aoeuhtnspyfgcrlqjkxbmwvz"),
            // Dvorak left half: ', . , p y / a o e u i / ; q j k x
            leftHand: Set("',.pyaoeui;qjkx")
        ),
    ]

    static let defaultName = "qwerty"

    static func resolve(_ raw: String?) -> Resolved {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let p = presets[defaultName]!
            return Resolved(chars: p.chars, leftHand: p.leftHand, warning: nil)
        }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            let name = String(trimmed.dropFirst().dropLast()).lowercased()
            if let p = presets[name] {
                return Resolved(chars: p.chars, leftHand: p.leftHand, warning: nil)
            }
            let fallback = presets[defaultName]!
            return Resolved(chars: fallback.chars, leftHand: fallback.leftHand,
                            warning: "Unknown preset <\(name)>, falling back to <\(defaultName)>")
        }
        // Custom literal alphabet. We don't know the user's layout, so use the
        // QWERTY hand split as a best guess — that's the physical layout most
        // hardware ships with.
        var seen = Set<Character>()
        var out: [Character] = []
        var rejected: [Character] = []
        for ch in trimmed {
            let lower = Character(ch.lowercased())
            guard lower.isASCII, lower.isLetter || lower == ";" || lower == "'" else {
                rejected.append(ch); continue
            }
            if seen.insert(lower).inserted { out.append(lower) }
        }
        if out.count < 2 {
            let fallback = presets[defaultName]!
            return Resolved(chars: fallback.chars, leftHand: fallback.leftHand,
                            warning: "hints.keys must have at least 2 valid chars, falling back to <\(defaultName)>")
        }
        let warning = rejected.isEmpty ? nil : "Dropped invalid chars from hints.keys: \(String(rejected))"
        return Resolved(chars: out, leftHand: presets["qwerty"]!.leftHand, warning: warning)
    }
}

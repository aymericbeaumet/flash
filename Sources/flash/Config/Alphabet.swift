import Foundation

enum Alphabet {
    static let presets: [String: [Character]] = [
        "colemak": Array("arstneiogfplmuywvbckxjqzdh"),
        "qwerty":  Array("sadfjklewcmpghvtbynruo"),
        "dvorak":  Array("aoeuhtnspyfgcrlqjkxbmwvz"),
    ]

    static let defaultName = "colemak"

    static func resolve(_ raw: String?) -> (chars: [Character], warning: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (presets[defaultName]!, nil)
        }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            let name = String(trimmed.dropFirst().dropLast()).lowercased()
            if let chars = presets[name] {
                return (chars, nil)
            }
            return (presets[defaultName]!, "Unknown preset <\(name)>, falling back to <\(defaultName)>")
        }
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
            return (presets[defaultName]!, "hints.keys must have at least 2 valid chars, falling back to <\(defaultName)>")
        }
        let warning = rejected.isEmpty ? nil : "Dropped invalid chars from hints.keys: \(String(rejected))"
        return (out, warning)
    }
}

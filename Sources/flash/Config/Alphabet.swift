import Foundation

enum Alphabet {
  struct Resolved {
    let chars: [Character]
    /// Characters typed by the left hand on the inferred layout.
    /// Empty for literal strings, where Flash only knows the user's
    /// requested priority order and cannot infer physical hands.
    let leftHand: Set<Character>
    /// Per-key score. Higher scores are assigned first and contribute to
    /// multi-key labels.
    let keyScores: [Character: Int]
    let layoutName: String?
    let warning: String?
  }

  private enum Row: String, CaseIterable {
    case toprow
    case homerow
    case bottomrow
  }

  private enum Hand: String {
    case lefthand
    case righthand
  }

  private struct Layout {
    let rows: [Row: [Character]]
    let leftHand: Set<Character>
    let keyScores: [Character: Int]
  }

  private struct Selector {
    let layoutName: String
    let row: Row?
    let hand: Hand?
  }

  private static let layouts: [String: Layout] = [
    "colemak": Layout(
      rows: [
        .toprow: Array("qwfpgjluy"),
        .homerow: Array("arstdhneio"),
        .bottomrow: Array("zxcvbkm"),
      ],
      leftHand: Set("qwfpgarstdzxcvb"),
      keyScores: scoreGroups([
        ("arstneio", 100),
        ("dh", 94),
        ("wfpluy", 74),
        ("qgj", 62),
        ("zxcvbm", 54),
        ("k", 42),
      ])
    ),
    "qwerty": Layout(
      rows: [
        .toprow: Array("qwertyuiop"),
        .homerow: Array("asdfghjkl"),
        .bottomrow: Array("zxcvbnm"),
      ],
      leftHand: Set("qwertasdfgzxcvb"),
      keyScores: scoreGroups([
        ("sdfjkl", 100),
        ("agh", 92),
        ("erui", 76),
        ("wtyo", 66),
        ("cvbnm", 56),
        ("qzp", 38),
        ("x", 32),
      ])
    ),
    "dvorak": Layout(
      rows: [
        .toprow: Array("pyfgcrl"),
        .homerow: Array("aoeuidhtns"),
        .bottomrow: Array("qjkxbmwvz"),
      ],
      leftHand: Set("pyaoeuiqjkx"),
      keyScores: scoreGroups([
        ("aoeutns", 100),
        ("idh", 94),
        ("pyfcrl", 74),
        ("g", 62),
        ("qjkxbmwv", 54),
        ("z", 38),
      ])
    ),
  ]

  static let defaultKeys = "<qwerty_homerow+qwerty_toprow>"

  static func resolve(_ raw: String?) -> Resolved {
    let trimmed = (raw ?? "").trimmed
    if trimmed.isEmpty {
      return resolve(defaultKeys)
    }
    if isAngleToken(trimmed) {
      return resolveToken(String(trimmed.dropFirst().dropLast()).lowercased())
    }
    return resolveLiteral(trimmed)
  }

  private static func resolveToken(_ raw: String) -> Resolved {
    let rawParts = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard !rawParts.isEmpty, rawParts.allSatisfy({ !$0.isEmpty }) else {
      return fallback("hints.keys preset is empty, falling back to \(defaultKeys)")
    }

    var selectors: [Selector] = []
    for part in rawParts {
      guard let selector = parseSelector(part) else {
        return fallback("Unknown hints.keys preset <\(raw)>, falling back to \(defaultKeys)")
      }
      selectors.append(selector)
    }

    guard let layoutName = selectors.first?.layoutName,
      selectors.allSatisfy({ $0.layoutName == layoutName })
    else {
      return fallback("hints.keys cannot mix layouts, falling back to \(defaultKeys)")
    }
    guard let layout = layouts[layoutName] else {
      return fallback("Unknown hints.keys layout <\(layoutName)>, falling back to \(defaultKeys)")
    }

    var seen = Set<Character>()
    var charsWithOrdinal: [(Character, Int)] = []
    var ordinal = 0
    for selector in selectors {
      for ch in selectedChars(selector, layout: layout) where seen.insert(ch).inserted {
        charsWithOrdinal.append((ch, ordinal))
        ordinal += 1
      }
    }
    let chars = rankedLayoutChars(charsWithOrdinal, keyScores: layout.keyScores)
    if chars.count < 2 {
      return fallback("hints.keys preset <\(raw)> has too few keys, falling back to \(defaultKeys)")
    }
    return Resolved(
      chars: chars,
      leftHand: layout.leftHand,
      keyScores: layout.keyScores,
      layoutName: layoutName,
      warning: nil)
  }

  private static func parseSelector(_ raw: String) -> Selector? {
    let parts = raw.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
    guard let layoutName = parts.first, layouts[layoutName] != nil else { return nil }
    switch parts.count {
    case 1:
      return Selector(layoutName: layoutName, row: nil, hand: nil)
    case 2:
      if let row = Row(rawValue: parts[1]) {
        return Selector(layoutName: layoutName, row: row, hand: nil)
      }
      if let hand = Hand(rawValue: parts[1]) {
        return Selector(layoutName: layoutName, row: nil, hand: hand)
      }
      return nil
    case 3:
      guard let row = Row(rawValue: parts[1]),
        let hand = Hand(rawValue: parts[2])
      else {
        return nil
      }
      return Selector(layoutName: layoutName, row: row, hand: hand)
    default:
      return nil
    }
  }

  private static func selectedChars(_ selector: Selector, layout: Layout) -> [Character] {
    let rows = selector.row.map { [$0] } ?? [.homerow, .toprow, .bottomrow]
    var chars: [Character] = []
    for row in rows {
      let rowChars = layout.rows[row] ?? []
      switch selector.hand {
      case .none:
        chars += rowChars
      case .lefthand:
        chars += rowChars.filter { layout.leftHand.contains($0) }
      case .righthand:
        chars += rowChars.filter { !layout.leftHand.contains($0) }
      }
    }
    return chars
  }

  private static func rankedLayoutChars(
    _ chars: [(Character, Int)],
    keyScores: [Character: Int]
  ) -> [Character] {
    chars.sorted { a, b in
      let aScore = keyScores[a.0] ?? 0
      let bScore = keyScores[b.0] ?? 0
      if aScore != bScore { return aScore > bScore }
      return a.1 < b.1
    }
    .map(\.0)
  }

  private static func resolveLiteral(_ raw: String) -> Resolved {
    let literal = parseLiteralAlphabet(raw)
    guard literal.chars.count >= 2 else {
      return fallback("hints.keys must have at least 2 valid chars, falling back to \(defaultKeys)")
    }
    let warning =
      literal.rejected.isEmpty
      ? nil : "Dropped invalid chars from hints.keys: \(String(literal.rejected))"
    return Resolved(
      chars: literal.chars,
      leftHand: [],
      keyScores: literalScores(literal.chars),
      layoutName: nil,
      warning: warning)
  }

  private static func fallback(_ warning: String) -> Resolved {
    let resolved = resolve(defaultKeys)
    return Resolved(
      chars: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      layoutName: resolved.layoutName,
      warning: warning)
  }

  private static func isAngleToken(_ raw: String) -> Bool {
    raw.hasPrefix("<") && raw.hasSuffix(">") && raw.count >= 2
  }

  private static func parseLiteralAlphabet(_ raw: String) -> (
    chars: [Character], rejected: [Character]
  ) {
    var seen = Set<Character>()
    var out: [Character] = []
    var rejected: [Character] = []
    for ch in raw {
      let lower = Character(ch.lowercased())
      guard lower.isASCII, lower.isLetter || lower == ";" || lower == "'" else {
        rejected.append(ch)
        continue
      }
      if seen.insert(lower).inserted { out.append(lower) }
    }
    return (out, rejected)
  }

  private static func literalScores(_ chars: [Character]) -> [Character: Int] {
    var scores: [Character: Int] = [:]
    for (idx, ch) in chars.enumerated() {
      scores[ch] = chars.count - idx
    }
    return scores
  }

  private static func scoreGroups(_ groups: [(String, Int)]) -> [Character: Int] {
    var scores: [Character: Int] = [:]
    for (chars, base) in groups {
      for (offset, ch) in chars.enumerated() {
        scores[ch] = base - offset
      }
    }
    return scores
  }
}

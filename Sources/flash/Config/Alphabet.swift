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
    /// Physical matrix row of each layout key: number 0, top 1, home 2,
    /// bottom 3. Empty for a literal alphabet, which has no keyboard.
    let keyRows: [Character: Int]
    /// Physical matrix column of each layout key, 0 at the left. Empty for a
    /// literal alphabet, whose keys then sit in one row in written order.
    let keyColumns: [Character: Int]
    let layoutName: String?
    let warning: String?

    /// This alphabet with `[hints] key_priority` applied: the listed keys
    /// outrank every other key, in the order written, and the rest keep
    /// their layout ease behind them. Keys the alphabet does not hold are
    /// ignored; `prepareDerivedValues` reports them. An empty priority is
    /// the alphabet itself.
    func prioritizing(_ priority: String) -> Resolved {
      let listed = Alphabet.priorityKeys(priority).filter { chars.contains($0) }
      guard !listed.isEmpty else { return self }
      var scores = keyScores
      let ceiling = (keyScores.values.max() ?? 0) + 1
      for (index, key) in listed.enumerated() {
        scores[key] = ceiling + listed.count - index
      }
      let order = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($1, $0) })
      let ranked = chars.sorted { a, b in
        let aScore = scores[a] ?? 0
        let bScore = scores[b] ?? 0
        if aScore != bScore { return aScore > bScore }
        return (order[a] ?? 0) < (order[b] ?? 0)
      }
      return Resolved(
        chars: ranked, leftHand: leftHand, keyScores: scores, keyRows: keyRows,
        keyColumns: keyColumns, layoutName: layoutName, warning: warning)
    }

    /// The `[hints] key_priority` keys this alphabet cannot label with.
    func unknownPriorityKeys(_ priority: String) -> [Character] {
      Alphabet.priorityKeys(priority).filter { !chars.contains($0) }
    }
  }

  /// The distinct keys of a `[hints] key_priority` string, lowercased, in
  /// written order. Whitespace separates nothing and is skipped.
  static func priorityKeys(_ priority: String) -> [Character] {
    var seen = Set<Character>()
    var keys: [Character] = []
    for raw in priority where !raw.isWhitespace {
      let key = Character(raw.lowercased())
      if seen.insert(key).inserted { keys.append(key) }
    }
    return keys
  }

  enum Row: String, CaseIterable {
    case toprow
    case homerow
    case bottomrow
  }

  private enum Hand: String {
    case lefthand
    case righthand
  }

  struct Layout {
    /// Every key at its physical position, 4 rows × 10 columns: the number
    /// row, then the top, home and bottom rows, left to right.
    let physical: [[Character]]
    let keyScores: [Character: Int]
    /// Matrix row of every key, including the number row and punctuation.
    /// This is the row index, not the ease band: bottom outranks top in
    /// `keyScores`, but a home-to-top jump is still one row.
    let keyRows: [Character: Int]
    /// Matrix column of every key, 0 at the left.
    let keyColumns: [Character: Int]
    /// The letters of the top, home and bottom rows, for hint selectors.
    let rows: [Row: [Character]]
    /// The letters in the left five columns of those rows.
    let leftHand: Set<Character>

    init(physical rows: [String]) {
      let physical = rows.map(Array.init)
      self.physical = physical
      var scores: [Character: Int] = [:]
      var keyRows: [Character: Int] = [:]
      var keyColumns: [Character: Int] = [:]
      for (row, keys) in physical.enumerated() {
        for (column, key) in keys.enumerated() {
          scores[key] = Alphabet.physicalKeyScore(row: row, column: column)
          keyRows[key] = row
          keyColumns[key] = column
        }
      }
      self.keyScores = scores
      self.keyRows = keyRows
      self.keyColumns = keyColumns
      self.rows = [
        .toprow: physical[1].filter(\.isLetter),
        .homerow: physical[2].filter(\.isLetter),
        .bottomrow: physical[3].filter(\.isLetter),
      ]
      self.leftHand = Set(physical.dropFirst().flatMap { $0.prefix(5).filter(\.isLetter) })
    }
  }

  /// Ease of the key at `row` and `column` of a layout's 4×10 matrix.
  /// Higher is easier. The row decides the band, and every key in a band
  /// outranks every key in the next: home, then bottom, then top, then the
  /// number row. Within a row the column is the finger that owns it
  /// (pinky 0, ring 1, middle 2, index 3) times 10, minus 15 when that
  /// finger reaches inward (columns 4 and 5). The left key of a mirrored
  /// pair scores one point higher, so the order is total.
  static func physicalKeyScore(row: Int, column: Int) -> Int {
    let rowBase: Int
    switch row {
    case 2: rowBase = 300
    case 3: rowBase = 200
    case 1: rowBase = 100
    default: rowBase = 0
    }
    let finger = [0, 1, 2, 3, 3, 3, 3, 2, 1, 0]
    guard column >= 0, column < finger.count else { return rowBase }
    let reach = column == 4 || column == 5 ? 1 : 0
    let ease = finger[column] * 10 - reach * 15 + (column < 5 ? 1 : 0)
    return rowBase + ease
  }

  private struct Selector {
    let layoutName: String
    let row: Row?
    let hand: Hand?
  }

  private static let qwerty = Layout(
    physical: ["1234567890", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"])

  static let layouts: [String: Layout] = [
    "colemak": Layout(
      physical: ["1234567890", "qwfpgjluy;", "arstdhneio", "zxcvbkm,./"]),
    "qwerty": qwerty,
    "dvorak": Layout(
      physical: ["1234567890", "',.pyfgcrl", "aoeuidhtns", ";qjkxbmwvz"]),
    // ANSI first ten columns of bépo. The number row is the unshifted
    // symbols; digits are Shift. `^` is a dead key.
    "bepo": Layout(
      physical: ["$\"«»()@+-/", "bépoè^vdlj", "auie,ctsrn", "àyx.k'qghf"]),
  ]

  /// One physical key. `character` is what the layout types there. `ansi`
  /// is the QWERTY name of that key, used when the character is not a letter.
  struct Key: Equatable {
    var character: Character
    var ansi: Character
  }

  struct Cluster: Equatable {
    var left: Key
    var down: Key
    var up: Key
    var right: Key
  }

  /// Home-row columns 5–8 are the vim cluster (left, down, up, right).
  /// `esdf` is the QWERTY E/S/D/F positions (up, left, down, right). F is
  /// the home-row index-finger mark, so the right arrow sits on that bump.
  /// Quadrants are the QWERTY y/u and b/n keys on that layout.
  /// `left`/`down`/`up`/`right` stay the vim cluster for bisect and pointer
  /// movement. HYPER arrows use `esdf` only.
  struct Navigation: Equatable {
    var quadrants: [[Character]]
    var left: Character
    var down: Character
    var up: Character
    var right: Character
    var esdf: Cluster

    static let qwerty = Navigation(
      quadrants: [["y", "u"], ["b", "n"]],
      left: "h", down: "j", up: "k", right: "l",
      esdf: Cluster(
        left: Key(character: "s", ansi: "s"),
        down: Key(character: "d", ansi: "d"),
        up: Key(character: "e", ansi: "e"),
        right: Key(character: "f", ansi: "f")))
  }

  static var layoutNames: [String] { layouts.keys.sorted() }

  /// `layoutName` nil or unknown uses QWERTY. Callers that already resolved
  /// a hint selector pass that name; otherwise they pass `[keyboard] layout`.
  static func navigation(layoutName: String?) -> Navigation {
    let layout = layoutName.flatMap { layouts[$0] } ?? qwerty
    let top = layout.physical[1]
    let home = layout.physical[2]
    let bottom = layout.physical[3]
    guard top.count >= 7, home.count >= 9, bottom.count >= 6 else { return .qwerty }
    let qwertyTop = qwerty.physical[1]
    let qwertyHome = qwerty.physical[2]
    func key(_ keys: [Character], _ ansi: [Character], _ index: Int) -> Key {
      Key(character: keys[index], ansi: ansi[index])
    }
    return Navigation(
      quadrants: [[top[5], top[6]], [bottom[4], bottom[5]]],
      left: home[5], down: home[6], up: home[7], right: home[8],
      esdf: Cluster(
        left: key(home, qwertyHome, 1),
        down: key(home, qwertyHome, 2),
        up: key(top, qwertyTop, 2),
        right: key(home, qwertyHome, 3)))
  }

  /// The mouse grid's keys: the left-hand 4×5 block of the layout's keyboard
  /// (number, top, home and bottom rows), so each screen cell sits where its
  /// key does. A literal `hints.keys` has no layout, so it gets QWERTY's.
  static func gridKeys(layoutName: String?) -> [[Character]] {
    let layout = layoutName.flatMap { layouts[$0] } ?? qwerty
    return layout.physical.map { Array($0.prefix(5)) }
  }

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
      keyRows: layout.keyRows,
      keyColumns: layout.keyColumns,
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
      keyRows: [:],
      keyColumns: [:],
      layoutName: nil,
      warning: warning)
  }

  private static func fallback(_ warning: String) -> Resolved {
    let resolved = resolve(defaultKeys)
    return Resolved(
      chars: resolved.chars,
      leftHand: resolved.leftHand,
      keyScores: resolved.keyScores,
      keyRows: resolved.keyRows,
      keyColumns: resolved.keyColumns,
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

}

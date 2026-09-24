import Foundation

/// `hints.mouse_grid_keys`: the keys labelling the mouse grid, one string per
/// keyboard row, top row first. Each cell carries the key at the same position
/// in this matrix, so the screen maps onto the keyboard. Empty (the default)
/// derives the left-hand block of the `hints.keys` layout.
enum MouseGridKeys {
  /// Grid-owned keys that cannot label a cell: `` ` `` toggles cursor-follow
  /// (`MouseGridInputInterpreter`).
  static let reserved: Set<Character> = ["`"]

  enum Problem: Equatable {
    case tooFewRows
    case tooFewColumns
    case unevenRows
    case whitespace
    case reserved(Character)
    case duplicate(Character)

    var message: String {
      let prefix = "hints.mouse_grid_keys"
      switch self {
      case .tooFewRows: return "\(prefix) needs at least 2 rows"
      case .tooFewColumns: return "\(prefix) needs at least 2 keys per row"
      case .unevenRows: return "\(prefix) rows must all have the same number of keys"
      case .whitespace: return "\(prefix) cannot contain whitespace"
      case .reserved(let key): return "\(prefix) cannot use '\(key)', which the grid reserves"
      case .duplicate(let key): return "\(prefix) uses '\(key)' more than once"
      }
    }
  }

  /// Why `rows` cannot label a grid, or nil when it can. Empty is valid: it
  /// means "derive from `hints.keys`".
  static func problem(in rows: [String]) -> Problem? {
    guard !rows.isEmpty else { return nil }
    let matrix = self.matrix(rows)
    guard matrix.count >= 2 else { return .tooFewRows }
    let columns = matrix[0].count
    guard columns >= 2 else { return .tooFewColumns }
    guard matrix.allSatisfy({ $0.count == columns }) else { return .unevenRows }
    var seen = Set<Character>()
    for key in matrix.joined() {
      if key.isWhitespace || key.isNewline { return .whitespace }
      if reserved.contains(key) { return .reserved(key) }
      guard seen.insert(key).inserted else { return .duplicate(key) }
    }
    return nil
  }

  /// The grid's key matrix: the configured rows lowercased, or the layout's
  /// left-hand block when none are configured.
  static func resolve(_ rows: [String], layoutName: String?) -> [[Character]] {
    rows.isEmpty ? Alphabet.gridKeys(layoutName: layoutName) : matrix(rows)
  }

  private static func matrix(_ rows: [String]) -> [[Character]] {
    rows.map { Array($0.lowercased()) }
  }
}

import Foundation

/// Vim's command-line editing keys over the `:` line, pure: the text and
/// the caret (a character offset) after `ctrl+w`, `ctrl+u` or `ctrl+r {x}`.
/// The prompt's leading `:` is never deleted.
enum CommandLineEditing {
  struct Line: Equatable {
    var text: String
    var cursor: Int
  }

  /// `ctrl+w`: the word before the caret, with the blanks between them, as
  /// Vim deletes it: a run of letters, digits and `_`, or a run of other
  /// characters (`--`, `=`).
  static func deleteWordBackward(_ line: Line) -> Line {
    let characters = Array(line.text)
    let cursor = min(max(line.cursor, 0), characters.count)
    let floor = promptEnd(characters)
    var start = cursor
    while start > floor, characters[start - 1].isWhitespace { start -= 1 }
    if start > floor {
      let word = isWordCharacter(characters[start - 1])
      while start > floor, !characters[start - 1].isWhitespace,
        isWordCharacter(characters[start - 1]) == word
      {
        start -= 1
      }
    }
    return Line(
      text: String(characters[..<start] + characters[cursor...]), cursor: start)
  }

  /// `ctrl+u`: everything between the prompt and the caret.
  static func deleteToStart(_ line: Line) -> Line {
    let characters = Array(line.text)
    let cursor = min(max(line.cursor, 0), characters.count)
    let floor = min(promptEnd(characters), cursor)
    return Line(text: String(characters[..<floor] + characters[cursor...]), cursor: floor)
  }

  /// `ctrl+r {x}`: `inserted` (register `x`'s text) at the caret, on one
  /// line: each line break becomes a space.
  static func insert(_ inserted: String, into line: Line) -> Line {
    let flat = inserted.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
    let characters = Array(line.text)
    let cursor = min(max(line.cursor, promptEnd(characters)), characters.count)
    return Line(
      text: String(characters[..<cursor]) + flat + String(characters[cursor...]),
      cursor: cursor + flat.count)
  }

  /// The register name typed after `ctrl+r`: the one character `after`
  /// adds to `before` at its caret, or nil when the edit was anything else.
  static func registerName(typedInto before: Line, giving after: String) -> Character? {
    let old = Array(before.text)
    let new = Array(after)
    let cursor = min(max(before.cursor, 0), old.count)
    guard new.count == old.count + 1, Array(new[..<cursor]) == Array(old[..<cursor]),
      Array(new[(cursor + 1)...]) == Array(old[cursor...])
    else { return nil }
    return new[cursor]
  }

  private static func promptEnd(_ characters: [Character]) -> Int {
    characters.first == ":" ? 1 : 0
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
  }
}

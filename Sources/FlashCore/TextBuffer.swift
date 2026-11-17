import Foundation

/// A snapshot of focused text, measured the way Accessibility measures it:
/// every offset is a UTF-16 offset, as `AXSelectedTextRange`,
/// `AXNumberOfCharacters` and `AXStringForRange` count. Lines end at a line
/// break (`\n`, `\r`, `\r\n` as one break, vertical tab, form feed, NEL,
/// U+2028 and U+2029); characters are Swift `Character`s, extended grapheme
/// clusters, so a step never splits an emoji, a flag or a letter and its
/// combining marks. Pure: NORMAL's cursor keys, `s` `S` `C` and the Vim
/// motions read it off the main thread.
public struct TextBuffer: Sendable {
  public let string: String
  /// The text's UTF-16 code units; `units.count` is the text's length.
  public let units: [UInt16]

  public init(_ string: String) {
    self.string = string
    self.units = Array(string.utf16)
  }

  public var length: Int { units.count }

  /// One line: `start` is its first unit, `end` the offset of its line
  /// break (or of the text's end), `next` the first unit after the break,
  /// which is `end` on a last line without one.
  public struct Line: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let next: Int

    public init(start: Int, end: Int, next: Int) {
      self.start = start
      self.end = end
      self.next = next
    }

    /// No characters before the break.
    public var isEmpty: Bool { start == end }
    /// Whether a line break ends it.
    public var hasBreak: Bool { next > end }
  }

  /// The line holding `offset`, clamped into the text. An offset on a line
  /// break belongs to the line the break ends; the text's end belongs to
  /// the last line, an empty one after a trailing break.
  public func line(containing offset: Int) -> Line {
    let offset = min(max(offset, 0), length)
    var start = offset
    while start > 0 {
      let previous = units[start - 1]
      if Self.isLineBreak(previous) { break }
      start -= 1
    }
    // A `\r\n` pair is one break: an offset between its two units sits on
    // the break that ends the line before it.
    if offset > 0, offset < length, units[offset - 1] == Self.carriageReturn,
      units[offset] == Self.lineFeed
    {
      return line(containing: offset - 1)
    }
    return lineStarting(at: start)
  }

  /// The line that begins at `start`, a line's first unit.
  public func lineStarting(at start: Int) -> Line {
    var end = start
    while end < length, !Self.isLineBreak(units[end]) { end += 1 }
    var next = end
    if end < length {
      next = end + 1
      if units[end] == Self.carriageReturn, next < length, units[next] == Self.lineFeed {
        next += 1
      }
    }
    return Line(start: start, end: end, next: next)
  }

  /// The line after `line`; nil on the last line.
  public func line(after line: Line) -> Line? {
    line.hasBreak ? lineStarting(at: line.next) : nil
  }

  /// The line before `line`; nil on the first line.
  public func line(before line: Line) -> Line? {
    line.start > 0 ? self.line(containing: line.start - 1) : nil
  }

  /// The first unit of `line` that is not a blank (space, tab or another
  /// horizontal space), or its end when it has none.
  public func firstNonBlank(of line: Line) -> Int {
    var offset = line.start
    while offset < line.end, Self.isBlank(units[offset]) { offset += 1 }
    return offset
  }

  /// The characters of `range`, each with where it starts and how many
  /// units it spans. `range` must start and end on character boundaries,
  /// as a line's bounds do.
  public func characters(in range: Range<Int>) -> [Span] {
    let lower = min(max(range.lowerBound, 0), length)
    let upper = min(max(range.upperBound, lower), length)
    guard lower < upper else { return [] }
    let from = String.Index(utf16Offset: lower, in: string)
    let to = String.Index(utf16Offset: upper, in: string)
    var spans: [Span] = []
    var offset = lower
    for character in string[from..<to] {
      let width = character.utf16.count
      spans.append(Span(offset: offset, length: width, character: character))
      offset += width
    }
    return spans
  }

  /// The characters of `line`, its break excluded.
  public func characters(of line: Line) -> [Span] {
    characters(in: line.start..<line.end)
  }

  /// One character of the text and where it sits.
  public struct Span: Equatable, Sendable {
    public let offset: Int
    public let length: Int
    public let character: Character

    public init(offset: Int, length: Int, character: Character) {
      self.offset = offset
      self.length = length
      self.character = character
    }

    public var end: Int { offset + length }
  }

  /// The start of the character holding `offset` on its line: the offset
  /// itself on a boundary, the cluster's start inside one, the line's end
  /// past its last character.
  public func characterStart(atOrBefore offset: Int) -> Int {
    let line = line(containing: offset)
    let clamped = min(max(offset, line.start), line.end)
    guard clamped < line.end else { return line.end }
    var start = line.start
    for span in characters(of: line) {
      if span.offset > clamped { break }
      start = span.offset
    }
    return start
  }

  static let lineFeed: UInt16 = 0x0A
  static let carriageReturn: UInt16 = 0x0D

  /// `\n`, `\r`, vertical tab, form feed, NEL, line and paragraph separator.
  public static func isLineBreak(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
    default: return false
    }
  }

  /// Horizontal white space: space, tab, no-break space and the other
  /// Unicode space separators. Never a line break.
  public static func isBlank(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x20, 0x09, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
  }
}

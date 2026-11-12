/// A Vim motion, as NORMAL and Visual mode type it. `TextMotionEngine` moves
/// a cursor by one over a `TextBuffer` the way Vim 9 moves its cursor over a
/// buffer (`:help motion.txt`); each case names the keys it stands for.
public enum TextMotion: Hashable, Sendable {
  /// `h`: count characters left, never leaving the line.
  case left
  /// `l`: count characters right, never past the line's last character; in
  /// Visual mode at most onto the line's break, as Vim's inclusive
  /// selection allows.
  case right
  /// `j`: count logical lines down, landing on the desired column or on the
  /// line's last character.
  case down
  /// `k`: count logical lines up, like `down`.
  case up
  /// `w`, or `W` when `big`: the start of the count-th next word. An empty
  /// line counts as a word.
  case nextWord(big: Bool)
  /// `b`, or `B`: the start of the count-th previous word, or of the word
  /// the cursor is inside. An empty line counts as a word.
  case previousWord(big: Bool)
  /// `e`, or `E`: the end of the count-th word, moving at least one
  /// character. Empty lines are skipped.
  case wordEnd(big: Bool)
  /// `ge`, or `gE`: the end of the count-th previous word. An empty line
  /// counts as a word end.
  case previousWordEnd(big: Bool)
  /// `0`: the line's first character.
  case lineStart
  /// `^`: the line's first non-blank character.
  case firstNonBlank
  /// `$`: the last character of the line count - 1 lines down.
  case lineEnd
  /// `g_`: the last non-blank character of the line count - 1 lines down.
  case lastNonBlank
  /// `|`: the count-th character of the line, the first without a count.
  case column
  /// `gg`: the first non-blank of line count, the first line without one.
  case firstLine
  /// `G`: the first non-blank of line count, the last line without one.
  case lastLine
  /// `{count}%`: the first non-blank of the line count percent through the
  /// text. Needs a count from 1 to 100.
  case percent
  /// `%` without a count: the bracket matching the first of `( ) [ ] { }`
  /// at or after the cursor on its line.
  case matchingBracket
  /// `}`: the count-th next paragraph boundary, an empty line.
  case nextParagraph
  /// `{`: the count-th previous paragraph boundary.
  case previousParagraph
  /// `)`: the start of the count-th next sentence.
  case nextSentence
  /// `(`: the start of the count-th previous sentence, counting the one the
  /// cursor is inside.
  case previousSentence
  /// `+` and `<CR>`: the first non-blank count lines down.
  case nextLineFirstNonBlank
  /// `-`: the first non-blank count lines up.
  case previousLineFirstNonBlank
  /// `_`: the first non-blank count - 1 lines down.
  case lineFirstNonBlank
  /// `H`: the first non-blank of the count-th visible line from the top.
  case screenTop
  /// `M`: the first non-blank of the middle visible line.
  case screenMiddle
  /// `L`: the first non-blank of the count-th visible line from the bottom.
  case screenBottom
  /// `f` `F` `t` `T`: the count-th occurrence of a character on the line.
  case find(TextCharacterSearch)
}

/// What `f`, `F`, `t` and `T` look for: one character, searched forward or
/// backward on the cursor's line, landing on it or, for `t` and `T` (`till`),
/// on the character just before it in the search's direction.
public struct TextCharacterSearch: Hashable, Sendable {
  public var character: Character
  public var forward: Bool
  public var till: Bool

  public init(character: Character, forward: Bool, till: Bool) {
    self.character = character
    self.forward = forward
    self.till = till
  }

  /// The search `,` runs: the same character, the other direction.
  public var reversed: TextCharacterSearch {
    TextCharacterSearch(character: character, forward: !forward, till: till)
  }
}

/// Where a motion lands.
public struct TextMotionTarget: Equatable, Sendable {
  /// The UTF-16 offset of the character the cursor lands on: a character
  /// start, an empty line's start, or in Visual mode possibly a line's
  /// `end` (the cursor just past its last character).
  public let offset: Int
  /// Vim's curswant: the column a following j/k aims for, in characters
  /// from the line start; `Int.max` after `$` (stay at line ends).
  public let desiredColumn: Int

  public init(offset: Int, desiredColumn: Int) {
    self.offset = offset
    self.desiredColumn = desiredColumn
  }
}

/// Vim's motions over a text snapshot. Vim's NORMAL cursor sits on a
/// character where macOS draws a caret between two: the cursor on the
/// character starting at offset `i` is the caret at `i`, so every motion
/// answers a character start, never an offset inside a grapheme cluster or a
/// `\r\n` pair. Lines are Vim's: a trailing line break ends the last line
/// rather than opening an empty one after it, so `G`, `j` and `+` never reach
/// that empty line (two trailing breaks do make an empty last line). Pure, so
/// it runs off the main thread; a call walks only the lines it needs, except
/// the motions that number lines (`gg` `G` `{count}%`) and `%`'s bracket scan.
public enum TextMotionEngine {
  /// Where `motion` moves the cursor at UTF-16 offset `cursor`. `count` is
  /// the typed count, nil without one (most motions then move once; `G`,
  /// `gg`, `|` and `%` read their absence). The cursor may sit anywhere,
  /// including just past a line's last character (its `end`); an offset
  /// inside a cluster counts as that cluster's start.
  ///
  /// - `visible`: the visible character range, which `H` `M` `L` need.
  /// - `desiredColumn`: the curswant a previous motion returned, which `j`
  ///   and `k` aim for; without it they keep the cursor's column.
  /// - `isRepeat`: `find` repeated by `;` or `,` (pass the search reversed
  ///   for `,`). A repeated `t` or `T` then skips a match next to the cursor
  ///   so the repeat makes progress, as Vim does without `;` in cpoptions.
  /// - `inVisual`: Visual mode, where the cursor may also rest just past a
  ///   line's last character: `$` lands there, and `l`, `j`, `k`, `|`, `w`
  ///   and `e` may as Vim's inclusive selection lets them. `TextSelection`
  ///   includes the line break of such a position.
  ///
  /// Nil when Vim would not move (it beeps): `b` at the text's start, `f`
  /// without a match, `j` on the last line, `H` without a visible range, an
  /// empty text. A count larger than the text allows moves as far as it can
  /// (except `f` `t` `F` `T`, which fail as a whole like Vim's), and
  /// motions Vim never beeps for (`0`, `^`, `}` on the last line) answer
  /// their target even when it is the cursor itself.
  public static func target(
    of motion: TextMotion, count: Int?, from cursor: Int, in buffer: TextBuffer,
    visible: Range<Int>? = nil, desiredColumn: Int? = nil, isRepeat: Bool = false,
    inVisual: Bool = false
  ) -> TextMotionTarget? {
    guard buffer.length > 0 else { return nil }
    let text = MotionText(buffer: buffer, inVisual: inVisual)
    let start = text.position(at: cursor)
    // A zero or negative count is no count, as Vim's count0 of zero is.
    let typed = count.flatMap { $0 > 0 ? $0 : nil }
    let times = typed ?? 1
    switch motion {
    case .left:
      return text.left(from: start, count: times)
    case .right:
      return text.right(from: start, count: times)
    case .down, .up:
      return text.vertical(
        from: start, count: times, down: motion == .down, desiredColumn: desiredColumn)
    case .nextWord(let big):
      return text.wordMotion(from: start, forward: true) {
        text.forwardWord(&$0, count: times, big: big)
      }
    case .previousWord(let big):
      return text.wordMotion(from: start, forward: false) {
        text.backwardWord(&$0, count: times, big: big)
      }
    case .wordEnd(let big):
      return text.wordMotion(from: start, forward: true) {
        text.forwardWordEnd(&$0, count: times, big: big)
      }
    case .previousWordEnd(let big):
      return text.wordMotion(from: start, forward: false) {
        text.backwardWordEnd(&$0, count: times, big: big)
      }
    case .lineStart:
      return text.target(start.line.start, in: start.line)
    case .firstNonBlank:
      return text.target(text.firstNonBlank(of: start.line), in: start.line)
    case .lineEnd:
      guard let line = text.lineDown(from: start.line, count: times - 1) else { return nil }
      let offset = inVisual ? line.end : text.lastCharacter(of: line)
      return TextMotionTarget(offset: offset, desiredColumn: Int.max)
    case .lastNonBlank:
      guard let line = text.lineDown(from: start.line, count: times - 1) else { return nil }
      return text.target(text.lastNonBlank(of: line), in: line)
    case .column:
      // Vim's `|` counts screen columns; here every character, a tab
      // included, is one column. The desired column stays the one asked
      // for, even past a shorter line's end.
      let column = times - 1
      let offset = text.offset(ofColumn: column, in: start.line, allowEnd: inVisual)
      return TextMotionTarget(offset: offset, desiredColumn: column)
    case .firstLine:
      return text.lineTarget(text.line(number: typed ?? 1))
    case .lastLine:
      return text.lineTarget(typed.map { text.line(number: $0) } ?? text.lastLine)
    case .percent:
      guard let typed, typed <= 100 else { return nil }
      return text.lineTarget(text.line(number: (typed * text.lineCount + 99) / 100))
    case .matchingBracket:
      return text.matchingBracket(from: start)
    case .nextParagraph, .previousParagraph:
      return text.paragraph(from: start, count: times, forward: motion == .nextParagraph)
    case .nextSentence, .previousSentence:
      guard
        let position = text.sentence(from: start, count: times, forward: motion == .nextSentence)
      else { return nil }
      return text.target(text.settled(position))
    case .nextLineFirstNonBlank:
      return text.lineDown(from: start.line, count: times).map(text.lineTarget)
    case .previousLineFirstNonBlank:
      return text.lineUp(from: start.line, count: times).map(text.lineTarget)
    case .lineFirstNonBlank:
      return text.lineDown(from: start.line, count: times - 1).map(text.lineTarget)
    case .screenTop, .screenMiddle, .screenBottom:
      guard let visible else { return nil }
      let lines = text.visibleLines(in: visible)
      let index: Int
      switch motion {
      case .screenTop: index = min(times, lines.count) - 1
      case .screenBottom: index = lines.count - min(times, lines.count)
      default: index = (lines.count + 1) / 2 - 1
      }
      return text.lineTarget(lines[index])
    case .find(let search):
      return text.find(search, from: start, count: times, isRepeat: isRepeat)
    }
  }
}

/// Visual mode's selected range, as a UTF-16 range to hand to
/// AXSelectedTextRange.
public enum TextSelection {
  /// `v`: from the earlier of anchor/cursor through the later one's character,
  /// inclusive. If that last position is on a line break (an empty line, or
  /// `line.end` after `$` in Visual mode) the break is included (through
  /// `line.next`); at the text's end the range ends there.
  public static func charwise(anchor: Int, cursor: Int, in buffer: TextBuffer) -> Range<Int> {
    guard buffer.length > 0 else { return 0..<0 }
    let text = MotionText(buffer: buffer, inVisual: true)
    let anchor = text.position(at: anchor)
    let cursor = text.position(at: cursor)
    let (first, last) = anchor.offset <= cursor.offset ? (anchor, cursor) : (cursor, anchor)
    let upper =
      last.offset < last.line.end ? text.nextStart(last.offset) : last.line.next
    return first.offset..<upper
  }

  /// `V`: every line from the anchor's through the cursor's, whole, with the
  /// last line's break (through its `next`); a last line without a break ends
  /// at the text's end. The empty line after a trailing break, which Vim has
  /// no line for, selects the last line instead.
  public static func linewise(anchor: Int, cursor: Int, in buffer: TextBuffer) -> Range<Int> {
    guard buffer.length > 0 else { return 0..<0 }
    let text = MotionText(buffer: buffer, inVisual: true)
    let anchor = text.vimLine(text.position(at: anchor).line)
    let cursor = text.vimLine(text.position(at: cursor).line)
    return min(anchor.start, cursor.start)..<max(anchor.next, cursor.next)
  }
}

/// A place Vim's cursor can be while a motion walks: a character start, or
/// a line's `end`, the line break that Vim reads as the NUL after the line's
/// last character (an empty line's only position).
private struct Position {
  var line: TextBuffer.Line
  var offset: Int

  var isOnBreak: Bool { offset >= line.end }
}

/// How one step of Vim's inc() and dec() went.
private enum Step {
  /// To another character of the same line.
  case within
  /// Forward from the last character onto the line's break.
  case ontoBreak
  /// Onto another line: its start forward, its break backward.
  case crossedLine
  /// Nowhere: the text's start or end.
  case edge
}

/// The motions' walk over one buffer, in Vim's terms: lines are Vim's lines
/// (no empty line after a trailing break), positions are `Position`s, and
/// each algorithm follows its Vim 9 counterpart in search.c, textobject.c or
/// normal.c.
private struct MotionText {
  typealias Line = TextBuffer.Line

  let buffer: TextBuffer
  let inVisual: Bool

  var string: String { buffer.string }
  var length: Int { buffer.length }

  // MARK: Lines

  /// The empty line after a trailing break, which Vim has no line for. Only
  /// an input cursor sits there; motions never move onto it.
  func isPastLastLine(_ line: Line) -> Bool {
    line.start == length && length > 0
  }

  /// The line after `line`, nil on Vim's last line.
  func lineAfter(_ line: Line) -> Line? {
    guard line.hasBreak, line.next < length else { return nil }
    return buffer.lineStarting(at: line.next)
  }

  /// The line before `line`, nil on the first.
  func lineBefore(_ line: Line) -> Line? {
    buffer.line(before: line)
  }

  /// `line`, or Vim's last line for the empty line after a trailing break.
  func vimLine(_ line: Line) -> Line {
    isPastLastLine(line) ? (lineBefore(line) ?? line) : line
  }

  /// Vim's last line.
  var lastLine: Line {
    vimLine(buffer.line(containing: length))
  }

  /// How many lines Vim sees: a break opens a line only when text follows it.
  var lineCount: Int {
    let units = buffer.units
    var count = 1
    var index = 0
    while index < units.count {
      let unit = units[index]
      if TextBuffer.isLineBreak(unit) {
        if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
        if index + 1 < units.count { count += 1 }
      }
      index += 1
    }
    return count
  }

  /// Line `number`, 1-based, clamped to the first and last lines.
  func line(number: Int) -> Line {
    var line = buffer.lineStarting(at: 0)
    var remaining = number
    while remaining > 1, let next = lineAfter(line) {
      line = next
      remaining -= 1
    }
    return line
  }

  /// Vim's cursor_down: `count` lines down, as far as there are lines; nil
  /// when a move is needed and the cursor is already on the last line.
  func lineDown(from line: Line, count: Int) -> Line? {
    guard count > 0 else { return line }
    guard var current = lineAfter(line) else { return nil }
    var moved = 1
    while moved < count, let next = lineAfter(current) {
      current = next
      moved += 1
    }
    return current
  }

  /// Vim's cursor_up, like `lineDown` towards the first line.
  func lineUp(from line: Line, count: Int) -> Line? {
    guard count > 0 else { return line }
    guard var current = lineBefore(line) else { return nil }
    var moved = 1
    while moved < count, let previous = lineBefore(current) {
      current = previous
      moved += 1
    }
    return current
  }

  /// The lines `H` `M` `L` choose from: those starting inside `visible`, or
  /// the line holding its start when none does.
  func visibleLines(in visible: Range<Int>) -> [Line] {
    let lower = min(max(visible.lowerBound, 0), length)
    let upper = min(max(visible.upperBound, lower), length)
    let holding = buffer.line(containing: lower)
    var lines: [Line] = []
    var line: Line? = holding.start < lower ? lineAfter(holding) : holding
    while let current = line, current.start < upper, !isPastLastLine(current) {
      lines.append(current)
      line = lineAfter(current)
    }
    return lines.isEmpty ? [vimLine(holding)] : lines
  }

  // MARK: Characters

  func index(_ offset: Int) -> String.Index {
    String.Index(utf16Offset: offset, in: string)
  }

  /// The start of the character after the one starting at `offset`.
  func nextStart(_ offset: Int) -> Int {
    let index = index(offset)
    return offset + string.utf16.distance(from: index, to: string.index(after: index))
  }

  /// The start of the character before `offset`, a character start or a
  /// line's end after the line's start.
  func previousStart(_ offset: Int) -> Int {
    let index = index(offset)
    return offset - string.utf16.distance(from: string.index(before: index), to: index)
  }

  /// The start of the character holding `offset` on `line`, or the line's
  /// end past its last character. Swift rounds an index inside a cluster
  /// down to the cluster's start, which only looks at the nearby scalars.
  func characterStart(atOrBefore offset: Int, in line: Line) -> Int {
    if offset >= line.end { return line.end }
    if offset <= line.start { return line.start }
    let rounded = string.index(before: string.index(after: index(offset)))
    return rounded.utf16Offset(in: string)
  }

  /// `cursor` as a position: clamped into the text, a `\r\n` pair's inside
  /// on its break, a cluster's inside on its start.
  func position(at cursor: Int) -> Position {
    let offset = min(max(cursor, 0), length)
    let line = buffer.line(containing: offset)
    return Position(line: line, offset: characterStart(atOrBefore: offset, in: line))
  }

  /// The first Unicode scalar of the character starting at `offset`, the
  /// one Vim's class and punctuation checks read.
  func scalar(at offset: Int) -> Unicode.Scalar {
    let units = buffer.units
    let lead = units[offset]
    if UTF16.isLeadSurrogate(lead), offset + 1 < units.count,
      UTF16.isTrailSurrogate(units[offset + 1])
    {
      let value = 0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(units[offset + 1]) - 0xDC00)
      return Unicode.Scalar(value) ?? "\u{FFFD}"
    }
    return Unicode.Scalar(lead) ?? "\u{FFFD}"
  }

  /// Vim's gchar_pos(): the character's first scalar, nil on a line break
  /// (Vim's NUL).
  func scalar(at position: Position) -> Unicode.Scalar? {
    position.isOnBreak ? nil : scalar(at: position.offset)
  }

  /// The character count from `line`'s start to `offset`: Vim's column, in
  /// characters rather than screen cells.
  func column(of offset: Int, in line: Line) -> Int {
    guard offset > line.start else { return 0 }
    return string.distance(from: index(line.start), to: index(offset))
  }

  /// The character at `column` on `line`, or its last character when the
  /// line is shorter (its end when `allowEnd`, Visual mode's one more).
  func offset(ofColumn column: Int, in line: Line, allowEnd: Bool) -> Int {
    guard !line.isEmpty else { return line.start }
    var offset = line.start
    var remaining = column
    while remaining > 0 {
      let next = nextStart(offset)
      if next >= line.end { return allowEnd ? line.end : offset }
      offset = next
      remaining -= 1
    }
    return offset
  }

  /// The start of `line`'s last character, or its start when empty.
  func lastCharacter(of line: Line) -> Int {
    line.isEmpty ? line.start : previousStart(line.end)
  }

  /// Vim's beginline(BL_WHITE | BL_FIX): the first non-blank character, or
  /// the last character of a line of blanks.
  func firstNonBlank(of line: Line) -> Int {
    guard !line.isEmpty else { return line.start }
    let unit = buffer.firstNonBlank(of: line)
    guard unit < line.end else { return previousStart(line.end) }
    return characterStart(atOrBefore: unit, in: line)
  }

  /// `g_`: back from the last character over blanks, stopping at the line's
  /// first character (so a line of blanks gives its start, as in Vim).
  func lastNonBlank(of line: Line) -> Int {
    guard !line.isEmpty else { return line.start }
    var offset = previousStart(line.end)
    while offset > line.start, TextBuffer.isBlank(buffer.units[offset]) {
      offset = previousStart(offset)
    }
    return offset
  }

  static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0xFFFF && TextBuffer.isBlank(UInt16(scalar.value))
  }

  // MARK: Targets

  func target(_ offset: Int, in line: Line) -> TextMotionTarget {
    TextMotionTarget(offset: offset, desiredColumn: column(of: offset, in: line))
  }

  func target(_ position: Position) -> TextMotionTarget {
    target(position.offset, in: position.line)
  }

  /// Vim's startofline landing for `gg`, `G`, `+` and the like.
  func lineTarget(_ line: Line) -> TextMotionTarget {
    target(firstNonBlank(of: line), in: line)
  }

  /// Vim's adjust_cursor(): outside Visual mode the cursor does not stay on
  /// a non-empty line's break; it backs onto the last character.
  func settled(_ position: Position) -> Position {
    guard !inVisual, position.isOnBreak, !position.line.isEmpty else { return position }
    return Position(line: position.line, offset: previousStart(position.line.end))
  }

  // MARK: Steps

  /// Vim's inc(): the next character, from the last one the line's break,
  /// from the break the next line's start.
  func increment(_ position: inout Position) -> Step {
    if position.offset < position.line.end {
      position.offset = nextStart(position.offset)
      return position.offset < position.line.end ? .within : .ontoBreak
    }
    guard let next = lineAfter(position.line) else { return .edge }
    position = Position(line: next, offset: next.start)
    return .crossedLine
  }

  /// Vim's dec(): the previous character, from a line's start the previous
  /// line's break.
  func decrement(_ position: inout Position) -> Step {
    if position.offset > position.line.start {
      position.offset = previousStart(position.offset)
      return .within
    }
    guard let previous = lineBefore(position.line) else { return .edge }
    position = Position(line: previous, offset: previous.end)
    return .crossedLine
  }

  /// Vim's incl(): `increment`, stepping over a non-empty line's break.
  func incrementSkippingBreaks(_ position: inout Position) -> Step {
    let step = increment(&position)
    return step == .ontoBreak ? increment(&position) : step
  }

  /// Vim's decl(): `decrement`, stepping over a non-empty line's break.
  func decrementSkippingBreaks(_ position: inout Position) -> Step {
    let step = decrement(&position)
    return step == .crossedLine && !position.line.isEmpty ? decrement(&position) : step
  }

  // MARK: h l j k

  func left(from start: Position, count: Int) -> TextMotionTarget? {
    var offset = start.offset
    var moved = 0
    while moved < count, offset > start.line.start {
      offset = previousStart(offset)
      moved += 1
    }
    return moved > 0 ? target(offset, in: start.line) : nil
  }

  func right(from start: Position, count: Int) -> TextMotionTarget? {
    let line = start.line
    var offset = start.offset
    var moved = 0
    while moved < count, offset < line.end {
      let next = nextStart(offset)
      if next >= line.end, !inVisual { break }
      offset = next
      moved += 1
    }
    return moved > 0 ? target(offset, in: line) : nil
  }

  func vertical(
    from start: Position, count: Int, down: Bool, desiredColumn: Int?
  ) -> TextMotionTarget? {
    let column = desiredColumn ?? self.column(of: start.offset, in: start.line)
    let moved =
      down ? lineDown(from: start.line, count: count) : lineUp(from: start.line, count: count)
    guard let line = moved else { return nil }
    let offset = self.offset(ofColumn: column, in: line, allowEnd: inVisual)
    return TextMotionTarget(offset: offset, desiredColumn: column)
  }

  // MARK: Words

  /// Runs a word motion, then settles a cursor it moved forward off a
  /// line's break as nv_wordcmd does; nil when the cursor did not move.
  func wordMotion(
    from start: Position, forward: Bool, _ move: (inout Position) -> Void
  ) -> TextMotionTarget? {
    var position = start
    move(&position)
    if forward, position.offset > start.offset { position = settled(position) }
    return position.offset == start.offset ? nil : target(position)
  }

  /// Vim's cls(): 0 for blanks and line breaks, otherwise the character's
  /// class; only blank against non-blank for big words.
  func wordClass(at position: Position, big: Bool) -> Int {
    guard !position.isOnBreak else { return WordClass.blank }
    let wordClass = WordClass.of(scalar(at: position.offset))
    return big && wordClass != WordClass.blank ? WordClass.punctuation : wordClass
  }

  /// Vim's skip_chars(): past the run of `wordClass`; true at the text's edge.
  func skip(_ wordClass: Int, forward: Bool, _ position: inout Position, big: Bool) -> Bool {
    while self.wordClass(at: position, big: big) == wordClass {
      let step = forward ? increment(&position) : decrement(&position)
      if step == .edge { return true }
    }
    return false
  }

  /// `w` `W`: Vim's fwd_word(). From the text's last word it reaches the
  /// break after the last character, which `settled` turns into that
  /// character.
  func forwardWord(_ position: inout Position, count: Int, big: Bool) {
    for _ in 0..<count {
      let startClass = wordClass(at: position, big: big)
      let onLastLine = lineAfter(position.line) == nil
      let step = increment(&position)
      if step == .edge || (step != .within && onLastLine) { return }
      if startClass != WordClass.blank {
        while wordClass(at: position, big: big) == startClass {
          if increment(&position) == .edge { return }
        }
      }
      // Then to the next non-blank; an empty line is a word of its own.
      while wordClass(at: position, big: big) == WordClass.blank {
        if position.line.isEmpty { break }
        if increment(&position) == .edge { return }
      }
    }
  }

  /// `b` `B`: Vim's bck_word(); an empty line is a word.
  func backwardWord(_ position: inout Position, count: Int, big: Bool) {
    for _ in 0..<count {
      if decrement(&position) == .edge { return }
      var onEmptyLine = false
      while wordClass(at: position, big: big) == WordClass.blank {
        if position.line.isEmpty {
          onEmptyLine = true
          break
        }
        if decrement(&position) == .edge { return }
      }
      if onEmptyLine { continue }
      if skip(wordClass(at: position, big: big), forward: false, &position, big: big) { return }
      // Overshot onto the blank or other class before the word.
      _ = increment(&position)
    }
  }

  /// `e` `E`: Vim's end_word(); empty lines are not stops.
  func forwardWordEnd(_ position: inout Position, count: Int, big: Bool) {
    for _ in 0..<count {
      let startClass = wordClass(at: position, big: big)
      if increment(&position) == .edge { return }
      if startClass != WordClass.blank, wordClass(at: position, big: big) == startClass {
        // Inside a word: to its end.
        if skip(startClass, forward: true, &position, big: big) { return }
      } else {
        // At a word's end: over blanks, then to the next word's end.
        while wordClass(at: position, big: big) == WordClass.blank {
          if increment(&position) == .edge { return }
        }
        if skip(wordClass(at: position, big: big), forward: true, &position, big: big) { return }
      }
      // Overshot past the word's last character.
      _ = decrement(&position)
    }
  }

  /// `ge` `gE`: Vim's bckend_word(). Vim stops on an empty line here, so an
  /// empty line counts as a word end, as it counts as a word for `b`.
  func backwardWordEnd(_ position: inout Position, count: Int, big: Bool) {
    for _ in 0..<count {
      let startClass = wordClass(at: position, big: big)
      if decrement(&position) == .edge { return }
      if startClass != WordClass.blank {
        while wordClass(at: position, big: big) == startClass {
          if decrement(&position) == .edge { return }
        }
      }
      while wordClass(at: position, big: big) == WordClass.blank {
        if position.line.isEmpty { break }
        if decrement(&position) == .edge { return }
      }
    }
  }

  // MARK: Paragraphs and sentences

  /// `}` `{`: Vim's findpar(). A boundary is an empty line (a line of blanks
  /// is not one; nroff macros such as `.PP` are not read). At the text's end
  /// `}` lands on the last line's last character, `{` on the first line's
  /// start; a count left over at either edge fails the motion.
  func paragraph(from start: Position, count: Int, forward: Bool) -> TextMotionTarget? {
    var current = start.line
    for remaining in stride(from: count - 1, through: 0, by: -1) {
      var skipped = false
      var first = true
      while true {
        if !current.isEmpty { skipped = true }
        if !first, skipped, current.isEmpty { break }
        guard let next = forward ? lineAfter(current) : lineBefore(current) else {
          if remaining > 0 { return nil }
          break
        }
        current = next
        first = false
      }
    }
    if forward, lineAfter(current) == nil, !isPastLastLine(current) {
      return target(lastCharacter(of: current), in: current)
    }
    return target(current.start, in: current)
  }

  static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?"]
  static let sentenceClosers: Set<Unicode.Scalar> = [")", "]", "\"", "'"]

  static func isSentencePunctuation(_ scalar: Unicode.Scalar) -> Bool {
    sentenceEnds.contains(scalar) || sentenceClosers.contains(scalar)
  }

  func sentenceStep(_ position: inout Position, forward: Bool) -> Step {
    forward ? incrementSkippingBreaks(&position) : decrementSkippingBreaks(&position)
  }

  /// A step of findsent()'s search for a sentence end, jumping straight to
  /// the next `.`, `!` or `?` on the line (or its last or first character):
  /// the characters in between could only be stepped over one by one.
  func sentenceSearchStep(_ position: inout Position, forward: Bool) -> Step {
    let line = position.line
    if !position.isOnBreak {
      let units = buffer.units
      let landing: Int
      if forward {
        var unit = position.offset + 1
        while unit < line.end, !Self.endsSentence(units[unit]) { unit += 1 }
        landing =
          unit < line.end ? characterStart(atOrBefore: unit, in: line) : lastCharacter(of: line)
      } else {
        var unit = position.offset - 1
        while unit >= line.start, !Self.endsSentence(units[unit]) { unit -= 1 }
        landing = unit >= line.start ? characterStart(atOrBefore: unit, in: line) : line.start
      }
      if forward ? landing > position.offset : landing < position.offset {
        position.offset = landing
        return .within
      }
    }
    return sentenceStep(&position, forward: forward)
  }

  static func endsSentence(_ unit: UInt16) -> Bool {
    unit == 0x2E || unit == 0x21 || unit == 0x3F
  }

  /// `)` `(`: Vim's findsent(). A sentence ends at `.`, `!` or `?` followed
  /// by any `)`, `]`, `"` and `'`, then a line's end or a blank; the next one
  /// starts at the following non-blank. An empty line is a sentence of its
  /// own. Nil when a count is left over at the text's edge (the cursor does
  /// not move); the result may be a line's break, which the caller settles.
  func sentence(from start: Position, count: Int, forward: Bool) -> Position? {
    var position = start
    var remaining = count
    var noSkip = false
    while remaining > 0 {
      remaining -= 1
      let before = position
      var found = false
      if scalar(at: position) == nil {
        // On an empty line (or a line's break): to the next non-empty line.
        repeat {
          if sentenceStep(&position, forward: forward) == .edge { break }
        } while scalar(at: position) == nil
        found = forward
      } else if !forward {
        _ = decrementSkippingBreaks(&position)
      }
      if !found {
        // Back to the last character that is neither blank nor sentence
        // punctuation, to start inside the current sentence.
        var foundDot = false
        while let current = scalar(at: position),
          Self.isBlank(current) || Self.isSentencePunctuation(current)
        {
          var probe = position
          if decrementSkippingBreaks(&probe) == .edge || (probe.line.isEmpty && forward) { break }
          if foundDot { break }
          if Self.sentenceEnds.contains(current) { foundDot = true }
          if Self.sentenceClosers.contains(current),
            !(scalar(at: probe).map(Self.isSentencePunctuation) ?? false)
          {
            break
          }
          _ = decrementSkippingBreaks(&position)
        }
        let startLine = position.line.start
        search: while true {
          guard let current = scalar(at: position) else {
            // An empty line ends the search; backward, the sentence starts
            // on the line after it.
            if !forward, position.line.start != startLine, let next = lineAfter(position.line) {
              position = Position(line: next, offset: next.start)
            }
            break
          }
          if Self.sentenceEnds.contains(current) {
            var probe = position
            var step = Step.within
            var following: Unicode.Scalar?
            repeat {
              step = increment(&probe)
              if step == .edge { break }
              following = scalar(at: probe)
            } while following.map(Self.sentenceClosers.contains) ?? false
            if step == .edge || following.map(Self.isBlank) ?? true {
              position = probe
              if scalar(at: position) == nil { _ = increment(&position) }
              break search
            }
          }
          if sentenceSearchStep(&position, forward: forward) == .edge {
            if remaining > 0 { return nil }
            noSkip = true
            break
          }
        }
      }
      if !noSkip {
        while let current = scalar(at: position), Self.isBlank(current) {
          if incrementSkippingBreaks(&position) == .edge { break }
        }
      }
      if position.offset == before.offset {
        // Did not move: step once and try again.
        if sentenceStep(&position, forward: forward) == .edge {
          if remaining > 0 { return nil }
          break
        }
        remaining += 1
      }
    }
    return position
  }

  // MARK: Brackets

  /// The bracket closing (or opening) `unit`, nil when it is not one.
  static func bracketPartner(_ unit: UInt16) -> UInt16? {
    switch unit {
    case 0x28: return 0x29
    case 0x29: return 0x28
    case 0x5B: return 0x5D
    case 0x5D: return 0x5B
    case 0x7B: return 0x7D
    case 0x7D: return 0x7B
    default: return nil
    }
  }

  /// `%`: the first of `( ) [ ] { }` at or after the cursor on its line (the
  /// last character when the cursor is past it), then its partner, counting
  /// nesting of that pair through the whole text. Unlike Vim it does not
  /// skip quoted or escaped brackets, comments or `#if` blocks.
  func matchingBracket(from start: Position) -> TextMotionTarget? {
    let line = start.line
    guard !line.isEmpty else { return nil }
    let units = buffer.units
    var offset = start.isOnBreak ? lastCharacter(of: line) : start.offset
    while offset < line.end, Self.bracketPartner(units[offset]) == nil { offset += 1 }
    guard offset < line.end, let partner = Self.bracketPartner(units[offset]) else { return nil }
    let bracket = units[offset]
    let forward = bracket == 0x28 || bracket == 0x5B || bracket == 0x7B
    var depth = 0
    var index = offset
    while true {
      index += forward ? 1 : -1
      guard index >= 0, index < units.count else { return nil }
      if units[index] == bracket {
        depth += 1
      } else if units[index] == partner {
        if depth == 0 { break }
        depth -= 1
      }
    }
    let matchLine = buffer.line(containing: index)
    return target(characterStart(atOrBefore: index, in: matchLine), in: matchLine)
  }

  // MARK: f F t T

  /// Vim's searchc() on the cursor's line: the count-th match, comparing
  /// whole characters (canonically equivalent ones match), then for `t` and
  /// `T` the character before it. Fails as a whole when a match is missing.
  func find(
    _ search: TextCharacterSearch, from start: Position, count: Int, isRepeat: Bool
  ) -> TextMotionTarget? {
    let line = start.line
    // A repeated `t` or `T` skips the character next to the cursor, whose
    // match would leave it in place (cpoptions without `;`); only for a
    // single repeat.
    var skip = isRepeat && search.till && count == 1
    var remaining = count
    var match: Int?
    if search.forward {
      guard start.offset < line.end else { return nil }
      var offset = nextStart(start.offset)
      for character in string[index(offset)..<index(line.end)] {
        if !skip, character == search.character {
          remaining -= 1
          if remaining == 0 {
            match = offset
            break
          }
        }
        skip = false
        offset += character.utf16.count
      }
    } else {
      var offset = start.offset
      for character in string[index(line.start)..<index(start.offset)].reversed() {
        offset -= character.utf16.count
        if !skip, character == search.character {
          remaining -= 1
          if remaining == 0 {
            match = offset
            break
          }
        }
        skip = false
      }
    }
    guard var offset = match else { return nil }
    if search.till {
      offset = search.forward ? previousStart(offset) : nextStart(offset)
    }
    // `T` from past the line's end onto its last character lands back on
    // the end: no move, and never a resting place outside Visual mode.
    if offset >= line.end, !line.isEmpty, !inVisual { return nil }
    return target(offset, in: line)
  }
}

/// Vim's character classes for word motions: utf_class() in mbyte.c with
/// the default `iskeyword` (`@,48-57,_,192-255`), checked against Vim 9.1's
/// `charclass()` over every code point. Emoji follow the Unicode Emoji
/// property of the running system, which may be newer than Vim's table.
private enum WordClass {
  static let blank = 0
  static let punctuation = 1
  static let keyword = 2
  static let emoji = 3

  /// The class of a character, from its first scalar (a base keeps its
  /// combining marks' class). As in Vim, a character its table does not
  /// name is a keyword character, so most letters, digits and marks are.
  static func of(_ scalar: Unicode.Scalar) -> Int {
    let value = scalar.value
    if value < 0x100 { return latin1(value) }
    if scalar.properties.isEmoji { return emoji }
    return table(value) ?? keyword
  }

  /// Latin-1 through `iskeyword`: ASCII letters and digits, `_`, `µ` and
  /// 192-255 are keyword characters, blanks are space, tab and no-break
  /// space, the rest punctuation.
  static func latin1(_ value: UInt32) -> Int {
    switch value {
    case 0x00, 0x09, 0x20, 0xA0: return blank
    case 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A, 0xB5, 0xC0...0xFF: return keyword
    default: return punctuation
    }
  }

  /// Vim's table: punctuation and blanks across scripts, and the scripts
  /// with a class of their own (braille, Hiragana, Katakana, CJK
  /// ideographs, Hangul syllables) that end a word where they meet another
  /// class.
  static func table(_ value: UInt32) -> Int? {
    switch value {
    case 0x037E, 0x0387, 0x055A...0x055F, 0x0589, 0x05BE, 0x05C0, 0x05C3, 0x05F3...0x05F4,
      0x060C, 0x061B, 0x061F, 0x066A...0x066D, 0x06D4, 0x0700...0x070D, 0x0964...0x0965,
      0x0970, 0x0DF4, 0x0E4F, 0x0E5A...0x0E5B, 0x0F04...0x0F12, 0x0F3A...0x0F3D, 0x0F85,
      0x104A...0x104F, 0x10FB, 0x1361...0x1368, 0x166D...0x166E, 0x169B...0x169C,
      0x16EB...0x16ED, 0x1735...0x1736, 0x17D4...0x17DC, 0x1800...0x180A:
      return punctuation
    case 0x1680, 0x2000...0x200B, 0x2028...0x2029, 0x202F, 0x205F, 0x3000:
      return blank
    case 0x200C...0x27FF, 0x2900...0x2998, 0x29D8...0x29DB, 0x29FC...0x29FD, 0x2E00...0x2E7F,
      0x3001...0x3020, 0x3030, 0x303D, 0xFD3E...0xFD3F, 0xFE30...0xFE6B, 0xFF00...0xFF0F,
      0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0x1D000...0x1D24F, 0x1D400...0x1D7FF,
      0x1F000...0x1F2FF, 0x1F300...0x1F9FF:
      return punctuation
    case 0x2800...0x28FF: return 0x2800
    case 0x3040...0x309F: return 0x3040
    case 0x30A0...0x30FF: return 0x30A0
    case 0x3300...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x2A700...0x2B81F,
      0x2F800...0x2FA1F:
      return 0x4E00
    case 0xAC00...0xD7A3: return 0xAC00
    default: return nil
    }
  }
}

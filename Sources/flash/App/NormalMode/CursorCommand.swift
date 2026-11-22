import FlashCore
import Foundation

/// `cursor <motion>`: Vim's motions in the focused text. Each moves the
/// caret where Vim's would land (`TextMotionEngine`), computed from the text
/// Accessibility gives, off the main loop, and set through
/// `AXSelectedTextRange`; where the app gives no text, the app's own binding
/// for the motion runs (the macOS chord for the eight macOS has), else
/// nothing. Only editable text NORMAL acts on (`TextScope`) moves; a terminal
/// never does.
enum CursorCommand: Hashable {
  /// A motion the count repeats or measures (`3w`, `5|`).
  case motion(TextMotion)
  /// `{count}G` and `{count}gg`: line `index`, from 1.
  case line(index: Int)
  /// `{count}%`: the line `percent` of the way through the text.
  case percent(Int)
  /// `f` `F` `t` `T`: the character is the next key NORMAL reads when nil.
  case findCharacter(CharacterSearchKind, Character?)
  /// `;` and `,`: the last character search again, `,` the other way.
  case repeatCharacterSearch(reversed: Bool)

  /// The motions named by a `cursor <action>` that takes no argument, in the
  /// order the manual lists them.
  static let motionActions: [(action: String, motion: TextMotion)] = [
    ("next_word", .nextWord(big: false)), ("next_big_word", .nextWord(big: true)),
    ("previous_word", .previousWord(big: false)),
    ("previous_big_word", .previousWord(big: true)),
    ("word_end", .wordEnd(big: false)), ("big_word_end", .wordEnd(big: true)),
    ("previous_word_end", .previousWordEnd(big: false)),
    ("previous_big_word_end", .previousWordEnd(big: true)),
    ("line_start", .lineStart), ("first_nonblank", .firstNonBlank), ("line_end", .lineEnd),
    ("last_nonblank", .lastNonBlank), ("column", .column),
    ("first_line", .firstLine), ("last_line", .lastLine),
    ("matching_bracket", .matchingBracket),
    ("next_paragraph", .nextParagraph), ("previous_paragraph", .previousParagraph),
    ("next_sentence", .nextSentence), ("previous_sentence", .previousSentence),
    ("next_line", .nextLineFirstNonBlank), ("previous_line", .previousLineFirstNonBlank),
    ("line_nonblank", .lineFirstNonBlank),
    ("screen_top", .screenTop), ("screen_middle", .screenMiddle),
    ("screen_bottom", .screenBottom),
  ]

  /// One sentence per motion action, for the command catalog.
  static let motionSummaries: [String: String] = [
    "next_word": "Move to the start of the next word (w)",
    "next_big_word": "Move to the start of the next blank-separated word (W)",
    "previous_word": "Move to the start of this or the previous word (b)",
    "previous_big_word": "Move to the start of this or the previous blank-separated word (B)",
    "word_end": "Move to the end of this or the next word (e)",
    "big_word_end": "Move to the end of this or the next blank-separated word (E)",
    "previous_word_end": "Move to the end of the previous word (ge)",
    "previous_big_word_end": "Move to the end of the previous blank-separated word (gE)",
    "line_start": "Move to the first character of the line (0)",
    "first_nonblank": "Move to the line's first non-blank character (^)",
    "line_end": "Move to the line's last character, count - 1 lines down ($)",
    "last_nonblank": "Move to the line's last non-blank character, count - 1 lines down (g_)",
    "column": "Move to the column the count names on the line",
    "first_line": "Move to the first line's first non-blank character (gg)",
    "last_line": "Move to the last line's first non-blank character (G)",
    "matching_bracket": "Move to the bracket matching the next one on the line (%)",
    "next_paragraph": "Move to the next empty line (})",
    "previous_paragraph": "Move to the previous empty line ({)",
    "next_sentence": "Move to the start of the next sentence ())",
    "previous_sentence": "Move to the start of this or the previous sentence (()",
    "next_line": "Move to the next line's first non-blank character (+, Return)",
    "previous_line": "Move to the previous line's first non-blank character (-)",
    "line_nonblank": "Move to the first non-blank character, count - 1 lines down (_)",
    "screen_top": "Move to the first line on screen, or the count-th (H)",
    "screen_middle": "Move to the middle line on screen (M)",
    "screen_bottom": "Move to the last line on screen, or the count-th from it (L)",
  ]

  /// The action word of a motion, or nil for one no `cursor` action names.
  static func action(of motion: TextMotion) -> String? {
    motionActions.first { $0.motion == motion }?.action
  }

  /// The words after `flash cursor`, as a mapping writes them.
  var argvTail: [String] {
    switch self {
    case .motion(let motion): return [Self.action(of: motion) ?? "next_word"]
    case .line(let index): return ["line", "--index=\(index)"]
    case .percent(let percent): return ["line", "--percent=\(percent)"]
    case .findCharacter(let kind, let character):
      return [kind.rawValue] + (character.map { ["--char=\($0)"] } ?? [])
    case .repeatCharacterSearch(let reversed):
      return [reversed ? "repeat_char_back" : "repeat_char"]
    }
  }

  /// What a count does: the motion's own count, or, for a character search
  /// waiting for its character, nothing yet.
  var awaitsCharacter: CharacterSearchKind? {
    if case .findCharacter(let kind, nil) = self { return kind }
    return nil
  }

  /// A motion whose landing depends on the visible text (`H`, `M`, `L`).
  var readsVisibleRange: Bool {
    switch self {
    case .motion(.screenTop), .motion(.screenMiddle), .motion(.screenBottom): return true
    default: return false
    }
  }
}

/// `f` `F` `t` `T` as `cursor` actions.
enum CharacterSearchKind: String, CaseIterable, Hashable {
  case nextChar = "next_char"
  case previousChar = "previous_char"
  case tillNextChar = "till_next_char"
  case tillPreviousChar = "till_previous_char"

  var forward: Bool { self == .nextChar || self == .tillNextChar }

  /// The search's Vim letter, which a pending search carries
  /// (`NormalModeInterpreter.characterPendingMark`).
  var pendingCode: String {
    switch self {
    case .nextChar: return "f"
    case .previousChar: return "F"
    case .tillNextChar: return "t"
    case .tillPreviousChar: return "T"
    }
  }

  init?(pendingCode: Character) {
    guard let kind = Self.allCases.first(where: { $0.pendingCode == String(pendingCode) })
    else { return nil }
    self = kind
  }
  var till: Bool { self == .tillNextChar || self == .tillPreviousChar }

  func search(for character: Character) -> TextCharacterSearch {
    TextCharacterSearch(character: character, forward: forward, till: till)
  }

  var summary: String {
    switch self {
    case .nextChar: return "Move onto the next occurrence of a character on the line (f)"
    case .previousChar: return "Move onto the previous occurrence of a character on the line (F)"
    case .tillNextChar: return "Move just before the next occurrence of a character on the line (t)"
    case .tillPreviousChar:
      return "Move just after the previous occurrence of a character on the line (T)"
    }
  }
}

/// `scroll cursor_top|cursor_middle|cursor_bottom`: Vim's `zt`, `zz` and
/// `zb`, the view scrolled so the caret's line sits at the top, the middle
/// or the bottom of the focused text's scroll area.
enum ScrollCursorPosition: String, CaseIterable, Hashable {
  case top = "cursor_top"
  case middle = "cursor_middle"
  case bottom = "cursor_bottom"

  /// Pixels the view scrolls down (negative: up) to bring a caret line at
  /// `caret` to its place in `area`; both in Accessibility's top-left
  /// coordinates.
  func scrollDelta(caret: CGRect, area: CGRect) -> CGFloat {
    switch self {
    case .top: return caret.minY - area.minY
    case .middle: return caret.midY - area.midY
    case .bottom: return caret.maxY - area.maxY
    }
  }
}

/// How a `cursor` command runs once the focused text is read. Pure.
enum CursorResolution {
  /// The engine's motion and count for `command`, given the last character
  /// search (`;` and `,` repeat it); nil when there is nothing to do (a
  /// search with no character, or no search to repeat).
  static func motion(
    for command: CursorCommand, count: Int, lastSearch: TextCharacterSearch?
  ) -> (motion: TextMotion, count: Int?, isRepeat: Bool)? {
    switch command {
    case .motion(let motion):
      // `G` and `gg` read a typed count as a line (`line(index:)`); here
      // the count NORMAL passes is a repeat, which for them means nothing.
      switch motion {
      case .firstLine, .lastLine, .percent: return (motion, nil, false)
      default: return (motion, count, false)
      }
    case .line(let index): return (.firstLine, index, false)
    case .percent(let percent): return (.percent, percent, false)
    case .findCharacter(let kind, let character?):
      return (.find(kind.search(for: character)), count, false)
    case .findCharacter(_, nil): return nil
    case .repeatCharacterSearch(let reversed):
      guard let lastSearch else { return nil }
      return (.find(reversed ? lastSearch.reversed : lastSearch), count, true)
    }
  }

  /// Where the caret goes in `text` (UTF-16 offsets), or nil when Vim would
  /// not move. The cursor is where the app's selection starts.
  static func target(
    _ motion: TextMotion, count: Int?, isRepeat: Bool, in contents: FocusedText.Contents,
    visible: Range<Int>?
  ) -> Int? {
    guard let string = contents.text else { return nil }
    return TextMotionEngine.target(
      of: motion, count: count, from: contents.selection.lowerBound, in: TextBuffer(string),
      visible: visible, isRepeat: isRepeat)?.offset
  }
}

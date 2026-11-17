import FlashCore
import Foundation

/// One VISUAL selection: where it was started (`anchor`), the end the
/// motions move (`cursor`), and what the app reported selecting last, so a
/// selection the user changed by other means is noticed. Offsets are UTF-16,
/// as Accessibility counts them. Main thread only.
struct VisualSession: Equatable {
  var pid: pid_t
  var kind: VisualKind
  var anchor: Int
  var cursor: Int
  /// Vim's curswant: the column `j` and `k` aim for.
  var desiredColumn: Int?
  /// The range the app reported after the last selection Flash set; nil
  /// when the app gives no text (`measured` false).
  var selected: Range<Int>?
  /// Whether the app gives the text, so VISUAL measures the selection and
  /// sets it itself. Without it VISUAL extends the app's own selection with
  /// the app's selection keys (`input select_*`).
  var measured: Bool
  /// The focused element's identity (`CFHash`) when VISUAL began; a focus
  /// reading that names another element ends VISUAL.
  var element: Int? = nil

  /// Whether a focus reading in `pid` naming `element` still describes this
  /// selection's field.
  func survives(focusIn pid: pid_t?, element: Int?) -> Bool {
    pid == self.pid && (self.element == nil || element == self.element)
  }
}

/// One step of a VISUAL operator (`selection copy|paste|swap_ends`: `y`,
/// `p`, `P`, `o`). Each acts through the app's own keys or its selection,
/// never by writing its text, and none deletes or changes it: Flash never
/// edits text.
enum VisualOperatorStep: Equatable {
  /// The moving end goes to the other end; VISUAL stays.
  case swapEnds
  /// Flash writes the selected text it read into the named register.
  case writeRegister
  /// Flash writes the selected text it read into the yank register `0`, as
  /// a bare yank does, beside the app's Copy onto the clipboard.
  case writeYankRegister
  /// The app's Copy (`clipboard copy`).
  case appCopy
  /// The app's Left (`input char_left`): the selection collapses to its
  /// start, where Vim leaves the cursor after `y`.
  case collapseToStart
  /// VISUAL ends in NORMAL.
  case leave
  /// The register's text replaces the selection (`register paste`).
  case paste
}

/// VISUAL's decisions, pure: where a selection starts, what range it
/// covers, where a motion takes its moving end, and the app's selection
/// keys where the app gives no text.
enum VisualPlan {
  /// How `v` or `V` starts in the focused element `text`.
  enum Entry: Equatable {
    /// Not editable text: nothing happens.
    case none
    /// Flash measures the text: the selection starts at `anchor` as `range`.
    case measured(anchor: Int, range: Range<Int>)
    /// Editable, but the app gives no text: its own selection keys.
    case appKeys
  }

  static func entry(_ kind: VisualKind, in text: FocusedText) -> Entry {
    guard TextScope.isEditable(text) else { return .none }
    guard let contents = text.contents, let string = contents.text else { return .appKeys }
    let buffer = TextBuffer(string)
    let anchor = start(caret: contents.selection.lowerBound, in: buffer)
    return .measured(
      anchor: anchor, range: range(kind, anchor: anchor, cursor: anchor, in: buffer))
  }

  /// `gv`: the selection VISUAL last ended with, again, in the field it was
  /// made in (`element`, when both are known), its ends brought back into
  /// the text as it is now. Nil for a selection the app gave no text for, or
  /// another field, or no text.
  static func reselect(_ last: VisualSession, element: Int?, in buffer: TextBuffer)
    -> VisualSession?
  {
    guard last.measured, buffer.length > 0 else { return nil }
    if let made = last.element, let element, made != element { return nil }
    func clamped(_ offset: Int) -> Int {
      buffer.characterStart(atOrBefore: min(max(offset, 0), buffer.length - 1))
    }
    var session = last
    session.anchor = clamped(last.anchor)
    session.cursor = clamped(last.cursor)
    session.desiredColumn = nil
    session.selected = range(last.kind, anchor: session.anchor, cursor: session.cursor, in: buffer)
    return session
  }

  /// The app's keys that start a selection it extends itself: `V` selects
  /// the line from its start (Cmd-Left, then Shift-Cmd-Right, without its
  /// break); `v` selects nothing until the first motion.
  static func entryKeys(_ kind: VisualKind) -> [InputMotion] {
    kind == .linewise ? [.lineStart, .selectLineEnd] : []
  }

  /// The anchor for a caret at `caret`: Vim's cursor never rests past a
  /// non-empty line's last character, so a caret at a line's end starts on
  /// that character.
  static func start(caret: Int, in buffer: TextBuffer) -> Int {
    let line = buffer.line(containing: caret)
    let cursor = buffer.characterStart(atOrBefore: caret)
    guard cursor >= line.end, !line.isEmpty else { return cursor }
    return buffer.characters(of: line).last?.offset ?? line.start
  }

  /// The selection for `kind` between `anchor` and `cursor`: characters
  /// through the later one's, inclusive (`v`), or the whole lines with the
  /// last one's break (`V`).
  static func range(_ kind: VisualKind, anchor: Int, cursor: Int, in buffer: TextBuffer)
    -> Range<Int>
  {
    switch kind {
    case .charwise: return TextSelection.charwise(anchor: anchor, cursor: cursor, in: buffer)
    case .linewise: return TextSelection.linewise(anchor: anchor, cursor: cursor, in: buffer)
    }
  }

  /// What `action` does to `session`'s selection, in order. A named
  /// register is Flash's: it is written from the text VISUAL measured, and
  /// the clipboard stays as it was. A bare `y` is the app's Copy, and the
  /// text it measured goes into `"0` too, as any bare yank's does. Without
  /// the text the app's own Copy takes the selection, whatever register was
  /// named.
  static func operatorSteps(_ action: SelectionAction, named: Bool, session: VisualSession)
    -> [VisualOperatorStep]
  {
    let named = named && session.measured
    switch action {
    case .swapEnds: return [.swapEnds]
    case .copy:
      if named { return [.writeRegister, .collapseToStart, .leave] }
      let yank: [VisualOperatorStep] = session.measured ? [.writeYankRegister] : []
      return yank + [.appCopy, .collapseToStart, .leave]
    case .paste: return [.leave, .paste]
    }
  }

  /// The engine motion a `move` command is in VISUAL: logical lines and
  /// characters, a half page `pageLines` lines, the edges the first and
  /// last line.
  static func motion(for move: MoveCommand, count: Int, pageLines: Int)
    -> (motion: TextMotion, count: Int?)
  {
    switch move {
    case .down: return (.down, count)
    case .up: return (.up, count)
    case .left: return (.left, count)
    case .right: return (.right, count)
    case .halfPageDown: return (.down, count * pageLines)
    case .halfPageUp: return (.up, count * pageLines)
    case .pageDown: return (.down, count * 2 * pageLines)
    case .pageUp: return (.up, count * 2 * pageLines)
    case .top: return (.firstLine, nil)
    case .bottom: return (.lastLine, nil)
    }
  }

  /// `session` after `motion` moves its cursor end in `buffer`; nil when
  /// Vim would not move. `j` and `k` keep the column they aim for.
  static func step(
    _ session: VisualSession, motion: TextMotion, count: Int?, isRepeat: Bool = false,
    in buffer: TextBuffer, visible: Range<Int>? = nil
  ) -> VisualSession? {
    let vertical = motion == .down || motion == .up
    guard
      let target = TextMotionEngine.target(
        of: motion, count: count, from: session.cursor, in: buffer, visible: visible,
        desiredColumn: vertical ? session.desiredColumn : nil, isRepeat: isRepeat,
        inVisual: true)
    else { return nil }
    var next = session
    next.cursor = target.offset
    next.desiredColumn = target.desiredColumn
    return next
  }

  /// The app's selection key a motion falls back to where the app gives no
  /// text, and how many times; nil where no key is safe.
  static func fallback(for motion: TextMotion, count: Int?) -> (InputMotion, times: Int)? {
    let times = max(count ?? 1, 1)
    switch motion {
    case .down: return (.selectDown, times)
    case .up: return (.selectUp, times)
    case .left: return (.selectLeft, times)
    case .right: return (.selectRight, times)
    case .nextWord, .wordEnd: return (.selectWordRight, times)
    case .previousWord: return (.selectWordLeft, times)
    case .lineStart, .firstNonBlank: return (.selectLineStart, 1)
    case .lineEnd, .lastNonBlank: return (.selectLineEnd, 1)
    case .firstLine: return (.selectDocumentStart, 1)
    case .lastLine: return (.selectDocumentEnd, 1)
    default: return nil
    }
  }
}

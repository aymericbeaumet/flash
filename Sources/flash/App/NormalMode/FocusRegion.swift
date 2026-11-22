import CoreGraphics
import FlashCore
import Foundation

/// Where the keyboard focus sits in the focused app, as NORMAL's movement
/// keys read it: an arrow means something different in each. Read once per
/// focus change, off the main loop, and cached (`FocusRegionTracker`), so a
/// keypress costs a lookup.
enum FocusRegion: Equatable {
  /// Editable text (`FocusedText.Kind.singleLine` or `.multiLine`): the
  /// arrows move the caret once the field is engaged (`TextScope`), and
  /// scroll as a page before.
  case text(FocusedText.Kind)
  /// A list, table, outline, column browser, collection view or sidebar, or
  /// one of their rows or cells: the arrows move the selection.
  case collection
  /// A page or document with no focused control (a web area, a scroll area,
  /// a PDF, an image, nothing focused), or anything unknown: Flash scrolls.
  case document
  /// A declared terminal emulator, tmux panes included, or xterm.js in web
  /// content: an arrow is input to the shell (Up recalls history), so Flash
  /// scrolls as it always has.
  case terminal

  /// Whether `app cancel` (NORMAL's Escape) may reach the focus: never a
  /// terminal, whose shell or vim would read the Escape. A declared
  /// emulator binds it `false` already; this covers one in web content
  /// (VS Code's), which no binding names.
  var takesTheAppsCancel: Bool { self != .terminal }

  /// The region of a focused element read as `text`, with the role and
  /// subrole of it and of its first ancestors (`roles`, the element first).
  /// Editable text and terminals are what the focused-text read says; a
  /// collection role on the element or an ancestor makes a collection,
  /// except a plain document list (`AXContentList`, a web page's `<ul>`),
  /// where an arrow scrolls the page anyway; everything else is a document.
  static func classify(text: FocusedText, roles: [(role: String?, subrole: String?)])
    -> FocusRegion
  {
    if text.kind == .terminal { return .terminal }
    if TextScope.isEditable(text) { return .text(text.kind) }
    let inCollection = roles.contains { entry in
      guard let role = entry.role, collectionRoles.contains(role) else { return false }
      return entry.subrole != contentListSubrole
    }
    return inCollection ? .collection : .document
  }

  /// Roles whose arrows move a selection.
  static let collectionRoles: Set<String> = [
    "AXList", "AXTable", "AXOutline", "AXBrowser", "AXGrid", "AXRow", "AXCell",
  ]

  /// A web page's plain list: Chromium and WebKit give `<ul>` and `<ol>` this
  /// subrole. It has no selection; Down scrolls the page around it.
  static let contentListSubrole = "AXContentList"

  /// How many ancestors the read looks through for a collection role: a
  /// cell's text, a row's button, an outline row's disclosure triangle.
  static let ancestorDepth = 3
}

/// `move <direction>`: NORMAL's `h` `j` `k` `l`, `ctrl+d` `ctrl+u`, `ctrl+f`
/// `ctrl+b`, `gg` and `G`. One command per key, resolved by where the focus
/// sits (`MoveResolution`): the caret in text, the selection in a list, the
/// view in a page or a terminal.
enum MoveCommand: String, CaseIterable, Hashable {
  case down, up, left, right
  case halfPageDown = "half_page_down"
  case halfPageUp = "half_page_up"
  case pageDown = "page_down"
  case pageUp = "page_up"
  case top, bottom

  var commandName: CommandName { CommandName("move", rawValue) }

  /// The scroll the command is in a page, a terminal or a held drag.
  var scroll: NormalModeDispatcher.ScrollKind {
    switch self {
    case .down: return .down
    case .up: return .up
    case .left: return .left
    case .right: return .right
    case .halfPageDown: return .halfPageDown
    case .halfPageUp: return .halfPageUp
    case .pageDown: return .pageDown
    case .pageUp: return .pageUp
    case .top: return .top
    case .bottom: return .bottom
    }
  }

  /// Arrows per press: one, `[mode] move_page_lines` for a half page, twice
  /// that for a page; nil for the edges, which are one key.
  func arrowCount(pageLines: Int) -> Int? {
    switch self {
    case .down, .up, .left, .right: return 1
    case .halfPageDown, .halfPageUp: return pageLines
    case .pageDown, .pageUp: return 2 * pageLines
    case .top, .bottom: return nil
    }
  }

  /// The one-step move a page repeats: Down for `half_page_down`.
  var step: MoveCommand {
    switch self {
    case .halfPageDown, .pageDown: return .down
    case .halfPageUp, .pageUp: return .up
    default: return self
    }
  }
}

/// What a `move` command does where the focus sits. Pure: the region comes
/// from the cache, never from Accessibility on the keypress.
///
/// | Region | `j` `k` | `h` `l` | `ctrl+d` `ctrl+u`, `ctrl+f` `ctrl+b` | `gg` `G` |
/// | --- | --- | --- | --- | --- |
/// | Text | Down / Up (`input line_down` / `line_up`) | Left / Right within the line | the arrows × `move_page_lines`, × twice that | `input document_start` / `document_end` |
/// | Collection | Down / Up (`move down` / `up`) | Left / Right (`move left` / `right`) | the arrows × `move_page_lines`, × twice that | the app's binding, else the scroller to the edge |
/// | Document | Down / Up (`move down` / `up`) | Left / Right (`move left` / `right`) | `scroll half_page_*`, `page_*` | `scroll top` / `bottom` |
/// | Terminal | `scroll down` / `up` | `scroll left` / `right` | `scroll half_page_*`, `page_*` | `scroll top` / `bottom` |
enum MoveResolution: Equatable {
  /// Scroll as the `scroll` command does.
  case scroll(NormalModeDispatcher.ScrollKind)
  /// An `input` move in the focused text, `times` per count.
  case text(InputMotion, times: Int)
  /// Left or Right in the focused text, never past its line: the read
  /// decides how many of the count fit (`LineStep`).
  case textInLine(InputMotion)
  /// The `move` command's own binding (the arrow keys), `times` per count:
  /// in a list, and for `h` `j` `k` `l` on a page, which scrolls on them.
  case arrows(MoveCommand, times: Int)

  /// How many strokes `count` presses make: the arrows of each press, once
  /// per press, or a single edge key however often it is asked for. In-line
  /// moves are capped by their line afterwards (`LineStep`).
  func strokes(count: Int) -> Int {
    switch self {
    case .scroll, .textInLine: return count
    case .text(let motion, let times):
      return motion == .documentStart || motion == .documentEnd ? 1 : count * times
    case .arrows(let step, let times):
      return step == .top || step == .bottom ? 1 : count * times
    }
  }

  static func resolve(_ move: MoveCommand, in region: FocusRegion, pageLines: Int)
    -> MoveResolution
  {
    switch region {
    case .terminal:
      // An arrow is input to the shell there: Up recalls history.
      return .scroll(move.scroll)
    case .document:
      // `h` `j` `k` `l` are the arrows a page or a PDF scrolls on; the page
      // keys and the edges scroll as before.
      switch move {
      case .down, .up, .left, .right: return .arrows(move, times: 1)
      default: return .scroll(move.scroll)
      }
    case .text:
      switch move {
      case .left: return .textInLine(.charLeft)
      case .right: return .textInLine(.charRight)
      case .top: return .text(.documentStart, times: 1)
      case .bottom: return .text(.documentEnd, times: 1)
      default:
        let times = move.arrowCount(pageLines: pageLines) ?? 1
        return .text(move.step == .down ? .lineDown : .lineUp, times: times)
      }
    case .collection:
      return .arrows(move.step, times: move.arrowCount(pageLines: pageLines) ?? 1)
    }
  }
}

/// How far `h` and `l` move in the focused text: Vim's never leave the line,
/// `h` stops at its start and `l` on its last character. Pure.
enum LineStep {
  /// How many of `requested` characters fit between the caret and the edge
  /// of its line in the direction of `motion` (`.charLeft` or `.charRight`).
  static func count(_ motion: InputMotion, requested: Int, caret: Int, in buffer: TextBuffer)
    -> Int
  {
    let line = buffer.line(containing: caret)
    let characters = buffer.characters(of: line)
    let cursor = buffer.characterStart(atOrBefore: caret)
    let index = characters.firstIndex { $0.offset == cursor } ?? characters.count
    switch motion {
    case .charLeft: return min(max(requested, 0), index)
    case .charRight: return min(max(requested, 0), max(characters.count - 1 - index, 0))
    default: return 0
    }
  }
}

import FlashCore
import Foundation

/// The mappings each mode has before a configuration adds or removes any.
extension Config.Mode {
  static let defaultNormalMappings: [ModeMapping] = makeDefaultNormalMappings()

  /// Apple function row while HYPER is held: `1`–`9`, `0`, `-`, `=`.
  /// Shift plus the same key sends F1–F12.
  static let defaultHyperMappings: [ModeMapping] = {
    let bindings: [(String, URLCommand)] = [
      ("1", .systemKey(.brightnessDown)),
      ("2", .systemKey(.brightnessUp)),
      ("3", .systemSurface(SystemSurfaceCommand(.missionControl, .toggle))),
      ("4", .systemKey(.spotlight)),
      ("5", .systemKey(.dictation)),
      ("6", .systemKey(.focus)),
      ("7", .systemKey(.mediaPrevious)),
      ("8", .systemKey(.mediaPlay)),
      ("9", .systemKey(.mediaNext)),
      ("0", .systemKey(.mute)),
      ("-", .systemKey(.volumeDown)),
      ("=", .systemKey(.volumeUp)),
      ("shift+1", .functionKey(1)),
      ("shift+2", .functionKey(2)),
      ("shift+3", .functionKey(3)),
      ("shift+4", .functionKey(4)),
      ("shift+5", .functionKey(5)),
      ("shift+6", .functionKey(6)),
      ("shift+7", .functionKey(7)),
      ("shift+8", .functionKey(8)),
      ("shift+9", .functionKey(9)),
      ("shift+0", .functionKey(10)),
      ("shift+-", .functionKey(11)),
      ("shift+=", .functionKey(12)),
    ]
    return bindings.map { key, command in
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        preconditionFailure("invalid default hyper mapping: \(key)")
      }
      return ModeMapping(key: canonical, action: .flashCommand(command))
    }
  }()

  /// HOLD moves what the held button grabbed: `h` `j` `k` `l` nudge it,
  /// `H` `J` `K` `L` further, a picked target is where it goes, Return
  /// drops it and Escape puts it back. `y` copies a text selection and `p`
  /// pastes over it; nothing cuts, since Flash never edits text. The page
  /// keys scroll under the held button, as they always did in HOLD, so the
  /// selection follows them; NORMAL's `move` would send arrows in text.
  /// `cmd+ctrl+h` enters or leaves it.
  static let defaultHoldMappings: [ModeMapping] = makeDefaultMappings(
    "hold",
    [
      ("y", .selection(.copy)),
      ("p", .selection(.paste)),
      ("w", .mouseJump(.nextWord)),
      ("b", .mouseJump(.previousWord)),
      ("e", .mouseJump(.wordEnd)),
      ("0", .mouseJump(.lineStart)),
      ("$", .mouseJump(.lineEnd)),
      ("h", .mouseNudge(.left, distance: 16)),
      ("j", .mouseNudge(.down, distance: 16)),
      ("k", .mouseNudge(.up, distance: 16)),
      ("l", .mouseNudge(.right, distance: 16)),
      ("H", .mouseNudge(.left, distance: 96)),
      ("J", .mouseNudge(.down, distance: 96)),
      ("K", .mouseNudge(.up, distance: 96)),
      ("L", .mouseNudge(.right, distance: 96)),
      ("ctrl+d", .scroll(.halfPageDown)),
      ("ctrl+u", .scroll(.halfPageUp)),
      ("ctrl+f", .scroll(.pageDown)),
      ("ctrl+b", .scroll(.pageUp)),
      ("gg", .scroll(.top)),
      ("G", .scroll(.bottom)),
      ("f", .mouseTarget(.move)),
      ("F", .mouseGrid(.init(.move))),
      ("s", .mouseBigram(.move)),
      ("<return>", .mouseButton(.init(state: .release, button: .primary, hold: .hold))),
      ("<esc>", .mouseButton(.init(state: .cancel, button: .primary, hold: .hold))),
    ])

  /// NORMAL while a field is engaged (`TextScope`): Vim's motions, read
  /// before NORMAL's keys, which answer the rest; Escape disengages. `H`, `L` and `t`
  /// are Vim's here (screen lines, till) and keep their Flash meaning
  /// (history back and forward, a new tab) everywhere else; `f` and `F`
  /// stay the hints. `j` `k` `h` `l` and the page keys are NORMAL's
  /// `move`, which already moves the caret in text.
  static let defaultTextMappings: [ModeMapping] = makeDefaultMappings(
    "text",
    [
      ("w", .cursor(.motion(.nextWord(big: false)))),
      ("W", .cursor(.motion(.nextWord(big: true)))),
      ("b", .cursor(.motion(.previousWord(big: false)))),
      ("B", .cursor(.motion(.previousWord(big: true)))),
      ("e", .cursor(.motion(.wordEnd(big: false)))),
      ("E", .cursor(.motion(.wordEnd(big: true)))),
      ("ge", .cursor(.motion(.previousWordEnd(big: false)))),
      ("gE", .cursor(.motion(.previousWordEnd(big: true)))),
      ("0", .cursor(.motion(.lineStart))),
      ("^", .cursor(.motion(.firstNonBlank))),
      ("$", .cursor(.motion(.lineEnd))),
      ("g_", .cursor(.motion(.lastNonBlank))),
      ("|", .cursor(.motion(.column))),
      ("gg", .cursor(.motion(.firstLine))),
      ("G", .cursor(.motion(.lastLine))),
      ("%", .cursor(.motion(.matchingBracket))),
      ("{", .cursor(.motion(.previousParagraph))),
      ("}", .cursor(.motion(.nextParagraph))),
      ("(", .cursor(.motion(.previousSentence))),
      (")", .cursor(.motion(.nextSentence))),
      ("<plus>", .cursor(.motion(.nextLineFirstNonBlank))),
      ("<return>", .cursor(.motion(.nextLineFirstNonBlank))),
      ("-", .cursor(.motion(.previousLineFirstNonBlank))),
      ("_", .cursor(.motion(.lineFirstNonBlank))),
      ("H", .cursor(.motion(.screenTop))),
      ("M", .cursor(.motion(.screenMiddle))),
      ("L", .cursor(.motion(.screenBottom))),
      ("t", .cursor(.findCharacter(.tillNextChar, nil))),
      ("T", .cursor(.findCharacter(.tillPreviousChar, nil))),
      (";", .cursor(.repeatCharacterSearch(reversed: false))),
      (",", .cursor(.repeatCharacterSearch(reversed: true))),
      ("zt", .scrollCursor(.top)),
      ("zz", .scrollCursor(.middle)),
      ("zb", .scrollCursor(.bottom)),
      // Display lines are what the arrows already move by.
      ("gj", .move(.down)),
      ("gk", .move(.up)),
      // Vim's `p` puts after the cursor, `P` at it.
      ("p", .paste(register: nil, after: true)),
      ("P", .paste(register: nil)),
      // `gv` selects the last VISUAL range of this field again.
      ("gv", .visualReselect),
      // Escape hands the keys back to NORMAL's own (`TextScope`).
      ("<esc>", .leaveMode),
    ])

  /// VISUAL's own keys, read before the text table's motions (`move`,
  /// `cursor`, `scroll`), which grow the selection; every other key is
  /// swallowed. `y` copies, `p` and `P` paste over it, Command-C and -V
  /// likewise, `o` swaps its ends, and Escape or `v` / `V` again deselect.
  /// Nothing cuts, deletes or changes it: Flash never edits text.
  static let defaultVisualMappings: [ModeMapping] = makeDefaultMappings(
    "visual",
    [
      ("y", .selection(.copy)),
      ("p", .selection(.paste)),
      ("P", .selection(.paste)),
      ("o", .selection(.swapEnds)),
      ("v", .visualMode(.charwise)),
      ("V", .visualMode(.linewise)),
      ("<esc>", .leaveMode),
    ])

  private static func makeDefaultMappings(
    _ table: String, _ bindings: [(String, URLCommand)]
  ) -> [ModeMapping] {
    bindings.map { key, command in
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        preconditionFailure("invalid default \(table) mapping: \(key)")
      }
      return ModeMapping(key: canonical, action: .flashCommand(command))
    }
  }

  static let defaultTerminalMappings: [ModeMapping] = {
    let bindings: [(String, URLCommand)] = [
      ("cmd+q", .popupQuit(name: nil)),
      ("cmd+r", .popupRestart(name: nil)),
      ("cmd+w", .leaveMode),
    ]
    return bindings.map { key, command in
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        preconditionFailure("invalid default terminal mapping: \(key)")
      }
      return ModeMapping(key: canonical, action: .flashCommand(command))
    }
  }()

  private static func makeDefaultNormalMappings() -> [ModeMapping] {
    let raw: [(String, MappingCommand)] = [
      // vim's movement keys move what has focus (`move`): the caret in
      // editable text, the selection in a list, and the view, by scrolling,
      // in a page or a terminal. `ctrl+e` / `ctrl+y` always scroll, one
      // line, as vim's scroll the view without moving the cursor.
      ("h", .flashCommand(.move(.left))),
      ("l", .flashCommand(.move(.right))),
      ("j", .flashCommand(.move(.down))),
      ("k", .flashCommand(.move(.up))),
      ("ctrl+d", .flashCommand(.move(.halfPageDown))),
      ("ctrl+u", .flashCommand(.move(.halfPageUp))),
      ("ctrl+f", .flashCommand(.move(.pageDown))),
      ("ctrl+b", .flashCommand(.move(.pageUp))),
      ("gg", .flashCommand(.move(.top))),
      ("G", .flashCommand(.move(.bottom))),
      ("ctrl+e", .flashCommand(.scroll(.lineDown))),
      ("ctrl+y", .flashCommand(.scroll(.lineUp))),
      // The vim keys that bind modes and the command line. Only `i` enters
      // INSERT, the explicit entry of AGENTS.md rule 9. Vim's `I` `a` `A`
      // `o` `O` `S` `C` stay unbound, and so swallowed: Flash never edits
      // text (rule 11), and `s` is the letter jump. `:` opens the command
      // line.
      (":", .flashCommand(.commandMode)),
      ("i", .flashCommand(.insertMode)),
      // VISUAL in the focused field, which `v` and `V` engage; nothing
      // where no field is focused.
      ("v", .flashCommand(.visualMode(.charwise))),
      ("V", .flashCommand(.visualMode(.linewise))),
      // The macOS clipboard chords act on what the app selects, as they do
      // outside NORMAL, through each app's `clipboard` bindings. Command-X
      // stays unbound: Flash cuts nothing.
      // `gi` focuses an input and keeps NORMAL.
      ("gi", .flashCommand(.focusInput)),
      ("[a", .flashCommand(.appPrev)),
      ("]a", .flashCommand(.appNext)),
      ("[w", .flashCommand(.focusWindow(.app(.previous)))),
      ("]w", .flashCommand(.focusWindow(.app(.next)))),
      ("[t", .flashCommand(.tabPrev)),
      ("]t", .flashCommand(.tabNext)),
      ("t", .flashCommand(.tabNew)),
      ("g1", .flashCommand(.tabSelect(index: 1))),
      ("g2", .flashCommand(.tabSelect(index: 2))),
      ("g3", .flashCommand(.tabSelect(index: 3))),
      ("g4", .flashCommand(.tabSelect(index: 4))),
      ("g5", .flashCommand(.tabSelect(index: 5))),
      ("g6", .flashCommand(.tabSelect(index: 6))),
      ("g7", .flashCommand(.tabSelect(index: 7))),
      ("g8", .flashCommand(.tabSelect(index: 8))),
      ("g9", .flashCommand(.tabSelect(index: 9))),
      ("g0", .flashCommand(.tabFirst)),
      ("g^", .flashCommand(.tabFirst)),
      ("g$", .flashCommand(.tabLast)),
      ("[m", .flashCommand(.tabMovePrev)),
      ("]m", .flashCommand(.tabMoveNext)),
      // vim's tab keys, and Vimium's: `gt` / `gT` and `K` / `J` switch, `<<` /
      // `>>` reorder. `<` and `>` are the key syntax's markers, so the
      // reference file spells them `<less>` and `<greater>`.
      ("gt", .flashCommand(.tabNext)),
      ("gT", .flashCommand(.tabPrev)),
      ("J", .flashCommand(.tabPrev)),
      ("K", .flashCommand(.tabNext)),
      ("<less><less>", .flashCommand(.tabMovePrev)),
      ("<greater><greater>", .flashCommand(.tabMoveNext)),
      // `ZZ` saves and quits, `ZQ` quits.
      ("ZZ", .flashCommand(.saveAndQuit(force: false))),
      ("ZQ", .flashCommand(.quitApp(force: false))),
      // `ctrl+w` is vim's window prefix: a chord followed by a key is a
      // sequence to the key syntax, read by the interpreter, never Carbon.
      ("ctrl+w h", .flashCommand(.focusWindow(.direction(.left)))),
      ("ctrl+w j", .flashCommand(.focusWindow(.direction(.down)))),
      ("ctrl+w k", .flashCommand(.focusWindow(.direction(.up)))),
      ("ctrl+w l", .flashCommand(.focusWindow(.direction(.right)))),
      ("ctrl+w w", .flashCommand(.focusWindow(.app(.next)))),
      ("ctrl+w q", .flashCommand(.windowClose)),
      ("ctrl+w c", .flashCommand(.windowClose)),
      ("ctrl+w W", .flashCommand(.focusWindow(.app(.previous)))),
      ("ctrl+w n", .flashCommand(.windowNew(private: false))),
      // vim's previous window: the one focused before this one.
      ("ctrl+w p", .flashCommand(.windowLast)),
      // vim moves the window to that edge; here it takes that half.
      (
        "ctrl+w H",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.leftHalf), screen: 0)))
      ),
      (
        "ctrl+w J",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.bottomHalf), screen: 0)))
      ),
      (
        "ctrl+w K",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.topHalf), screen: 0)))
      ),
      (
        "ctrl+w L",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.rightHalf), screen: 0)))
      ),
      (
        "ctrl+w o",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.maximized), screen: 0)))
      ),
      (
        "ctrl+w =",
        .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.centered), screen: 0)))
      ),
      ("ctrl+w s", .flashCommand(.paneSplitHorizontal)),
      ("ctrl+w v", .flashCommand(.paneSplitVertical)),
      ("ctrl+o", .flashCommand(.movementBack)),
      ("ctrl+i", .flashCommand(.movementForward)),
      ("H", .flashCommand(.historyBack)),
      ("L", .flashCommand(.historyForward)),
      // The app's own zoom (Surfingkeys, Tridactyl); `gs` is Vimium's page
      // source.
      ("zi", .flashCommand(.zoomIn)),
      ("zo", .flashCommand(.zoomOut)),
      ("z0", .flashCommand(.zoomReset)),
      ("gs", .flashCommand(.viewSource)),
      // `gm`, go to a monitor: every display shows its number, and the
      // pointer and keyboard focus go to the one typed. `2gm` goes to
      // display 2 at once. (vim's `gm` goes to the middle of the screen
      // line; this lands in the middle of a display.)
      ("gm", .flashCommand(.mouseScreens(.init(focus: true)))),
      // A mouse action is a prefix and a finisher. Prefixes are none,
      // `m` (move), `d` (double) and `c` (context, the right-click).
      // Finishers are `f` (a discovered target), `F` (the grid) and `s`
      // (one visible letter, then its hint). `c` is the operator Vim and
      // Vimium leave free; `r` is reload. Modifiers on the final hint key
      // (`hints.magic_modifiers`) still ride the click.
      //
      // Every prefix letter must be free of a mapping of its own. The
      // interpreter parks a key that is both an exact mapping and the prefix
      // of a longer one until `sequence_timeout_ms` elapses, so binding `t`
      // here would make a bare `t` (new tab) wait a full second. Triple
      // click is deliberately unbound for that reason — add `"tf"` in your
      // own config if you want it, and remove `t` with `"t" = false`.
      // `s` starts no other mapping, so the EasyMotion jump fires at once.
      ("f", .flashCommand(.mouseTarget(.click(.leftClick, modifiers: [])))),
      ("F", .flashCommand(.mouseGrid(.init(.click(.leftClick, modifiers: []))))),
      ("s", .flashCommand(.mouseBigram(.click(.leftClick, modifiers: [])))),
      ("mf", .flashCommand(.mouseTarget(.move))),
      ("mF", .flashCommand(.mouseGrid(.init(.move)))),
      ("ms", .flashCommand(.mouseBigram(.move))),
      ("df", .flashCommand(.mouseTarget(.click(.doubleClick, modifiers: [])))),
      ("dF", .flashCommand(.mouseGrid(.init(.click(.doubleClick, modifiers: []))))),
      ("ds", .flashCommand(.mouseBigram(.click(.doubleClick, modifiers: [])))),
      ("cf", .flashCommand(.mouseTarget(.click(.rightClick, modifiers: [])))),
      ("cF", .flashCommand(.mouseGrid(.init(.click(.rightClick, modifiers: []))))),
      ("cs", .flashCommand(.mouseBigram(.click(.rightClick, modifiers: [])))),
      // Vimium's `<a-f>`: a click chain, labels again after every click
      // until Escape. Command held on a label opens a link in a new tab.
      ("alt+f", .flashCommand(.mouseTarget(.multi(.leftClick, modifiers: [])))),
      ("u", .flashCommand(.undo)),
      ("ctrl+r", .flashCommand(.redo)),
      ("x", .flashCommand(.tabClose)),
      ("X", .flashCommand(.tabReopen)),
      ("r", .flashCommand(.reload(force: false))),
      ("R", .flashCommand(.reload(force: true))),
      ("y", .flashCommand(.yankSelection(register: nil))),
      // Outside text there is no cursor to put after or before: `p` and
      // `P` both paste at the app's insertion point. The text table puts
      // `p` after the cursor, as Vim does.
      ("p", .flashCommand(.paste(register: nil))),
      ("P", .flashCommand(.paste(register: nil))),
      ("/", .flashCommand(.find)),
      // `n` / `N` step through Find's matches (Cmd-G / Cmd-Shift-G by
      // convention): app actions like `/`, so NORMAL stays.
      ("n", .flashCommand(.findNext)),
      ("N", .flashCommand(.findPrevious)),
      ("?", .flashCommand(.showMappings)),
      // Escape is the app's own cancel (a popover, a dialog, a search);
      // hints, a half-typed key and an engaged field's Escape come first.
      ("<esc>", .flashCommand(.appCancel)),
      // `.` runs the last command again (a count before it replaces the
      // count it ran with); `q{reg}` and `@{reg}` record and play macros
      // while no mapping takes `q` or `@`.
      (".", .flashCommand(.macro(.repeatLast(count: nil)))),
    ]
    // Every built-in bracket-pair mapping follows vim-unimpaired repetition:
    // after `[x` or `]x`, additional presses of `x` repeat the action.
    let repeatableKeys = Set(
      raw.lazy.map(\.0).filter { $0.hasPrefix("[") || $0.hasPrefix("]") })
    return raw.map { (key, action) in
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
        preconditionFailure("default mapping key \"\(key)\" failed canonicalization")
      }
      return ModeMapping(
        key: canonical,
        action: action,
        repeatsOnFinalKey: repeatableKeys.contains(key))
    }
  }
}

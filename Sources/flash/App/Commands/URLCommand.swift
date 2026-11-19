import AppKit
import FlashCore

indirect enum URLCommand: Hashable, Sendable {
  case mouseTarget(MouseCommand)
  /// One letter of visible text in the focused window and on its status bar,
  /// then a hint bigram, then a click (`s`). Only `.click` and `.move`.
  case mouseBigram(MouseCommand)

  /// Entering or leaving a mode. An EasyMotion jump releases the keyboard
  /// for these and then runs them; other commands stay inside the jump.
  var changesMode: Bool {
    switch self {
    case .insertMode, .normalMode, .commandMode, .enterCommand, .terminalMode, .leaveMode,
      .layerMode, .visualMode, .visualReselect:
      return true
    default:
      return false
    }
  }
  /// `mouse target --scope=screen`: hints across the front-most surface of
  /// every app on the focused window's screen (click variants only).
  case mouseTargetScreen(MouseCommand)
  /// `mouse target --words`: a hint on every visible word of the focused
  /// window's text, landing on the word's leading edge (click, move, drag
  /// and select).
  case mouseTargetWords(MouseCommand)
  /// `mouse screens`: monitor select. A display by its number label, its
  /// `--index` or a step from the pointer's; the pointer lands on it and,
  /// with `--focus`, keyboard focus follows.
  case mouseScreens(ScreenSelectRequest)
  /// `mouse warp`: the pointer jumps to an edge or the centre of the focused
  /// window or its screen.
  case mouseWarp(MouseWarpRequest)
  /// `mouse step`: the pointer moves one text line or one character from the
  /// text under it; in HOLD that extends a text selection.
  case mouseStep(TextStep.Direction)
  /// `mouse step --to`: Vim's word and line jumps on the text under the
  /// pointer (`w`, `b`, `e`, `0`, `$`).
  case mouseJump(TextStep.Jump)
  /// `selection copy|paste|swap_ends`: copy the selected text or paste
  /// over it, ending a drag first.
  case selection(SelectionAction, register: String? = nil)
  /// `mouse nudge`: the pointer moves a fixed distance; in HOLD the held
  /// button drags what it grabbed.
  case mouseNudge(TextStep.Direction, distance: Int)
  /// `mouse position`: the saved pointer positions — save, hint, cycle,
  /// forget.
  case mousePosition(MousePositionRequest)
  case mouseGrid(MouseGridRequest)
  /// Re-click the last Flash-committed click point (sticky click). Repeats
  /// honour normal-mode counts (`3` + mapped key clicks three times).
  case mouseRepeat
  /// Freestyle keyboard cursor control (pointer mode).
  case mousePointer
  /// Press, release or toggle a button at the pointer; moves drag while it
  /// is held.
  case mouseButton(MouseButtonRequest)
  /// `mode hold`: grab what is under the pointer with `button` held
  /// (HOLD), or drop it there when that button is already held. Sugar for
  /// `mouse button --state=toggle --mode=hold`; bound to Command-Control-H.
  case holdMode(MouseButtonKind)
  /// Focus the first (or count-th) editable text input in the focused window
  /// while preserving the current mode.
  case focusInput
  /// `input line_start|line_end|char_left|char_right|line_up|line_down|
  /// document_start|document_end|select_*`: one cursor move, or one step of
  /// the app's own selection, in the focused editable text, asked of the
  /// focused app like every source command. Nothing editable focused, nothing
  /// sent. None edits the text: Flash never does.
  case inputMotion(InputMotion)
  /// `move <direction>`: NORMAL's `h` `j` `k` `l`, half pages, pages and
  /// edges, resolved by where the focus sits (`MoveResolution`): the caret
  /// in text, the selection in a list, a scroll in a page or a terminal.
  case move(MoveCommand)
  /// `cursor <motion>`: one of Vim's motions in the focused text, computed
  /// from the text Accessibility gives (`CursorCommand`).
  case cursor(CursorCommand)
  /// `scroll cursor_top|cursor_middle|cursor_bottom`: Vim's `zt` `zz` `zb`.
  case scrollCursor(ScrollCursorPosition)
  /// `mode visual [--line]`: VISUAL, a selection the motions grow; the same
  /// kind again leaves it, the other kind switches.
  case visualMode(VisualKind)
  /// `mode visual --reselect`, vim's `gv`: the last VISUAL range again, in
  /// the engaged field it was made in.
  case visualReselect
  /// Hint-label the focused window's scroll areas; committing moves the
  /// pointer into the chosen one so subsequent scroll commands land there.
  case scrollTarget
  /// Hint-label the Dock's items (apps, minimized windows, trash).
  case mouseDock
  /// Hint-label the menu bar: the focused app's menu titles (AX) and the
  /// status items (WindowServer geometry only).
  case mouseMenuBar
  /// Hint-label what Notification Center shows: banners, alerts and their
  /// buttons, and the panel when it is open.
  case mouseNotifications
  case normalMode
  case leaveMode
  /// Restart the focused or named popup's process.
  case popupRestart(name: String?)
  /// Quit the focused or named popup's process.
  case popupQuit(name: String?)
  /// `mode insert`, vim's `i`: the one way into INSERT. It takes no
  /// placement and no change, since Flash never edits text.
  case insertMode
  case commandMode
  /// TERMINAL mode on a popup: show it standalone and focus its terminal;
  /// no name opens the built-in `terminal` popup. `mode leave` closes it.
  case terminalMode(name: String?)
  /// `mode layer --name=<name>`: read keys from `[mode.layers.<name>]`
  /// until Escape or `mode leave`.
  case layerMode(name: String)
  case scroll(NormalModeDispatcher.ScrollKind)
  case reload(force: Bool)
  case undo
  case redo
  case archive
  case resourceNext
  case resourcePrevious
  case tabClose
  case find
  /// `app find_next` / `app find_previous`: the next and previous Find match,
  /// app actions like Find itself (Cmd-G / Cmd-Shift-G by convention) that
  /// never enter INSERT.
  case findNext
  case findPrevious
  /// `app switch`: the flashlight on what is running.
  case appSwitch
  /// `mode flashlight [--query=<text>] [--restore-mode]`: the flashlight over
  /// every source, pre-filled with `query`. `restoreMode` returns to the mode
  /// it opened from once it closes, as `mode command --restore-mode` does.
  case flashlight(query: String?, restoreMode: Bool)
  /// Open command-line mode pre-seeded with `input`. `restoreMode` is set
  /// when the mapping carries `--restore-mode`; on exit (submit or cancel)
  /// the command-line dismiss restores whichever mode was active when the
  /// command fired instead of bouncing the user to normal. The flashlight
  /// has its own `mode flashlight`, whose `--query` needs no trailing space.
  case enterCommand(input: String, restoreMode: Bool)
  case copyURL
  /// Yank (copy) the focused app's current selection into a register.
  /// `register == nil` (and the synonyms `+` / `*` / `"`) targets the system
  /// clipboard; a named register (`a`–`z`, `0`–`9`) is an in-process buffer
  /// that survives clipboard churn. An uppercase name appends to the matching
  /// lowercase register. See ``RegisterStore``.
  case yankSelection(register: String?)
  /// Paste a register into the focused app with its own paste command: the
  /// clipboard as it is for the unnamed register, a named register by
  /// borrowing the clipboard and giving the copy back. Same register grammar
  /// as ``yankSelection(register:)``.
  case paste(register: String?, after: Bool = false)
  case tabNext
  case tabPrev
  case tabFirst
  case tabLast
  case tabSelect(index: Int?)
  case tabMovePrev
  case tabMoveNext
  case tabReopen
  /// Cycle to the next / previous split inside the focused terminal window.
  /// Terminal sources (tmux) perform these as core commands they declare; a
  /// terminal without one receives the native ⌘] / ⌘[ chord, and
  /// non-terminal apps ignore the command.
  case paneNext
  case panePrev
  /// Create a side-by-side or stacked split inside the focused window.
  /// Terminal sources (tmux) perform these; the host has no generic
  /// native-key fallback for apps that do not support split panes.
  case paneSplitVertical
  case paneSplitHorizontal
  /// Close the active split inside the focused window. Tmux performs this;
  /// non-terminal apps should keep using `tab close`.
  case paneClose
  case historyBack
  case historyForward
  case movementBack
  case movementForward
  case appPrev
  case appNext
  case quitApp(force: Bool)
  case saveAndQuit(force: Bool)
  /// `app close`, vim's `:q`: the tab; in an app with no tab to close, its
  /// window, and the app itself with its last window (`AppClose`).
  case appClose
  case tabNew
  /// The focused app's save, print, open-document, new-window and
  /// close-window commands and its clipboard, each resolved like every
  /// command asked of the app: a source, then the app's plugin `bindings`.
  case save
  case print
  case documentOpen
  /// `window new [--private]`: `--private` asks a browser for a private
  /// window, a binding key of its own (`window new --private`).
  case windowNew(private: Bool)
  case windowClose
  case clipboardCopy
  case clipboardPaste
  /// `clipboard show`, `delete`, `pin` and `unpin`: the history page, or one
  /// entry by id.
  case clipboardHistory(action: String, id: String?, offset: Int?)
  /// `clipboard restore --id=<id> [--paste] [--plain]`: put a history entry
  /// back on the clipboard, and paste it into the focused app with `paste`.
  case clipboardRestore(id: String, paste: Bool, plain: Bool)
  /// `mouse gesture`: a trackpad gesture by finger count and motion, emulated at
  /// the pointer (`TrackpadGesture`).
  case trackpadGesture(fingers: Int, motion: TrackpadGesture.Motion)
  /// `app look_up`: the focused app's Look Up (definition, data detectors) on the
  /// word under the pointer, a three-finger tap on a trackpad.
  case lookUp
  /// `app zoom_in`, `app zoom_out` and `app zoom_reset`: the focused app's
  /// own zoom (Command-Plus, Command-Minus, Command-0 by convention).
  case zoomIn
  case zoomOut
  case zoomReset
  /// `app view_source`: the focused browser's page source.
  case viewSource
  /// `document save_as`, `export_pdf`, `revert`, `duplicate`, `rename` and
  /// `page_setup`: the focused document's own File-menu commands, asked of
  /// the app like `app save`. `revert` asks first (`hostConfirmation`).
  case documentSaveAs
  case documentExportPDF
  case documentRevert
  case documentDuplicate
  case documentRename
  case documentPageSetup
  /// `app settings`, `app select_all`, `app help` and `app cancel` (NORMAL's
  /// Escape): the conventions apps share, asked of the focused app.
  case appSettings
  case selectAll
  case appHelp
  case appCancel
  /// `app stop`, `app downloads` and `app developer_tools`: a browser's.
  case appStop
  case appDownloads
  case developerTools
  /// `window close_all` (after asking) and `window zoom`: the focused app's
  /// windows, asked of the app.
  case windowCloseAll
  case windowZoom
  /// `url bookmark`, `url edit` and `history show`: a browser's bookmark,
  /// address bar and history.
  case urlBookmark
  case urlEdit
  case historyShow
  /// `tab duplicate`, `tab pin`, `tab mute` and `tab detach`: the current
  /// tab, asked of the app.
  case tabDuplicate
  case tabPin
  case tabMute
  case tabDetach
  /// `app hide`, `app hide_others`, `app show_all` and `app raise`: which
  /// apps show, Flash's own (`NSRunningApplication`), never a chord.
  case appVisibility(AppVisibilityAction)
  /// `menu press --path=<Menu,Item,…>`: press a menu-bar item of the focused
  /// app by its titles, as a `bindings` menu item is pressed. A user's
  /// escape hatch, like `key send`: no default or bundled mapping uses it.
  case menuPress(path: [String])
  case showAlert(AlertCommand)
  case dismissAlert
  /// Ask before running a command the user cannot undo: the question is the
  /// alert, `y` runs the wrapped command, any other key closes it.
  case confirm(ConfirmCommand)
  case showUsage(topic: String?)
  case showMappings
  case showPlugins
  /// `plugins reload`: stop and restart every loaded plugin.
  case reloadPlugins
  /// `logs show`: the logs view of the browser help.
  case showLogs
  /// `commands show`: the command catalog of the browser help.
  case showCommands
  /// `monitors show`: the help page listing every monitor and its state.
  case showMonitors
  /// `telemetry show`: the help page of received OpenTelemetry data and
  /// the receiver's and exporter's state.
  case showTelemetry
  case showAbout
  case dismissHints
  case quit
  case openApp(name: String)
  case pluginCommand(command: String, subcommand: String, args: [String])
  case moveWindow(MoveWindowParams)
  case focusWindow(WindowFocusRequest)
  case windowState(WindowStateAction)
  /// `window switch`: every window, most recently focused first, labeled
  /// for one-key picks; again while it is up, the next one. See
  /// `WindowSwitcherCommands.swift`.
  case windowSwitch
  /// `window last`: the window focused before this one, as tmux's
  /// `last-window` and vim's `ctrl-w p`. See `WindowSwitcherCommands.swift`.
  case windowLast
  /// `tile …`: the focused window's place in its workspace's tiling tree.
  /// Fails while `[tiling]` is off. See `TilingEngine`.
  case tile(TilingCommand)
  /// `workspace …`: emulated workspaces over the displays. See
  /// `TilingWorkspaces`.
  case workspace(WorkspaceCommand)
  /// `status set` / `status clear`: a value pushed into a declared
  /// `[statusbar.sources.<name>]`, as if its command had printed it.
  case statusPush(StatusPush)
  /// `status refresh`: run a shown `[statusbar.sources.<name>]` now.
  case statusRefresh(source: String)
  /// `notify send` / `notify clear`: a native macOS notification, apart
  /// from `alert show`'s centred alert.
  case notify(NotifyCommand)
  /// `logs write`: one line into Flash's log.
  case logWrite(LogWrite)
  /// `metrics record`: one measurement into Flash's metrics.
  case metricRecord(MetricRecord)
  /// `menu choose --file=<path>`: pick one of the file's lines in the
  /// flashlight; the command answers with it (`MenuChoice`).
  case menuChoose(file: String, prompt: String? = nil)
  /// `macro record|stop|play|repeat`: vim's `q`, `@` and `.` over commands.
  case macro(MacroCommand)
  /// `config reload` (`:so[urce]`) re-reads the configuration now;
  /// `config edit` opens the file in its default app.
  case configReload
  case configEdit
  /// `startup run`: run `[startup] run` again, as launch did. See
  /// `StartupRunner`.
  case startup(StartupCommand)
  /// `updates check` and `updates install`; see `UpdateController`.
  case updates(UpdatesCommand)
  /// `mark set --letter=<x>` and `mark jump --letter=<x>`: save the
  /// focused app under a letter or digit, or bring it back. See `MarkStore`.
  case marks(MarkCommand)
  /// One printed Apple function-row action (brightness, sound, …).
  case systemKey(SystemKeyboard.RowKey)
  /// `desktop`, `missioncontrol`, `appwindows`, `launchpad`,
  /// `notificationcenter` and `controlcenter`, each `show`, `hide` or
  /// `toggle`. See `SystemSurfaceController`.
  case systemSurface(SystemSurfaceCommand)
  /// A plain F1–F20 keystroke, with no modifiers.
  case functionKey(Int)
  /// One arrow key, optionally shifted. HYPER binds the layout's ESDF positions here.
  case arrow(direction: WindowFocusDirection, shift: Bool)
  case sendKey(keys: String, keyCode: CGKeyCode, flagsRawValue: UInt64)
  case sendKeys(keys: String, keyCodes: [CGKeyCode], flagsRawValues: [UInt64])
}

extension URLCommand {
  /// Whether a topic typed alone may run this, the one action of its that
  /// does (`:mappings`, `flash logs`): a command that only shows a page or
  /// a surface and changes nothing. Any other, `resident quit` above
  /// all, runs only when its action is typed.
  var impliedByItsTopic: Bool {
    switch self {
    case .showMappings, .showLogs, .showCommands, .showMonitors, .showTelemetry, .showAbout,
      .showUsage(topic: nil):
      return true
    default:
      return false
    }
  }

  /// The command this asks the focused app to perform, resolved through the
  /// sources that declare it and then the app's plugin `bindings`; nil for a
  /// command Flash performs itself. Its words are this command's argv after
  /// the two command words, so a mapping, the CLI, a manifest and a plugin's
  /// `perform` all spell one thing. `tab select` (counted) and
  /// `scroll top`/`scroll bottom` (Flash scrolling first) reach it on their
  /// own paths.
  var sourceCommand: SourceCommand? {
    switch self {
    case .reload, .undo, .redo, .find, .findNext, .findPrevious, .archive, .resourceNext,
      .resourcePrevious, .tabNext, .tabPrev, .tabFirst, .tabLast, .tabSelect, .tabNew, .tabClose,
      .tabReopen, .tabMovePrev, .tabMoveNext, .paneNext, .panePrev, .paneSplitVertical,
      .paneSplitHorizontal, .paneClose, .historyBack, .historyForward, .save, .print,
      .documentOpen, .windowNew, .windowClose, .clipboardCopy, .clipboardPaste, .lookUp, .zoomIn,
      .zoomOut, .zoomReset, .viewSource, .inputMotion, .documentSaveAs, .documentExportPDF,
      .documentRevert, .documentDuplicate, .documentRename, .documentPageSetup, .appSettings,
      .selectAll, .appHelp, .appCancel, .appStop, .appDownloads, .developerTools,
      .windowCloseAll, .windowZoom, .urlBookmark, .urlEdit, .historyShow, .tabDuplicate, .tabPin,
      .tabMute, .tabDetach:
      return Self.sourceCommand(of: argv)
    case .scroll(let kind) where kind == .top || kind == .bottom:
      return Self.sourceCommand(of: argv)
    // A list's own moves; a half page or a page repeats the one-step move.
    case .move(let move) where move.step == move:
      return Self.sourceCommand(of: argv)
    // A text motion's binding is what runs where the app gives no text.
    case .cursor(.motion):
      return Self.sourceCommand(of: argv)
    default:
      return nil
    }
  }

  private static func sourceCommand(of argv: [String]) -> SourceCommand? {
    guard argv.count >= 3, argv[0] == "flash", let name = CommandName("\(argv[1]) \(argv[2])")
    else { return nil }
    return SourceCommand(name: name, arguments: Array(argv.dropFirst(3)))
  }

  /// `sourceCommand` for a command known to be one (`URLCommand.save`,
  /// `.clipboardPaste`, a counted `.tabSelect`).
  var requiredSourceCommand: SourceCommand {
    guard let command = sourceCommand else {
      preconditionFailure("\(diagnosticDescription) is not a command asked of the focused app")
    }
    return command
  }

  /// Whether a NORMAL count repeats the command; the first and last tab are
  /// one place however often they are asked for.
  var sourceCommandRepeats: Bool {
    switch self {
    case .tabFirst, .tabLast, .move(.top), .move(.bottom): return false
    default: return true
    }
  }
}

extension URLCommand {
  /// The command line `mode flashlight` opens with: `flashlight `, then the
  /// query and one space, so a `@type` or `!bang` reads as confirmed and
  /// the next word starts after it. The matcher trims a plain query's space.
  static func flashlightInput(query: String?) -> String {
    guard let query = query?.trimmed, !query.isEmpty else { return "flashlight " }
    return "flashlight \(query) "
  }
}

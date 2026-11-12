import AppKit
import FlashCore

// Flash's command table. Every command is `flash <topic> <action>
// [--name=value ...]`: the words a terminal sends the resident over its
// socket (`IPCServer`), a mapping names (`"f" = ["flash", "mouse",
// "target"]`, parsed at load time through `URLEventHandler.parse(words:)`)
// and the command line resolves, so every entry point shares one source of
// truth.

indirect enum URLCommand: Hashable {
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
  /// The default audio devices and what is playing: `volume up`,
  /// `volume down`, `volume mute`, `audio input`, `audio output` and
  /// `media status`. See `MediaController`.
  case media(MediaCommand)
  /// The resident's keep-awake power assertions: `caffeinate on`,
  /// `caffeinate off`, `caffeinate toggle` and `caffeinate status`. See
  /// `CaffeinateController`.
  case caffeinate(CaffeinateRequest)
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
  /// `notes open`, `notes refresh` and their reminders and contacts twins:
  /// open the app, or relist its flashlight catalog. See `AppleCatalogs`.
  case appleCatalog(AppleCatalogCommand)
  /// `calendar join` and `calendar next`: the next or current event's
  /// meeting link, or the event itself. See `CalendarEvents`.
  case calendar(CalendarCommand)
  /// `mark set --letter=<x>` and `mark jump --letter=<x>`: save the
  /// focused app under a letter or digit, or bring it back. See `MarkStore`.
  case marks(MarkCommand)
  /// One printed Apple function-row action (brightness, sound, …).
  case systemKey(SystemKeyboard.RowKey)
  /// `desktop`, `missioncontrol`, `appwindows`, `launchpad`,
  /// `notificationcenter` and `controlcenter`, each `show`, `hide` or
  /// `toggle`. See `SystemSurfaceController`.
  case systemSurface(SystemSurfaceCommand)
  /// `screen lock`, `system sleep`, `system restart`, …: a machine or session
  /// action Flash performs itself. Restart, shut down, log out and emptying
  /// the Trash ask first.
  case systemAction(SystemAction)
  /// `process kill --pid=<pid>`: SIGTERM one process, after asking.
  case processKill(pid: pid_t)
  /// A plain F1–F20 keystroke, with no modifiers.
  case functionKey(Int)
  /// One arrow key, optionally shifted. HYPER binds the layout's ESDF positions here.
  case arrow(direction: WindowFocusDirection, shift: Bool)
  case sendKey(keys: String, keyCode: CGKeyCode, flagsRawValue: UInt64)
  case sendKeys(keys: String, keyCodes: [CGKeyCode], flagsRawValues: [UInt64])
}

/// `app hide|hide_others|show_all|raise`: the focused app hidden, every other
/// app hidden, every hidden app shown, or every window of the focused app
/// brought to the front (the Window menu's Bring All to Front).
enum AppVisibilityAction: String, CaseIterable, Hashable {
  case hide
  case hideOthers = "hide_others"
  case showAll = "show_all"
  case raise
}

enum WindowStateAction: Hashable {
  enum FullscreenState: String, Hashable {
    case on, off, toggle
  }

  case minimize
  case restore
  case fullscreen(FullscreenState)
}

extension URLCommand {
  /// Whether a topic typed alone may run this, the one action of its that
  /// does (`:mappings`, `flash logs`): a command that only shows a page or
  /// a surface and changes nothing. Any other, `display sleep` or
  /// `screen lock` above all, runs only when its action is typed.
  var impliedByItsTopic: Bool {
    switch self {
    case .showMappings, .showLogs, .showCommands, .showMonitors, .showTelemetry, .showAbout,
      .showUsage(topic: nil), .media(.status):
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

struct AlertCommand: Hashable {
  let message: String
  let duration: TimeInterval?
  let style: StatusAlert.Style

  /// The alert the command shows: one line, for the style's default dwell
  /// unless the call passed `--duration`.
  var alert: StatusAlert {
    .message(message, duration: duration.map { .seconds($0) } ?? .standard, style: style)
  }

  var argTokens: [String] {
    var tokens = ["--message=\(message)"]
    if let duration {
      tokens.append("--duration=\(duration)")
    }
    if style != .standard {
      tokens.append("--style=\(style.rawValue)")
    }
    return tokens
  }
}

/// `alert confirm --prompt=<text> --command=<topic action [--arg=value ...]>`:
/// the question and the Flash command it gates. The wrapped command is any
/// command a mapping could name after `flash`, a plugin command included; a
/// confirmation cannot wrap another confirmation.
struct ConfirmCommand: Hashable {
  let prompt: String
  let command: URLCommand

  /// The `--command` value: the wrapped command and its arguments,
  /// space-joined.
  var commandText: String {
    command.argv.dropFirst().joined(separator: " ")
  }
}

/// `mouse grid`: the click the grid commits, plus how the grid starts.
struct MouseGridRequest: Hashable {
  var mouse: MouseCommand
  /// `--zoom-to-depth=N`: start N steps deep on the cell under the pointer.
  var zoomToDepth: Int?
  /// `--bisect`: halves and quadrants instead of the keyboard-shaped grid.
  var bisect: Bool

  init(_ mouse: MouseCommand, zoomToDepth: Int? = nil, bisect: Bool = false) {
    self.mouse = mouse
    self.zoomToDepth = zoomToDepth
    self.bisect = bisect
  }

  /// Arg tokens in diagnostic form: the mouse tokens, then the grid's own.
  var argTokens: [String] {
    var tokens = mouse.argTokens
    if bisect { tokens.append("--bisect") }
    if let zoomToDepth { tokens.append("--zoom-to-depth=\(zoomToDepth)") }
    return tokens
  }
}

/// `selection <action>`: what to do with the selected text. Copy and paste
/// go through `register yank` and `register paste`; nothing cuts, since
/// Flash never edits text. None of them changes the mode.
enum SelectionAction: String, CaseIterable, Hashable {
  case copy, paste
  /// VISUAL's `o`: the moving end goes to the other end.
  case swapEnds = "swap_ends"

  /// Copy and paste name a register; swapping the ends takes none.
  var takesRegister: Bool { self == .copy || self == .paste }
}

/// `mouse warp`: where the pointer jumps. `area` is the focused window or
/// the display it is on; `edge` the centre or one side, a few points inside
/// it so the pointer still sits on the area.
struct MouseWarpRequest: Hashable {
  enum Area: String, Hashable, CaseIterable {
    case window, screen
  }
  enum Edge: String, Hashable, CaseIterable {
    case center, top, bottom, left, right
  }
  var area: Area = .window
  var edge: Edge = .center

  var argTokens: [String] {
    ["--area=\(area.rawValue)", "--edge=\(edge.rawValue)"]
  }

  /// The point `edge` names inside `frame` (NSScreen coordinates), `inset`
  /// points in from a side.
  func point(in frame: CGRect, inset: CGFloat = 8) -> CGPoint {
    let dx = min(inset, frame.width / 2)
    let dy = min(inset, frame.height / 2)
    switch edge {
    case .center: return CGPoint(x: frame.midX, y: frame.midY)
    case .top: return CGPoint(x: frame.midX, y: frame.maxY - dy)
    case .bottom: return CGPoint(x: frame.midX, y: frame.minY + dy)
    case .left: return CGPoint(x: frame.minX + dx, y: frame.midY)
    case .right: return CGPoint(x: frame.maxX - dx, y: frame.midY)
    }
  }
}

/// `mouse position`: one action on the saved pointer positions.
enum MousePositionRequest: Hashable {
  /// Remember where the pointer is.
  case save
  /// Forget the saved position the pointer is on.
  case unsave
  /// Forget every saved position (of this app, when the history is per app).
  case clear
  /// Hint every saved position and act on the one you pick.
  case hints(MouseCommand)
  /// Jump to the saved position after / before the one the pointer is on.
  case next
  case previous

  var argTokens: [String] {
    switch self {
    case .save: return ["--action=save"]
    case .unsave: return ["--action=unsave"]
    case .clear: return ["--action=clear"]
    case .hints(let command): return ["--action=hints"] + command.argTokens
    case .next: return ["--action=next"]
    case .previous: return ["--action=previous"]
    }
  }
}

/// `window focus`: the nearest window in a direction, or the next one in
/// the z-order.
enum WindowFocusCycle: String, Hashable, CaseIterable {
  /// The window just below the focused one in the z-order (wrapping).
  case next
  /// The window just above it in the z-order (wrapping).
  case previous
  /// The frontmost window below the focused one that it overlaps.
  case behind
}

/// `window next` / `window previous`: the focused app's windows, in the order
/// the first press of a run found them.
enum WindowAppCycle: String, Hashable, CaseIterable {
  case next
  case previous
}

enum WindowFocusRequest: Hashable {
  case direction(WindowFocusDirection)
  case cycle(WindowFocusCycle)
  case app(WindowAppCycle)

  /// A `window focus --direction=` value.
  init?(direction rawValue: String) {
    if let direction = WindowFocusDirection(rawValue: rawValue) {
      self = .direction(direction)
    } else if let cycle = WindowFocusCycle(rawValue: rawValue) {
      self = .cycle(cycle)
    } else {
      return nil
    }
  }
}

/// `--gesture`: a trackpad gesture performed at the picked point instead of
/// a click. The pointer lands on the point first, as with `--move`.
enum TargetGesture: String, CaseIterable, Hashable {
  /// Look Up (three-finger tap): the app's look-up action on the word under
  /// the pointer.
  case lookUp = "look_up"
  /// Smart zoom (two-finger double tap) at the point.
  case smartZoom = "smart_zoom"
}

enum MouseCommand: Hashable {
  case click(JumpAction, modifiers: ClickModifiers)
  case move
  /// `mouse target --copy-url` (Vimium's `yf`): label only the targets that
  /// carry a URL, and copy the chosen one's instead of clicking it.
  case copyURL
  /// `mouse target --copy-text` (Wooshy's ⌘C): label only the targets with
  /// text, and copy the chosen one's (its label as Flash read it).
  case copyText
  /// The pointer lands on the point, then the trackpad gesture runs there.
  case gesture(TargetGesture)
  /// Two-phase drag: the first commit picks the grab point, the second picks
  /// the drop point, then the dispatcher synthesizes one continuous
  /// down→dragged…→up gesture. Modifiers are held for the whole gesture
  /// (option-drag copy, cmd-drag move, …).
  case drag(modifiers: ClickModifiers)
  /// Two-phase text selection: the first commit clicks to set the caret, the
  /// second shift-clicks to extend the selection to that point — the standard
  /// macOS gesture, so it works across line wraps and never turns into an
  /// accidental drag of an existing selection.
  case select(modifiers: ClickModifiers)
  /// Multi-click session (a click chain): each commit performs `action`,
  /// then the targets are discovered again (or the grid restarts) for the
  /// next pick; Escape ends the session (`ClickChain`). Never a secondary
  /// click: its menu would take the keyboard.
  case multi(JumpAction, modifiers: ClickModifiers)
  /// Precision session (`mouse target` only): the matched hint enters an
  /// adjustment sub-state — snap the click point to the target's bounding-box
  /// edges or interpolate across its width — before the commit key clicks.
  case adjust(JumpAction, modifiers: ClickModifiers)
  /// Seek & click (`mouse target` only): type visible label text to filter
  /// the targets, Tab cycles, Return commits the selection with `action`.
  case search(JumpAction, modifiers: ClickModifiers)
  /// Path session (`mouse target` only): the first commit picks one end,
  /// the second the other, and every target between them in reading order
  /// gets `action`, in that order.
  case path(JumpAction, modifiers: ClickModifiers)
  /// Sticky session (`mouse target` only): each commit performs `action`
  /// and the same labels stay up, with no new walk, until Escape ends it.
  /// Never a secondary click, as for `multi`.
  case sticky(JumpAction, modifiers: ClickModifiers)

  var action: JumpAction {
    switch self {
    case .click(let action, _): return action
    case .multi(let action, _): return action
    case .adjust(let action, _): return action
    case .search(let action, _): return action
    case .path(let action, _): return action
    case .sticky(let action, _): return action
    case .move, .gesture, .drag, .select, .copyURL, .copyText: return .leftClick
    }
  }

  var modifiers: ClickModifiers {
    switch self {
    case .click(_, let modifiers): return modifiers
    case .drag(let modifiers): return modifiers
    case .select(let modifiers): return modifiers
    case .multi(_, let modifiers): return modifiers
    case .adjust(_, let modifiers): return modifiers
    case .search(_, let modifiers): return modifiers
    case .path(_, let modifiers): return modifiers
    case .sticky(_, let modifiers): return modifiers
    case .move, .gesture, .copyURL, .copyText: return []
    }
  }

  var isSticky: Bool {
    if case .sticky = self { return true }
    return false
  }

  /// A session that keeps its labels up after a commit (`--multi`,
  /// `--sticky`).
  var repeats: Bool { isMulti || isSticky }

  /// This command as a plain click of its action and modifiers: what a
  /// surface that has no session shapes of its own (the grid, a switched
  /// surface) performs.
  var asClick: MouseCommand {
    switch self {
    case .move, .gesture, .copyURL, .copyText: return self
    case .drag(let modifiers): return .drag(modifiers: modifiers)
    case .select(let modifiers): return .select(modifiers: modifiers)
    case .multi: return self
    case .click, .adjust, .search, .path, .sticky:
      return .click(action, modifiers: modifiers)
    }
  }

  /// A count typed before a mouse finisher is a finger count, the way a
  /// trackpad reads it: two fingers turn a click into a secondary click and a
  /// double click into smart zoom; three fingers turn a click into Look Up.
  /// Every other count, and every other command, is unchanged.
  func withFingers(_ fingers: Int) -> MouseCommand {
    switch (fingers, self) {
    case (2, .click(.leftClick, let modifiers)): return .click(.rightClick, modifiers: modifiers)
    case (2, .click(.doubleClick, let modifiers)) where modifiers.isEmpty:
      return .gesture(.smartZoom)
    case (3, .click(.leftClick, let modifiers)) where modifiers.isEmpty: return .gesture(.lookUp)
    default: return self
    }
  }

  var isDrag: Bool {
    if case .drag = self { return true }
    return false
  }

  var isSelect: Bool {
    if case .select = self { return true }
    return false
  }

  var isMulti: Bool {
    if case .multi = self { return true }
    return false
  }

  var isSearch: Bool {
    if case .search = self { return true }
    return false
  }
}

/// A proportional frame for `flash window move`. Percentages are relative to
/// the target screen's Flash-usable frame. `x` grows from the left and `y`
/// grows from the top so the CLI stays independent of AppKit's Y-up space.
struct ProportionalWindowFrame: Hashable {
  let xPercent: Double
  let yPercent: Double
  let widthPercent: Double
  let heightPercent: Double
}

/// Semantic window geometry retained across explicit screen moves and display
/// topology changes. Named positions are shortcuts; proportional frames carry
/// the user's exact size and placement intent.
enum WindowLayout: Hashable {
  case position(WindowPosition)
  case proportional(ProportionalWindowFrame)
}

/// Geometry for `flash window move`. Named positions map the focused window to
/// a fixed slot of the target screen's Flash-usable frame: `visibleFrame` plus
/// Flash's own top status-bar reservation folded in so a slot's height is the
/// height the user actually sees. A proportional layout supplies all of
/// `x`, `y`, `width`, and `height` as percentages of that same usable frame.
///
/// Layout and monitor selection are orthogonal controls:
///
/// - `layout` (optional): named slot or complete proportional frame of the target screen's
///   Flash-usable frame. When omitted, the window keeps its shape and
///   is only translated (proportionally remapped) onto the target
///   screen.
/// - `screen` (optional): relative monitor offset. `0` (or omitted)
///   stays on the window's current screen. `+N` / `-N` cycle forward
///   / backward through `NSScreen.screens` with modulo wrap.
///
/// The parser rejects the empty form (`flash window move`) so a mapping
/// that forgot both keys fails at config load instead of firing a silent
/// no-op on every press.
struct MoveWindowParams: Hashable {
  let layout: WindowLayout?
  let screen: Int
}

/// The command table and the names, topics and suggestions derived from it.
enum URLEventHandler {
  static func rejectionMessage(_ invocation: String) -> String {
    var words = invocation.split(separator: " ").map(String.init)
    if let first = words.first, first == "flash" || first.hasSuffix("/flash") {
      words.removeFirst()
    }
    // An argument's `@<type>` that names no type: say which type it meant.
    let values = words.map { $0.split(separator: "=", maxSplits: 1).last.map(String.init) ?? $0 }
    let typeHint = ResourceTypes.firstInvalidToken(in: values.joined(separator: " ")).map {
      " " + ResourceTypes.invalidTokenMessage($0)
    }
    let hint =
      typeHint
      ?? suggestionPhrase(suggestedCommands(for: words)).map { " Did you mean \($0)?" } ?? ""
    return
      "Unsupported command or invalid arguments: \(invocation).\(hint) Check the command and its "
      + "configuration or mapping."
  }

  /// The commands `words` most likely mean when they name none: those whose
  /// every word appears in what was typed (`enter_insert_mode` is `mode
  /// insert`), the most specific first; failing that, those containing every
  /// typed word (`quit`), shortest first. At most three. Snake case splits
  /// into words and a plural `s` folds on both sides. Only a suggestion:
  /// nothing runs under the typed name.
  static func suggestedCommands(for words: [String]) -> [String] {
    let typed = words.filter { !$0.hasPrefix("-") }
    guard !typed.isEmpty else { return [] }
    if typed.count >= 2, commands[typed.prefix(2).joined(separator: " ")] != nil { return [] }
    let typedWords = suggestionWords(typed.joined(separator: "_"))
    guard !typedWords.isEmpty else { return [] }
    let names = commandNames.map(\.description)
    var named: [String] = []
    var specificity = 0
    for name in names {
      let words = suggestionWords(name)
      guard words.allSatisfy(typedWords.contains) else { continue }
      if words.count > specificity {
        named = [name]
        specificity = words.count
      } else if words.count == specificity {
        named.append(name)
      }
    }
    if !named.isEmpty { return Array(named.sorted().prefix(3)) }
    let containing = names.filter { Set(typedWords).isSubset(of: Set(suggestionWords($0))) }
    return Array(
      containing.sorted { (suggestionWords($0).count, $0) < (suggestionWords($1).count, $1) }
        .prefix(3))
  }

  private static func suggestionWords(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " }).map { word in
      word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
    }
  }

  /// `` `a` ``, `` `a` or `b` `` or `` `a`, `b` or `c` ``; nil for none.
  static func suggestionPhrase(_ names: [String]) -> String? {
    let quoted = names.map { "`\($0)`" }
    guard let last = quoted.last else { return nil }
    guard quoted.count > 1 else { return last }
    return quoted.dropLast().joined(separator: ", ") + " or " + last
  }

  /// Every Flash command, sorted: `flash <topic> <action>`.
  static let commandNames: [CommandName] = commands.keys.compactMap(CommandName.init).sorted()

  /// The topics Flash owns: every command's, and the queries'. A plugin
  /// command name is never one of them.
  static let topics: Set<String> = Set(
    commandNames.map(\.topic) + FlashQuery.allCases.map(\.name.topic))

  /// Whether `word` is one of Flash's topics.
  static func isTopic(_ word: String) -> Bool {
    topics.contains(word)
  }

  /// The commands of `topic`, sorted by action.
  static func commandNames(of topic: String) -> [CommandName] {
    commandNames.filter { $0.topic == topic }
  }

  /// The commands that ask the focused app for something: every table
  /// command whose bare form is a source command (``URLCommand/sourceCommand``).
  /// A plugin performs one by declaring it in `commands[]`; `bindings`
  /// declare what an app does for one.
  static let sourceCommandNames: Set<CommandName> = Set(
    commandNames.filter { name in
      commands[name.description]?.command(arguments: [:])?.sourceCommand != nil
    })

  /// Every key a manifest `bindings` entry may use, sorted: each source
  /// command's bare key, plus each bool-flag variant that still yields a
  /// source command (`app reload --force`).
  static let sourceCommandBindingKeys: [CommandBindingKey] = {
    var keys = Set<CommandBindingKey>()
    for name in sourceCommandNames {
      guard let definition = commands[name.description] else { continue }
      keys.insert(CommandBindingKey(name))
      for parameter in definition.parameters {
        guard case .flag = parameter.kind,
          let command = definition.command(arguments: [parameter.name: "1"])?.sourceCommand
        else { continue }
        keys.insert(CommandBindingKey(command))
      }
    }
    return keys.sorted()
  }()

  /// The parameters of `name`, or nil for a command the table does not have.
  static func commandParameters(of name: CommandName) -> [CommandParameter]? {
    commands[name.description]?.parameters
  }

  /// Resolve `flash <topic> <action>` with its `--name=value` arguments.
  /// Nil for an unknown command or arguments it does not accept.
  ///
  /// Plugin commands are not in this table. They are
  /// `flash <command> <subcommand>`, parsed by ``PluginGitInvocation``.
  static func parse(topic: String, action: String, args: [String: String]) -> URLCommand? {
    commands["\(topic) \(action)"]?.command(arguments: args)
  }

  /// Resolve the words after `flash`: `<topic> <action> [--name=value ...]`.
  static func parse(words: [String]) -> URLCommand? {
    guard words.count >= 2, let args = try? CommandArguments.parse(words.dropFirst(2)) else {
      return nil
    }
    return parse(topic: words[0], action: words[1], args: args)
  }

  /// The command table's raw keys, so a test can hold every one to the
  /// `<topic> <action>` shape.
  static var commandTableKeys: [String] { Array(commands.keys) }

  /// The one-line description of a command, for the catalog and completion.
  static func summary(of name: CommandName) -> String? {
    commands[name.description]?.summary
  }

  /// Dispatch table keyed by `"<topic> <action>"`. Adding a command is a
  /// two-step change: add a case to `URLCommand`, then add its summary,
  /// parameters and parser closure here. `AppDelegate` switches exhaustively
  /// over `URLCommand` so the compiler flags any missed wiring.
  private static let mouseParameters: [CommandParameter] = [
    .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
    .flag("move"), .flag("drag"), .flag("select"), .flag("multi"),
    .flag("adjust"), .flag("search"), .flag("path"), .flag("sticky"), .flag("copy_url"),
    .flag("copy_text"),
    .text("gesture", "look_up|smart_zoom"), .text("modifiers", "cmd+ctrl+alt+shift"),
  ]

  /// The click flags alone: no session shape.
  private static let clickParameters: [CommandParameter] = [
    .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
    .flag("move"), .text("modifiers", "cmd+ctrl+alt+shift"),
  ]

  /// The session shapes only `mouse target` on the focused window offers.
  private static let targetSessionFlags = [
    "adjust", "search", "path", "sticky", "copy_url", "copy_text",
  ]

  /// `input <motion>`, which takes no arguments.
  private static func inputMotion(_ motion: InputMotion, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .inputMotion(motion) : nil })
  }

  /// `move <direction>`, which takes no arguments.
  private static func move(_ move: MoveCommand, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .move(move) : nil })
  }

  /// `cursor <motion>`, which takes no arguments.
  private static func cursorMotion(_ motion: TextMotion, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .cursor(.motion(motion)) : nil })
  }

  /// `cursor next_char|…`: the character from `--char`, else the next key.
  private static func characterSearch(_ kind: CharacterSearchKind) -> CommandDefinition {
    .init(
      kind.summary + "; without --char, the next key typed", [.text("char", "c")],
      parse: { a in
        guard a.args.keys.allSatisfy({ $0 == "char" }) else { return nil }
        guard let raw = a.value("char") else { return .cursor(.findCharacter(kind, nil)) }
        guard raw.count == 1, let character = raw.first else { return nil }
        return .cursor(.findCharacter(kind, character))
      })
  }

  /// The `cursor` commands: one per Vim motion, a line by number or
  /// percentage, and the character searches.
  private static let cursorCommands: [String: CommandDefinition] = {
    var table: [String: CommandDefinition] = [:]
    for (action, motion) in CursorCommand.motionActions {
      table["cursor \(action)"] = cursorMotion(
        motion, CursorCommand.motionSummaries[action] ?? action)
    }
    for kind in CharacterSearchKind.allCases {
      table["cursor \(kind.rawValue)"] = characterSearch(kind)
    }
    table["cursor repeat_char"] = .init(
      "Repeat the last character search on the line (;)",
      parse: { a in a.args.isEmpty ? .cursor(.repeatCharacterSearch(reversed: false)) : nil })
    table["cursor repeat_char_back"] = .init(
      "Repeat the last character search the other way (,)",
      parse: { a in a.args.isEmpty ? .cursor(.repeatCharacterSearch(reversed: true)) : nil })
    table["cursor line"] = .init(
      "Move to line --index, or --percent of the way through the text ({count}G, {count}%)",
      [.integer("index"), .integer("percent")],
      parse: { a in
        switch (a.int("index"), a.int("percent")) {
        case (let index?, nil) where index >= 1: return .cursor(.line(index: index))
        case (nil, let percent?) where (1...100).contains(percent):
          return .cursor(.percent(percent))
        default: return nil
        }
      })
    let selections: [(InputMotion, String)] = [
      (.selectLeft, "a character left"), (.selectRight, "a character right"),
      (.selectUp, "a line up"), (.selectDown, "a line down"),
      (.selectWordLeft, "a word left"), (.selectWordRight, "a word right"),
      (.selectLineStart, "to the line's start"), (.selectLineEnd, "to the line's end"),
      (.selectDocumentStart, "to the text's start"), (.selectDocumentEnd, "to the text's end"),
    ]
    for (motion, extent) in selections {
      table["input \(motion.rawValue)"] = inputMotion(
        motion, "Extend the selection \(extent) with the app's own key")
    }
    for position in ScrollCursorPosition.allCases {
      let place: String
      switch position {
      case .top: place = "at the top (zt)"
      case .middle: place = "in the middle (zz)"
      case .bottom: place = "at the bottom (zb)"
      }
      table["scroll \(position.rawValue)"] = .init(
        "Scroll the focused text so the cursor's line sits \(place)",
        parse: { a in a.args.isEmpty ? .scrollCursor(position) : nil })
    }
    return table
  }()

  /// `<surface> show|hide|toggle`, which take no arguments.
  private static func surface(
    _ surface: SystemSurface, _ visibility: SurfaceVisibility
  ) -> CommandDefinition {
    let command = SystemSurfaceCommand(surface, visibility)
    return .init(command.summary, parse: { _ in .systemSurface(command) })
  }

  /// Every command: the table below and the generated `cursor` family.
  private static let commands: [String: CommandDefinition] = baseCommands.merging(
    cursorCommands
  ) { listed, _ in
    preconditionFailure("a cursor command shadows \(listed.summary)")
  }

  private static let baseCommands: [String: CommandDefinition] = [
    "mouse target": .init(
      "Label the focused window's targets and click the one you pick",
      mouseParameters + [.text("scope", "app|screen"), .flag("words")],
      parse: { a in
        if a.bool("words") {
          // Words are a text walk: the session shapes that walk the app's
          // controls again (`--multi`) or filter by control text do not apply.
          guard a.value("scope") == nil, let command = mouseCommand(a) else { return nil }
          switch command {
          case .click, .move, .gesture, .drag, .select: return .mouseTargetWords(command)
          default: return nil
          }
        }
        switch a.value("scope") {
        case nil, "app":
          return mouseCommand(a).map(URLCommand.mouseTarget)
        case "screen":
          // Screen scope is click-only: session flags (drag/select/multi/…)
          // assume a single-app session.
          guard let command = mouseCommand(a), case .click = command else { return nil }
          return .mouseTargetScreen(command)
        default:
          return nil
        }
      }),
    "mouse screens": .init(
      "Label each display by its number and move the pointer to the one you pick",
      [
        .integer("index"), .text("direction", "next|previous"), .text("to", "center|last"),
        .flag("focus"),
      ],
      parse: { a in screenSelectCommand(a) }),
    "mouse warp": .init(
      "Move the pointer to an edge or the centre of the window or screen",
      [.text("area", "window|screen"), .text("edge", "center|top|bottom|left|right")],
      parse: { a in
        var request = MouseWarpRequest()
        if let area = a.value("area") {
          guard let parsed = MouseWarpRequest.Area(rawValue: area) else { return nil }
          request.area = parsed
        }
        if let edge = a.value("edge") {
          guard let parsed = MouseWarpRequest.Edge(rawValue: edge) else { return nil }
          request.edge = parsed
        }
        return .mouseWarp(request)
      }),
    "mouse step": .init(
      "Move the pointer one text line or character, or jump a word or line",
      [
        .text("direction", "up|down|left|right"),
        .text("to", "next_word|previous_word|word_end|line_start|line_end"),
      ],
      parse: { a in
        // Exactly one of a one-step direction or a jump.
        switch (a.value("direction"), a.value("to")) {
        case (let direction?, nil):
          return TextStep.Direction(rawValue: direction).map { .mouseStep($0) }
        case (nil, let to?):
          return TextStep.Jump(rawValue: to).map { .mouseJump($0) }
        case (_?, _?), (nil, nil):
          return nil
        }
      }),
    "selection copy": selectionCommand(.copy, "Copy the selected text, ending HOLD or VISUAL"),
    "selection paste": selectionCommand(
      .paste, "Paste over the selected text, ending HOLD or VISUAL"),
    "selection swap_ends": selectionCommand(
      .swapEnds, "Move VISUAL's moving end to the other end of the selection (o)"),

    "mode visual": .init(
      "Select from the cursor in the focused text (VISUAL); --line selects whole lines; "
        + "again, leave it; --reselect selects the last VISUAL range again (gv)",
      [.flag("line"), .flag("reselect")],
      parse: { a in
        if a.bool("reselect") { return a.bool("line") ? nil : .visualReselect }
        return .visualMode(a.bool("line") ? .linewise : .charwise)
      }),
    "mouse nudge": .init(
      "Move the pointer, and a held drag, a few points",
      [.text("direction", "up|down|left|right", required: true), .text("distance", "points")],
      parse: { a in
        guard let direction = a.value("direction").flatMap(TextStep.Direction.init(rawValue:))
        else { return nil }
        guard let raw = a.value("distance") else { return .mouseNudge(direction, distance: 16) }
        guard let distance = Int(raw), (1...2000).contains(distance) else { return nil }
        return .mouseNudge(direction, distance: distance)
      }),
    "mouse position": .init(
      "Save, label, cycle or forget saved pointer positions",
      [.text("action", "save|unsave|clear|hints|next|previous", required: true)]
        + clickParameters,
      parse: { a in
        let clickArgs = a.args.filter { $0.key != "action" }
        switch a.value("action") {
        case "save": return clickArgs.isEmpty ? .mousePosition(.save) : nil
        case "unsave": return clickArgs.isEmpty ? .mousePosition(.unsave) : nil
        case "clear": return clickArgs.isEmpty ? .mousePosition(.clear) : nil
        case "next": return clickArgs.isEmpty ? .mousePosition(.next) : nil
        case "previous": return clickArgs.isEmpty ? .mousePosition(.previous) : nil
        case "hints":
          guard let command = mouseCommand(a, allowAdjust: false) else { return nil }
          switch command {
          case .click, .move: return .mousePosition(.hints(command))
          default: return nil
          }
        default: return nil
        }
      }),
    // The grid IS the precision surface, so `--adjust` and `--search` are
    // config errors there.
    "mouse bigram": .init(
      "Type a visible character, then its hint, and click that glyph",
      [
        .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
        .flag("move"), .text("gesture", "look_up|smart_zoom"),
        .text("modifiers", "cmd+ctrl+alt+shift"),
      ],
      parse: { a in
        guard let command = mouseCommand(a, allowAdjust: false) else { return nil }
        switch command {
        case .click, .move, .gesture: return .mouseBigram(command)
        default: return nil
        }
      }),
    "mouse grid": .init(
      "Pick any screen position on a keyboard-shaped grid",
      mouseParameters.filter { !targetSessionFlags.contains($0.name) }
        + [.flag("bisect"), .integer("zoom_to_depth")],
      parse: { a in
        mouseCommand(a, allowAdjust: false).map {
          .mouseGrid(
            MouseGridRequest($0, zoomToDepth: a.int("zoom_to_depth"), bisect: a.bool("bisect")))
        }
      }),

    "mouse repeat": .init(
      "Click again where Flash last clicked", parse: { a in a.args.isEmpty ? .mouseRepeat : nil }),

    "mouse pointer": .init(
      "Move the pointer from the keyboard", parse: { a in a.args.isEmpty ? .mousePointer : nil }),

    "mode hold": .init(
      "Grab what is under the pointer (HOLD), or drop it", [.flag("secondary"), .flag("middle")],
      parse: { a in
        switch (a.bool("secondary"), a.bool("middle")) {
        case (false, false): return .holdMode(.primary)
        case (true, false): return .holdMode(.secondary)
        case (false, true): return .holdMode(.middle)
        case (true, true): return nil
        }
      }),

    "mouse button": .init(
      "Press, release or toggle a mouse button at the pointer",
      [
        .text("state", "down|up|toggle|release|cancel", required: true), .flag("secondary"),
        .flag("middle"), .text("mode", "hold"),
      ],
      parse: { a in
        guard let state = a.value("state").flatMap(MouseButtonState.init(rawValue:)) else {
          return nil
        }
        let hold: ButtonHold
        if let mode = a.value("mode") {
          guard let parsed = ButtonHold(rawValue: mode) else { return nil }
          hold = parsed
        } else {
          hold = .hold
        }
        switch (a.bool("secondary"), a.bool("middle")) {
        case (false, false): return .mouseButton(.init(state: state, button: .primary, hold: hold))
        case (true, false):
          return .mouseButton(.init(state: state, button: .secondary, hold: hold))
        case (false, true): return .mouseButton(.init(state: state, button: .middle, hold: hold))
        case (true, true): return nil
        }
      }),

    "input focus": .init(
      "Focus an editable field in the focused window, keeping the mode",
      parse: { a in a.args.isEmpty ? .focusInput : nil }),

    "input line_start": inputMotion(
      .lineStart, "Move the cursor to the start of its line in the focused text"),
    "input line_end": inputMotion(
      .lineEnd, "Move the cursor to the end of its line in the focused text"),
    "input char_left": inputMotion(
      .charLeft, "Move the cursor one character left in the focused text"),
    "input char_right": inputMotion(
      .charRight, "Move the cursor one character right in the focused text"),
    "input line_up": inputMotion(.lineUp, "Move the cursor up a line in the focused text"),
    "input line_down": inputMotion(.lineDown, "Move the cursor down a line in the focused text"),
    "input document_start": inputMotion(
      .documentStart, "Move the cursor to the start of the focused text"),
    "input document_end": inputMotion(
      .documentEnd, "Move the cursor to the end of the focused text"),

    "move down": move(.down, "Move down: the caret in text, the selection in a list, else scroll"),
    "move up": move(.up, "Move up: the caret in text, the selection in a list, else scroll"),
    "move left": move(
      .left, "Move left: the caret within its line, the selection in a list, else scroll"),
    "move right": move(
      .right, "Move right: the caret within its line, the selection in a list, else scroll"),
    "move half_page_down": move(
      .halfPageDown, "Move down by [mode] move_page_lines arrows, or scroll half a page"),
    "move half_page_up": move(
      .halfPageUp, "Move up by [mode] move_page_lines arrows, or scroll half a page"),
    "move page_down": move(.pageDown, "Move down by twice move_page_lines arrows, or a page"),
    "move page_up": move(.pageUp, "Move up by twice move_page_lines arrows, or a page"),
    "move top": move(
      .top, "Move to the start of the text, the first item where the app says, or the top"),
    "move bottom": move(
      .bottom, "Move to the end of the text, the last item where the app says, or the bottom"),

    "scroll target": .init(
      "Pick the scroll area the scroll commands drive",
      parse: { a in a.args.isEmpty ? .scrollTarget : nil }),

    "mouse dock": .init(
      "Label the Dock's items", parse: { a in a.args.isEmpty ? .mouseDock : nil }),

    "mouse menubar": .init(
      "Label the focused app's menus and the menu-bar status items",
      parse: { a in a.args.isEmpty ? .mouseMenuBar : nil }),

    "mouse notifications": .init(
      "Label Notification Center's banners, alerts and buttons",
      parse: { a in a.args.isEmpty ? .mouseNotifications : nil }),

    "mode normal": .init(
      "Enter NORMAL mode", parse: { _ in .normalMode }),

    "mode leave": .init(
      "Leave the current mode: INSERT, a layer, the command line or a popup",
      parse: { a in a.args.isEmpty ? .leaveMode : nil }),

    "mode insert": .init(
      "Enter INSERT mode: keys go to the focused app", parse: { _ in .insertMode }),

    "mode layer": .init(
      "Enter a layer: its own keys act until Escape or mode leave",
      [.text("name", "layer", required: true)],
      parse: { a in
        guard a.args.keys.allSatisfy({ $0 == "name" }), let name = a.value("name"),
          Config.Mode.isValidLayerName(name)
        else { return nil }
        return .layerMode(name: name)
      }),

    "mode command": .init(
      "Open the command line, optionally pre-filled with --input",
      [.text("input", "text"), .flag("restore_mode")],
      parse: { a in
        guard let raw = a.value("input") else {
          return a.args.isEmpty ? .commandMode : nil
        }
        guard !raw.isEmpty else { return nil }
        // Strip every leading `:` and feed the rest through verbatim. A single
        // `:` is later prepended by `commandLineBuffer(from:)`. Trailing spaces
        // are meaningful and must NOT be trimmed: `--input=:flashlight ` opens
        // the flashlight with an empty query (all candidates) while
        // `--input=:flashlight` instead surfaces completions for commands that
        // start with `flashlight`. The user gets full control over which
        // behaviour they want.
        let normalized = String(raw.drop(while: { $0 == ":" }))
        // A flashlight query's `@<type>` must name a type, as in `mode
        // flashlight --query=`.
        if normalized.lowercased().hasPrefix("flashlight "),
          ResourceTypes.firstInvalidToken(in: normalized) != nil
        {
          return nil
        }
        return .enterCommand(input: normalized, restoreMode: a.bool("restore_mode"))
      }),

    "mode flashlight": .init(
      "Open the flashlight, optionally pre-filled with --query (a @type, a !bang or text)",
      [.text("query", "text"), .flag("restore_mode")],
      parse: { a in
        let query = a.value("query")
        if let query, query.trimmed.isEmpty { return nil }
        // `@<type>` must name a resource type (`ResourceTypes`); a dotted
        // source name from before types is rejected, with the type it meant.
        if let query, ResourceTypes.firstInvalidToken(in: query) != nil { return nil }
        return .flashlight(query: query?.trimmed, restoreMode: a.bool("restore_mode"))
      }),

    "mode terminal": .init(
      "Show and focus a popup; without --name, the terminal popup", [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }),
          args.value("name").map({ !$0.trimmed.isEmpty }) ?? true
        else { return nil }
        return .terminalMode(name: args.value("name"))
      }),

    "popup restart": .init(
      "Restart the focused or named popup's process", [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }), args.value("name") != "" else {
          return nil
        }
        return .popupRestart(name: args.value("name"))
      }),
    "popup quit": .init(
      "Quit the focused or named popup's process; persistent popups restart",
      [.text("name", "popup")],
      parse: { args in
        guard args.args.keys.allSatisfy({ $0 == "name" }), args.value("name") != "" else {
          return nil
        }
        return .popupQuit(name: args.value("name"))
      }),

    "scroll left": .init(
      "Scroll left", parse: { _ in .scroll(.left) }),

    "scroll right": .init(
      "Scroll right", parse: { _ in .scroll(.right) }),

    "scroll up": .init(
      "Scroll up [mode] scroll_step_lines lines", parse: { _ in .scroll(.up) }),

    "scroll down": .init(
      "Scroll down [mode] scroll_step_lines lines", parse: { _ in .scroll(.down) }),

    "scroll line_up": .init(
      "Scroll up one line, the count that many (ctrl+y)", parse: { _ in .scroll(.lineUp) }),

    "scroll line_down": .init(
      "Scroll down one line, the count that many (ctrl+e)", parse: { _ in .scroll(.lineDown) }),

    "scroll half_page_up": .init(
      "Scroll up half a page", parse: { _ in .scroll(.halfPageUp) }),

    "scroll half_page_down": .init(
      "Scroll down half a page", parse: { _ in .scroll(.halfPageDown) }),

    "scroll page_up": .init(
      "Scroll up a page", parse: { _ in .scroll(.pageUp) }),

    "scroll page_down": .init(
      "Scroll down a page", parse: { _ in .scroll(.pageDown) }),

    "scroll top": .init(
      "Scroll to the top", parse: { _ in .scroll(.top) }),

    "scroll bottom": .init(
      "Scroll to the bottom", parse: { _ in .scroll(.bottom) }),

    "app reload": .init(
      "Reload the focused app's page; --force bypasses its cache", [.flag("force")],
      parse: { a in .reload(force: a.bool("force")) }),

    "app undo": .init(
      "Undo the last edit in the focused app", parse: { _ in .undo }),

    "app redo": .init(
      "Redo the last edit in the focused app", parse: { _ in .redo }),

    "resource archive": .init(
      "Archive the current item in the focused app", parse: { _ in .archive }),

    "resource next": .init(
      "Go to the next item in the focused app", parse: { _ in .resourceNext }),

    "resource previous": .init(
      "Go to the previous item in the focused app", parse: { _ in .resourcePrevious }),

    "tab close": .init(
      "Close the current tab", parse: { _ in .tabClose }),

    "app find": .init(
      "Open the focused app's Find", parse: { _ in .find }),

    "app find_next": .init(
      "Go to the next Find match in the focused app", parse: { _ in .findNext }),

    "app find_previous": .init(
      "Go to the previous Find match in the focused app", parse: { _ in .findPrevious }),

    "app switch": .init(
      "Open the flashlight on what is running", parse: { _ in .appSwitch }),

    "url copy": .init(
      "Copy the focused page's URL", parse: { _ in .copyURL }),

    "register yank": .init(
      "Copy the focused app's selection into a register", [.text("register", "name")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .yankSelection(register: registerArg(a))
      }),

    "register paste": .init(
      "Paste a register with the app's own paste; --after first steps past the character "
        + "under the cursor, as vim's p",
      [.text("register", "name"), .flag("after")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .paste(register: registerArg(a), after: a.bool("after"))
      }),

    "tab next": .init(
      "Select the next tab", parse: { _ in .tabNext }),

    "tab previous": .init(
      "Select the previous tab", parse: { _ in .tabPrev }),

    "tab first": .init(
      "Select the first tab", parse: { _ in .tabFirst }),

    "tab last": .init(
      "Select the last tab", parse: { _ in .tabLast }),

    "tab select": .init(
      "Select a tab by --index or the typed count", [.integer("index")],
      parse: { a in .tabSelect(index: a.int("index")) }),

    "tab move_previous": .init(
      "Move the current tab one place backward", parse: { _ in .tabMovePrev }),

    "tab move_next": .init(
      "Move the current tab one place forward", parse: { _ in .tabMoveNext }),

    "tab reopen": .init(
      "Reopen the last closed tab", parse: { _ in .tabReopen }),

    "pane next": .init(
      "Focus the next split pane", parse: { _ in .paneNext }),

    "pane previous": .init(
      "Focus the previous split pane", parse: { _ in .panePrev }),

    "pane split_vertical": .init(
      "Split the focused pane side by side", parse: { _ in .paneSplitVertical }),

    "pane split_horizontal": .init(
      "Split the focused pane top and bottom", parse: { _ in .paneSplitHorizontal }),

    "pane close": .init(
      "Close the focused split pane", parse: { _ in .paneClose }),

    "history back": .init(
      "Go back in the focused app", parse: { _ in .historyBack }),

    "history forward": .init(
      "Go forward in the focused app", parse: { _ in .historyForward }),

    "movement back": .init(
      "Jump back through Flash's movement history", parse: { _ in .movementBack }),

    "movement forward": .init(
      "Jump forward through Flash's movement history", parse: { _ in .movementForward }),

    "app previous": .init(
      "Focus the previous app", parse: { _ in .appPrev }),

    "app next": .init(
      "Focus the next app", parse: { _ in .appNext }),

    "app quit": .init(
      "Quit the focused app; --force force-quits it", [.flag("force")],
      parse: { a in .quitApp(force: a.bool("force")) }),

    "app save_and_quit": .init(
      "Save the focused document, then quit the app", [.flag("force")],
      parse: { a in .saveAndQuit(force: a.bool("force")) }),

    "app close": .init(
      "Close the current tab, else the focused window, quitting the app with its last window",
      parse: { _ in .appClose }),

    "tab new": .init(
      "Open a new tab", parse: { _ in .tabNew }),

    "app save": .init(
      "Save the focused document", parse: { _ in .save }),

    "app print": .init(
      "Print the focused document", parse: { _ in .print }),

    "document open": .init(
      "Open a document in the focused app", parse: { _ in .documentOpen }),

    "document save_as": .init(
      "Save the focused document under another name",
      parse: { a in a.args.isEmpty ? .documentSaveAs : nil }),

    "document export_pdf": .init(
      "Export the focused document as a PDF",
      parse: { a in a.args.isEmpty ? .documentExportPDF : nil }),

    "document revert": .init(
      "Revert the focused document to its last saved version, after asking",
      parse: { a in a.args.isEmpty ? .documentRevert : nil }),

    "document duplicate": .init(
      "Duplicate the focused document",
      parse: { a in a.args.isEmpty ? .documentDuplicate : nil }),

    "document rename": .init(
      "Rename the focused document", parse: { a in a.args.isEmpty ? .documentRename : nil }),

    "document page_setup": .init(
      "Open the focused document's page setup",
      parse: { a in a.args.isEmpty ? .documentPageSetup : nil }),

    "window new": .init(
      "Open a new window; --private, a private browsing one", [.flag("private")],
      parse: { a in .windowNew(private: a.bool("private")) }),

    "window close_all": .init(
      "Close every window of the focused app, after asking",
      parse: { a in a.args.isEmpty ? .windowCloseAll : nil }),

    "window zoom": .init(
      "Zoom the focused window to fit its content, or back",
      parse: { a in a.args.isEmpty ? .windowZoom : nil }),

    "window close": .init(
      "Close the focused window", parse: { _ in .windowClose }),

    "clipboard copy": .init(
      "Copy with the focused app's copy command", parse: { _ in .clipboardCopy }),

    "clipboard paste": .init(
      "Paste with the focused app's paste command", parse: { _ in .clipboardPaste }),
    "clipboard show": .init(
      "Open the clipboard history", [.text("offset", "0..10000")],
      parse: { args in
        let raw = args.value("offset") ?? "0"
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
          let offset = Int(raw), (0...10_000).contains(offset)
        else { return nil }
        return .clipboardHistory(action: "show", id: nil, offset: offset)
      }),
    "clipboard delete": .init(
      "Delete one clipboard history entry", [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "delete", id: id, offset: nil)
      }),
    "clipboard pin": .init(
      "Pin one clipboard history entry: it lists first and is never trimmed",
      [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "pin", id: id, offset: nil)
      }),
    "clipboard unpin": .init(
      "Unpin one clipboard history entry", [.text("id", "entry-id", required: true)],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardHistory(action: "unpin", id: id, offset: nil)
      }),
    "clipboard restore": .init(
      "Put a clipboard history entry back on the clipboard; --paste pastes it, "
        + "--plain keeps only its text",
      [.text("id", "entry-id", required: true), .flag("paste"), .flag("plain")],
      parse: { args in
        guard let id = args.value("id"), ClipboardCapture.isEntryID(id) else { return nil }
        return .clipboardRestore(id: id, paste: args.bool("paste"), plain: args.bool("plain"))
      }),
    "app look_up": .init(
      "Look up the word under the pointer in the focused app",
      parse: { a in a.args.isEmpty ? .lookUp : nil }),
    "app zoom_in": .init(
      "Zoom in with the focused app's own zoom", parse: { a in a.args.isEmpty ? .zoomIn : nil }),
    "app zoom_out": .init(
      "Zoom out with the focused app's own zoom", parse: { a in a.args.isEmpty ? .zoomOut : nil }),
    "app zoom_reset": .init(
      "Reset the focused app's zoom to actual size",
      parse: { a in a.args.isEmpty ? .zoomReset : nil }),
    "app view_source": .init(
      "Show the focused browser page's source",
      parse: { a in a.args.isEmpty ? .viewSource : nil }),
    "app settings": .init(
      "Open the focused app's settings", parse: { a in a.args.isEmpty ? .appSettings : nil }),
    "app select_all": .init(
      "Select everything in the focused app", parse: { a in a.args.isEmpty ? .selectAll : nil }),
    "app help": .init(
      "Open the focused app's Help menu", parse: { a in a.args.isEmpty ? .appHelp : nil }),
    "app cancel": .init(
      "Cancel in the focused app: close its popover, dialog or search",
      parse: { a in a.args.isEmpty ? .appCancel : nil }),
    "app stop": .init(
      "Stop loading the focused browser page", parse: { a in a.args.isEmpty ? .appStop : nil }),
    "app downloads": .init(
      "Show the focused browser's downloads", parse: { a in a.args.isEmpty ? .appDownloads : nil }),
    "app developer_tools": .init(
      "Open the focused browser's developer tools",
      parse: { a in a.args.isEmpty ? .developerTools : nil }),
    "app hide": .init(
      "Hide the focused app", parse: { a in a.args.isEmpty ? .appVisibility(.hide) : nil }),
    "app hide_others": .init(
      "Hide every app but the focused one",
      parse: { a in a.args.isEmpty ? .appVisibility(.hideOthers) : nil }),
    "app show_all": .init(
      "Show every hidden app", parse: { a in a.args.isEmpty ? .appVisibility(.showAll) : nil }),
    "app raise": .init(
      "Bring every window of the focused app to the front",
      parse: { a in a.args.isEmpty ? .appVisibility(.raise) : nil }),
    "url bookmark": .init(
      "Bookmark the focused page", parse: { a in a.args.isEmpty ? .urlBookmark : nil }),
    "url edit": .init(
      "Focus the focused browser's address bar", parse: { a in a.args.isEmpty ? .urlEdit : nil }),
    "history show": .init(
      "Show the focused browser's history", parse: { a in a.args.isEmpty ? .historyShow : nil }),
    "tab duplicate": .init(
      "Duplicate the current tab", parse: { a in a.args.isEmpty ? .tabDuplicate : nil }),
    "tab pin": .init(
      "Pin or unpin the current tab", parse: { a in a.args.isEmpty ? .tabPin : nil }),
    "tab mute": .init(
      "Mute or unmute the current tab", parse: { a in a.args.isEmpty ? .tabMute : nil }),
    "tab detach": .init(
      "Move the current tab to a new window", parse: { a in a.args.isEmpty ? .tabDetach : nil }),
    "mouse gesture": .init(
      "Perform a trackpad gesture at the pointer",
      [
        .text("fingers", "2|3|4|5", required: true),
        .text(
          "motion",
          "tap|double_tap|pinch|spread|rotate_left|rotate_right|swipe_left|swipe_right|swipe_up|swipe_down",
          required: true),
      ],
      parse: { a in
        guard let fingers = a.value("fingers").flatMap(Int.init),
          let motion = a.value("motion").flatMap(TrackpadGesture.Motion.init(rawValue:)),
          TrackpadGesture.action(fingers: fingers, motion: motion) != nil
        else { return nil }
        return .trackpadGesture(fingers: fingers, motion: motion)
      }),

    "alert show": .init(
      "Show a message in the centred alert",
      [
        .text("message", "text", required: true), .text("duration", "seconds"),
        .text("style", "standard|warning|error"),
      ], parse: { alertCommand($0) }),

    "alert dismiss": .init(
      "Dismiss the alert", parse: { _ in .dismissAlert }),

    "alert confirm": .init(
      "Ask first, then run the wrapped command on y",
      [
        .text("prompt", "question", required: true),
        .text("command", "topic action [--arg=value ...]", required: true),
      ], parse: { confirmCommand($0) }),

    "help show": .init(
      "Open Flash's help, or a documentation page with --topic", [.text("topic", "topic")],
      parse: { a in .showUsage(topic: a.value("topic")) }),

    "mappings show": .init(
      "Open the mappings page for the focused app", parse: { _ in .showMappings }),

    "plugins show": .init(
      "Open the plugins page", parse: { _ in .showPlugins }),

    "plugins reload": .init(
      "Stop and restart every loaded plugin", parse: { _ in .reloadPlugins }),

    "logs show": .init(
      "Open the logs page", parse: { _ in .showLogs }),

    "logs write": .init(
      "Write a line to Flash's log, at info or the level flag given",
      [
        .text("message", "text", required: true), .flag("trace"), .flag("debug"), .flag("info"),
        .flag("warn"), .flag("error"), .text("area", "area"), .text("fields", "key=value,..."),
      ],
      parse: { a in
        let levels = LogWrite.levels.filter { a.bool($0.name) }
        guard
          case .success(let write) = LogWrite.make(
            levelFlags: levels, message: a.value("message"), area: a.value("area"),
            fields: a.value("fields"))
        else { return nil }
        return .logWrite(write)
      }),

    "metrics record": .init(
      "Record a gauge, counter or histogram value into Flash's metrics",
      [
        .text("name", "metric", required: true), .text("value", "number", required: true),
        .text("kind", "gauge|counter|histogram"), .text("unit", "unit"),
        .text("attributes", "key=value,..."),
      ],
      parse: { a in
        guard let name = a.value("name"), let value = a.value("value"),
          case .success(let record) = MetricRecord.make(
            name: name, value: value, kind: a.value("kind"), unit: a.value("unit"),
            attributes: a.value("attributes"))
        else { return nil }
        return .metricRecord(record)
      }),

    "notify send": .init(
      "Post a macOS notification; a click can open --url or run --command",
      [
        .text("title", "text"), .text("subtitle", "text"), .text("body", "text"),
        .flag("sound"), .text("url", "url"), .text("command", "topic action [--arg=value ...]"),
        .text("id", "id"),
      ],
      parse: { a in
        guard
          case .success(let request) = NotifyRequest.make(
            title: a.value("title"), subtitle: a.value("subtitle"), body: a.value("body"),
            sound: a.bool("sound"), url: a.value("url"), command: a.value("command"),
            id: a.value("id"))
        else { return nil }
        return .notify(.send(request))
      }),

    "notify clear": .init(
      "Remove Flash's notifications from Notification Center, or the one --id names",
      [.text("id", "id")],
      parse: { a in
        if let id = a.value("id") {
          return NotifyRequest.isValidID(id) ? .notify(.clear(id: id)) : nil
        }
        return .notify(.clear(id: nil))
      }),

    "commands show": .init(
      "Open the command catalog", parse: { _ in .showCommands }),

    "monitors show": .init(
      "Open the monitors page", parse: { a in a.args.isEmpty ? .showMonitors : nil }),

    "telemetry show": .init(
      "Open the telemetry page", parse: { a in a.args.isEmpty ? .showTelemetry : nil }),

    "about show": .init(
      "Open the About Flash window", parse: { _ in .showAbout }),

    "hints dismiss": .init(
      "Dismiss hint labels", parse: { _ in .dismissHints }),

    "resident quit": .init(
      "Quit Flash", parse: { _ in .quit }),

    "app open": .init(
      "Open or focus an app by name", [.text("name", "app", required: true)],
      parse: { a in
        guard let name = a.value("name"), !name.isEmpty else { return nil }
        return .openApp(name: name)
      }),

    "window move": .init(
      "Tile, resize or move the focused window",
      [
        .text("position", "slot"), .text("x", "percent"), .text("y", "percent"),
        .text("width", "percent"), .text("height", "percent"), .text("screen", "n"),
      ], parse: windowMoveCommand),

    "window focus": .init(
      "Focus the nearest window in a direction, or cycle the stack",
      [.text("direction", "left|right|up|down|next|previous|behind", required: true)],
      parse: { a in
        guard let value = a.value("direction"),
          let request = WindowFocusRequest(direction: value)
        else { return nil }
        return .focusWindow(request)
      }),

    "window next": .init(
      "Focus the focused app's next window",
      parse: { a in a.args.isEmpty ? .focusWindow(.app(.next)) : nil }),

    "window previous": .init(
      "Focus the focused app's previous window",
      parse: { a in a.args.isEmpty ? .focusWindow(.app(.previous)) : nil }),

    "window switch": .init(
      "Pick any window, most recently used first; again to move down the list",
      parse: { a in a.args.isEmpty ? .windowSwitch : nil }),
    "window last": .init(
      "Focus the window you were in before this one",
      parse: { a in a.args.isEmpty ? .windowLast : nil }),

    "tile move": .init(
      "Move the focused tiled window in a direction in its workspace's tree",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.move($0)) } }),
    "tile swap": .init(
      "Swap the focused tiled window with its neighbor in a direction",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.swap($0)) } }),
    "tile join": .init(
      "Put the focused tiled window and its neighbor in a new container",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.join($0)) } }),
    "tile layout": .init(
      "Set the focused window's container to tiles or accordion, horizontal or vertical",
      [.text("type", "tiles|accordion|horizontal|vertical|toggle", required: true)],
      parse: { a in
        a.value("type").flatMap(TilingLayoutRequest.init(rawValue:)).map { .tile(.layout($0)) }
      }),
    "tile resize": .init(
      "Grow or shrink the focused tiled window by points",
      [
        .text("dimension", "width|height|smart", required: true),
        .text("amount", "points", required: true),
      ],
      parse: { a in
        guard let dimension = a.value("dimension").flatMap(TilingResizeDimension.init(rawValue:)),
          let raw = a.value("amount"),
          let amount = Int(raw.hasPrefix("+") ? String(raw.dropFirst()) : raw), amount != 0,
          abs(amount) <= 10_000
        else { return nil }
        return .tile(.resize(dimension, amount: amount))
      }),
    "tile balance": .init(
      "Give every tiled window of the focused workspace an equal share",
      parse: { a in a.args.isEmpty ? .tile(.balance) : nil }),
    "tile flatten": .init(
      "Put every tiled window of the focused workspace in one container",
      parse: { a in a.args.isEmpty ? .tile(.flatten) : nil }),
    "tile float": .init(
      "Float the focused window, or tile it again",
      parse: { a in a.args.isEmpty ? .tile(.float) : nil }),
    "tile fullscreen": .init(
      "Make the focused tiled window fill its workspace, or end it",
      parse: { a in a.args.isEmpty ? .tile(.fullscreen) : nil }),

    "workspace switch": .init(
      "Show a workspace and focus it; created on demand",
      [.text("name", "workspace", required: true)],
      parse: { a in a.value("name").map { .workspace(.switchTo($0)) } }),
    "workspace next": .init(
      "Show the next workspace on the focused display",
      parse: { a in a.args.isEmpty ? .workspace(.next) : nil }),
    "workspace previous": .init(
      "Show the previous workspace on the focused display",
      parse: { a in a.args.isEmpty ? .workspace(.previous) : nil }),
    "workspace back_and_forth": .init(
      "Show the workspace focused before this one",
      parse: { a in a.args.isEmpty ? .workspace(.backAndForth) : nil }),
    "workspace move_window": .init(
      "Move the focused window to a workspace",
      [.text("name", "workspace", required: true)],
      parse: { a in a.value("name").map { .workspace(.moveWindow($0)) } }),
    "workspace move_to_monitor": .init(
      "Show the focused workspace on the next or previous display",
      [.text("direction", "next|previous", required: true)],
      parse: { a in
        switch a.value("direction") {
        case "next": return .workspace(.moveToMonitor(1))
        case "previous": return .workspace(.moveToMonitor(-1))
        default: return nil
        }
      }),
    "workspace list": .init(
      "List the workspaces, their windows and displays, the focused one marked",
      parse: { a in a.args.isEmpty ? .workspace(.list) : nil }),

    "window minimize": .init(
      "Minimize the focused window", parse: { a in a.args.isEmpty ? .windowState(.minimize) : nil }),

    "window restore": .init(
      "Restore the most recently minimized window",
      parse: { a in a.args.isEmpty ? .windowState(.restore) : nil }),

    "window fullscreen": .init(
      "Toggle, enter or leave native full screen", [.text("state", "on|off|toggle")],
      parse: { a in
        guard let state = WindowStateAction.FullscreenState(rawValue: a.value("state") ?? "toggle")
        else { return nil }
        return .windowState(.fullscreen(state))
      }),

    "volume up": .init(
      "Raise the output volume one step", parse: { _ in .media(.volumeUp) }),

    "volume down": .init(
      "Lower the output volume one step", parse: { _ in .media(.volumeDown) }),

    "volume mute": .init(
      "Mute or unmute the output", parse: { _ in .media(.volumeMute) }),

    "audio input": .init(
      "List the input devices, or select one with --device", [.text("device", "name-or-uid")],
      parse: { audioDeviceCommand(.input, $0) }),

    "audio output": .init(
      "List the output devices, or select one with --device", [.text("device", "name-or-uid")],
      parse: { audioDeviceCommand(.output, $0) }),

    "media status": .init(
      "Show what the media apps are playing and the volume", parse: { _ in .media(.status) }),

    "macro record": .init(
      "Record the commands that follow into a register (q{reg})",
      [.text("register", "name", required: true)],
      parse: { a in
        a.value("register").flatMap(MacroCommand.recordingRegister).map {
          .macro(.record(register: $0))
        }
      }),

    "macro stop": .init(
      "Stop recording the macro", parse: { _ in .macro(.stop) }),

    "macro play": .init(
      "Replay a macro register, or the last one played (@{reg}, @@)",
      [.text("register", "name")],
      parse: { a in
        guard let raw = a.value("register") else { return .macro(.play(register: nil)) }
        return MacroCommand.playRegister(raw).map { .macro(.play(register: $0)) }
      }),

    "macro repeat": .init(
      "Run the last NORMAL command again (.), --count times instead of its own count ({count}.)",
      [.integer("count")],
      parse: { a in
        guard let raw = a.value("count") else { return .macro(.repeatLast(count: nil)) }
        guard let count = Int(raw), (1...RepeatCount.max).contains(count) else { return nil }
        return .macro(.repeatLast(count: count))
      }),

    "config reload": .init(
      "Re-read the configuration file now", parse: { _ in .configReload }),

    "config edit": .init(
      "Open the configuration file in its default app", parse: { _ in .configEdit }),

    "status set": .init(
      "Push a value into a [statusbar.sources] source from a script or hook",
      [.text("name", "source", required: true), .text("value", "text", required: true)],
      parse: { a in
        guard let name = a.value("name"), let value = a.value("value") else { return nil }
        return .statusPush(StatusPush(source: name, value: value))
      }),

    "status clear": .init(
      "Clear the value pushed into a [statusbar.sources] source",
      [.text("name", "source", required: true)],
      parse: { a in a.value("name").map { .statusPush(StatusPush(source: $0, value: nil)) } }),

    "menu choose": .init(
      "Pick a line of --file in the flashlight and answer with it; for scripts, like dmenu",
      [.text("file", "path", required: true), .text("prompt", "label")],
      parse: { a in
        guard let file = a.value("file"), !file.isEmpty else { return nil }
        let prompt = a.value("prompt")
        guard prompt.map(MenuChoice.validPrompt) ?? true else { return nil }
        return .menuChoose(file: file, prompt: prompt)
      }),

    "menu press": .init(
      "Press a menu-bar item of the focused app by its titles, comma-separated",
      [.text("path", "Menu,Item,...", required: true)],
      parse: { a in a.value("path").flatMap(menuPath).map { .menuPress(path: $0) } }),

    "status refresh": .init(
      "Run a [statusbar.sources] source's command now instead of at its interval",
      [.text("name", "source", required: true)],
      parse: { a in a.value("name").map { .statusRefresh(source: $0) } }),

    "caffeinate on": .init(
      "Keep the Mac awake, for --minutes or until caffeinate off", [.integer("minutes")],
      parse: { a in caffeinateMinutes(a).map { .caffeinate(.on(minutes: $0)) } }),

    "caffeinate off": .init(
      "Let the Mac sleep again", parse: { _ in .caffeinate(.off) }),

    "caffeinate toggle": .init(
      "Keep the Mac awake, or let it sleep again", [.integer("minutes")],
      parse: { a in caffeinateMinutes(a).map { .caffeinate(.toggle(minutes: $0)) } }),

    "caffeinate status": .init(
      "Show whether the Mac is kept awake", parse: { _ in .caffeinate(.status) }),

    "updates check": .init(
      UpdatesCommand.check.summary, parse: { a in a.args.isEmpty ? .updates(.check) : nil }),

    "updates install": .init(
      UpdatesCommand.install.summary, parse: { a in a.args.isEmpty ? .updates(.install) : nil }),

    "startup run": .init(
      StartupCommand.run.summary, parse: { a in a.args.isEmpty ? .startup(.run) : nil }),

    "notes open": .init(
      AppleCatalogCommand.open(.notes).summary, parse: { _ in .appleCatalog(.open(.notes)) }),

    "notes refresh": .init(
      AppleCatalogCommand.refresh(.notes).summary, parse: { _ in .appleCatalog(.refresh(.notes)) }),

    "reminders open": .init(
      AppleCatalogCommand.open(.reminders).summary, parse: { _ in .appleCatalog(.open(.reminders)) }
    ),

    "reminders refresh": .init(
      AppleCatalogCommand.refresh(.reminders).summary,
      parse: { _ in .appleCatalog(.refresh(.reminders)) }),

    "contacts open": .init(
      AppleCatalogCommand.open(.contacts).summary, parse: { _ in .appleCatalog(.open(.contacts)) }),

    "contacts refresh": .init(
      AppleCatalogCommand.refresh(.contacts).summary,
      parse: { _ in .appleCatalog(.refresh(.contacts)) }),

    "calendar join": .init(CalendarCommand.join.summary, parse: { _ in .calendar(.join) }),

    "calendar next": .init(CalendarCommand.next.summary, parse: { _ in .calendar(.next) }),

    "mark set": .init(
      MarkCommand.setSummary, [.text("letter", "a-z|0-9", required: true)],
      parse: { a in markSlot(a).map { .marks(.set($0)) } }),

    "mark jump": .init(
      MarkCommand.jumpSummary, [.text("letter", "a-z|0-9", required: true)],
      parse: { a in markSlot(a).map { .marks(.jump($0)) } }),

    "key system": .init(
      "Press an Apple function-row key (media_play, brightness_down, …)",
      [.text("key", "brightness_down", required: true)],
      parse: { a in
        guard let name = a.value("key"), let key = SystemKeyboard.RowKey.named(name) else {
          return nil
        }
        return .systemKey(key)
      }),

    "desktop show": surface(.desktop, .show),
    "desktop hide": surface(.desktop, .hide),
    "desktop toggle": surface(.desktop, .toggle),
    "missioncontrol show": surface(.missionControl, .show),
    "missioncontrol hide": surface(.missionControl, .hide),
    "missioncontrol toggle": surface(.missionControl, .toggle),
    "appwindows show": surface(.appWindows, .show),
    "appwindows hide": surface(.appWindows, .hide),
    "appwindows toggle": surface(.appWindows, .toggle),
    "launchpad show": surface(.launchpad, .show),
    "launchpad hide": surface(.launchpad, .hide),
    "launchpad toggle": surface(.launchpad, .toggle),
    "notificationcenter show": surface(.notificationCenter, .show),
    "notificationcenter hide": surface(.notificationCenter, .hide),
    "notificationcenter toggle": surface(.notificationCenter, .toggle),
    "controlcenter show": surface(.controlCenter, .show),
    "controlcenter hide": surface(.controlCenter, .hide),
    "controlcenter toggle": surface(.controlCenter, .toggle),

    "screen lock": .init(
      "Lock the screen", parse: { a in a.args.isEmpty ? .systemAction(.screenLock) : nil }),

    "system sleep": .init(
      "Sleep the Mac", parse: { a in a.args.isEmpty ? .systemAction(.systemSleep) : nil }),

    "display sleep": .init(
      "Turn the displays off", parse: { a in a.args.isEmpty ? .systemAction(.displaySleep) : nil }),

    "system restart": .init(
      "Restart the Mac, after asking",
      parse: { a in
        a.args.isEmpty ? .systemAction(.systemRestart) : nil
      }),

    "system shutdown": .init(
      "Shut the Mac down, after asking",
      parse: { a in
        a.args.isEmpty ? .systemAction(.systemShutdown) : nil
      }),

    "system logout": .init(
      "Log out, after asking", parse: { a in a.args.isEmpty ? .systemAction(.systemLogout) : nil }),

    "trash empty": .init(
      "Empty the Trash, after asking",
      parse: { a in a.args.isEmpty ? .systemAction(.trashEmpty) : nil }),

    "appearance toggle": .init(
      "Switch between light and dark appearance",
      parse: { a in
        a.args.isEmpty ? .systemAction(.darkModeToggle) : nil
      }),

    "screensaver start": .init(
      "Start the screen saver",
      parse: { a in
        a.args.isEmpty ? .systemAction(.screensaverStart) : nil
      }),

    "process kill": .init(
      "Terminate one process, after asking", [.integer("pid", required: true)],
      parse: { a in
        guard let pid = a.int("pid").flatMap({ pid_t(exactly: $0) }), pid > 1 else { return nil }
        return .processKill(pid: pid)
      }),

    "key function": .init(
      "Press a plain F1–F20 key", [.text("key", "f1", required: true)],
      parse: { a in
        guard let name = a.value("key")?.lowercased(),
          name.hasPrefix("f"), let index = Int(name.dropFirst()), (1...20).contains(index)
        else { return nil }
        return .functionKey(index)
      }),

    "key arrow": .init(
      "Press one arrow key; --shift holds Shift",
      [.text("direction", "left|down|up|right", required: true), .flag("shift")],
      parse: { a in
        guard let value = a.value("direction"),
          let direction = WindowFocusDirection(rawValue: value)
        else { return nil }
        return .arrow(direction: direction, shift: a.bool("shift"))
      }),

    "key send": .init(
      "Send one keystroke to the focused app", [.text("keys", "hotkey", required: true)],
      parse: sendKeyCommand),

    "key sequence": .init(
      "Send a short key sequence to the focused app",
      [.text("keys", "hotkey,hotkey,...", required: true)], parse: sendKeysCommand),

  ]

  static var usageText: String {
    commandNames.compactMap { syntax(for: $0, prefix: "flash ") }.joined(separator: "\n")
  }

  static func syntax(for name: CommandName, prefix: String) -> String? {
    guard let definition = commands[name.description] else { return nil }
    let arguments = definition.parameters.map(\.syntax).joined(separator: " ")
    return prefix + name.description + (arguments.isEmpty ? "" : " " + arguments)
  }

  /// The arguments `name` requires, so completion keeps its line open.
  static func requiresArguments(_ name: CommandName) -> Bool {
    commands[name.description]?.parameters.contains(where: \.required) ?? false
  }

  private static func selectionCommand(_ action: SelectionAction, _ summary: String)
    -> CommandDefinition
  {
    guard action.takesRegister else {
      return .init(summary, parse: { a in a.args.isEmpty ? .selection(action) : nil })
    }
    return .init(
      summary, [.text("register", "name")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .selection(action, register: registerArg(a))
      })
  }
}

/// Args bag for a command dispatch. Constructed from the JSON dictionary on
/// the AppleEvent payload (CLI path) or from a mapping array's `k=v`
/// tail (config path). The few `bool` / `int` accessors keep the
/// dispatch table tight.
struct CommandArgs {
  let args: [String: String]
  func value(_ name: String) -> String? {
    args[name]
  }
  func bool(_ name: String) -> Bool {
    let v = args[name]
    return v == "1" || v == "true"
  }
  func int(_ name: String) -> Int? {
    args[name].flatMap(Int.init)
  }
}

private func alertCommand(_ a: CommandArgs) -> URLCommand? {
  guard let message = a.value("message"), !message.isEmpty else { return nil }

  let duration: TimeInterval?
  if let rawDuration = a.value("duration") {
    guard
      let parsed = TimeInterval(rawDuration),
      parsed.isFinite,
      parsed > 0
    else {
      return nil
    }
    duration = parsed
  } else {
    duration = nil
  }

  let styleRaw = a.value("style") ?? StatusAlert.Style.standard.rawValue
  guard let style = StatusAlert.Style(rawValue: styleRaw) else { return nil }
  return .showAlert(AlertCommand(message: message, duration: duration, style: style))
}

/// `--command` holds the wrapped command line as the words after `flash` in a
/// mapping: `tab close`, `tab select --index=2`, `screenshot window`. The
/// words are split on spaces, so an argument value cannot contain one.
private func confirmCommand(_ a: CommandArgs) -> URLCommand? {
  guard let prompt = a.value("prompt")?.trimmed, !prompt.isEmpty,
    let line = a.value("command")
  else { return nil }
  let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  guard !words.isEmpty,
    case .flashCommand(let command)? = parseMappingCommand(argv: ["flash"] + words)
  else { return nil }
  if case .confirm = command { return nil }
  return .confirm(ConfirmCommand(prompt: prompt, command: command))
}

/// `menu press --path=`: the menu's title, then each nested item's,
/// comma-separated and trimmed; at least two, none blank. A title holding a
/// comma cannot be named.
private func menuPath(_ raw: String) -> [String]? {
  let titles = raw.split(separator: ",", omittingEmptySubsequences: false).map {
    $0.trimmingCharacters(in: .whitespaces)
  }
  guard titles.count >= 2, !titles.contains(where: \.isEmpty) else { return nil }
  return titles
}

/// `audio input` / `audio output`: no `--device` lists the devices; a device
/// is a name or UID, never blank.
private func audioDeviceCommand(_ direction: AudioDeviceDirection, _ a: CommandArgs) -> URLCommand?
{
  guard let device = a.value("device") else { return .media(.device(direction, query: nil)) }
  let query = device.trimmed
  guard !query.isEmpty else { return nil }
  return .media(.device(direction, query: query))
}

/// The optional `--minutes` bound of a keep-awake: `.some(nil)` without one,
/// nil (a parse failure) beyond `CaffeinateRequest.maximumMinutes`. The command
/// table already rejects zero, negatives and non-numbers.
private func caffeinateMinutes(_ a: CommandArgs) -> Int?? {
  guard a.value("minutes") != nil else { return .some(nil) }
  guard let minutes = a.int("minutes"), minutes <= CaffeinateRequest.maximumMinutes else {
    return nil
  }
  return .some(minutes)
}

/// The required `--letter` of a mark: one ASCII letter or digit.
private func markSlot(_ a: CommandArgs) -> MarkSlot? {
  a.value("letter").flatMap(MarkSlot.init(parsing:))
}

/// Read the optional register shared by yank, paste and selection commands.
private func registerArg(_ a: CommandArgs) -> String? {
  a.value("register")
}

private func validRegisterArg(_ a: CommandArgs) -> Bool {
  guard let raw = registerArg(a) else { return true }
  return raw.count == 1 && raw.first.map(NormalModeInterpreter.isRegisterNameChar) == true
}

private func mouseCommand(_ a: CommandArgs, allowAdjust: Bool = true) -> MouseCommand? {
  let modifiers: ClickModifiers
  if let raw = a.value("modifiers") {
    let names = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    let parsed = KeyModifier.parseList(names)
    guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }), parsed.unknown.isEmpty else {
      return nil
    }
    modifiers = ClickModifiers(names: names)
  } else {
    modifiers = []
  }
  let drag = a.bool("drag")
  let select = a.bool("select")
  let multi = a.bool("multi")
  let adjust = a.bool("adjust")
  let search = a.bool("search")
  let path = a.bool("path")
  let sticky = a.bool("sticky")
  if (adjust || search || path || sticky) && !allowAdjust { return nil }
  if [drag, select, multi, adjust, search, path, sticky].filter({ $0 }).count > 1 { return nil }
  let variants: [JumpAction] = [
    a.bool("secondary") ? .rightClick : nil,
    a.bool("double") ? .doubleClick : nil,
    a.bool("middle") ? .middleClick : nil,
    a.bool("triple") ? .tripleClick : nil,
  ].compactMap { $0 }
  let shaped = drag || select || multi || adjust || search || path || sticky
  if a.bool("copy_url") || a.bool("copy_text") {
    guard allowAdjust, a.value("gesture") == nil, !a.bool("move"), modifiers.isEmpty,
      variants.isEmpty, !shaped, !(a.bool("copy_url") && a.bool("copy_text"))
    else { return nil }
    return a.bool("copy_url") ? .copyURL : .copyText
  }
  if let raw = a.value("gesture") {
    guard let gesture = TargetGesture(rawValue: raw), !a.bool("move"), modifiers.isEmpty,
      variants.isEmpty, !shaped
    else { return nil }
    return .gesture(gesture)
  }
  if a.bool("move") {
    return (modifiers.isEmpty && variants.isEmpty && !shaped) ? .move : nil
  }
  if drag { return variants.isEmpty ? .drag(modifiers: modifiers) : nil }
  if select { return variants.isEmpty ? .select(modifiers: modifiers) : nil }
  if variants.count > 1 { return nil }
  // A secondary click (a Control-click is one) opens a menu that takes the
  // keyboard and ends a chain (`ClickChain.Step.nativeMenu`), so a session
  // that repeats its click never carries one.
  if multi || sticky, variants.first == .rightClick || modifiers.contains(.control) {
    return nil
  }
  if multi { return .multi(variants.first ?? .leftClick, modifiers: modifiers) }
  if adjust { return .adjust(variants.first ?? .leftClick, modifiers: modifiers) }
  if search { return .search(variants.first ?? .leftClick, modifiers: modifiers) }
  if path { return .path(variants.first ?? .leftClick, modifiers: modifiers) }
  if sticky { return .sticky(variants.first ?? .leftClick, modifiers: modifiers) }
  return .click(variants.first ?? .leftClick, modifiers: modifiers)
}

/// `flash key send --keys=<hotkey>` synthesizes one modified keystroke to
/// the focused app. `keys` uses the exact same syntax as a config hotkey
/// (`cmd+option+r`, `shift+tab`, `0x24`), so a plugin can override a
/// built-in keystroke (e.g. Safari's hard refresh is `cmd+option+r`, not
/// the default `cmd+shift+r`) just by registering an app-scoped mapping
/// that points here. Rejected at parse time when `keys` is missing or
/// unparseable.
private func sendKeyCommand(_ a: CommandArgs) -> URLCommand? {
  guard let keys = a.value("keys"), let parsed = HotkeySyntax.parse(hotkey: keys) else {
    return nil
  }
  return .sendKey(
    keys: keys,
    keyCode: CGKeyCode(parsed.virtualKey),
    flagsRawValue: parsed.eventFlags.rawValue)
}

/// `flash key sequence --keys=<hotkey,hotkey,...>` synthesizes a short key sequence
/// to the focused app. It is primarily for app-local multi-stroke shortcuts
/// such as Gmail's `g` then `i` navigation commands.
private func sendKeysCommand(_ a: CommandArgs) -> URLCommand? {
  guard let keys = a.value("keys") else { return nil }
  var keyCodes: [CGKeyCode] = []
  var flagsRawValues: [UInt64] = []
  let parts = keys.split(separator: ",", omittingEmptySubsequences: false)
  guard !parts.isEmpty else { return nil }
  for raw in parts {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, let parsed = HotkeySyntax.parse(hotkey: token) else {
      return nil
    }
    keyCodes.append(CGKeyCode(parsed.virtualKey))
    flagsRawValues.append(parsed.eventFlags.rawValue)
  }
  return .sendKeys(keys: keys, keyCodes: keyCodes, flagsRawValues: flagsRawValues)
}

/// `mouse screens`: at most one of `--index` and `--direction`; neither
/// labels every display.
private func screenSelectCommand(_ a: CommandArgs) -> URLCommand? {
  var request = ScreenSelectRequest()
  switch (a.int("index"), a.value("direction")) {
  case (nil, nil): break
  case (let index?, nil): request.pick = .index(index)
  case (nil, "next"): request.pick = .next
  case (nil, "previous"): request.pick = .previous
  default: return nil
  }
  if let to = a.value("to") {
    guard let landing = ScreenSelectRequest.Landing(rawValue: to) else { return nil }
    request.landing = landing
  }
  request.focus = a.bool("focus")
  return .mouseScreens(request)
}

private func windowMoveCommand(_ a: CommandArgs) -> URLCommand? {
  let rawPosition = a.value("position")
  let rawScreen = a.value("screen")
  let rawX = a.value("x")
  let rawY = a.value("y")
  let rawWidth = a.value("width")
  let rawHeight = a.value("height")
  let rawFrame = [rawX, rawY, rawWidth, rawHeight]
  let hasProportionalFrame = rawFrame.contains(where: { $0 != nil })
  // Empty form `flash window move` is a no-op mapping — flag it at
  // config load so the user can't mis-write a hotkey.
  if rawPosition == nil && rawScreen == nil && !hasProportionalFrame { return nil }
  // Named slots and explicit percentage frames are two complete layout forms;
  // mixing them would make the source of each dimension ambiguous.
  if rawPosition != nil && hasProportionalFrame { return nil }
  // A *typo'd* position (e.g. `position=foo`) is rejected too; we
  // don't want to silently degrade to "just move screen".
  var layout: WindowLayout? = nil
  if let raw = rawPosition {
    guard let p = WindowPosition(rawValue: raw.lowercased()) else {
      return nil
    }
    layout = .position(p)
  } else if hasProportionalFrame {
    guard
      let x = parseWindowPercentage(rawX),
      let y = parseWindowPercentage(rawY),
      let width = parseWindowPercentage(rawWidth),
      let height = parseWindowPercentage(rawHeight),
      width > 0,
      height > 0,
      x + width <= 100,
      y + height <= 100
    else { return nil }
    layout = .proportional(
      ProportionalWindowFrame(
        xPercent: x,
        yPercent: y,
        widthPercent: width,
        heightPercent: height))
  }
  // Swift's Int(_:) already accepts a leading "+" or "-", so
  // `screen=+1` and `screen=-1` round-trip without a custom sign
  // parser. A non-numeric `screen=` value is rejected.
  let screen: Int
  if let raw = rawScreen {
    guard let n = Int(raw) else { return nil }
    screen = n
  } else {
    screen = 0
  }
  return .moveWindow(MoveWindowParams(layout: layout, screen: screen))
}

private func parseWindowPercentage(_ raw: String?) -> Double? {
  guard let raw, raw.hasSuffix("%"), raw.count > 1 else { return nil }
  let number = String(raw.dropLast())
  guard let percentage = Double(number), percentage.isFinite,
    percentage >= 0, percentage <= 100
  else { return nil }
  return percentage
}

/// `WindowPosition` is also referenced by `WindowMover`. Keep its
/// declaration near `URLCommand`/`MoveWindowParams` so they live in one
/// file.
enum WindowPosition: String, CaseIterable, Hashable {
  case topLeft = "topleft"
  case topRight = "topright"
  case bottomLeft = "bottomleft"
  case bottomRight = "bottomright"
  case leftHalf = "lefthalf"
  case rightHalf = "righthalf"
  case topHalf = "tophalf"
  case bottomHalf = "bottomhalf"
  case maximized = "maximized"
  case centered = "centered"
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

/// `--direction=left|right|up|down` for the `tile` commands.
private func tileDirection(_ arguments: CommandArgs) -> WindowFocusDirection? {
  arguments.value("direction").flatMap(WindowFocusDirection.init(rawValue:))
}

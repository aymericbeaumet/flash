import AppKit
import Carbon.HIToolbox
import FlashCore

enum URLCommand: Hashable {
  case mouseTarget(MouseCommand)
  case mouseGrid(MouseCommand)
  case normalMode
  case insertMode
  case commandMode
  case scroll(NormalModeDispatcher.ScrollKind)
  case reload(force: Bool)
  case undo
  case redo
  case close
  case tabClose
  case find
  case candidateFinder(all: Bool)
  case flashlight
  case emojiPicker
  case copyURL
  case tabNext
  case tabPrev
  case tabFirst
  case tabLast
  case tabSelect(index: Int?)
  case tabMovePrev
  case tabMoveNext
  case tabReopen
  case historyBack
  case historyForward
  case movementBack
  case movementForward
  case appPrev
  case appNext
  case setMark(letter: String)
  case jumpToMark(letter: String)
  case quitApp(force: Bool)
  case save
  case saveAndQuit(force: Bool)
  case print
  case openDocument
  case newWindow
  case tabNew
  case copy
  case cut
  case paste
  case copyAll
  case showAlert(message: String)
  case dismissAlert
  case showUsage(topic: String?)
  case showPlugins
  case dismissHints
  case quit
  case openApp(name: String)
  case pluginCommand(command: String, subcommand: String, args: [String])
  case moveWindow(MoveWindowParams)
  case sendKey(keys: String, keyCode: CGKeyCode, flagsRawValue: UInt64)
}

enum MouseCommand: Hashable {
  case click(JumpAction)
  case move

  var action: JumpAction {
    switch self {
    case .click(let action): return action
    case .move: return .leftClick
    }
  }

  var isMove: Bool {
    if case .move = self { return true }
    return false
  }
}

/// Named positions for `flash://window_move?position=…`. Each value
/// maps the focused window to a fixed slot of the target screen's
/// Flash-usable frame: `visibleFrame` plus Flash's own top status-bar
/// reservation when advanced mode is active. The names mirror the
/// shape users expect from Rectangle / Magnet / Hammerspoon
/// snippets — halves, quarters, a maximized fill, and a centered
/// "70 × 80 of the screen" common breakpoint.
enum WindowPosition: String, Hashable {
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

/// Parameters for `flash://window_move?position=&screen=`. Both
/// query keys are optional and orthogonal:
///
/// - `position` (optional): named slot of the target screen's
///   Flash-usable frame. When omitted, the window keeps its shape and
///   is only translated (proportionally remapped) onto the target
///   screen.
/// - `screen` (optional): relative monitor offset. `0` (or omitted)
///   stays on the window's current screen. `+N` / `-N` cycle forward
///   / backward through `NSScreen.screens` with modulo wrap.
///
/// The URL parser rejects the empty form (`flash://window_move`) so
/// a mapping that forgot both keys fails at config load instead of
/// firing a silent no-op on every press.
struct MoveWindowParams: Hashable {
  let position: WindowPosition?
  let screen: Int
}

final class URLEventHandler: NSObject {
  private let handler: (URLCommand) -> Void

  init(handler: @escaping (URLCommand) -> Void) {
    self.handler = handler
    super.init()
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURL(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  @objc func handleGetURL(
    _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
  ) {
    guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let cmd = URLEventHandler.parseAppleEventURL(raw)
    else { return }
    handler(cmd)
  }

  /// Parse a flash URL received from an external AppleEvent (`open -g flash://`,
  /// `osascript`, `flashctl`, drive-by browser navigations). Sender is
  /// untrusted: any process or web page that can construct a URL and hand it to
  /// Launch Services can trigger this path. Limited to the AppleEvent-safe
  /// command subset; actions that would let a remote sender hijack the focused
  /// app (e.g. `send_key`) are rejected here and remain reachable only through
  /// trusted mapping config.
  static func parseAppleEventURL(_ raw: String) -> URLCommand? {
    parseFlashURL(raw, trust: .appleEvent)
  }

  /// Parse a flash URL coming out of trusted mapping config — `[mode.*.mappings]`
  /// entries the user wrote in `~/.config/flash/flash.toml`. The full command
  /// surface is available because the sender is the on-disk config file the
  /// user controls.
  static func parseMappingURL(_ raw: String) -> URLCommand? {
    parseFlashURL(raw, trust: .mapping)
  }

  /// Distinguishes which command table is consulted. Centralized in
  /// `parseFlashURL` so each callsite explicitly picks a trust level instead of
  /// inheriting the maximum surface by default.
  enum Trust {
    /// External, untrusted (AppleEvent / Launch Services).
    case appleEvent
    /// Trusted (on-disk config the user wrote).
    case mapping
  }

  private static func parseFlashURL(_ raw: String, trust: Trust) -> URLCommand? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "flash"
    else { return nil }
    let name = (components.host ?? components.path).lowercased()
    let parser: ((FlashURLQuery) -> URLCommand?)?
    switch trust {
    case .appleEvent:
      parser = Self.commands[name]
    case .mapping:
      parser = Self.commands[name] ?? Self.mappingOnlyCommands[name]
    }
    guard let parser else { return nil }
    return parser(FlashURLQuery(items: components.queryItems ?? []))
  }

  /// Dispatch table for `flash://<name>` commands. Adding a new
  /// command is a two-step change:
  ///   1. add a case to `URLCommand`
  ///   2. add a parser closure here
  /// The dispatcher in `AppDelegate` switches exhaustively over
  /// `URLCommand`, so the compiler points out any missed wiring.
  private static let commands: [String: (FlashURLQuery) -> URLCommand?] = [
    "mouse_target": { q in mouseCommand(q).map(URLCommand.mouseTarget) },
    "mouse_grid": { q in mouseCommand(q).map(URLCommand.mouseGrid) },
    "mouse_snipe": { q in mouseCommand(q).map(URLCommand.mouseGrid) },
    "mouse_click": { q in mouseCommand(q).map(URLCommand.mouseTarget) },
    "mode_normal": { _ in .normalMode },
    "mode_insert": { _ in .insertMode },
    "mode_command": { _ in .commandMode },
    "scroll_left": { _ in .scroll(.left) },
    "scroll_right": { _ in .scroll(.right) },
    "scroll_up": { _ in .scroll(.up) },
    "scroll_down": { _ in .scroll(.down) },
    "scroll_half_page_up": { _ in .scroll(.halfPageUp) },
    "scroll_half_page_down": { _ in .scroll(.halfPageDown) },
    "scroll_top": { _ in .scroll(.top) },
    "scroll_bottom": { _ in .scroll(.bottom) },
    "app_reload": { q in .reload(force: q.bool("force")) },
    "app_undo": { _ in .undo },
    "app_redo": { _ in .redo },
    "window_close": { _ in .close },
    "tab_close": { _ in .tabClose },
    "app_find": { _ in .find },
    "app_open_finder": { q in .candidateFinder(all: q.bool("all")) },
    "flashlight": { _ in .flashlight },
    "emojis": { _ in .emojiPicker },
    "url_copy": { _ in .copyURL },
    "tab_next": { _ in .tabNext },
    "tab_previous": { _ in .tabPrev },
    "tab_first": { _ in .tabFirst },
    "tab_last": { _ in .tabLast },
    "tab_select": { q in .tabSelect(index: q.int("index")) },
    "tab_move_previous": { _ in .tabMovePrev },
    "tab_move_next": { _ in .tabMoveNext },
    "tab_reopen": { _ in .tabReopen },
    "history_back": { _ in .historyBack },
    "history_forward": { _ in .historyForward },
    "movement_back": { _ in .movementBack },
    "movement_forward": { _ in .movementForward },
    "app_previous": { _ in .appPrev },
    "app_next": { _ in .appNext },
    "set_mark": { q in
      guard let letter = q.value("letter"), !letter.isEmpty else { return nil }
      return .setMark(letter: letter)
    },
    "jump_to_mark": { q in
      guard let letter = q.value("letter"), !letter.isEmpty else { return nil }
      return .jumpToMark(letter: letter)
    },
    "app_quit": { q in .quitApp(force: q.bool("force")) },
    "app_save": { _ in .save },
    "app_save_and_quit": { q in .saveAndQuit(force: q.bool("force")) },
    "app_print": { _ in .print },
    "document_open": { _ in .openDocument },
    "window_new": { _ in .newWindow },
    "tab_new": { _ in .tabNew },
    "clipboard_copy": { _ in .copy },
    "clipboard_cut": { _ in .cut },
    "clipboard_paste": { _ in .paste },
    "clipboard_copy_all": { _ in .copyAll },
    "alert_show": { q in
      guard let message = q.value("message"), !message.isEmpty else { return nil }
      return .showAlert(message: message)
    },
    "alert_dismiss": { _ in .dismissAlert },
    "help_show": { q in .showUsage(topic: q.value("topic")) },
    "plugins": { _ in .showPlugins },
    "hints_dismiss": { _ in .dismissHints },
    "flash_quit": { _ in .quit },
    "app_open": { q in
      guard let name = q.value("name"), !name.isEmpty else { return nil }
      return .openApp(name: name)
    },
    "plugin_command": { q in
      guard let command = q.value("command"), !command.isEmpty,
        let subcommand = q.value("subcommand"), !subcommand.isEmpty
      else { return nil }
      let args =
        q.value("args")?
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init) ?? []
      return .pluginCommand(command: command, subcommand: subcommand, args: args)
    },
    "window_move": windowMoveCommand,
  ]

  /// Commands exposed only to trusted mapping config — never to the AppleEvent
  /// entry point. `send_key` synthesizes a keystroke into the focused app and
  /// would let any URL sender drive the foreground app's keyboard if it were
  /// reachable from `flash://send_key?keys=…` URLs.
  private static let mappingOnlyCommands: [String: (FlashURLQuery) -> URLCommand?] = [
    "send_key": sendKeyCommand
  ]

  static let usageText = """
    flash://mouse_target[?secondary=1|double=1|move=1]
    flash://mouse_grid[?secondary=1|double=1|move=1]
    flash://mode_normal
    flash://mode_insert
    flash://mode_command
    flash://scroll_left
    flash://scroll_right
    flash://scroll_up
    flash://scroll_down
    flash://scroll_half_page_up
    flash://scroll_half_page_down
    flash://scroll_top
    flash://scroll_bottom
    flash://app_reload[?force=1]
    flash://app_undo
    flash://app_redo
    flash://window_close
    flash://tab_close
    flash://app_find
    flash://app_open_finder[?all=1]
    flash://flashlight
    flash://emojis
    flash://url_copy
    flash://tab_next
    flash://tab_previous
    flash://tab_first
    flash://tab_last
    flash://tab_select[?index=<n>]
    flash://tab_move_previous
    flash://tab_move_next
    flash://tab_reopen
    flash://history_back
    flash://history_forward
    flash://movement_back
    flash://movement_forward
    flash://app_previous
    flash://app_next
    flash://app_quit[?force=1]
    flash://app_save
    flash://app_save_and_quit[?force=1]
    flash://app_print
    flash://document_open
    flash://window_new
    flash://tab_new
    flash://clipboard_copy
    flash://clipboard_cut
    flash://clipboard_paste
    flash://clipboard_copy_all
    flash://alert_show?message=<text>
    flash://alert_dismiss
    flash://hints_dismiss
    flash://app_open?name=<app>
    flash://window_move?position=<slot>&screen=<n>
    flash://flash_quit
    flash://help_show[?topic=<topic>]
    flash://plugins
    flash://plugin_command?command=<command>&subcommand=<subcommand>[&args=<space-separated>]
    """
}

extension URLEventHandler {
  static let helpTopic = HelpTopic(
    name: "urls",
    title: "Flash URLs",
    summary: "URL actions accepted by Flash and flashctl.",
    body: """
      # Flash URLs

      Every resident action is addressed through a `flash://` URL. The same
      parser is used by Launch Services, the `flash` / `flashctl` CLI, and
      configured in-process mappings.

      `mouse_target` selects an app-discovered target. `mouse_grid` selects a
      precise screen position by repeatedly narrowing a deterministic grid.

      ```text
      \(URLEventHandler.usageText)
      ```
      """)
}

private func mouseCommand(_ q: FlashURLQuery) -> MouseCommand? {
  if q.bool("move") { return .move }
  let secondary = q.bool("secondary")
  let double = q.bool("double")
  if secondary && double { return nil }
  if secondary { return .click(.rightClick) }
  if double { return .click(.doubleClick) }
  return .click(.leftClick)
}

/// `flash://send_key?keys=<hotkey>` synthesizes one modified keystroke to the
/// focused app. `keys` uses the exact same syntax as a config hotkey
/// (`cmd+option+r`, `shift+tab`, `0x24`), so a plugin can override a built-in
/// keystroke (e.g. Safari's hard refresh is `cmd+option+r`, not the default
/// `cmd+shift+r`) just by registering an app-scoped mapping that points here.
/// Rejected at parse time when `keys` is missing or unparseable.
private func sendKeyCommand(_ q: FlashURLQuery) -> URLCommand? {
  guard let keys = q.value("keys"), let parsed = HotkeySyntax.parse(hotkey: keys) else {
    return nil
  }
  return .sendKey(
    keys: keys,
    keyCode: CGKeyCode(parsed.virtualKey),
    flagsRawValue: cgEventFlags(carbon: parsed.modifiers).rawValue)
}

/// Translate Carbon modifier flags (as `HotkeySyntax` emits) into the
/// `CGEventFlags` the synthesizer consumes.
private func cgEventFlags(carbon: UInt32) -> CGEventFlags {
  var flags: CGEventFlags = []
  if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
  if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
  if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
  if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
  return flags
}

private func windowMoveCommand(_ q: FlashURLQuery) -> URLCommand? {
  let rawPosition = q.value("position")
  let rawScreen = q.value("screen")
  // Empty form `flash://window_move` is a no-op mapping — flag
  // it at config load so the user can't mis-write a hotkey.
  if rawPosition == nil && rawScreen == nil { return nil }
  // A *typo'd* position (e.g. `position=foo`) is rejected too;
  // we don't want to silently degrade to "just move screen".
  var position: WindowPosition? = nil
  if let raw = rawPosition {
    guard let p = WindowPosition(rawValue: raw.lowercased()) else {
      return nil
    }
    position = p
  }
  // Swift's Int(_:) already accepts a leading "+" or "-", so
  // `screen=+1` and `screen=-1` round-trip without a custom
  // sign parser. A non-numeric `screen=` value is rejected.
  let screen: Int
  if let raw = rawScreen {
    guard let n = Int(raw) else { return nil }
    screen = n
  } else {
    screen = 0
  }
  return .moveWindow(MoveWindowParams(position: position, screen: screen))
}

/// Thin wrapper over `[URLQueryItem]` providing the lookups every
/// flash command parser needs (`value(name)` for strings, `bool(name)`
/// for `"1"`/`"true"` flags). Kept private so the command table is
/// the only place that touches query parsing.
private struct FlashURLQuery {
  let items: [URLQueryItem]
  func value(_ name: String) -> String? {
    items.first { $0.name == name }?.value
  }
  func bool(_ name: String) -> Bool {
    let v = value(name)
    return v == "1" || v == "true"
  }
  func int(_ name: String) -> Int? {
    guard let raw = value(name), let value = Int(raw), value > 0 else { return nil }
    return value
  }
}

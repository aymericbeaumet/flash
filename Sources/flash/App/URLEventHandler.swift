import AppKit
import FlashCore

enum URLCommand: Hashable {
  case mouseClick(action: JumpAction)
  case mouseMove
  case normalMode
  case insertMode
  case commandMode
  case scroll(NormalModeDispatcher.ScrollKind)
  case reload
  case undo
  case redo
  case close
  case tabClose
  case find
  case candidateFinder(all: Bool)
  case copyURL
  case nextFrame
  case mainFrame
  case tabNext
  case tabPrev
  case tabSelect(index: Int?)
  case historyBack
  case historyForward
  case movementBack
  case movementForward
  case quitApp(force: Bool)
  case save
  case saveAndQuit(force: Bool)
  case print
  case openDocument
  case newWindow
  case tabNew
  case tabNewInsert
  case copy
  case cut
  case paste
  case copyAll
  case showAlert(message: String)
  case dismissAlert
  case showUsage
  case dismissHints
  case quit
  case openApp(name: String)
  case moveWindow(MoveWindowParams)
}

/// Named positions for `flash://window_move?position=…`. Each value
/// maps the focused window to a fixed slot of the target screen's
/// `visibleFrame` (menu bar + Dock excluded). The names mirror the
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
///   `visibleFrame`. When omitted, the window keeps its shape and is
///   only translated (proportionally remapped) onto the target
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
      let cmd = URLEventHandler.parseFlashURL(raw)
    else { return }
    handler(cmd)
  }

  /// Parse a flash command into a `URLCommand`. Used both by the
  /// live AppleEvent handler (`flash://` URLs from `open` /
  /// `osascript` / Launch Services) AND by `MappingsCoordinator`
  /// at config-load time so the hot path already has a resolved
  /// `URLCommand` and never re-parses a string on a Carbon callback.
  ///
  /// The `flash://` scheme is mandatory. Bare command names like
  /// `"mouse_click"` are rejected — the URL shape is what tells the
  /// reader "this is a flash command, dispatched in-process" and
  /// keeps the string form visually distinct from the argv form
  /// (`["open", ...]`). Any other scheme also returns nil so things
  /// like `https://...` force the user to spell out the slow path
  /// as an argv array.
  static func parseFlashURL(_ raw: String) -> URLCommand? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "flash"
    else { return nil }
    let name = (components.host ?? components.path).lowercased()
    guard let parser = Self.commands[name] else { return nil }
    return parser(FlashURLQuery(items: components.queryItems ?? []))
  }

  /// Dispatch table for `flash://<name>` commands. Adding a new
  /// command is a two-step change:
  ///   1. add a case to `URLCommand`
  ///   2. add a parser closure here
  /// The dispatcher in `AppDelegate` switches exhaustively over
  /// `URLCommand`, so the compiler points out any missed wiring.
  private static let commands: [String: (FlashURLQuery) -> URLCommand?] = [
    "mouse_click": mouseClickCommand,
    "mouse_move": { _ in .mouseMove },
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
    "app_reload": { _ in .reload },
    "app_undo": { _ in .undo },
    "app_redo": { _ in .redo },
    "window_close": { _ in .close },
    "tab_close": { _ in .tabClose },
    "app_find": { _ in .find },
    "app_open_finder": { q in .candidateFinder(all: q.bool("all")) },
    "url_copy": { _ in .copyURL },
    "frame_next": { _ in .nextFrame },
    "frame_main": { _ in .mainFrame },
    "tab_next": { _ in .tabNext },
    "tab_previous": { _ in .tabPrev },
    "tab_select": { q in .tabSelect(index: q.int("index")) },
    "history_back": { _ in .historyBack },
    "history_forward": { _ in .historyForward },
    "movement_back": { _ in .movementBack },
    "movement_forward": { _ in .movementForward },
    "app_back": { _ in .movementBack },
    "app_forward": { _ in .movementForward },
    "app_quit": { q in .quitApp(force: q.bool("force")) },
    "app_save": { _ in .save },
    "app_save_and_quit": { q in .saveAndQuit(force: q.bool("force")) },
    "app_print": { _ in .print },
    "document_open": { _ in .openDocument },
    "window_new": { _ in .newWindow },
    "tab_new": { _ in .tabNew },
    "tab_new_insert": { _ in .tabNewInsert },
    "clipboard_copy": { _ in .copy },
    "clipboard_cut": { _ in .cut },
    "clipboard_paste": { _ in .paste },
    "clipboard_copy_all": { _ in .copyAll },
    "alert_show": { q in
      guard let message = q.value("message"), !message.isEmpty else { return nil }
      return .showAlert(message: message)
    },
    "show_alert": { q in
      guard let message = q.value("message"), !message.isEmpty else { return nil }
      return .showAlert(message: message)
    },
    "alert_dismiss": { _ in .dismissAlert },
    "help_show": { _ in .showUsage },
    "hints_dismiss": { _ in .dismissHints },
    "flash_quit": { _ in .quit },
    "app_open": { q in
      guard let name = q.value("name"), !name.isEmpty else { return nil }
      return .openApp(name: name)
    },
    "window_move": windowMoveCommand,
  ]

  static let usageText = """
    flash://mouse_click[?right=1|double=1]
    flash://mouse_move
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
    flash://app_reload
    flash://app_undo
    flash://app_redo
    flash://window_close
    flash://tab_close
    flash://app_find
    flash://app_open_finder[?all=1]
    flash://url_copy
    flash://frame_next
    flash://frame_main
    flash://tab_next
    flash://tab_previous
    flash://tab_select[?index=<n>]
    flash://history_back
    flash://history_forward
    flash://movement_back
    flash://movement_forward
    flash://app_quit[?force=1]
    flash://app_save
    flash://app_save_and_quit[?force=1]
    flash://app_print
    flash://document_open
    flash://window_new
    flash://tab_new
    flash://tab_new_insert
    flash://clipboard_copy
    flash://clipboard_cut
    flash://clipboard_paste
    flash://clipboard_copy_all
    flash://alert_show?message=<text>
    flash://show_alert?message=<text>
    flash://alert_dismiss
    flash://hints_dismiss
    flash://app_open?name=<app>
    flash://window_move?position=<slot>&screen=<n>
    flash://flash_quit
    flash://help_show
    """
}

private func mouseClickCommand(_ q: FlashURLQuery) -> URLCommand? {
  if q.bool("right") { return .mouseClick(action: .rightClick) }
  if q.bool("double") { return .mouseClick(action: .doubleClick) }
  return .mouseClick(action: .leftClick)
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

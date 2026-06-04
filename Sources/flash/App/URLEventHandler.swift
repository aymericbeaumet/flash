import AppKit

enum URLCommand {
  case showHints(rightClick: Bool)
  case showAlert(message: String)
  case dismissAlert
  case showUsage
  case dismissHints
  case quit
  case openApp(name: String)
  case moveWindow(MoveWindowParams)
}

/// Named positions for `flash://move_window?position=…`. Each value
/// maps the focused window to a fixed slot of the target screen's
/// `visibleFrame` (menu bar + Dock excluded). The names mirror the
/// shape users expect from Rectangle / Magnet / Hammerspoon
/// snippets — halves, quarters, a maximized fill, and a centered
/// "70 × 80 of the screen" common breakpoint.
enum WindowPosition: String {
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

/// Parameters for `flash://move_window?position=&screen=`. Both
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
/// The URL parser rejects the empty form (`flash://move_window`) so
/// a binding that forgot both keys fails at config load instead of
/// firing a silent no-op on every press.
struct MoveWindowParams: Equatable {
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
  /// `osascript` / Launch Services) AND by `ShortcutsCoordinator`
  /// at config-load time so the hot path already has a resolved
  /// `URLCommand` and never re-parses a string on a Carbon callback.
  ///
  /// The `flash://` scheme is mandatory. Bare command names like
  /// `"show_hints"` are rejected — the URL shape is what tells the
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
    "show_hints": { q in .showHints(rightClick: q.bool("right")) },
    "show_alert": { q in
      guard let message = q.value("message"), !message.isEmpty else { return nil }
      return .showAlert(message: message)
    },
    "dismiss_alert": { _ in .dismissAlert },
    "help": { _ in .showUsage },
    "dismiss_hints": { _ in .dismissHints },
    "quit": { _ in .quit },
    "open_app": { q in
      guard let name = q.value("name"), !name.isEmpty else { return nil }
      return .openApp(name: name)
    },
    "move_window": { q in
      let rawPosition = q.value("position")
      let rawScreen = q.value("screen")
      // Empty form `flash://move_window` is a no-op binding — flag
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
    },
  ]

  static let usageText = """
    flash://show_hints[?right=1]
    flash://show_alert?message=<text>
    flash://dismiss_alert
    flash://dismiss_hints
    flash://open_app?name=<app>
    flash://move_window?position=<slot>&screen=<n>
    flash://quit
    flash://help
    """
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
}

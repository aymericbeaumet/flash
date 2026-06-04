import AppKit

enum URLCommand {
  case showHints(rightClick: Bool)
  case dismissHints
  case quit
  case openApp(name: String)
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

  /// Parse a `flash://...` URL string into a `URLCommand`. Used both
  /// by the live Apple-Event handler (`flash://` URLs that arrive from
  /// `open` / `osascript` / Launch Services) AND by
  /// `ShortcutsCoordinator` at config-load time so the hot path
  /// already has a resolved `URLCommand` and never re-parses a
  /// string when a hotkey fires.
  static func parseFlashURL(_ raw: String) -> URLCommand? {
    guard let components = URLComponents(string: raw) else { return nil }
    if let scheme = components.scheme, scheme.lowercased() != "flash" {
      return nil
    }
    switch components.host?.lowercased() ?? components.path.lowercased() {
    case "show_hints":
      let right =
        components.queryItems?.contains(where: {
          $0.name == "right" && ($0.value == "1" || $0.value == "true")
        }) ?? false
      return .showHints(rightClick: right)
    case "dismiss_hints":
      return .dismissHints
    case "quit":
      return .quit
    case "open_app":
      let name =
        components.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
      return name.isEmpty ? nil : .openApp(name: name)
    default:
      return nil
    }
  }
}

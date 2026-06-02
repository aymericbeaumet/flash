import AppKit

enum URLCommand {
  case showHints(rightClick: Bool)
  case dismissHints
  case quit
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
      let components = URLComponents(string: raw)
    else { return }
    switch components.host?.lowercased() ?? components.path.lowercased() {
    case "show_hints":
      let right =
        components.queryItems?.contains(where: {
          $0.name == "right" && ($0.value == "1" || $0.value == "true")
        }) ?? false
      handler(.showHints(rightClick: right))
    case "dismiss_hints":
      handler(.dismissHints)
    case "quit":
      handler(.quit)
    default:
      break
    }
  }
}

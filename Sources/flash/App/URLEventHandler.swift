import AppKit

enum URLCommand {
  case activate(rightClick: Bool)
  case cancel
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
    case "activate":
      let right =
        components.queryItems?.contains(where: {
          $0.name == "right" && ($0.value == "1" || $0.value == "true")
        }) ?? false
      handler(.activate(rightClick: right))
    case "cancel":
      handler(.cancel)
    case "quit":
      handler(.quit)
    default:
      break
    }
  }
}

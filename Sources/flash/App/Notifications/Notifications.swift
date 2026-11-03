import AppKit
import FlashCore
import UserNotifications

/// `notify send`: a native macOS notification, posted through the system's
/// Notification Center, where it stays until dismissed. Distinct from
/// `alert show`, Flash's own centred alert, which comes and goes on screen.
struct NotifyRequest: Hashable {
  var title: String
  var subtitle: String
  var body: String
  var sound: Bool
  /// Opened when the notification is clicked.
  var url: URL?
  /// Run when the notification is clicked, as a mapping runs it.
  var command: URLCommand?
  /// A notification posted with the same id replaces this one.
  var id: String?

  static let maxTitleLength = 256
  static let maxBodyLength = 2048
  static let maxIDLength = 64

  /// Schemes a click never opens: local files and script URLs.
  static let refusedSchemes: Set<String> = ["file", "data", "javascript"]

  /// A request, or why it is refused.
  static func make(
    title: String?, subtitle: String?, body: String?, sound: Bool, url: String?,
    command: String?, id: String?
  ) -> Result<NotifyRequest, NotifyError> {
    let title = title?.trimmed ?? ""
    let subtitle = subtitle?.trimmed ?? ""
    let body = body?.trimmed ?? ""
    guard !title.isEmpty || !body.isEmpty else {
      return .failure(.init("notify send needs a --title or a --body"))
    }
    guard title.count <= maxTitleLength, subtitle.count <= maxTitleLength else {
      return .failure(.init("a title or subtitle is at most \(maxTitleLength) characters"))
    }
    guard body.count <= maxBodyLength else {
      return .failure(.init("a body is at most \(maxBodyLength) characters"))
    }
    if url != nil, command != nil {
      return .failure(.init("a click opens a --url or runs a --command, not both"))
    }
    var parsedURL: URL?
    if let url {
      switch Self.clickURL(url) {
      case .success(let value): parsedURL = value
      case .failure(let error): return .failure(error)
      }
    }
    var parsedCommand: URLCommand?
    if let command {
      let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard !words.isEmpty,
        case .flashCommand(let parsed)? = parseMappingCommand(argv: ["flash"] + words)
      else {
        return .failure(.init("--command must be a Flash command, such as \"window switch\""))
      }
      parsedCommand = parsed
    }
    if let id {
      guard Self.isValidID(id) else {
        return .failure(
          .init("--id is 1 to \(maxIDLength) letters, digits, '.', '_' or '-'"))
      }
    }
    return .success(
      NotifyRequest(
        title: title, subtitle: subtitle, body: body, sound: sound, url: parsedURL,
        command: parsedCommand, id: id))
  }

  /// A URL a click may open: absolute, with a scheme that is not a local
  /// file or a script.
  static func clickURL(_ text: String) -> Result<URL, NotifyError> {
    guard let url = URLParsing.url(text.trimmed), let scheme = url.scheme?.lowercased(),
      !scheme.isEmpty
    else { return .failure(.init("--url must be an absolute URL such as https://example.com")) }
    guard !refusedSchemes.contains(scheme) else {
      return .failure(.init("--url cannot open \(scheme): URLs"))
    }
    return .success(url)
  }

  static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= maxIDLength
      && id.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "." || $0 == "_" || $0 == "-"
      }
  }

  /// The words that send it again, after `notify send`.
  var argTokens: [String] {
    var tokens: [String] = []
    if !title.isEmpty { tokens.append("--title=\(title)") }
    if !subtitle.isEmpty { tokens.append("--subtitle=\(subtitle)") }
    if !body.isEmpty { tokens.append("--body=\(body)") }
    if sound { tokens.append("--sound") }
    if let url { tokens.append("--url=\(url.absoluteString)") }
    if let command { tokens.append("--command=\(command.argv.dropFirst().joined(separator: " "))") }
    if let id { tokens.append("--id=\(id)") }
    return tokens
  }

  /// The click action, as the notification carries it across restarts.
  var userInfo: [String: String] {
    var info: [String: String] = [:]
    if let url { info[NotifyClick.urlKey] = url.absoluteString }
    if let command {
      info[NotifyClick.commandKey] = command.argv.dropFirst().joined(separator: " ")
    }
    return info
  }
}

struct NotifyError: Error, Equatable, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

/// `notify send` and `notify clear`.
enum NotifyCommand: Hashable {
  case send(NotifyRequest)
  /// Remove Flash's notifications from Notification Center: one by `id`, or
  /// all of them.
  case clear(id: String?)

  var name: CommandName {
    switch self {
    case .send: return CommandName("notify", "send")
    case .clear: return CommandName("notify", "clear")
    }
  }

  var argTokens: [String] {
    switch self {
    case .send(let request): return request.argTokens
    case .clear(let id): return id.map { ["--id=\($0)"] } ?? []
    }
  }

  var explanation: String {
    switch self {
    case .send(let request):
      let text = request.title.isEmpty ? request.body : request.title
      return "Posts the macOS notification “\(text)”."
    case .clear(let id):
      return id.map { "Removes Flash's \($0) notification from Notification Center." }
        ?? "Removes Flash's notifications from Notification Center."
    }
  }
}

/// What clicking a notification does, read back from its user info.
enum NotifyClick: Equatable {
  case open(URL)
  case run(URLCommand)
  case nothing

  static let urlKey = "flash.url"
  static let commandKey = "flash.command"

  /// The click action of a notification's user info. A URL or command that
  /// no longer parses (a later version renamed it) does nothing.
  init(userInfo: [AnyHashable: Any]) {
    if let text = userInfo[Self.urlKey] as? String,
      case .success(let url) = NotifyRequest.clickURL(text)
    {
      self = .open(url)
      return
    }
    if let line = userInfo[Self.commandKey] as? String {
      let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      if !words.isEmpty,
        case .flashCommand(let command)? = parseMappingCommand(argv: ["flash"] + words)
      {
        self = .run(command)
        return
      }
    }
    self = .nothing
  }
}

/// Whether Flash may post, as Notification Center reports it.
enum NotifyAuthorization: Equatable {
  /// Nobody was asked yet: the first `notify send` asks.
  case notDetermined
  case allowed
  case denied
}

/// The system's notification center, behind a seam: tests never post a real
/// notification or raise the permission prompt.
protocol NotificationCentering: AnyObject {
  func authorization(_ completion: @escaping (NotifyAuthorization) -> Void)
  /// Ask the user; true when allowed.
  func requestAuthorization(_ completion: @escaping (Bool) -> Void)
  /// Post `request` under `identifier`; nil, or why macOS refused it.
  func post(_ request: NotifyRequest, identifier: String, completion: @escaping (String?) -> Void)
  /// Remove the delivered and pending notifications with these ids; nil
  /// removes all of Flash's.
  func remove(identifiers: [String]?)
}

/// Posts notifications for `notify send` and the monitors that ask for
/// them. Main-thread owner: authorization is asked lazily, on the first post,
/// never at launch; posts that arrive while the prompt is up wait for its
/// answer instead of asking again.
final class NotificationController {
  private let center: any NotificationCentering
  private var authorizing = false
  private var waiting: [(NotifyRequest, String, (String?) -> Void)] = []

  /// What a denial says, for the CLI and the log.
  static let deniedMessage =
    "notifications are off for Flash: allow them in System Settings › Notifications › Flash"

  init(center: any NotificationCentering) {
    self.center = center
  }

  /// The resident's controller over the system's notification center; nil
  /// inside the test runner and outside an app bundle, where macOS has no
  /// notification center to give.
  static func live() -> NotificationController? {
    guard NSClassFromString("XCTestCase") == nil, Bundle.main.bundleIdentifier != nil else {
      return nil
    }
    return NotificationController(center: LiveNotificationCenter.shared)
  }

  /// The identifier a request posts under: its `id`, or a fresh one.
  static func identifier(for request: NotifyRequest) -> String {
    request.id.map { "flash.notify.\($0)" } ?? "flash.notify.\(UUID().uuidString)"
  }

  /// Post `request`; `completion` gets nil once posted, or why not, on main.
  func send(_ request: NotifyRequest, completion: @escaping (String?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = Self.identifier(for: request)
    if authorizing {
      waiting.append((request, identifier, completion))
      return
    }
    center.authorization { [weak self] state in
      DispatchQueue.main.async {
        guard let self else { return }
        switch state {
        case .allowed:
          self.post(request, identifier: identifier, completion: completion)
        case .denied:
          completion(Self.deniedMessage)
        case .notDetermined:
          self.waiting.append((request, identifier, completion))
          self.ask()
        }
      }
    }
  }

  /// Remove Flash's notification `id`, or all of them.
  func clear(id: String?) {
    center.remove(identifiers: id.map { ["flash.notify.\($0)"] })
  }

  private func ask() {
    guard !authorizing else { return }
    authorizing = true
    FlashLog.info("[notify] authorization_requested")
    center.requestAuthorization { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self else { return }
        self.authorizing = false
        FlashLog.info("[notify] authorization", fields: ["allowed": allowed ? "true" : "false"])
        let pending = self.waiting
        self.waiting = []
        for (request, identifier, completion) in pending {
          if allowed {
            self.post(request, identifier: identifier, completion: completion)
          } else {
            completion(Self.deniedMessage)
          }
        }
      }
    }
  }

  private func post(
    _ request: NotifyRequest, identifier: String, completion: @escaping (String?) -> Void
  ) {
    center.post(request, identifier: identifier) { failure in
      DispatchQueue.main.async { completion(failure) }
    }
  }
}

/// `NotificationCentering` over `UNUserNotificationCenter`, and its delegate:
/// a notification shows even while Flash is frontmost, and a click hands
/// its action to `onClick` on main.
final class LiveNotificationCenter: NSObject, NotificationCentering,
  UNUserNotificationCenterDelegate
{
  static let shared = LiveNotificationCenter()

  /// Set once at launch, so a click on a notification posted before a
  /// restart still acts.
  var onClick: ((NotifyClick) -> Void)?

  private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  /// Become the delegate. Asks nothing: authorization waits for a post.
  func activate() {
    center.delegate = self
  }

  func authorization(_ completion: @escaping (NotifyAuthorization) -> Void) {
    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .notDetermined: completion(.notDetermined)
      case .authorized, .provisional, .ephemeral: completion(.allowed)
      case .denied: completion(.denied)
      @unknown default: completion(.denied)
      }
    }
  }

  func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
    center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
      if let error {
        FlashLog.warn("[notify] authorization_failed", fields: ["error": "\(error)"])
      }
      completion(allowed)
    }
  }

  func post(_ request: NotifyRequest, identifier: String, completion: @escaping (String?) -> Void) {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.subtitle = request.subtitle
    content.body = request.body
    if request.sound { content.sound = .default }
    content.userInfo = request.userInfo
    let notification = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    center.add(notification) { error in
      completion(error.map { "macOS refused the notification: \($0.localizedDescription)" })
    }
  }

  func remove(identifiers: [String]?) {
    if let identifiers {
      center.removeDeliveredNotifications(withIdentifiers: identifiers)
      center.removePendingNotificationRequests(withIdentifiers: identifiers)
    } else {
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let click = NotifyClick(userInfo: response.notification.request.content.userInfo)
    DispatchQueue.main.async { [weak self] in
      self?.onClick?(click)
      completionHandler()
    }
  }
}

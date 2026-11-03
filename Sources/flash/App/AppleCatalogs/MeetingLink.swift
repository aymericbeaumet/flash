import FlashCore
import Foundation

/// An event's meeting link, found in its URL, location or notes.
struct MeetingLink: Equatable {
  /// The service, as `calendar next` names it: `Zoom`, `Google Meet`, or
  /// the host of a link no service claims.
  var service: String
  /// The link as the event writes it.
  var url: URL
  /// The same meeting in its app (`zoommtg:`, `msteams:`): `calendar join`
  /// opens it when an app handles it, and `url` otherwise.
  var appURL: URL?
}

/// Finds the join link of a Zoom, Google Meet, Microsoft Teams, Webex,
/// Around, Whereby, FaceTime, Slack huddle, Jitsi Meet, GoTo Meeting or
/// Amazon Chime meeting in an event. Pure.
enum MeetingLinks {
  private struct Service {
    let name: String
    let pattern: NSRegularExpression
    let appURL: (URL) -> URL?
  }

  /// What a link runs to: never whitespace, a quote or the brackets that wrap
  /// one in text or HTML.
  private static let body = #"[^\s<>"'()\[\]{}]+"#

  private static func service(
    _ name: String, _ pattern: String, appURL: @escaping (URL) -> URL? = { _ in nil }
  ) -> Service {
    Service(
      name: name,
      // The patterns are constants; a broken one fails every test that finds a link.
      pattern: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      appURL: appURL)
  }

  /// In order of preference when two match at the same place.
  private static let services: [Service] = [
    service(
      "Zoom", #"https?://(?:[a-z0-9-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc/join)/"# + body,
      appURL: zoomAppURL),
    service("Zoom", #"zoom(?:mtg|us)://"# + body),
    service(
      "Google Meet", #"https?://meet\.google\.com/(?:lookup/)?[a-z0-9_-]+(?:\?"# + body + ")?"),
    service(
      "Microsoft Teams",
      #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet|v2)/"# + body,
      appURL: teamsAppURL),
    service("Microsoft Teams", #"msteams:/"# + body),
    service("Webex", #"https?://(?!help\.|www\.)(?:[a-z0-9-]+\.)+webex\.com/"# + body),
    service("Around", #"https?://(?:meet\.)?around\.co/"# + body),
    service("Whereby", #"https?://(?:[a-z0-9-]+\.)?whereby\.com/"# + body),
    service("FaceTime", #"https?://facetime\.apple\.com/join"# + body),
    service("FaceTime", #"facetime(?:-audio)?://"# + body),
    service("Slack huddle", #"https?://app\.slack\.com/huddle/"# + body),
    service("Jitsi Meet", #"https?://meet\.jit\.si/"# + body),
    service(
      "GoTo Meeting",
      #"https?://(?:(?:global|www)\.gotomeeting\.com/join|meet\.goto\.com|(?:www\.)?gotomeet\.me)/"#
        + body),
    service("Amazon Chime", #"https?://chime\.aws/"# + body),
  ]

  /// The event's meeting link: a service's link in its URL, else in its
  /// location, else in its notes, the earliest in each; else its URL or a
  /// location that is one web link, as a meeting no service claims.
  static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
    for text in [url?.absoluteString, location, notes].compactMap({ $0 }) {
      if let link = find(in: text) { return link }
    }
    if let url, isWeb(url) { return generic(url) }
    if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
      !location.contains(where: \.isWhitespace), let url = URLParsing.url(location), isWeb(url),
      url.host != nil
    {
      return generic(url)
    }
    return nil
  }

  /// The earliest service link in `text`.
  static func find(in text: String) -> MeetingLink? {
    let range = NSRange(text.startIndex..., in: text)
    var best: (location: Int, link: MeetingLink)?
    for service in services {
      guard let match = service.pattern.firstMatch(in: text, range: range),
        best.map({ match.range.location < $0.location }) ?? true,
        let matched = Range(match.range, in: text),
        let url = URLParsing.url(cleaned(String(text[matched])))
      else { continue }
      best = (
        match.range.location,
        MeetingLink(service: service.name, url: url, appURL: service.appURL(url))
      )
    }
    return best?.link
  }

  /// A link as written in HTML notes, without the punctuation that ends the
  /// sentence around it.
  private static func cleaned(_ link: String) -> String {
    var link = link.replacingOccurrences(of: "&amp;", with: "&")
    while let last = link.last, ".,;:!?".contains(last) { link.removeLast() }
    return link
  }

  private static func isWeb(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
  }

  private static func generic(_ url: URL) -> MeetingLink {
    var host = url.host ?? url.absoluteString
    if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
    return MeetingLink(service: host, url: url)
  }

  /// `https://<host>/j/<id>?pwd=<pwd>` as Zoom's own `zoommtg:` join link.
  private static func zoomAppURL(_ url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host
    else { return nil }
    let path = components.path.split(separator: "/")
    guard path.count == 2, path[0] == "j", path[1].allSatisfy(\.isNumber) else { return nil }
    var app = URLComponents()
    app.scheme = "zoommtg"
    app.host = host
    app.path = "/join"
    app.queryItems =
      [
        URLQueryItem(name: "action", value: "join"),
        URLQueryItem(name: "confno", value: String(path[1])),
      ]
      + (components.queryItems ?? []).filter { $0.name == "pwd" }
    return app.url
  }

  /// A Teams web link as Teams' own `msteams:` link.
  private static func teamsAppURL(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = "msteams"
    return components.url
  }
}

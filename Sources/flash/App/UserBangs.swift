import AppKit
import FlashCore

/// The user's own bangs and quicklinks, `[flashlight.bangs]`: `!jira ABC-1`
/// opens the bang's URL with the query percent-encoded into every `{query}`;
/// a URL without one is a quicklink, opened as written whatever follows the
/// bang. They list beside the plugins' bangs and dispatch after Flash's own
/// and a plugin's declared tokens, before the search catch-all.
enum UserBangs {
  static let placeholder = "{query}"

  /// Opens the resolved URL, activating the app that takes it. Replaced
  /// under test.
  static var opener: (URL) -> Void = { url in
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
  }

  /// A name is one word of lowercase ASCII letters and digits, typed after
  /// `!`.
  static func isValidName(_ name: String) -> Bool {
    !name.isEmpty
      && name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0)
      }
  }

  /// Why `template` is no bang URL, or nil: an http or https URL whose
  /// only braces are `{query}`.
  static func templateProblem(_ template: String) -> String? {
    let withoutSlots = template.replacingOccurrences(of: placeholder, with: "q")
    if withoutSlots.contains("{") || withoutSlots.contains("}") {
      return "takes no braces but \(placeholder)"
    }
    guard let components = URLParsing.components(withoutSlots),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host, !host.isEmpty
    else { return "must be an http or https URL" }
    return nil
  }

  static func takesQuery(_ template: String) -> Bool { template.contains(placeholder) }

  /// `template` with `query` in each slot, or as written when it has none.
  static func url(template: String, query: String) -> URL? {
    URLParsing.url(template.replacingOccurrences(of: placeholder, with: percentEncoded(query)))
  }

  /// RFC 3986: unreserved characters stay, every other byte of the UTF-8
  /// form is `%XX`, so a space is `%20` and `&`, `/`, `?` and `+` cannot
  /// reach the site as syntax.
  static func percentEncoded(_ query: String) -> String {
    var encoded = ""
    for byte in query.utf8 {
      switch byte {
      case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
        UInt8(ascii: "_"), UInt8(ascii: "~"):
        encoded.unicodeScalars.append(Unicode.Scalar(byte))
      default:
        encoded += String(format: "%%%02X", byte)
      }
    }
    return encoded
  }

  /// `!<name>` rows for the bang list, shaped like plugin bangs: the
  /// description, or the URL as written, under the trigger.
  static func candidates(_ bangs: [String: Config.Flashlight.Bang]) -> [Candidate] {
    bangs.keys.sorted().map { name in
      let bang = bangs[name]!
      return Candidate(
        kind: CandidateFinder.bangKind,
        sourceID: "bang:user",
        source: "bang",
        title: "!\(name)",
        subtitle: bang.description.isEmpty ? bang.url : bang.description,
        sourcePayload: name)
    }
  }

  /// The bang `token` names, or nil. Tokens ignore case as every bang does.
  static func bang(token: String, in bangs: [String: Config.Flashlight.Bang])
    -> Config.Flashlight.Bang?
  {
    bangs[token.lowercased()]
  }
}

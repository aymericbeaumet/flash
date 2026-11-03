import AppKit

/// Which URLs a status link may hand to macOS. A `#[link=…]` is text a
/// plugin, a named source, a `#()` job or a popup's program wrote, so the
/// schemes it may open are an allowlist: web and mail links, plus the
/// `[statusbar] link_schemes` the user trusts those writers with. Everything
/// else is refused: a `file:` link would have Launch Services run what a
/// program wrote, and a custom scheme hands the URL to whatever app
/// registered it. `[statusbar.click]` URLs are the user's own configuration
/// and never pass here, and `$FLASH_STATUS_LINK` reaches a popup's command as
/// text, not as an open.
enum StatusLinkPolicy {
  /// The schemes every status link may open.
  static let builtinSchemes: Set<String> = ["http", "https", "mailto"]

  /// A scheme name as `[statusbar] link_schemes` takes it: RFC 3986's
  /// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`, lowercase, so that each
  /// entry names exactly one scheme and reads as the URL spells it.
  static func isSchemeName(_ name: String) -> Bool {
    guard let first = name.utf8.first, isLowercaseLetter(first) else { return false }
    return name.utf8.allSatisfy {
      isLowercaseLetter($0) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
    }
  }

  private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
  }

  /// The scheme `url` would open under, as macOS reads it (case-insensitive,
  /// so lowercased); nil when the URL has none.
  static func scheme(of url: URL) -> String? {
    guard let scheme = url.scheme, !scheme.isEmpty else { return nil }
    return scheme.lowercased()
  }

  /// Whether `url` may open: its scheme is built in or among `schemes`, the
  /// configured names exactly as written.
  static func permits(_ url: URL, schemes: Set<String>) -> Bool {
    guard let scheme = scheme(of: url) else { return false }
    return builtinSchemes.contains(scheme) || schemes.contains(scheme)
  }
}

/// The one door a status link leaves Flash through, owned by the overlay
/// panel: a click on the bar's click window, an `f` hint on a link and a
/// hyperlink in a popup's pager or program all `follow` here. Main thread.
final class StatusLinkOpener {
  /// How many distinct refused schemes the note keeps.
  static let refusedSchemesLimit = 32

  /// `[statusbar] link_schemes`, applied with the configuration. A scheme
  /// that becomes allowed leaves the refused note.
  var schemes: Set<String> = [] {
    didSet { refusedSchemes.removeAll { schemes.contains($0) } }
  }
  /// The schemes refused since launch, first refusal first, each once:
  /// what `resident doctor` reports. The refusal is the only trace a refused
  /// link leaves, and it never carries the URL.
  private(set) var refusedSchemes: [String] = []
  /// Hands a permitted URL to macOS. Tests replace it.
  var open: (URL) -> Void = StatusLinkOpener.openActivating

  /// Opens `url` when its scheme is allowed and says whether it was; a
  /// refused link does nothing but note its scheme.
  @discardableResult
  func follow(_ url: URL) -> Bool {
    guard StatusLinkPolicy.permits(url, schemes: schemes) else {
      refuse(url)
      return false
    }
    open(url)
    return true
  }

  private func refuse(_ url: URL) {
    let scheme = StatusLinkPolicy.scheme(of: url) ?? "(none)"
    guard !refusedSchemes.contains(scheme), refusedSchemes.count < Self.refusedSchemesLimit
    else { return }
    refusedSchemes.append(scheme)
    // Once per scheme: the URL stays out of the log, and a bar that keeps
    // publishing the same link does not storm it.
    FlashLog.info(
      "[statusbar] link_refused", fields: ["scheme": scheme], source: "core:StatusLinkOpener")
  }

  /// Hand a status link to whichever app handles it, bringing that app to
  /// the front with keyboard focus. A plain `open(url)` opens the tab in the
  /// background: the click panel is non-activating, so the previously
  /// focused app would keep focus and typing would land in the old app.
  static func openActivating(_ url: URL) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(url, configuration: configuration) { app, error in
      if let error {
        FlashLog.warn(
          "[statusbar] link_open_failed", fields: ["error": String(describing: error)],
          source: "core:StatusLinkOpener")
      } else {
        FlashLog.trace(
          "[statusbar] link_opened url=\(url.absoluteString) "
            + "app=\(app?.bundleIdentifier ?? "nil")")
      }
    }
  }
}

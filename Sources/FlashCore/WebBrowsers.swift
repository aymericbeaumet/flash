/// Desktop web browsers by bundle identifier: the one list every "is this a
/// browser?" decision reads (tab verbs, accessibility waking, and which web
/// areas hold arbitrary pages rather than an app's own UI).
public enum WebBrowsers {
  public static let safari: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
  ]

  public static let firefox: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
  ]

  public static let chromium: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext",
    "com.operasoftware.OperaDeveloper",
  ]

  public static let all = safari.union(firefox).union(chromium)

  public static func contains(_ bundleIdentifier: String?) -> Bool {
    bundleIdentifier.map { all.contains($0) } ?? false
  }
}

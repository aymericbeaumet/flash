import Foundation

/// Browser bundle-id constants the host still consults for behavioural
/// decisions ("is this a browser?" — e.g. force tab_last to ⌘9 instead of a
/// plugin source action). The actual tab discovery, resolution, and tab
/// actions now live in the per-browser plugins under `Plugins/{safari,
/// firefox, chromium}/`, which is why the rest of this file is gone.
enum BrowserTabSources {
  static let safariBundleIdentifiers: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
  ]

  static let firefoxBundleIdentifiers: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
  ]

  static let chromiumBundleIdentifiers: Set<String> = [
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

  static let allBundleIdentifiers =
    safariBundleIdentifiers.union(firefoxBundleIdentifiers).union(chromiumBundleIdentifiers)
}

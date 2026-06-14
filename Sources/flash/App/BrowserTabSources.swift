import AppKit
import ApplicationServices
import FlashCore
import Foundation

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

  /// Source-label convention: `<plugin>.<subsource>`. Tabs from
  /// firefox-dev still share the firefox plugin namespace — the
  /// `-dev` distinction lives in the bundle ID, not the source
  /// taxonomy. Bare-name browsers (`firefox`, `safari`, …) are still
  /// matchable via the existing `hasPrefix` rule, so `@firefox`
  /// continues to fold firefox.tabs / firefox.bookmarks / etc. when
  /// future cold sources land.
  static func sourceName(bundleID: String, appName: String) -> String {
    switch bundleID {
    case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
      return "firefox.tabs"
    case "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
      "com.google.Chrome.dev":
      return "chrome.tabs"
    case "org.chromium.Chromium":
      return "chromium.tabs"
    case "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly":
      return "brave.tabs"
    case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
      "com.microsoft.edgemac.Canary":
      return "edge.tabs"
    case "company.thebrowser.Browser":
      return "arc.tabs"
    case "com.vivaldi.Vivaldi":
      return "vivaldi.tabs"
    case "com.operasoftware.Opera", "com.operasoftware.OperaNext",
      "com.operasoftware.OperaDeveloper":
      return "opera.tabs"
    case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
      return "safari.tabs"
    default:
      return appName.lowercased().replacingOccurrences(of: " ", with: "-") + ".tabs"
    }
  }

  static func browserTabName(title: String, url: String?) -> String {
    let title = title.trimmed
    let url = url?.trimmed ?? ""
    if title.isEmpty { return url }
    return title
  }

  static func browserTabItem(
    sourceID: String,
    source: String,
    app: NSRunningApplication,
    title: String,
    url: String?,
    sourcePayload: String? = nil
  ) -> Candidate? {
    let name = browserTabName(title: title, url: url)
    guard !name.isEmpty else { return nil }
    return Candidate(
      kind: .plugin("browser_tab"),
      sourceID: sourceID,
      source: source,
      pid: app.processIdentifier,
      name: name,
      subtitle: "browser tab",
      bundleIdentifier: app.bundleIdentifier ?? "",
      url: url.flatMap(URL.init(string:)),
      sourcePayload: sourcePayload)
  }

  static func runningBrowserApps(
    in environment: FlashSourceEnvironment,
    bundleIdentifiers: Set<String>
  ) -> [NSRunningApplication] {
    environment.runningApplications.filter { app in
      app.activationPolicy == .regular
        && !app.isTerminated
        && bundleIdentifiers.contains(app.bundleIdentifier ?? "")
    }
  }

  static func scriptString(_ raw: String) -> String {
    "\""
      + raw
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }

  static func parseTabLines(_ raw: String) -> [(title: String, url: String)] {
    raw.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      let title = String(parts[0]).trimmed
      let url = String(parts[1]).trimmed
      guard !title.isEmpty || !url.isEmpty else { return nil }
      return (title: title.isEmpty ? url : title, url: url)
    }
  }

  static func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let descriptor = script.executeAndReturnError(&error)
    if let error {
      FlashLog.debug("[browser_tabs] applescript_error \(error)")
      return nil
    }
    return descriptor.stringValue
  }

  static func runAppleScriptAsync(
    _ source: String,
    completion: @escaping (String?) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let result = runAppleScript(source)
      DispatchQueue.main.async {
        completion(result?.trimmed)
      }
    }
  }

  static func resolveURLBackedTab(
    _ item: Candidate,
    appName: String?,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    guard let pid = item.pid, let app = NSRunningApplication(processIdentifier: pid) else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }

    RunningApplicationActivation.activate(app, options: [.activateAllWindows])
    let url = item.url?.absoluteString ?? item.sourcePayload ?? ""
    guard !url.isEmpty, let appName else {
      DispatchQueue.main.async { completion(.resolved(pid: pid)) }
      return
    }

    let script = """
      tell application \(scriptString(appName))
        activate
        set targetURL to \(scriptString(url))
        repeat with w in windows
          repeat with t in tabs of w
            try
              if (URL of t as text) is targetURL then
                set current tab of w to t
                set index of w to 1
                return "ok"
              end if
            end try
          end repeat
        end repeat
      end tell
      return "missing"
      """
    DispatchQueue.global(qos: .utility).async {
      _ = runAppleScript(script)
      DispatchQueue.main.async {
        completion(.resolved(pid: pid))
      }
    }
  }

  static func axTabCandidates(
    sourceID: String,
    in environment: FlashSourceEnvironment,
    bundleIdentifiers: Set<String>
  ) -> [Candidate] {
    var out: [Candidate] = []
    var seen = Set<String>()
    for app in runningBrowserApps(in: environment, bundleIdentifiers: bundleIdentifiers) {
      let appName = app.localizedName ?? "Browser"
      let sourceName = sourceName(bundleID: app.bundleIdentifier ?? "", appName: appName)
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      let windows = AXCandidateSourceHelpers.elementArrayAttribute(
        axApp, kAXWindowsAttribute as String)
      for window in windows {
        let windowTitle =
          AXCandidateSourceHelpers.stringAttribute(window, kAXTitleAttribute as String) ?? appName
        for tab in axTabElements(in: window) {
          guard let title = axTabTitle(tab, fallback: windowTitle) else { continue }
          let url = axTabURL(tab)
          let key = "\(app.processIdentifier)|\(windowTitle)|\(title)|\(url ?? "")"
          guard seen.insert(key).inserted else { continue }
          if let item = browserTabItem(
            sourceID: sourceID,
            source: sourceName,
            app: app,
            title: title,
            url: url,
            sourcePayload: url)
          {
            out.append(item)
          }
        }
      }
    }
    return out
  }

  static func axTabElements(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var seen = Set<UInt>()
    var queue = [root]
    var index = 0
    while index < queue.count, index < 3_000 {
      let element = queue[index]
      index += 1
      let role = AXCandidateSourceHelpers.stringAttribute(element, kAXRoleAttribute as String)
      let subrole = AXCandidateSourceHelpers.stringAttribute(element, kAXSubroleAttribute as String)
      let roleDescription =
        AXCandidateSourceHelpers.stringAttribute(element, "AXRoleDescription")?
        .lowercased() ?? ""
      let isTabButton =
        subrole == "AXTabButton"
        || roleDescription == "tab"
        || roleDescription.contains("tab button")
      if (role == "AXRadioButton" || role == "AXButton" || role == "AXTab") && isTabButton {
        if seen.insert(CFHash(element)).inserted {
          out.append(element)
        }
      } else if role == "AXTab" {
        if seen.insert(CFHash(element)).inserted {
          out.append(element)
        }
      }
      queue.append(
        contentsOf: AXCandidateSourceHelpers.elementArrayAttribute(
          element, kAXChildrenAttribute as String))
      queue.append(
        contentsOf: AXCandidateSourceHelpers.elementArrayAttribute(
          element, "AXChildrenInNavigationOrder"))
    }
    return out
  }

  static func axTabTitle(_ element: AXUIElement, fallback: String) -> String? {
    let raw =
      AXCandidateSourceHelpers.stringAttribute(element, kAXTitleAttribute as String)
      ?? AXCandidateSourceHelpers.stringAttribute(element, kAXDescriptionAttribute as String)
      ?? AXCandidateSourceHelpers.stringAttribute(element, kAXValueAttribute as String)
      ?? fallback
    let trimmed = raw.trimmed
    return trimmed.isEmpty ? nil : trimmed
  }

  static func axTabURL(_ element: AXUIElement) -> String? {
    let raw =
      AXCandidateSourceHelpers.urlAttribute(element, kAXURLAttribute as String)
      ?? AXCandidateSourceHelpers.urlAttribute(element, kAXDocumentAttribute as String)
    guard let raw else { return nil }
    let trimmed = raw.trimmed
    return trimmed.isEmpty ? nil : trimmed
  }

  static func scriptBackedItems(
    sourceID: String,
    in environment: FlashSourceEnvironment,
    bundleIdentifiers: Set<String>,
    scriptBuilder: (String) -> String
  ) -> [Candidate] {
    var out: [Candidate] = []
    var seen = Set<String>()
    for app in runningBrowserApps(in: environment, bundleIdentifiers: bundleIdentifiers) {
      let appName = app.localizedName ?? "Browser"
      let sourceName = sourceName(bundleID: app.bundleIdentifier ?? "", appName: appName)
      guard let raw = runAppleScript(scriptBuilder(appName)) else { continue }
      for tab in parseTabLines(raw) {
        let key = "\(app.processIdentifier)|\(tab.url)|\(tab.title)"
        guard seen.insert(key).inserted else { continue }
        if let item = browserTabItem(
          sourceID: sourceID,
          source: sourceName,
          app: app,
          title: tab.title,
          url: tab.url,
          sourcePayload: tab.url)
        {
          out.append(item)
        }
      }
    }
    return out
  }

  static func appName(for item: Candidate, environment: FlashSourceEnvironment) -> String? {
    guard let pid = item.pid else { return nil }
    return appName(for: pid, environment: environment)
  }

  static func appName(for pid: pid_t, environment: FlashSourceEnvironment) -> String? {
    environment.runningApplications.first { $0.processIdentifier == pid }?.localizedName
  }
}

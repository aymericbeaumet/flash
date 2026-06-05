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

  static func sourceName(bundleID: String, appName: String) -> String {
    switch bundleID {
    case "org.mozilla.firefox":
      return "firefox"
    case "org.mozilla.firefoxdeveloperedition":
      return "firefox-dev"
    case "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
      "com.google.Chrome.dev":
      return "chrome"
    case "org.chromium.Chromium":
      return "chromium"
    case "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly":
      return "brave"
    case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
      "com.microsoft.edgemac.Canary":
      return "edge"
    case "company.thebrowser.Browser":
      return "arc"
    case "com.vivaldi.Vivaldi":
      return "vivaldi"
    case "com.operasoftware.Opera", "com.operasoftware.OperaNext",
      "com.operasoftware.OperaDeveloper":
      return "opera"
    case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
      return "safari"
    default:
      return appName.lowercased().replacingOccurrences(of: " ", with: "-")
    }
  }

  static func browserTabName(title: String, url: String?) -> String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if title.isEmpty { return url }
    return title
  }

  static func browserTabItem(
    sourceID: String,
    source: String,
    app: NSRunningApplication,
    title: String,
    url: String?,
    targetElement: AXUIElement? = nil,
    sourcePayload: String? = nil
  ) -> Candidate? {
    let name = browserTabName(title: title, url: url)
    guard !name.isEmpty else { return nil }
    return Candidate(
      kind: .browserTab,
      sourceID: sourceID,
      source: source,
      pid: app.processIdentifier,
      title: name,
      subtitle: "browser tab",
      bundleIdentifier: app.bundleIdentifier ?? "",
      url: url.flatMap(URL.init(string:)),
      tmuxClientTTY: nil,
      tmuxTarget: nil,
      targetElement: targetElement,
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
      let title = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let url = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        completion(result?.trimmingCharacters(in: .whitespacesAndNewlines))
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

    app.activate(options: [.activateAllWindows])
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
            targetElement: tab,
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
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func axTabURL(_ element: AXUIElement) -> String? {
    let raw =
      AXCandidateSourceHelpers.urlAttribute(element, kAXURLAttribute as String)
      ?? AXCandidateSourceHelpers.urlAttribute(element, kAXDocumentAttribute as String)
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

final class FirefoxTabsSource: FlashSource {
  let identifier = "firefox-tabs"
  let displayName = "firefox"
  let priority = 30
  let capabilities: FlashSourceCapabilities = [.candidates, .tabSelection]
  let activationPolicy: FlashSourceActivationPolicy = .bundleIDs(
    BrowserTabSources.firefoxBundleIdentifiers)

  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func supports(_ context: AppContext) -> Bool {
    BrowserTabSources.firefoxBundleIdentifiers.contains(context.bundleIdentifier)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    BrowserTabSources.axTabCandidates(
      sourceID: identifier,
      in: environment,
      bundleIdentifiers: BrowserTabSources.firefoxBundleIdentifiers)
  }

  func resolveCandidate(
    _ item: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    AXCandidateSourceHelpers.resolveAXItem(item, completion: completion)
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard index > 0 else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let app = AXUIElementCreateApplication(context.processID)
    let windows = AXCandidateSourceHelpers.elementArrayAttribute(
      app, kAXWindowsAttribute as String)
    for window in windows {
      let tabs = BrowserTabSources.axTabElements(in: window)
      guard index <= tabs.count else { continue }
      if let runningApp = NSRunningApplication(processIdentifier: context.processID) {
        runningApp.activate(options: [.activateAllWindows])
      }
      AXCandidateSourceHelpers.resolveAXItem(
        Candidate(
          kind: .browserTab,
          sourceID: identifier,
          source: displayName,
          pid: context.processID,
          title: "tab \(index)",
          subtitle: "browser tab",
          bundleIdentifier: context.bundleIdentifier,
          url: nil,
          tmuxClientTTY: nil,
          tmuxTarget: nil,
          targetElement: tabs[index - 1])
      ) { result in
        completion(result.didResolve ? .performed(pid: result.targetPID) : .unhandled)
      }
      return
    }
    DispatchQueue.main.async { completion(.unhandled) }
  }

}

final class SafariTabsSource: FlashSource {
  let identifier = "safari-tabs"
  let displayName = "safari"
  let priority = 30
  let capabilities: FlashSourceCapabilities = [.candidates, .tabSelection, .tabCreation]
  let activationPolicy: FlashSourceActivationPolicy = .bundleIDs(
    BrowserTabSources.safariBundleIdentifiers)

  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func supports(_ context: AppContext) -> Bool {
    BrowserTabSources.safariBundleIdentifiers.contains(context.bundleIdentifier)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    let scriptItems = scriptBackedItems(
      sourceID: identifier,
      in: environment,
      bundleIdentifiers: BrowserTabSources.safariBundleIdentifiers,
      scriptBuilder: safariTabsScript(appName:))
    if !scriptItems.isEmpty { return scriptItems }
    return BrowserTabSources.axTabCandidates(
      sourceID: identifier,
      in: environment,
      bundleIdentifiers: BrowserTabSources.safariBundleIdentifiers)
  }

  func resolveCandidate(
    _ item: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    BrowserTabSources.resolveURLBackedTab(
      item,
      appName: appName(for: item, environment: environment),
      completion: completion)
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = appName(for: context.processID, environment: environment), index > 0 else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let script = """
      tell application \(BrowserTabSources.scriptString(appName))
        activate
        set tabIndex to \(index)
        repeat with w in windows
          if (count of tabs of w) >= tabIndex then
            set current tab of w to tab tabIndex of w
            set index of w to 1
            return "ok"
          end if
          set tabIndex to tabIndex - (count of tabs of w)
        end repeat
      end tell
      return "missing"
      """
    BrowserTabSources.runAppleScriptAsync(script) { result in
      completion(result == "ok" ? .performed(pid: context.processID) : .unhandled)
    }
  }

  func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = appName(for: context.processID, environment: environment) else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let script = """
      tell application \(BrowserTabSources.scriptString(appName))
        activate
        if (count of windows) is 0 then
          make new document
        else
          tell front window
            set current tab to (make new tab)
          end tell
        end if
        return "ok"
      end tell
      """
    BrowserTabSources.runAppleScriptAsync(script) { result in
      completion(result == "ok" ? .performed(pid: context.processID) : .unhandled)
    }
  }

  private func safariTabsScript(appName: String) -> String {
    """
    set out to ""
    tell application \(BrowserTabSources.scriptString(appName))
      repeat with w in windows
        repeat with t in tabs of w
          try
            set out to out & (name of t as text) & tab & (URL of t as text) & linefeed
          end try
        end repeat
      end repeat
    end tell
    return out
    """
  }
}

final class ChromiumTabsSource: FlashSource {
  let identifier = "chromium-tabs"
  let displayName = "chrome"
  let priority = 30
  let capabilities: FlashSourceCapabilities = [.candidates, .tabSelection, .tabCreation]
  let activationPolicy: FlashSourceActivationPolicy = .bundleIDs(
    BrowserTabSources.chromiumBundleIdentifiers)

  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func supports(_ context: AppContext) -> Bool {
    BrowserTabSources.chromiumBundleIdentifiers.contains(context.bundleIdentifier)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    scriptBackedItems(
      sourceID: identifier,
      in: environment,
      bundleIdentifiers: BrowserTabSources.chromiumBundleIdentifiers,
      scriptBuilder: chromiumTabsScript(appName:))
  }

  func resolveCandidate(
    _ item: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    BrowserTabSources.resolveURLBackedTab(
      item,
      appName: appName(for: item, environment: environment),
      completion: completion)
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = appName(for: context.processID, environment: environment), index > 0 else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let script = """
      tell application \(BrowserTabSources.scriptString(appName))
        activate
        set tabIndex to \(index)
        repeat with w in windows
          if (count of tabs of w) >= tabIndex then
            set active tab index of w to tabIndex
            set index of w to 1
            return "ok"
          end if
          set tabIndex to tabIndex - (count of tabs of w)
        end repeat
      end tell
      return "missing"
      """
    BrowserTabSources.runAppleScriptAsync(script) { result in
      completion(result == "ok" ? .performed(pid: context.processID) : .unhandled)
    }
  }

  func tabNew(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = appName(for: context.processID, environment: environment) else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let script = """
      tell application \(BrowserTabSources.scriptString(appName))
        activate
        if (count of windows) is 0 then
          make new window
        else
          tell front window to make new tab
        end if
        return "ok"
      end tell
      """
    BrowserTabSources.runAppleScriptAsync(script) { result in
      completion(result == "ok" ? .performed(pid: context.processID) : .unhandled)
    }
  }

  private func chromiumTabsScript(appName: String) -> String {
    """
    set out to ""
    tell application \(BrowserTabSources.scriptString(appName))
      repeat with w in windows
        repeat with t in tabs of w
          try
            set out to out & (title of t as text) & tab & (URL of t as text) & linefeed
          end try
        end repeat
      end repeat
    end tell
    return out
    """
  }
}

private func scriptBackedItems(
  sourceID: String,
  in environment: FlashSourceEnvironment,
  bundleIdentifiers: Set<String>,
  scriptBuilder: (String) -> String
) -> [Candidate] {
  var out: [Candidate] = []
  var seen = Set<String>()
  for app in BrowserTabSources.runningBrowserApps(
    in: environment,
    bundleIdentifiers: bundleIdentifiers)
  {
    let appName = app.localizedName ?? "Browser"
    let sourceName = BrowserTabSources.sourceName(
      bundleID: app.bundleIdentifier ?? "",
      appName: appName)
    guard let raw = BrowserTabSources.runAppleScript(scriptBuilder(appName)) else { continue }
    for tab in BrowserTabSources.parseTabLines(raw) {
      let key = "\(app.processIdentifier)|\(tab.url)|\(tab.title)"
      guard seen.insert(key).inserted else { continue }
      if let item = BrowserTabSources.browserTabItem(
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

private func appName(for item: Candidate, environment: FlashSourceEnvironment) -> String? {
  guard let pid = item.pid else { return nil }
  return appName(for: pid, environment: environment)
}

private func appName(for pid: pid_t, environment: FlashSourceEnvironment) -> String? {
  environment.runningApplications.first { $0.processIdentifier == pid }?.localizedName
}

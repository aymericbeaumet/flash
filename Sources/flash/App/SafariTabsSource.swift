import AppKit
import FlashCore
import Foundation

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
    let scriptItems = BrowserTabSources.scriptBackedItems(
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
      appName: BrowserTabSources.appName(for: item, environment: environment),
      completion: completion)
  }

  func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = BrowserTabSources.appName(for: context.processID, environment: environment),
      index > 0
    else {
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
    guard let appName = BrowserTabSources.appName(for: context.processID, environment: environment)
    else {
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

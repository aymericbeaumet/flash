import AppKit
import FlashCore
import Foundation

final class SafariTabsSource: FlashSource {
  let identifier = "safari-tabs"
  let displayName = "safari"
  let priority = 30
  let capabilities: FlashSourceCapabilities = [
    .candidates, .tabSelection, .tabCreation, .tabClosing,
  ]
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
      // App matched (the activationPolicy already gated us to Safari)
      // and the script ran — a non-"ok" result is the source's claim
      // failing, not an unrelated context. Return `.failed` so the
      // host doesn't keystroke-fall-back on top of it.
      completion(result == "ok" ? .performed(pid: context.processID) : .failed)
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
      completion(result == "ok" ? .performed(pid: context.processID) : .failed)
    }
  }

  func tabClose(
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard let appName = BrowserTabSources.appName(for: context.processID, environment: environment)
    else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    // Closing the last tab via `close current tab` collapses to closing
    // the window — same as the user pressing ⌘W natively, which is what
    // we want: the gesture stays "close this thing in this context".
    let script = """
      tell application \(BrowserTabSources.scriptString(appName))
        if (count of windows) is 0 then return "missing"
        tell front window to close current tab
        return "ok"
      end tell
      """
    BrowserTabSources.runAppleScriptAsync(script) { result in
      completion(result == "ok" ? .performed(pid: context.processID) : .failed)
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

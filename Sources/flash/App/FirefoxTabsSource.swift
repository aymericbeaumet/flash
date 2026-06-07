import AppKit
import ApplicationServices
import FlashCore
import Foundation

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
        RunningApplicationActivation.activate(runningApp, options: [.activateAllWindows])
      }
      AXCandidateSourceHelpers.resolveAXItem(
        Candidate(
          kind: .browserTab,
          sourceID: identifier,
          source: displayName,
          pid: context.processID,
          name: "tab \(index)",
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

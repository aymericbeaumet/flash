import AppKit
import FlashCore
import Foundation

final class FirefoxTabsSource: FlashSource {
  let identifier = "firefox-tabs"
  let displayName = "firefox"
  let priority = 30
  let candidateSourceLabels = ["firefox.tabs"]
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
    BrowserTabSources.resolveAXBackedTab(
      item,
      in: environment,
      bundleIdentifiers: BrowserTabSources.firefoxBundleIdentifiers,
      completion: completion)
  }

  func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    switch action {
    case .tabSelect(let index):
      BrowserTabSources.performAXTabSelect(
        index: index,
        in: context,
        environment: environment,
        bundleIdentifiers: BrowserTabSources.firefoxBundleIdentifiers,
        completion: completion)
    default:
      DispatchQueue.main.async { completion(.unhandled) }
    }
  }
}

import AppKit
import FlashCore
import XCTest

@testable import flash

final class SourceRegistryTests: XCTestCase {
  func testRefreshOnlyInstantiatesSourcesWhoseActivationPolicyMatches() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    var alwaysCreated = 0
    var matchedCreated = 0
    var unmatchedCreated = 0

    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "always", activationPolicy: .always) {
          alwaysCreated += 1
          return StubSource(identifier: "always")
        },
        SourceDescriptor(identifier: "matched", activationPolicy: .bundleIDs([bundleID])) {
          matchedCreated += 1
          return StubSource(identifier: "matched")
        },
        SourceDescriptor(
          identifier: "unmatched",
          activationPolicy: .bundleIDs(["invalid.bundle"])
        ) {
          unmatchedCreated += 1
          return StubSource(identifier: "unmatched")
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [app])

    XCTAssertNotNil(registry.source(identifier: "always"))
    XCTAssertNotNil(registry.source(identifier: "matched"))
    XCTAssertNil(registry.source(identifier: "unmatched"))
    XCTAssertEqual(alwaysCreated, 1)
    XCTAssertEqual(matchedCreated, 1)
    XCTAssertEqual(unmatchedCreated, 0)
  }

  func testCandidatesOnlyQueriesActiveSources() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    var activeOpenCalls = 0
    var inactiveOpenCalls = 0

    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "active", activationPolicy: .bundleIDs([bundleID])) {
          StubSource(identifier: "active", capabilities: [.candidates]) { scope in
            activeOpenCalls += 1
            return [
              Candidate(
                kind: .app,
                sourceID: "active",
                source: "active",
                pid: nil,
                name: "\(scope)",
                subtitle: "source",
                bundleIdentifier: "",
                url: nil)
            ]
          }
        },
        SourceDescriptor(
          identifier: "inactive",
          activationPolicy: .bundleIDs(["invalid.bundle"])
        ) {
          StubSource(identifier: "inactive", capabilities: [.candidates]) { _ in
            inactiveOpenCalls += 1
            return []
          }
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [app])

    let items = registry.candidates(scope: .running)

    XCTAssertEqual(items.map(\.sourceID), ["active"])
    XCTAssertEqual(activeOpenCalls, 1)
    XCTAssertEqual(inactiveOpenCalls, 0)
  }

  func testCandidatesRefreshRunningApplicationsBeforeQueryingSources() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    var candidateCalls = 0

    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "dynamic", activationPolicy: .bundleIDs([bundleID])) {
          StubSource(identifier: "dynamic", capabilities: [.candidates]) { _ in
            candidateCalls += 1
            return [
              Candidate(
                kind: .app,
                sourceID: "dynamic",
                source: "dynamic",
                pid: app.processIdentifier,
                name: "Dynamic",
                subtitle: "source",
                bundleIdentifier: bundleID,
                url: nil)
            ]
          }
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      runningApplicationsProvider: { [app] })

    XCTAssertNil(registry.source(identifier: "dynamic"))

    let items = registry.candidates(scope: .running)

    XCTAssertEqual(items.map(\.sourceID), ["dynamic"])
    XCTAssertEqual(candidateCalls, 1)
  }

  // Regression: app_open?name=<app> used to type a text-insertion candidate
  // into the focused field when a higher-priority plugin substring-matched
  // the name (originally a copied "…slack.com…" clipboard URL; emoji is the
  // remaining insert-text kind). app_open must resolve the real app first.
  func testCandidateMatchingPrefersAppSourceOverHigherPriorityInsertTextShadow() {
    let slackApp = Candidate(
      kind: .app, sourceID: "core.apps", source: "core.apps", pid: nil,
      name: "Slack", subtitle: "app",
      bundleIdentifier: "com.tinyspeck.slackmacgap", url: nil)
    let emojiShadow = Candidate(
      kind: CandidateFinder.emojiKind, sourceID: "plugin:emojis",
      source: "emoji", pid: nil,
      name: "slack key cap",
      subtitle: "emoji", bundleIdentifier: "", url: nil)

    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(
            identifier: "core.apps", priority: 0, capabilities: [.appActivation],
            matchHandler: { target in
              "Slack".localizedCaseInsensitiveContains(target) ? slackApp : nil
            })
        },
        SourceDescriptor(identifier: "plugin:emojis", activationPolicy: .always) {
          StubSource(
            identifier: "plugin:emojis", priority: 100, capabilities: [.appActivation],
            matchHandler: { target in
              emojiShadow.name.localizedCaseInsensitiveContains(target) ? emojiShadow : nil
            })
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [])

    let match = registry.candidate(matching: "Slack")

    XCTAssertEqual(match?.sourceID, "core.apps")
    XCTAssertEqual(match?.kind, .app)
    XCTAssertFalse(match.map(CandidateFinder.insertsText) ?? true)
  }

  // app_open falls back to plugin sources for non-app names (e.g. a tmux
  // window), but a text-insertion candidate is never an activation target —
  // even when it is the only substring match, the resolver returns nil rather
  // than typing it.
  func testCandidateMatchingSkipsInsertTextAndFallsBackToActivatablePlugin() {
    let tmuxWindow = Candidate(
      kind: .plugin("tmux"), sourceID: "plugin:tmux", source: "tmux", pid: 42,
      name: "editor", subtitle: "tmux", bundleIdentifier: "", url: nil)
    let emojiEntry = Candidate(
      kind: CandidateFinder.emojiKind, sourceID: "plugin:emojis",
      source: "emoji", pid: nil, name: "editor pencil", subtitle: "emoji",
      bundleIdentifier: "", url: nil)

    func makeRegistry(includeActivatablePlugin: Bool) -> SourceRegistry {
      var descriptors: [SourceDescriptor] = [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(identifier: "core.apps", priority: 0, capabilities: [.appActivation])
        },
        SourceDescriptor(identifier: "plugin:emojis", activationPolicy: .always) {
          StubSource(
            identifier: "plugin:emojis", priority: 100, capabilities: [.appActivation],
            matchHandler: { target in
              emojiEntry.name.localizedCaseInsensitiveContains(target) ? emojiEntry : nil
            })
        },
      ]
      if includeActivatablePlugin {
        descriptors.append(
          SourceDescriptor(identifier: "plugin:tmux", activationPolicy: .always) {
            StubSource(
              identifier: "plugin:tmux", priority: 50, capabilities: [.appActivation],
              matchHandler: { target in
                tmuxWindow.name.localizedCaseInsensitiveContains(target) ? tmuxWindow : nil
              })
          })
      }
      return SourceRegistry(
        descriptors: descriptors, terminalBundleIDs: [], runningApplications: [])
    }

    // Only the emoji (insert-text) candidate matches → nil, never typed text.
    XCTAssertNil(makeRegistry(includeActivatablePlugin: false).candidate(matching: "editor"))

    // An activatable plugin candidate is still reachable as a fallback.
    let match = makeRegistry(includeActivatablePlugin: true).candidate(matching: "editor")
    XCTAssertEqual(match?.sourceID, "plugin:tmux")
    XCTAssertFalse(match.map(CandidateFinder.insertsText) ?? true)
  }
}

private final class StubSource: FlashSource {
  let identifier: String
  let priority: Int
  let capabilities: FlashSourceCapabilities
  private let candidatesHandler: (CandidateScope) -> [Candidate]
  private let matchHandler: (String) -> Candidate?

  init(
    identifier: String,
    priority: Int = 0,
    capabilities: FlashSourceCapabilities = [],
    candidatesHandler: @escaping (CandidateScope) -> [Candidate] = { _ in [] },
    matchHandler: @escaping (String) -> Candidate? = { _ in nil }
  ) {
    self.identifier = identifier
    self.priority = priority
    self.capabilities = capabilities
    self.candidatesHandler = candidatesHandler
    self.matchHandler = matchHandler
  }

  func supports(_ context: AppContext) -> Bool { false }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    []
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    candidatesHandler(scope)
  }

  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    matchHandler(target)
  }
}

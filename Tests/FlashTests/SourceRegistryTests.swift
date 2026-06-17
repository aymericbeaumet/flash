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
                title: "\(scope)",
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
                title: "Dynamic",
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

  func testCoreAppCandidatesOnlyQueryCoreAppSource() {
    var appCalls = 0
    var pluginCalls = 0
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(identifier: "core.apps", capabilities: [.candidates]) { _ in
            appCalls += 1
            return [
              Candidate(
                kind: .app, sourceID: "core.apps", source: "core.apps",
                pid: nil, title: "Finder", subtitle: "app",
                bundleIdentifier: "com.apple.finder", url: nil)
            ]
          }
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: {
        [
          StubSource(identifier: "plugin:tabs", capabilities: [.candidates]) { _ in
            pluginCalls += 1
            return [
              Candidate(
                kind: .plugin("browser_tab"), sourceID: "plugin:tabs",
                source: "tabs", pid: nil, title: "Tab", subtitle: "tab",
                bundleIdentifier: "", url: nil)
            ]
          }
        ]
      })

    let items = registry.coreAppCandidates(scope: .all)

    XCTAssertEqual(items.map(\.sourceID), ["core.apps"])
    XCTAssertEqual(appCalls, 1)
    XCTAssertEqual(pluginCalls, 0)
  }

  func testCandidatesGatherAllSourceSnapshotsWithoutQuerying() {
    var queryCalls = 0
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(
            identifier: "core.apps",
            capabilities: [.candidates],
            candidatesHandler: { _ in
              [
                Candidate(
                  kind: .app, sourceID: "core.apps", source: "core.apps",
                  pid: nil, title: "Finder", subtitle: "app",
                  bundleIdentifier: "com.apple.finder", url: nil)
              ]
            },
            queryHandler: { _, done in
              queryCalls += 1
              done([])
            })
        },
        SourceDescriptor(identifier: "native.tabs", activationPolicy: .always) {
          StubSource(
            identifier: "native.tabs",
            capabilities: [.candidates],
            candidatesHandler: { _ in
              [
                Candidate(
                  kind: CandidateFinder.browserTabKind,
                  sourceID: "native.tabs",
                  source: "tabs",
                  pid: nil, title: "Native Tab", subtitle: "tab",
                  bundleIdentifier: "", url: nil)
              ]
            },
            queryHandler: { _, done in
              queryCalls += 1
              done([])
            })
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: {
        [
          StubSource(
            identifier: "plugin:emojis",
            capabilities: [.candidates],
            candidatesHandler: { _ in
              [
                Candidate(
                  kind: CandidateFinder.emojiKind,
                  sourceID: "plugin:emojis",
                  source: "emoji",
                  pid: nil,
                  title: "sparkles",
                  subtitle: "emoji",
                  bundleIdentifier: "",
                  url: nil)
              ]
            },
            queryHandler: { _, done in
              queryCalls += 1
              done([])
            })
        ]
      })

    let ids = registry.candidates(scope: .all).map(\.sourceID).sorted()
    XCTAssertEqual(ids, ["core.apps", "native.tabs", "plugin:emojis"])
    XCTAssertEqual(queryCalls, 0)
  }

  func testRegisteredCandidateSourceLabelsUseDeclarations() {
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(
            identifier: "core.apps",
            capabilities: [.candidates],
            candidateSourceLabels: ["apps"])
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: {
        [
          StubSource(
            identifier: "plugin:firefox",
            capabilities: [.candidates],
            candidateSourceLabels: ["firefox.tabs"])
        ]
      })

    XCTAssertEqual(registry.registeredCandidateSourceLabels(), ["apps", "firefox.tabs"])
  }

  func testPluginSubsourceIdentifierRoutesToOwningPluginSource() {
    let plugin = StubSource(identifier: "plugin:slack", capabilities: [.candidates])
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [plugin] })

    XCTAssertTrue(registry.source(identifier: "plugin:slack.channels") === plugin)
  }

  func testRestoreNavigationRoutesByRegisteredSchemeInPriorityOrder() {
    let url = URL(string: "tmux://window/scratch:2")!
    let expectation = expectation(description: "restore")
    var lowCalls = 0
    var highCalls = 0
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "low", activationPolicy: .always) {
          StubSource(
            identifier: "low",
            priority: 10,
            capabilities: [.navigationRoutes],
            navigationSchemes: ["tmux"],
            restoreHandler: { _ in
              lowCalls += 1
              return .performed(pid: 12)
            })
        },
        SourceDescriptor(identifier: "high", activationPolicy: .always) {
          StubSource(
            identifier: "high",
            priority: 20,
            capabilities: [.navigationRoutes],
            navigationSchemes: ["tmux"],
            restoreHandler: { restoredURL in
              highCalls += 1
              XCTAssertEqual(restoredURL, url)
              return .unhandled
            })
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [])

    XCTAssertTrue(registry.canRestoreNavigation(to: url))
    registry.restoreNavigation(to: url) { result in
      XCTAssertEqual(result.disposition, .performed)
      XCTAssertEqual(result.targetPID, 12)
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(highCalls, 1)
    XCTAssertEqual(lowCalls, 1)
  }

  // Regression: app_open?name=<app> used to type a text-insertion candidate
  // into the focused field when a higher-priority plugin substring-matched
  // the name (originally a copied "…slack.com…" clipboard URL; emoji is the
  // remaining insert-text kind). app_open must resolve the real app first.
  func testCandidateMatchingPrefersAppSourceOverHigherPriorityInsertTextShadow() {
    let slackApp = Candidate(
      kind: .app, sourceID: "core.apps", source: "core.apps", pid: nil,
      title: "Slack", subtitle: "app",
      bundleIdentifier: "com.tinyspeck.slackmacgap", url: nil)
    let emojiShadow = Candidate(
      kind: CandidateFinder.emojiKind, sourceID: "plugin:emojis",
      source: "emoji", pid: nil,
      title: "slack key cap",
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
              emojiShadow.title.localizedCaseInsensitiveContains(target) ? emojiShadow : nil
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
      title: "editor", subtitle: "tmux", bundleIdentifier: "", url: nil)
    let emojiEntry = Candidate(
      kind: CandidateFinder.emojiKind, sourceID: "plugin:emojis",
      source: "emoji", pid: nil, title: "editor pencil", subtitle: "emoji",
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
              emojiEntry.title.localizedCaseInsensitiveContains(target) ? emojiEntry : nil
            })
        },
      ]
      if includeActivatablePlugin {
        descriptors.append(
          SourceDescriptor(identifier: "plugin:tmux", activationPolicy: .always) {
            StubSource(
              identifier: "plugin:tmux", priority: 50, capabilities: [.appActivation],
              matchHandler: { target in
                tmuxWindow.title.localizedCaseInsensitiveContains(target) ? tmuxWindow : nil
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
  private let queryHandler: (CandidateQuery, @escaping ([Candidate]) -> Void) -> Void
  private let matchHandler: (String) -> Candidate?
  let navigationSchemes: Set<String>
  private let restoreHandler: (URL) -> SourceActionResult
  let candidateSourceLabels: [String]

  init(
    identifier: String,
    priority: Int = 0,
    capabilities: FlashSourceCapabilities = [],
    candidateSourceLabels: [String] = [],
    navigationSchemes: Set<String> = [],
    candidatesHandler: @escaping (CandidateScope) -> [Candidate] = { _ in [] },
    queryHandler: ((CandidateQuery, @escaping ([Candidate]) -> Void) -> Void)? = nil,
    matchHandler: @escaping (String) -> Candidate? = { _ in nil },
    restoreHandler: @escaping (URL) -> SourceActionResult = { _ in .unhandled }
  ) {
    self.identifier = identifier
    self.priority = priority
    self.capabilities = capabilities
    self.candidateSourceLabels = candidateSourceLabels
    self.navigationSchemes = navigationSchemes
    self.candidatesHandler = candidatesHandler
    self.queryHandler =
      queryHandler ?? { request, done in
        done(candidatesHandler(request.scope))
      }
    self.matchHandler = matchHandler
    self.restoreHandler = restoreHandler
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

  func queryCandidates(
    in environment: FlashSourceEnvironment,
    request: CandidateQuery,
    completion: @escaping ([Candidate]) -> Void
  ) {
    queryHandler(request, completion)
  }

  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    matchHandler(target)
  }

  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    completion(restoreHandler(url))
  }
}

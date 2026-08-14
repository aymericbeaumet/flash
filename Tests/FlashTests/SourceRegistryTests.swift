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

    let items = registry.synchronousCandidates(scope: .running)

    XCTAssertEqual(items.map(\.sourceID), ["active"])
    XCTAssertEqual(activeOpenCalls, 1)
    XCTAssertEqual(inactiveOpenCalls, 0)
  }

  func testCandidateHotPathUsesWorkspaceMaintainedRunningApplicationsSnapshot() throws {
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

    let coldItems = registry.synchronousCandidates(scope: .running)
    XCTAssertTrue(coldItems.isEmpty)
    XCTAssertEqual(candidateCalls, 0)

    registry.refreshRunningApplications()
    let refreshedItems = registry.synchronousCandidates(scope: .running)

    XCTAssertEqual(refreshedItems.map(\.sourceID), ["dynamic"])
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

  func testCandidatesGatherAllSynchronousSourcesWithoutPullingSnapshots() {
    var snapshotCalls = 0
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
            snapshotHandler: { done in
              snapshotCalls += 1
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
            snapshotHandler: { done in
              snapshotCalls += 1
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
            snapshotHandler: { done in
              snapshotCalls += 1
              done([])
            })
        ]
      })

    let ids = registry.synchronousCandidates(scope: .all).map(\.sourceID).sorted()
    XCTAssertEqual(ids, ["core.apps", "native.tabs"])
    XCTAssertEqual(snapshotCalls, 0)
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

  func testRegisteredCandidateSourceDescriptorsUseDeclarations() {
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(
            identifier: "core.apps",
            capabilities: [.candidates],
            candidateSourceDescriptors: [
              CandidateSourceDescriptor(name: "core.apps", kind: .locations)
            ])
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: {
        [
          StubSource(
            identifier: "plugin:tmux",
            capabilities: [.candidates],
            candidateSourceDescriptors: [
              CandidateSourceDescriptor(name: "tmux.windows", kind: .locations)
            ])
        ]
      })

    XCTAssertEqual(
      registry.registeredCandidateSourceDescriptors(),
      [
        CandidateSourceDescriptor(name: "core.apps", kind: .locations),
        CandidateSourceDescriptor(name: "tmux.windows", kind: .locations),
      ])
  }

  func testHintProviderPlanPreparesAXFallbackBehindDynamicVolatileProvider() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let context = AppContext(
      bundleIdentifier: bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: .zero,
      allScreensFrame: .zero)
    let tmux = StubSource(
      identifier: "plugin:tmux",
      priority: 20,
      capabilities: [.jumpTargets],
      readinessPolicy: .volatile,
      fallsBackOnEmptyDiscovery: true,
      supportsHandler: { _ in true })
    let accessibility = StubSource(
      identifier: "accessibility",
      priority: 10,
      capabilities: [.jumpTargets],
      readinessPolicy: .continuous,
      supportsHandler: { _ in true })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [app],
      pluginSourcesProvider: { [tmux, accessibility] })

    let plan = registry.hintProviderPlan(for: context)

    XCTAssertEqual(plan.activationProviders.map(\.identifier), ["plugin:tmux", "accessibility"])
    XCTAssertEqual(plan.uncachedProviders.map(\.identifier), ["plugin:tmux"])
    XCTAssertEqual(plan.preparedProviders.map(\.identifier), ["accessibility"])
  }

  func testHintDiscoveryFallsBackAfterExplicitEmptyAndStopsAtFirstTargets() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let context = AppContext(
      bundleIdentifier: bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: .zero,
      allScreensFrame: .zero)
    var tmuxCalls = 0
    var accessibilityCalls = 0
    let tmux = StubSource(
      identifier: "plugin:tmux",
      priority: 20,
      capabilities: [.jumpTargets],
      readinessPolicy: .volatile,
      fallsBackOnEmptyDiscovery: true,
      supportsHandler: { _ in true },
      discoverHandler: { _ in
        tmuxCalls += 1
        return []
      })
    let accessibility = StubSource(
      identifier: "accessibility",
      priority: 10,
      capabilities: [.jumpTargets],
      readinessPolicy: .continuous,
      supportsHandler: { _ in true },
      discoverHandler: { context in
        accessibilityCalls += 1
        return [
          JumpTarget(
            id: "button",
            frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            pid: context.processID,
            providerID: "accessibility")
        ]
      })

    let collection = AppMonitor.collectFocusedTargets(
      context: context,
      providers: [tmux, accessibility])

    XCTAssertEqual(tmuxCalls, 1)
    XCTAssertEqual(accessibilityCalls, 1)
    XCTAssertEqual(
      collection.attemptedProviders.map(\.identifier), ["plugin:tmux", "accessibility"])
    XCTAssertEqual(collection.targets.map(\.target.id), ["button"])
    XCTAssertFalse(collection.allowsFallback)
  }

  func testCurrentLocationPrefersCurrentLocationCandidateForFocusedPID() throws {
    let resolved = expectation(description: "current plugin location")
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let context = AppContext(
      bundleIdentifier: bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: .zero,
      allScreensFrame: .zero)
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [app],
      pluginSourcesProvider: {
        [
          StubSource(
            identifier: "plugin:locations",
            capabilities: [.candidates],
            candidateSourceDescriptors: [
              CandidateSourceDescriptor(name: "locations.items", kind: .locations)
            ],
            candidatesHandler: { _ in
              [
                Candidate(
                  kind: .plugin("item"),
                  sourceID: "plugin:locations",
                  source: "locations.items",
                  pid: app.processIdentifier,
                  title: "Background",
                  isLocation: true),
                Candidate(
                  kind: .plugin("item"),
                  sourceID: "plugin:locations",
                  source: "locations.items",
                  pid: app.processIdentifier,
                  title: "Current",
                  isLocation: true,
                  isCurrentLocation: true),
              ]
            })
        ]
      })

    registry.snapshotCandidates(scope: .all) { candidates in
      XCTAssertEqual(
        registry.currentLocation(in: context, candidates: candidates)?.title,
        "Current")
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 1)
  }

  func testCurrentLocationFallsBackToFocusedAppCandidate() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let context = AppContext(
      bundleIdentifier: bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: .zero,
      allScreensFrame: .zero)
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          ApplicationSource()
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [app])

    let current = registry.currentLocation(
      in: context,
      candidates: registry.synchronousCandidates(scope: .all))

    XCTAssertEqual(current?.kind, .app)
    XCTAssertEqual(current?.pid, app.processIdentifier)
  }

  func testCurrentLocationSkipsDocumentURLForUnambiguousAppCandidate() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let context = AppContext(
      bundleIdentifier: bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: .zero,
      allScreensFrame: .zero)
    var documentURLCalls = 0
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          ApplicationSource()
        },
        SourceDescriptor(identifier: "document", activationPolicy: .always) {
          StubSource(
            identifier: "document",
            capabilities: [.jumpTargets, .documentURL],
            supportsHandler: { $0.processID == app.processIdentifier },
            documentURLHandler: { _ in
              documentURLCalls += 1
              return nil
            })
        },
      ],
      terminalBundleIDs: [],
      runningApplications: [app])

    let current = registry.currentLocation(
      in: context,
      candidates: registry.synchronousCandidates(scope: .all))

    XCTAssertEqual(current?.kind, .app)
    XCTAssertEqual(current?.pid, app.processIdentifier)
    XCTAssertEqual(documentURLCalls, 0)
  }

  func testPluginSubsourceIdentifierRoutesToOwningPluginSource() {
    let plugin = StubSource(identifier: "plugin:projects", capabilities: [.candidates])
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [plugin] })

    XCTAssertTrue(registry.source(identifier: "plugin:projects.locations") === plugin)
  }

  func testCandidateMatchingSubsourceIdentifierUsesOwningPluginSource() {
    let resolved = expectation(description: "plugin subsource")
    let project = Candidate(
      kind: .plugin("project"),
      sourceID: "plugin:projects.locations",
      source: "projects.locations",
      title: "General",
      subtitle: "Project location",
      isLocation: true)
    let plugin = StubSource(
      identifier: "plugin:projects",
      capabilities: [.candidates, .appActivation],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "projects.locations", kind: .locations)
      ],
      candidatesHandler: { _ in [project] },
      matchHandler: { target in
        project.title.localizedCaseInsensitiveContains(target) ? project : nil
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [plugin] })

    registry.resolveCandidate(
      matching: "general",
      sourceID: "plugin:projects.locations"
    ) { match in
      XCTAssertEqual(match?.sourceID, "plugin:projects.locations")
      XCTAssertEqual(match?.source, "projects.locations")
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 1)
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
    let resolved = expectation(description: "app source")
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

    registry.resolveCandidate(matching: "Slack") { match in
      XCTAssertEqual(match?.sourceID, "core.apps")
      XCTAssertEqual(match?.kind, .app)
      XCTAssertFalse(match.map(CandidateFinder.insertsText) ?? true)
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 1)
  }

  // app_open falls back to plugin sources for non-app names (e.g. a tmux
  // window), but a text-insertion candidate is never an activation target —
  // even when it is the only substring match, the resolver returns nil rather
  // than typing it.
  func testCandidateMatchingSkipsInsertTextAndFallsBackToActivatablePlugin() {
    let skipped = expectation(description: "insert text skipped")
    let resolved = expectation(description: "activatable fallback")
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
    makeRegistry(includeActivatablePlugin: false).resolveCandidate(matching: "editor") { match in
      XCTAssertNil(match)
      skipped.fulfill()
    }

    // An activatable plugin candidate is still reachable as a fallback.
    makeRegistry(includeActivatablePlugin: true).resolveCandidate(matching: "editor") { match in
      XCTAssertEqual(match?.sourceID, "plugin:tmux")
      XCTAssertFalse(match.map(CandidateFinder.insertsText) ?? true)
      resolved.fulfill()
    }
    wait(for: [skipped, resolved], timeout: 1)
  }

  func testPluginCandidateQueriesRespectActivationPolicy() throws {
    let app = try XCTUnwrap(
      NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
    let bundleID = try XCTUnwrap(app.bundleIdentifier)
    let active = StubSource(
      identifier: "plugin:active",
      capabilities: [.candidates],
      activationPolicy: .bundleIDs([bundleID]),
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "active.tabs", kind: .locations)
      ])
    let inactive = StubSource(
      identifier: "plugin:inactive",
      capabilities: [.candidates],
      activationPolicy: .bundleIDs(["invalid.bundle"]),
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "inactive.tabs", kind: .locations)
      ])
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [app],
      pluginSourcesProvider: { [active, inactive] })

    XCTAssertEqual(registry.locationCandidateSources().map(\.identifier), ["plugin:active"])
    XCTAssertNotNil(registry.source(identifier: "plugin:active"))
    XCTAssertNil(registry.source(identifier: "plugin:inactive"))
  }

  func testInitialCandidateSnapshotSourcesIncludeCoreAppsAndLocationPlugins() {
    let location = StubSource(
      identifier: "plugin:location",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "location.windows", kind: .locations)
      ])
    let nonLocation = StubSource(
      identifier: "plugin:emoji",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "emoji.glyphs", kind: .standard)
      ])
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: "core.apps", activationPolicy: .always) {
          StubSource(
            identifier: "core.apps",
            capabilities: [.candidates],
            candidateSourceDescriptors: [
              CandidateSourceDescriptor(name: "core.apps", kind: .locations, priority: .high)
            ])
        }
      ],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [nonLocation, location] })

    XCTAssertEqual(
      registry.initialCandidateSnapshotSources().map { $0.identifier },
      ["core.apps", "plugin:location"])
  }

  func testNonLocationCandidateSourcesCanTargetDeclaredSourcePrefix() {
    let emojis = StubSource(
      identifier: "plugin:emojis",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "emojis.glyphs", kind: .standard)
      ])
    let notes = StubSource(
      identifier: "plugin:notes",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "notes.notes", kind: .standard)
      ])
    let location = StubSource(
      identifier: "plugin:tmux",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "tmux.windows", kind: .locations)
      ])
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [notes, location, emojis] })

    XCTAssertEqual(
      registry.nonLocationCandidateSources(matching: "emojis").map(\.identifier),
      ["plugin:emojis"])
    XCTAssertEqual(
      Set(registry.nonLocationCandidateSources().map(\.identifier)),
      Set(["plugin:emojis", "plugin:notes"]))
  }

  func testPluginSnapshotFanInIsDeterministicDuplicateSafeAndBounded() {
    let completion = expectation(description: "snapshot fan-in")
    let first = StubSource(
      identifier: "plugin:a",
      capabilities: [.candidates],
      snapshotHandler: { done in
        done([Candidate(title: "a")])
        done([Candidate(title: "duplicate")])
      })
    let second = StubSource(
      identifier: "plugin:z",
      capabilities: [.candidates],
      snapshotHandler: { done in done([Candidate(title: "z")]) })
    let stalled = StubSource(
      identifier: "plugin:stalled",
      capabilities: [.candidates],
      snapshotHandler: { _ in })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [second, stalled, first] })

    registry.snapshotCandidates(scope: .all, timeoutMs: 5) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["a", "z"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
  }

  func testLocationSnapshotDoesNotPullNonLocationCatalogs() {
    let completion = expectation(description: "location-only snapshot")
    var locationCalls = 0
    var nonLocationCalls = 0
    let location = StubSource(
      identifier: "plugin:tabs",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "browser.tabs", kind: .locations)
      ],
      snapshotHandler: { done in
        locationCalls += 1
        done([
          Candidate(
            kind: .plugin("browser_tab"),
            sourceID: "plugin:tabs",
            source: "browser.tabs",
            title: "Tab",
            isLocation: true)
        ])
      })
    let nonLocation = StubSource(
      identifier: "plugin:notes",
      capabilities: [.candidates],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "notes.notes")
      ],
      snapshotHandler: { done in
        nonLocationCalls += 1
        done([Candidate(title: "Note")])
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [nonLocation, location] })

    registry.locationSnapshotCandidates(scope: .all) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["Tab"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
    XCTAssertEqual(locationCalls, 1)
    XCTAssertEqual(nonLocationCalls, 0)
  }

  func testPluginAppOpenOnlyPullsAndSelectsSafeLocationRows() {
    let completion = expectation(description: "safe plugin app open")
    var nonLocationCalls = 0
    let processes = StubSource(
      identifier: "plugin:processes",
      capabilities: [.candidates, .appActivation],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "processes.processes")
      ],
      snapshotHandler: { done in
        nonLocationCalls += 1
        done([Candidate(title: "bash")])
      })
    let locations = StubSource(
      identifier: "plugin:locations",
      capabilities: [.candidates, .appActivation],
      candidateSourceDescriptors: [
        CandidateSourceDescriptor(name: "terminal.windows", kind: .locations)
      ],
      snapshotHandler: { done in
        done([
          Candidate(
            kind: CandidateFinder.emojiKind,
            sourceID: "plugin:locations",
            source: "terminal.windows",
            title: "bash emoji",
            sourcePayload: "😀",
            isLocation: true),
          Candidate(
            kind: .plugin("terminal_window"),
            sourceID: "plugin:locations",
            source: "terminal.windows",
            title: "bash effect",
            isLocation: true,
            effect: .copyText("unsafe")),
          Candidate(
            kind: .plugin("process"),
            sourceID: "plugin:locations",
            source: "terminal.windows",
            title: "bash process",
            isLocation: false),
          Candidate(
            kind: .plugin("terminal_window"),
            sourceID: "plugin:locations",
            source: "terminal.windows",
            title: "bash window",
            isLocation: true),
        ])
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [processes, locations] })

    registry.resolveCandidate(matching: "bash") { candidate in
      XCTAssertEqual(candidate?.title, "bash window")
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
    XCTAssertEqual(nonLocationCalls, 0)
  }

  func testQueryEvaluatorsAreAdditivePriorityOrderedAndDuplicateSafe() {
    let completion = expectation(description: "query evaluation")
    let lowCandidate = Candidate(title: "low")
    let highCandidate = Candidate(title: "high")
    let low = StubSource(
      identifier: "plugin:low",
      queryEvaluationPriority: 10,
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { request, done in
        XCTAssertEqual(request.text, "1+1")
        done([lowCandidate])
      })
    let high = StubSource(
      identifier: "plugin:high",
      queryEvaluationPriority: 20,
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in
        done([highCandidate])
        done([Candidate(title: "duplicate callback")])
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [low, high] })

    registry.evaluateQuery(
      QueryEvaluationRequest(surface: .flashlight, scope: .all, text: "1+1")
    ) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["high", "low"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
  }

  func testExclusiveQueryPrefixRoutesOnlyToDeclaringEvaluator() {
    let completion = expectation(description: "exclusive query evaluation")
    var genericCalls = 0
    let calculator = StubSource(
      identifier: "plugin:calculator",
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationPrefixes: ["="],
      queryEvaluationHandler: { request, done in
        XCTAssertEqual(request.exclusivePrefix, "=")
        done([Candidate(title: "2")])
      })
    let generic = StubSource(
      identifier: "plugin:generic",
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in
        genericCalls += 1
        done([Candidate(title: "unrelated")])
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [calculator, generic] })

    registry.evaluateQuery(
      QueryEvaluationRequest(
        surface: .flashlight,
        scope: .all,
        text: "=1+1",
        exclusivePrefix: "=")
    ) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["2"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
    XCTAssertEqual(genericCalls, 0)
  }

  func testMainThreadQueryReplySettlesWithoutASecondRunloopHop() {
    let completion = expectation(description: "query evaluation")
    var evaluatorCallbackIsActive = false
    let evaluator = StubSource(
      identifier: "plugin:calculator",
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in
        evaluatorCallbackIsActive = true
        done([Candidate(title: "2")])
        evaluatorCallbackIsActive = false
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [evaluator] })

    registry.evaluateQuery(
      QueryEvaluationRequest(surface: .flashlight, scope: .all, text: "1+1")
    ) { candidates in
      XCTAssertTrue(
        evaluatorCallbackIsActive,
        "a main-thread plugin reply must not be queued behind its aggregate deadline")
      XCTAssertEqual(candidates.map(\.title), ["2"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
  }

  func testQueryEvaluatorTimeoutReturnsSettledAnswersOnce() {
    let completion = expectation(description: "query timeout")
    let fast = StubSource(
      identifier: "plugin:fast",
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in done([Candidate(title: "fast")]) })
    let stalled = StubSource(
      identifier: "plugin:stalled",
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, _ in })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [fast, stalled] })

    registry.evaluateQuery(
      QueryEvaluationRequest(surface: .flashlight, scope: .all, text: "2+2"),
      timeoutMs: 5
    ) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["fast"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
  }

  func testQueryEvaluatorsRespectPluginActivationPolicy() {
    let completion = expectation(description: "active query evaluators")
    var inactiveCalls = 0
    let active = StubSource(
      identifier: "plugin:active",
      activationPolicy: .always,
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in done([Candidate(title: "active")]) })
    let inactive = StubSource(
      identifier: "plugin:inactive",
      activationPolicy: .bundleIDs(["invalid.bundle"]),
      queryEvaluationSurfaces: [.flashlight],
      queryEvaluationHandler: { _, done in
        inactiveCalls += 1
        done([Candidate(title: "inactive")])
      })
    let registry = SourceRegistry(
      descriptors: [],
      terminalBundleIDs: [],
      runningApplications: [],
      pluginSourcesProvider: { [active, inactive] })

    registry.evaluateQuery(
      QueryEvaluationRequest(surface: .flashlight, scope: .all, text: "3+3")
    ) { candidates in
      XCTAssertEqual(candidates.map(\.title), ["active"])
      completion.fulfill()
    }

    wait(for: [completion], timeout: 1)
    XCTAssertEqual(inactiveCalls, 0)
  }
}

private final class StubSource: FlashSource, FlashQueryEvaluator {
  let identifier: String
  let priority: Int
  let capabilities: FlashSourceCapabilities
  let activationPolicy: FlashSourceActivationPolicy
  let readinessPolicy: FlashSourceReadinessPolicy
  let fallsBackOnEmptyDiscovery: Bool
  private let candidatesHandler: (CandidateScope) -> [Candidate]
  private let snapshotHandler: (@escaping ([Candidate]) -> Void) -> Void
  private let matchHandler: (String) -> Candidate?
  private let supportsHandler: (AppContext) -> Bool
  private let documentURLHandler: (AppContext) -> String?
  private let discoverHandler: (AppContext) throws -> [JumpTarget]
  let navigationSchemes: Set<String>
  private let restoreHandler: (URL) -> SourceActionResult
  let candidateSourceLabels: [String]
  let candidateSourceDescriptors: [CandidateSourceDescriptor]
  let queryEvaluationPriority: Int
  let queryEvaluationSurfaces: Set<QueryEvaluationSurface>
  let queryEvaluationPrefixes: Set<String>
  private let queryEvaluationHandler:
    (QueryEvaluationRequest, @escaping ([Candidate]) -> Void) -> Void
  var queryEvaluatorIdentifier: String { identifier }

  init(
    identifier: String,
    priority: Int = 0,
    capabilities: FlashSourceCapabilities = [],
    activationPolicy: FlashSourceActivationPolicy = .always,
    readinessPolicy: FlashSourceReadinessPolicy = .activationOnly,
    fallsBackOnEmptyDiscovery: Bool = false,
    candidateSourceLabels: [String] = [],
    candidateSourceDescriptors: [CandidateSourceDescriptor] = [],
    queryEvaluationPriority: Int = 0,
    queryEvaluationSurfaces: Set<QueryEvaluationSurface> = [],
    queryEvaluationPrefixes: Set<String> = [],
    navigationSchemes: Set<String> = [],
    candidatesHandler: @escaping (CandidateScope) -> [Candidate] = { _ in [] },
    snapshotHandler: ((@escaping ([Candidate]) -> Void) -> Void)? = nil,
    matchHandler: @escaping (String) -> Candidate? = { _ in nil },
    supportsHandler: @escaping (AppContext) -> Bool = { _ in false },
    documentURLHandler: @escaping (AppContext) -> String? = { _ in nil },
    discoverHandler: @escaping (AppContext) throws -> [JumpTarget] = { _ in [] },
    queryEvaluationHandler:
      @escaping (QueryEvaluationRequest, @escaping ([Candidate]) -> Void) -> Void =
      { _, done in done([]) },
    restoreHandler: @escaping (URL) -> SourceActionResult = { _ in .unhandled }
  ) {
    self.identifier = identifier
    self.priority = priority
    self.capabilities = capabilities
    self.activationPolicy = activationPolicy
    self.readinessPolicy = readinessPolicy
    self.fallsBackOnEmptyDiscovery = fallsBackOnEmptyDiscovery
    self.candidateSourceLabels = candidateSourceLabels
    self.candidateSourceDescriptors =
      candidateSourceDescriptors.isEmpty
      ? candidateSourceLabels.map { CandidateSourceDescriptor(name: $0) }
      : candidateSourceDescriptors
    self.navigationSchemes = navigationSchemes
    self.queryEvaluationPriority = queryEvaluationPriority
    self.queryEvaluationSurfaces = queryEvaluationSurfaces
    self.queryEvaluationPrefixes = queryEvaluationPrefixes
    self.queryEvaluationHandler = queryEvaluationHandler
    self.candidatesHandler = candidatesHandler
    self.snapshotHandler =
      snapshotHandler ?? { done in
        done(candidatesHandler(.all))
      }
    self.matchHandler = matchHandler
    self.supportsHandler = supportsHandler
    self.documentURLHandler = documentURLHandler
    self.discoverHandler = discoverHandler
    self.restoreHandler = restoreHandler
  }

  func supports(_ context: AppContext) -> Bool { supportsHandler(context) }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    try discoverHandler(context)
  }

  func candidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope
  ) -> [Candidate] {
    candidatesHandler(scope)
  }

  func snapshotCandidates(
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    _ = scope
    snapshotHandler(completion)
  }

  func evaluateQuery(
    _ request: QueryEvaluationRequest,
    in environment: FlashSourceEnvironment,
    completion: @escaping ([Candidate]) -> Void
  ) {
    queryEvaluationHandler(request, completion)
  }

  func candidate(
    matching target: String,
    in environment: FlashSourceEnvironment
  ) -> Candidate? {
    matchHandler(target)
  }

  func documentURL(in context: AppContext) -> String? {
    documentURLHandler(context)
  }

  func restoreNavigation(
    to url: URL,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    completion(restoreHandler(url))
  }
}

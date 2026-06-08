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
}

private final class StubSource: FlashSource {
  let identifier: String
  let priority = 0
  let capabilities: FlashSourceCapabilities
  private let candidatesHandler: (CandidateScope) -> [Candidate]

  init(
    identifier: String,
    capabilities: FlashSourceCapabilities = [],
    candidatesHandler: @escaping (CandidateScope) -> [Candidate] = { _ in [] }
  ) {
    self.identifier = identifier
    self.capabilities = capabilities
    self.candidatesHandler = candidatesHandler
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
}

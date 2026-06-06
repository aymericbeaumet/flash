import AppKit
import FlashCore
import XCTest

@testable import flash

final class SourceCandidateTests: XCTestCase {
  func testExactTitleMatchOutranksSourceOrFuzzyMatches() throws {
    let finder = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Finder",
        subtitle: "app",
        bundleIdentifier: "com.apple.finder"))
    let firefox = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "finder",
        name: "Firefox Developer Edition",
        subtitle: "app",
        bundleIdentifier: "org.mozilla.firefoxdeveloperedition"))
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .browserTab,
        source: "firefox",
        name: "Notes",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://docs.example.test/finder")))

    let finderScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: finder))
    let firefoxScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: firefox))
    let tabScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: tab))

    XCTAssertGreaterThan(finderScore, firefoxScore)
    XCTAssertGreaterThan(finderScore, tabScore)
  }

  func testAliveCandidatesSortBeforeDeadCandidatesForOpenResults() {
    let dead = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Alpha",
        subtitle: "app",
        bundleIdentifier: "com.example.alpha",
        pid: nil))
    let alive = CandidateFinder.prepare(
      candidate(
        kind: .tmuxWindow,
        source: "tmux",
        name: "Zulu",
        subtitle: "tmux window",
        bundleIdentifier: "",
        pid: 123))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: dead, score: 0),
      CandidateMatch(candidate: alive, score: 0),
    ])

    XCTAssertEqual(sorted.map(\.candidate.name), ["Zulu", "Alpha"])
  }

  func testAliveCandidatesOutrankDeadCandidatesBeforeTextScore() throws {
    let deadExact = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Finder",
        subtitle: "app",
        bundleIdentifier: "com.example.finder",
        pid: nil))
    let aliveTab = CandidateFinder.prepare(
      candidate(
        kind: .browserTab,
        source: "firefox",
        name: "Finder notes",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 123,
        url: URL(string: "https://docs.example.test/finder")))

    let deadScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: deadExact))
    let aliveScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: aliveTab))
    XCTAssertGreaterThan(deadScore, aliveScore)

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: deadExact, score: deadScore),
      CandidateMatch(candidate: aliveTab, score: aliveScore),
    ])

    XCTAssertEqual(sorted.map(\.candidate.name), ["Finder notes", "Finder"])
  }

  func testOpenCandidateScoringMatchesURL() throws {
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .browserTab,
        source: "firefox",
        name: "Inbox",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 123,
        url: URL(string: "https://gmail.com/mail/u/0/#inbox")))

    XCTAssertNotNil(CandidateFinder.score(query: "gmail", candidate: tab))
    XCTAssertNotNil(CandidateFinder.score(query: "gmail.com", candidate: tab))
  }

  func testApplicationSourceCanResolveFinderFromCoreServices() throws {
    let source = ApplicationSource()
    let finder = try XCTUnwrap(
      source.candidate(
        matching: "Finder",
        in: FlashSourceEnvironment(runningApplications: [])))

    XCTAssertEqual(finder.name, "Finder")
    XCTAssertEqual(finder.bundleIdentifier, "com.apple.finder")
  }

  func testBrowserTabDisplayTitleIncludesSourceTitleAndURL() throws {
    let candidate = try XCTUnwrap(
      BrowserTabSources.browserTabItem(
        sourceID: "safari-tabs",
        source: "safari",
        app: DummyRunningApplication.app,
        title: "Inbox",
        url: "https://mail.example.test/inbox"))
    let prepared = CandidateFinder.prepare(candidate)

    XCTAssertEqual(prepared.displayTitle, "[safari] Inbox (https://mail.example.test/inbox)")
    XCTAssertTrue(prepared.normalizedSearchText.contains("safari"))
    XCTAssertTrue(prepared.normalizedSearchText.contains("mail"))
    XCTAssertTrue(prepared.normalizedSearchText.contains("example"))
  }

  func testSlackChannelParserHandlesHashSeparatedFromName() {
    XCTAssertEqual(SlackSource.parseChannelName("# general"), "#general")
    XCTAssertEqual(SlackSource.parseChannelName("general, channel"), "#general")
  }

  func testSlackBareChannelParserRequiresChannelContextFromCaller() {
    XCTAssertEqual(SlackSource.parseBareChannelName("release_notes"), "#release_notes")
    XCTAssertNil(SlackSource.parseBareChannelName("channel"))
  }

  private func candidate(
    kind: CandidateKind,
    source: String,
    name: String,
    subtitle: String,
    bundleIdentifier: String,
    pid: pid_t? = nil,
    url: URL? = nil
  ) -> Candidate {
    Candidate(
      kind: kind,
      sourceID: source,
      source: source,
      pid: pid,
      name: name,
      subtitle: subtitle,
      bundleIdentifier: bundleIdentifier,
      url: url,
      tmuxClientTTY: nil,
      tmuxTarget: nil,
      targetElement: nil)
  }
}

private enum DummyRunningApplication {
  static var app: NSRunningApplication {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil }
      ?? NSRunningApplication.current
  }
}

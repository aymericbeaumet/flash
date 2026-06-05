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
        title: "Finder",
        subtitle: "app",
        bundleIdentifier: "com.apple.finder"))
    let firefox = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        title: "Firefox Developer Edition",
        subtitle: "app",
        bundleIdentifier: "org.mozilla.firefoxdeveloperedition"))
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .browserTab,
        source: "firefox",
        title: "Finder notes",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://docs.example.test/finder")))

    let finderScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: finder))
    let firefoxScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: firefox))
    let tabScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: tab))

    XCTAssertGreaterThan(finderScore, firefoxScore)
    XCTAssertGreaterThan(finderScore, tabScore)
  }

  func testApplicationSourceCanResolveFinderFromCoreServices() throws {
    let source = ApplicationSource()
    let finder = try XCTUnwrap(
      source.candidate(
        matching: "Finder",
        in: FlashSourceEnvironment(runningApplications: [])))

    XCTAssertEqual(finder.title, "Finder")
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
    title: String,
    subtitle: String,
    bundleIdentifier: String,
    url: URL? = nil
  ) -> Candidate {
    Candidate(
      kind: kind,
      sourceID: source,
      source: source,
      pid: nil,
      title: title,
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

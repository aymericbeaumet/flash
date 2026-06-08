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
        kind: .plugin("browser_tab"),
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
        kind: .plugin("tmux_window"),
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
    // Both candidates land on the **same** match tier (string prefix),
    // so their scores stay within `aliveTieBreakScoreMargin` and the
    // alive-bonus is allowed to settle the tie. Cross-tier matches
    // (e.g. exact vs prefix, gap ≥ 2000) intentionally bypass this
    // bump — match quality dominates the alive heuristic.
    let deadPrefix = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Finder Pro",
        subtitle: "app",
        bundleIdentifier: "com.example.finderpro",
        pid: nil))
    let alivePrefix = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Finder notes",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 123,
        url: URL(string: "https://docs.example.test/finder")))

    let deadScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: deadPrefix))
    let aliveScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: alivePrefix))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: deadPrefix, score: deadScore),
      CandidateMatch(candidate: alivePrefix, score: aliveScore),
    ])

    XCTAssertEqual(sorted.map(\.candidate.name), ["Finder notes", "Finder Pro"])
  }

  func testExactPrefixOnAppNameOutranksContainsOnBrowserTab() throws {
    // The motivating regression: typing `mes` must surface the
    // `Messages` app over a browser tab whose title merely contains
    // `mes` somewhere mid-string. Without the widened match tiers the
    // browser-tier bonus alone (+40 over app tier) was enough to flip
    // the order even though the app is a far stronger semantic match.
    let messagesApp = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Messages",
        subtitle: "app",
        bundleIdentifier: "com.apple.mobilesms",
        pid: 4242))
    let browserTab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Important message inbox",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 9876,
        url: URL(string: "https://mail.example.test/")))

    let appScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: messagesApp))
    let tabScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: browserTab))
    XCTAssertGreaterThan(appScore, tabScore)
    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: tabScore),
      CandidateMatch(candidate: messagesApp, score: appScore),
    ])
    XCTAssertEqual(sorted.map(\.candidate.name), ["Messages", "Important message inbox"])
  }

  func testWordPrefixOutranksContainsAcrossWordBoundary() throws {
    // "mes" matching the start of the word "Messages" in "iOS Messages"
    // (word-prefix, +1500) beats a generic mid-word substring hit
    // (+800).
    let iosMessages = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "iOS Messages",
        subtitle: "app",
        bundleIdentifier: "com.example.iosmessages",
        pid: 1111))
    let irrelevantMidword = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Compresso",  // contains "mes" but mid-word
        subtitle: "app",
        bundleIdentifier: "com.example.compresso",
        pid: 2222))

    let wordScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: iosMessages))
    let midScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: irrelevantMidword))
    XCTAssertGreaterThan(wordScore, midScore)
  }

  func testTmuxWindowsOutrankBrowserTabsOnCloseScores() {
    let browserTab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "agentic",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 4242,
        url: URL(string: "https://example.test/agentic")))
    let tmuxWindow = CandidateFinder.prepare(
      candidate(
        kind: .plugin("tmux_window"),
        source: "tmux",
        name: "agentic",
        subtitle: "tmux window",
        bundleIdentifier: "",
        pid: 4242))

    // Score the same query against both — the tier tie-break in
    // sortedMatches should put tmux first regardless of close fuzzy
    // delta.
    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: 10_120),
      CandidateMatch(candidate: tmuxWindow, score: 10_160),
    ])
    XCTAssertEqual(sorted.map(\.candidate.source), ["tmux", "firefox"])

    // Even when the browser tab edges ahead on the raw score (within
    // the alive-tie margin), the tier bias still settles in tmux's
    // favour because the comparator runs source-tier comparison
    // before falling back to alphabetical.
    let sortedReversed = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: 10_160),
      CandidateMatch(candidate: tmuxWindow, score: 10_120),
    ])
    XCTAssertEqual(sortedReversed.map(\.candidate.source), ["tmux", "firefox"])
  }

  func testFlashlightTierOrderTmuxBrowserActiveAppInactiveAppThenRest() {
    // The exact order the user asked for, exercised with equal scores so
    // only the tier tie-break decides:
    //   tmux > browser tab > active app > inactive app > the rest.
    let tmux = CandidateFinder.prepare(
      candidate(
        kind: .plugin("tmux_window"), source: "tmux", name: "z-tmux",
        subtitle: "tmux window", bundleIdentifier: "", pid: nil))
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "z-tab",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox", pid: nil))
    let activeApp = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "app", name: "z-active",
        subtitle: "app", bundleIdentifier: "com.example.active", pid: 4242))
    let inactiveApp = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "app", name: "z-inactive",
        subtitle: "app", bundleIdentifier: "com.example.inactive", pid: nil))
    let note = CandidateFinder.prepare(
      candidate(
        kind: .plugin("note"), source: "notes", name: "z-note",
        subtitle: "note", bundleIdentifier: "", pid: nil))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: note, score: 0),
      CandidateMatch(candidate: inactiveApp, score: 0),
      CandidateMatch(candidate: activeApp, score: 0),
      CandidateMatch(candidate: tab, score: 0),
      CandidateMatch(candidate: tmux, score: 0),
    ])

    XCTAssertEqual(
      sorted.map(\.candidate.name),
      ["z-tmux", "z-tab", "z-active", "z-inactive", "z-note"])
  }

  func testCandidateMatchesSourceFilterPrefixAndGroups() {
    let note = CandidateFinder.prepare(
      candidate(
        kind: .plugin("note"), source: "notes", name: "Inbox",
        subtitle: "note", bundleIdentifier: ""))
    let firefoxTab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "Gmail",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox"))
    let app = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "app", name: "Finder",
        subtitle: "app", bundleIdentifier: "com.apple.finder"))

    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(note, filter: "notes"))
    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(note, filter: "note"))
    XCTAssertFalse(CandidateFinder.candidateMatchesSourceFilter(note, filter: "app"))
    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "fire"))
    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "browser"))
    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "tabs"))
    XCTAssertTrue(CandidateFinder.candidateMatchesSourceFilter(app, filter: "apps"))
    XCTAssertFalse(CandidateFinder.candidateMatchesSourceFilter(app, filter: "browser"))
  }

  func testStrongTextScoreOutranksAliveTieBreaker() {
    let deadExact = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "System Settings",
        subtitle: "app",
        bundleIdentifier: "com.apple.systempreferences",
        pid: nil))
    let aliveWeak = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Messages",
        subtitle: "app",
        bundleIdentifier: "com.apple.MobileSMS",
        pid: 123))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: aliveWeak, score: 10_000),
      CandidateMatch(candidate: deadExact, score: 11_000),
    ])

    XCTAssertEqual(sorted.map(\.candidate.name), ["System Settings", "Messages"])
  }

  func testOpenCandidateScoringMatchesURL() throws {
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Inbox",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 123,
        url: URL(string: "https://gmail.com/mail/u/0/#inbox")))

    XCTAssertNotNil(CandidateFinder.score(query: "gmail", candidate: tab))
    XCTAssertNotNil(CandidateFinder.score(query: "gmail.com", candidate: tab))
  }

  func testOpenCandidateScoringMatchesBrowserTabTitleDomainAlias() throws {
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Gmail",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        pid: 123,
        url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))

    XCTAssertNotNil(CandidateFinder.score(query: "gmail.com", candidate: tab))
  }

  func testAppCandidateScoringIgnoresCommonFilePathPrefixes() throws {
    let messages = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "Messages",
        subtitle: "app",
        bundleIdentifier: "com.apple.MobileSMS",
        url: URL(fileURLWithPath: "/System/Applications/Messages.app")))
    let settings = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "app",
        name: "System Settings",
        subtitle: "app",
        bundleIdentifier: "com.apple.systempreferences",
        url: URL(fileURLWithPath: "/System/Applications/System Settings.app")))

    XCTAssertNil(CandidateFinder.score(query: "settings", candidate: messages))
    XCTAssertNotNil(CandidateFinder.score(query: "settings", candidate: settings))
  }

  func testApplicationSourceCanResolveFinderFromCoreServices() throws {
    let source = ApplicationSource()
    let finder = try XCTUnwrap(
      source.candidate(
        matching: "Finder",
        in: FlashSourceEnvironment(runningApplications: [])))

    XCTAssertEqual(finder.name, "Finder")
    XCTAssertEqual(finder.bundleIdentifier, "com.apple.finder")
    XCTAssertEqual(finder.url?.isFileURL, true)
    XCTAssertTrue(finder.url?.path.hasPrefix("/") ?? false)
  }

  func testApplicationSourceSystemSettingsCandidateHasOpenableFileURL() throws {
    let expectedURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    guard FileManager.default.fileExists(atPath: expectedURL.path) else {
      throw XCTSkip("System Settings.app is not present at the standard macOS path")
    }
    let source = ApplicationSource()
    let settings = try XCTUnwrap(
      source.candidate(
        matching: "System Settings",
        in: FlashSourceEnvironment(runningApplications: [])))

    XCTAssertEqual(settings.name, "System Settings")
    XCTAssertEqual(settings.bundleIdentifier, "com.apple.systempreferences")
    XCTAssertEqual(settings.url?.isFileURL, true)
    XCTAssertEqual(settings.url?.standardizedFileURL.path, expectedURL.standardizedFileURL.path)
    XCTAssertTrue(settings.url?.absoluteString.hasPrefix("file://") ?? false)
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
      targetElement: nil)
  }
}

private enum DummyRunningApplication {
  static var app: NSRunningApplication {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil }
      ?? NSRunningApplication.current
  }
}

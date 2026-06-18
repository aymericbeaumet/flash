import AppKit
import FlashCore
import XCTest

@testable import flash

final class SourceCandidateTests: XCTestCase {
  func testPrepareBuildsWordStartMaskFromTitleAndAliasTokens() throws {
    let prepared = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "AirPort Base Station Agent",
        subtitle: "app",
        bundleIdentifier: "com.apple.airport",
        searchAliases: "wifi router"))
    // Lower 26 bits are a–z first-letters across all tokens. AirPort →
    // 'a'; Base → 'b'; Station → 's'; Agent → 'a'; wifi → 'w'; router → 'r'.
    let bit: (Character) -> UInt64 = { ch in
      let v = ch.asciiValue!
      return v >= 97 && v <= 122 ? 1 << UInt64(v - 97) : 0
    }
    let expected = bit("a") | bit("b") | bit("s") | bit("w") | bit("r") | bit("c")
    // `c` because the source title contains "core.apps" — `core` is the
    // first token there.
    XCTAssertEqual(prepared.wordStartMask & expected, expected)
    // 'z' is not a word-start anywhere, so its bit must be unset.
    XCTAssertEqual(prepared.wordStartMask & bit("z"), 0)
  }

  func testShortQueryRejectsCandidateWithoutMatchingWordStart() {
    let memory = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "Memory Slot Utility",
        subtitle: "app",
        bundleIdentifier: ""))
    let inboxedMessage = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Important inbox message",
        subtitle: "browser tab",
        bundleIdentifier: ""))
    // Query "m" matches a word-start in both. Both pass the gate.
    XCTAssertNotNil(CandidateFinder.score(query: "m", candidate: memory))
    XCTAssertNotNil(CandidateFinder.score(query: "m", candidate: inboxedMessage))
    // Query "z" matches a word-start in neither — gate trips for the
    // short query and `score` returns nil.
    XCTAssertNil(CandidateFinder.score(query: "z", candidate: memory))
    XCTAssertNil(CandidateFinder.score(query: "z", candidate: inboxedMessage))
  }

  func testLongQueryBypassesWordStartGate() {
    // "fox" doesn't start any word in "Firefox" but a 3-character query
    // must still surface this substring-only match — the gate is for
    // 1–2 char typeahead, not a hard contract for longer searches.
    let firefox = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox",
        name: "Firefox",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox"))
    XCTAssertNotNil(CandidateFinder.score(query: "fox", candidate: firefox))
  }

  func testExactTitleMatchOutranksSourceOrFuzzyMatches() throws {
    let finder = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
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

  func testSourceFamilyMatchOutranksUnrelatedExactTitleMatches() throws {
    let tmuxWindow = CandidateFinder.prepare(
      candidate(
        kind: .plugin("tmux_window"),
        source: "tmux.windows",
        name: ".dotfiles",
        subtitle: "scratch:1 · zsh · ~/.dotfiles",
        bundleIdentifier: "",
        pid: 4242))
    let processA = CandidateFinder.prepare(
      candidate(
        kind: .plugin("process"),
        source: "processes.processes",
        name: "tmux",
        subtitle: "process",
        bundleIdentifier: "",
        pid: 101))
    let processB = CandidateFinder.prepare(
      candidate(
        kind: .plugin("process"),
        source: "processes.processes",
        name: "tmux",
        subtitle: "process",
        bundleIdentifier: "",
        pid: 102))

    let tmuxScore = try XCTUnwrap(CandidateFinder.score(query: "tmux", candidate: tmuxWindow))
    let processScore = try XCTUnwrap(CandidateFinder.score(query: "tmux", candidate: processA))
    XCTAssertGreaterThan(tmuxScore, processScore)

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: processA, score: processScore),
      CandidateMatch(candidate: processB, score: processScore),
      CandidateMatch(candidate: tmuxWindow, score: tmuxScore),
    ])
    XCTAssertEqual(sorted.first?.candidate.source, "tmux.windows")
  }

  func testAliveCandidatesSortBeforeDeadCandidatesForOpenResults() {
    let dead = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
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

    XCTAssertEqual(sorted.map(\.candidate.title), ["Zulu", "Alpha"])
  }

  func testStrongerMatchWinsWithinSameDefaultSourceBand() throws {
    // The strict default source bands (tmux > browser > apps > Slack)
    // settle cross-family order. Inside a band, match quality still leads.
    let deadPrefix = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "Finder Pro",
        subtitle: "app",
        bundleIdentifier: "com.example.finderpro",
        pid: nil))
    let alivePrefix = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "Finder notes",
        subtitle: "app",
        bundleIdentifier: "com.example.findernotes",
        pid: 123))

    let deadScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: deadPrefix))
    let aliveScore = try XCTUnwrap(CandidateFinder.score(query: "finder", candidate: alivePrefix))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: deadPrefix, score: deadScore),
      CandidateMatch(candidate: alivePrefix, score: aliveScore),
    ])

    // Whichever candidate scores higher comes first.
    let expectedFirst = deadScore >= aliveScore ? "Finder Pro" : "Finder notes"
    XCTAssertEqual(sorted.first?.candidate.title, expectedFirst)
  }

  func testDefaultFlashlightSourceBandOutranksCrossFamilyMatchQuality() throws {
    // The default flashlight is source-first: tmux > browser tabs > apps >
    // Slack channels. A browser tab with a weaker match still stays above an
    // app with a stronger match because the user asked for strict family order.
    let messagesApp = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
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
    XCTAssertEqual(sorted.map(\.candidate.title), ["Important message inbox", "Messages"])
  }

  func testWordPrefixOutranksContainsAcrossWordBoundary() throws {
    // "mes" matching the start of the word "Messages" in "iOS Messages"
    // (word-prefix, +1500) beats a generic mid-word substring hit
    // (+800).
    let iosMessages = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "iOS Messages",
        subtitle: "app",
        bundleIdentifier: "com.example.iosmessages",
        pid: 1111))
    let irrelevantMidword = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "Compresso",  // contains "mes" but mid-word
        subtitle: "app",
        bundleIdentifier: "com.example.compresso",
        pid: 2222))

    let wordScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: iosMessages))
    let midScore = try XCTUnwrap(CandidateFinder.score(query: "mes", candidate: irrelevantMidword))
    XCTAssertGreaterThan(wordScore, midScore)
  }

  func testTierBreaksScoreTiesBetweenTmuxAndBrowserTabs() {
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

    // On exact score ties the tier order (tmux > browser tab) settles
    // it. That keeps the intuitive "your active terminal context wins"
    // bias without overriding the matcher.
    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: 10_120),
      CandidateMatch(candidate: tmuxWindow, score: 10_120),
    ])
    XCTAssertEqual(sorted.map(\.candidate.source), ["tmux", "firefox"])

    // The family band is strict: even a higher browser-tab score stays below
    // a tmux row in default flashlight ordering.
    let scoreDrivenOrder = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: 14_000),
      CandidateMatch(candidate: tmuxWindow, score: 10_120),
    ])
    XCTAssertEqual(scoreDrivenOrder.map(\.candidate.source), ["tmux", "firefox"])
  }

  func testFlashlightSourceBandOrderBangTmuxBrowserAppsSlackThenRest() {
    // Bangs remain the top command surface. Default navigation families are
    // strict after that: tmux > browser tabs > apps > Slack channels. Hidden
    // sources sort after those families and are filtered from the live default
    // pool unless the user types `@source`.
    let bang = CandidateFinder.prepare(
      candidate(
        kind: .plugin("bang"), source: "bang", name: "z-bang",
        subtitle: "bang", bundleIdentifier: "", pid: nil))
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
        kind: .app, source: "core.apps", name: "z-active",
        subtitle: "app", bundleIdentifier: "com.example.active", pid: 4242))
    let inactiveApp = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "core.apps", name: "z-inactive",
        subtitle: "app", bundleIdentifier: "com.example.inactive", pid: nil))
    let slack = CandidateFinder.prepare(
      candidate(
        kind: .plugin("slack_channel"), source: "slack.channels", name: "z-slack",
        subtitle: "slack channel", bundleIdentifier: "", pid: nil))
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
      CandidateMatch(candidate: slack, score: 0),
      CandidateMatch(candidate: bang, score: 0),
    ])

    XCTAssertEqual(
      sorted.map(\.candidate.title),
      ["z-bang", "z-tmux", "z-tab", "z-active", "z-inactive", "z-slack", "z-note"])
  }

  func testNamePrefixMatchCrossesSourceBand() {
    let safariApp = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "core.apps", name: "Safari",
        subtitle: "app", bundleIdentifier: "com.apple.Safari", pid: 4242))
    // A browser tab whose own name does NOT start with the query — it would
    // only match `safa` via an unrelated field (here it doesn't match at all;
    // the score is supplied directly to isolate the band/tier ordering).
    let firefoxTab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "Apple Newsroom",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox", pid: 4242,
        url: URL(string: "https://example.test/safari")))

    // No query: the strict family band keeps the browser tab above the app
    // even with a much lower app score (unchanged behaviour).
    let banded = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: safariApp, score: 12_000),
      CandidateMatch(candidate: firefoxTab, score: 14_000),
    ])
    XCTAssertEqual(banded.map(\.candidate.source), ["firefox", "core.apps"])

    // Typing `safa` — a full-string prefix of the app's own name — lifts
    // Safari.app above the tab despite the tab's higher score and band.
    let prefixed = CandidateFinder.sortedMatches(
      [
        CandidateMatch(candidate: safariApp, score: 12_000),
        CandidateMatch(candidate: firefoxTab, score: 14_000),
      ],
      normalizedQuery: "safa")
    XCTAssertEqual(prefixed.map(\.candidate.source), ["core.apps", "firefox"])
  }

  func testDefaultFlashlightVisibilityOnlyIncludesNavigationFamilies() {
    let tmux = candidate(
      kind: .plugin("tmux_window"), source: "tmux.windows", name: "flash",
      subtitle: "tmux window", bundleIdentifier: "")
    let tab = candidate(
      kind: .plugin("browser_tab"), source: "firefox.tabs", name: "Gmail",
      subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox")
    let app = candidate(
      kind: .app, source: "core.apps", name: "Safari",
      subtitle: "app", bundleIdentifier: "com.apple.Safari")
    let slack = candidate(
      kind: .plugin("slack_channel"), source: "slack.channels", name: "#general",
      subtitle: "slack channel", bundleIdentifier: "")
    let note = candidate(
      kind: .plugin("note"), source: "notes.notes", name: "shopping",
      subtitle: "note", bundleIdentifier: "")
    let emoji = candidate(
      kind: CandidateFinder.emojiKind, source: "emojis.glyphs", name: "🔥 fire",
      subtitle: "emoji", bundleIdentifier: "")
    let source = CandidateFinder.sourceCompletionCandidate("notes.notes")

    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(tmux))
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(tab))
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(app))
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(slack))
    XCTAssertFalse(CandidateFinder.isDefaultFlashlightCandidate(note))
    XCTAssertFalse(CandidateFinder.isDefaultFlashlightCandidate(emoji))
    XCTAssertFalse(CandidateFinder.isDefaultFlashlightCandidate(source))
  }

  func testHigherScoreWinsEvenOverActiveAppTier() {
    // Score leads: a dead exact match (11k) outranks a live weak match
    // (10k) even though active apps are the higher tier — tier only
    // settles score ties.
    let deadExact = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "System Settings",
        subtitle: "app",
        bundleIdentifier: "com.apple.systempreferences",
        pid: nil))
    let aliveWeak = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
        name: "Messages",
        subtitle: "app",
        bundleIdentifier: "com.apple.MobileSMS",
        pid: 123))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: aliveWeak, score: 10_000),
      CandidateMatch(candidate: deadExact, score: 11_000),
    ])

    XCTAssertEqual(sorted.map(\.candidate.title), ["System Settings", "Messages"])
  }

  func testBangCandidatesAlwaysWinEvenAgainstStrongerNonBangScores() {
    // The one strict band: a registered bang must surface above every
    // non-bang candidate, however well it scores. A typed `!yt` means
    // dispatch; we never bury it under a Messages-app exact match.
    let bang = CandidateFinder.prepare(
      candidate(
        kind: .plugin("bang"), source: "bang", name: "!yt",
        subtitle: "youtube search", bundleIdentifier: "", pid: nil))
    let strongApp = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "core.apps", name: "YouTube",
        subtitle: "app", bundleIdentifier: "com.example.youtube", pid: 42))

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: strongApp, score: 50_000),
      CandidateMatch(candidate: bang, score: 100),
    ])

    XCTAssertEqual(sorted.map(\.candidate.title), ["!yt", "YouTube"])
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
        source: "core.apps",
        name: "Messages",
        subtitle: "app",
        bundleIdentifier: "com.apple.MobileSMS",
        url: URL(fileURLWithPath: "/System/Applications/Messages.app")))
    let settings = CandidateFinder.prepare(
      candidate(
        kind: .app,
        source: "core.apps",
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

    XCTAssertEqual(finder.title, "Finder")
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

    XCTAssertEqual(settings.title, "System Settings")
    XCTAssertEqual(settings.bundleIdentifier, "com.apple.systempreferences")
    XCTAssertEqual(settings.url?.isFileURL, true)
    XCTAssertEqual(settings.url?.standardizedFileURL.path, expectedURL.standardizedFileURL.path)
    XCTAssertTrue(settings.url?.absoluteString.hasPrefix("file://") ?? false)
  }

  func testBrowserTabDisplayTitleIncludesSourceTitleAndURL() throws {
    // The browser tab discovery now lives in `Plugins/{safari,firefox,
    // chromium}` — this test still exercises the host's candidate-prep
    // path (display title formatting, search-text normalisation) by
    // building the same `Candidate` shape the plugins emit.
    let candidate = Candidate(
      kind: .plugin("browser_tab"),
      sourceID: "safari-tabs",
      source: "safari",
      pid: DummyRunningApplication.app.processIdentifier,
      title: "Inbox",
      subtitle: "browser tab",
      bundleIdentifier: DummyRunningApplication.app.bundleIdentifier ?? "",
      url: URL(string: "https://mail.example.test/inbox"))
    let prepared = CandidateFinder.prepare(candidate)

    XCTAssertEqual(prepared.displayTitle, "[safari] Inbox · https://mail.example.test/inbox")
    XCTAssertTrue(prepared.normalizedSearchText.contains("safari"))
    XCTAssertTrue(prepared.normalizedSearchText.contains("mail"))
    XCTAssertTrue(prepared.normalizedSearchText.contains("example"))
  }

  func testPrefilterNeverRejectsAScoringCandidate() {
    // Soundness guard for the presence-mask prefilter: it must keep
    // every candidate the full scorer would accept, or results silently
    // vanish from the flashlight. The query set mixes exact, prefix,
    // subsequence, and typo'd spellings to exercise each scoring tier.
    let candidates = [
      candidate(
        kind: .app, source: "core.apps", name: "Finder", subtitle: "app",
        bundleIdentifier: "com.apple.finder"),
      candidate(
        kind: .app, source: "core.apps", name: "Messages", subtitle: "app",
        bundleIdentifier: "com.apple.MobileSMS"),
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "GitHub - flash",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://github.com/aymericbeaumet/flash")),
      candidate(
        kind: .plugin("tmux_window"), source: "tmux", name: "vim editor",
        subtitle: "tmux window", bundleIdentifier: ""),
      candidate(
        kind: .plugin("emoji"), source: "emoji", name: "fire", subtitle: "emoji",
        bundleIdentifier: ""),
      candidate(
        kind: .plugin("note"), source: "notes",
        name: "https://news.example.test/article-42", subtitle: "note",
        bundleIdentifier: ""),
    ].map { CandidateFinder.prepare($0) }

    let queries = [
      "f", "fi", "fir", "fire", "finder", "fnider", "mesages", "msg", "git",
      "github", "gthub", "vim", "editr", "news", "example", "42", "zzz", "xqv",
      "mes", "fox", "fierfox", "flsh", "flash", "article",
    ]

    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    for query in queries {
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(query)
      let prefilter = CandidateFinder.queryPrefilter(normalizedQuery: normalizedQuery)
      for entry in candidates {
        guard
          CandidateFinder.score(
            normalizedQuery: normalizedQuery, candidate: entry, fuzzyScore: fuzzy) != nil
        else { continue }
        XCTAssertTrue(
          CandidateFinder.passesPrefilter(prefilter, candidateMask: entry.scoringMask),
          "prefilter wrongly rejected '\(entry.title)' for query '\(query)'")
      }
    }
  }

  func testScoreMatchesEqualsNaiveScanAcrossTheParallelThreshold() {
    // The prefilter + parallel fan-out must produce exactly the scores a
    // plain sequential full scan would. The 800-candidate pool crosses
    // the parallel threshold so the concurrent path is exercised.
    let pool = (0..<800).map { i in
      CandidateFinder.prepare(
        candidate(
          kind: .plugin("emoji"), source: "emoji",
          name: "sample item \(i) fire flame", subtitle: "emoji", bundleIdentifier: ""))
    }
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    for query in ["fire", "sample", "flame", "item", "42", "fier", "zzz"] {
      let normalizedQuery = NormalModeDispatcher.normalizedSearchText(query)
      let viaEntry = CandidateFinder.scoreMatches(
        pool: pool, normalizedQuery: normalizedQuery, fuzzyScore: fuzzy)
      let naive = pool.compactMap { entry -> CandidateMatch? in
        guard
          let score = CandidateFinder.score(
            normalizedQuery: normalizedQuery, candidate: entry, fuzzyScore: fuzzy)
        else { return nil }
        return CandidateMatch(candidate: entry, score: score)
      }
      XCTAssertEqual(
        viaEntry.map(\.score), naive.map(\.score),
        "score stream diverged from naive scan for query '\(query)'")
    }
  }

  func testParseBangStateConfirmedOnTrailingSpace() {
    // The visual lock-in fires as soon as the user types whitespace
    // after the token — no need for a character after the space —
    // so `:flashlight !google ` already underlines the bang.
    let just = CandidateFinder.parseBangState("!google ")
    XCTAssertEqual(just?.token, "google")
    XCTAssertEqual(just?.confirmed, true)

    let withMore = CandidateFinder.parseBangState("!google t")
    XCTAssertEqual(withMore?.token, "google")
    XCTAssertEqual(withMore?.confirmed, true)

    let noSpace = CandidateFinder.parseBangState("!google")
    XCTAssertEqual(noSpace?.token, "google")
    XCTAssertEqual(noSpace?.confirmed, false)
  }

  func testParseAtSourceCompletionDetectsInProgressToken() {
    // Bare `@` → empty token, completion active.
    let bare = CandidateFinder.parseAtSourceCompletion("@")
    XCTAssertEqual(bare?.token, "")

    // Partial token, no whitespace yet → completion active.
    let partial = CandidateFinder.parseAtSourceCompletion("@fire")
    XCTAssertEqual(partial?.token, "fire")

    // Whitespace right after the token → already confirmed, no
    // completion (the source-filter parser takes over).
    XCTAssertNil(CandidateFinder.parseAtSourceCompletion("@firefox.tabs "))
    XCTAssertNil(CandidateFinder.parseAtSourceCompletion("@firefox.tabs gmail"))

    // Multiple `@` filters: only the last (unconfirmed) one drives
    // the completion list.
    let trailing = CandidateFinder.parseAtSourceCompletion("@notes.notes @sl")
    XCTAssertEqual(trailing?.token, "sl")

    // No `@` in the query → no completion.
    XCTAssertNil(CandidateFinder.parseAtSourceCompletion("gmail"))
  }

  func testSourceCompletionStateIgnoresBangQueriesAndCompletedSelectors() {
    XCTAssertEqual(
      CandidateFinder.sourceCompletionState(query: "@fire")?.token,
      "fire")
    XCTAssertNil(CandidateFinder.sourceCompletionState(query: "!google @fire"))
    XCTAssertNil(
      CandidateFinder.sourceCompletionState(query: "@firefox.tabs gmail"))
    XCTAssertNil(CandidateFinder.sourceCompletionState(query: "@source:fire"))
  }

  func testExpandFlashlightAliasRewritesShorthand() {
    // Keys are literal words — the sigil is part of the key. Both
    // bang aliases and source-filter aliases ride the same table.
    let aliases = [
      "!g": "!google",
      "!gh": "!github",
      "@ft": "@firefox.tabs",
    ]
    // Cursor right after the just-typed whitespace.
    let bang = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight !g ", cursorIndex: 15, aliases: aliases)
    XCTAssertEqual(bang?.text, ":flashlight !google ")
    XCTAssertEqual(bang?.cursorIndex, 20)

    // Source-filter aliases work via the same matching rule.
    let source = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight @ft ", cursorIndex: 16, aliases: aliases)
    XCTAssertEqual(source?.text, ":flashlight @firefox.tabs ")
    XCTAssertEqual(source?.cursorIndex, 26)

    // Existing canonical word is left alone.
    let canonical = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight !google ", cursorIndex: 20, aliases: aliases)
    XCTAssertNil(canonical)

    // No expansion when the preceding word isn't an alias key.
    let unrelated = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight hello ", cursorIndex: 18, aliases: aliases)
    XCTAssertNil(unrelated)

    // Non-final cursor position (user editing mid-buffer) still
    // expands when the immediately-preceding word matches.
    let middle = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight !gh foo", cursorIndex: 16, aliases: aliases)
    XCTAssertEqual(middle?.text, ":flashlight !github foo")
    XCTAssertEqual(middle?.cursorIndex, 20)

    // Empty alias map short-circuits.
    let empty = CandidateFinder.expandFlashlightAlias(
      text: ":flashlight !g ", cursorIndex: 15, aliases: [:])
    XCTAssertNil(empty)
  }

  func testParseBangRejectsNonBangQueries() {
    XCTAssertNil(CandidateFinder.parseBang(""))
    XCTAssertNil(CandidateFinder.parseBang("finder"))
    XCTAssertNil(CandidateFinder.parseBang("!"), "a bare bang has no token")
    XCTAssertNil(CandidateFinder.parseBang("! query"), "whitespace after `!` is not a token")
    XCTAssertNil(
      CandidateFinder.parseBang("!!foo"), "two `!`s in a row mean an empty token, not a bang")
    XCTAssertNil(CandidateFinder.parseBang("   "), "blank input is not a bang")
  }

  func testParseBangAcceptsBangAnywhereInInput() {
    // The bang can appear anywhere — the first `!` is the bang for the
    // whole input, and pre-bang text joins the remainder so the
    // dispatcher sees one query.
    let trailing = CandidateFinder.parseBang("foo !bar")
    XCTAssertEqual(trailing?.token, "bar")
    XCTAssertEqual(trailing?.remainder, "foo")

    let middle = CandidateFinder.parseBang("foo bar baz !google rust")
    XCTAssertEqual(middle?.token, "google")
    XCTAssertEqual(middle?.remainder, "foo bar baz rust")

    // Only the FIRST `!` is the bang — subsequent ones are literal.
    let multipleBangs = CandidateFinder.parseBang("foo !first bar !second")
    XCTAssertEqual(multipleBangs?.token, "first")
    XCTAssertEqual(multipleBangs?.remainder, "foo bar !second")
  }

  func testSelectedBangMatchesOnlyExactTypedToken() {
    XCTAssertTrue(
      CandidateFinder.selectedBangMatchesTypedToken(
        query: "!googlemaps",
        selectedToken: "googlemaps"))
    XCTAssertTrue(
      CandidateFinder.selectedBangMatchesTypedToken(
        query: "!GoogleMaps",
        selectedToken: "googlemaps"))
    XCTAssertFalse(
      CandidateFinder.selectedBangMatchesTypedToken(
        query: "!goo",
        selectedToken: "googlemaps"))
    XCTAssertFalse(
      CandidateFinder.selectedBangMatchesTypedToken(
        query: "googlemaps",
        selectedToken: "googlemaps"))
  }

  func testParseBangCapturesTokenAndRemainder() {
    let bare = CandidateFinder.parseBang("!yt")
    XCTAssertEqual(bare?.token, "yt")
    XCTAssertEqual(bare?.remainder, "")

    let args = CandidateFinder.parseBang("  !g rust language  ")
    XCTAssertEqual(args?.token, "g")
    XCTAssertEqual(args?.remainder, "rust language")

    // Multiple spaces inside the remainder are preserved (they're the
    // user's query for the bang's URL, not internal punctuation we own).
    let manySpaces = CandidateFinder.parseBang("!g  hello   world")
    XCTAssertEqual(manySpaces?.token, "g")
    XCTAssertEqual(manySpaces?.remainder, "hello   world")

    // Tabs and other whitespace also terminate the token.
    let tabAfterToken = CandidateFinder.parseBang("!g\tfoo")
    XCTAssertEqual(tabAfterToken?.token, "g")
    XCTAssertEqual(tabAfterToken?.remainder, "foo")
  }

  func testParseBangOnlyConsumesTheFirstBang() {
    // The token stops at the next `!` so subsequent bangs in the query
    // are literal — the dispatcher only ever sees one bang per submit.
    let backToBack = CandidateFinder.parseBang("!cla!u")
    XCTAssertEqual(backToBack?.token, "cla")
    XCTAssertEqual(
      backToBack?.remainder, "!u",
      "the second `!` is literal text in the remainder, not another bang")

    let separatedByWord = CandidateFinder.parseBang("!cla foo!bar")
    XCTAssertEqual(separatedByWord?.token, "cla")
    XCTAssertEqual(separatedByWord?.remainder, "foo!bar")

    let separatedBySpace = CandidateFinder.parseBang("!cla !test query")
    XCTAssertEqual(separatedBySpace?.token, "cla")
    XCTAssertEqual(separatedBySpace?.remainder, "!test query")
  }

  func testParseBangStateDistinguishesConfirmedFromOpenBang() {
    // No trailing whitespace → user is still typing the bang token; the
    // flashlight should keep showing matching bang candidates.
    let unconfirmed = CandidateFinder.parseBangState("!g")
    XCTAssertEqual(unconfirmed?.token, "g")
    XCTAssertFalse(unconfirmed?.confirmed ?? true)

    // Trailing whitespace → bang has been locked in (typed or
    // tab-completed); the flashlight must drop candidates.
    let confirmedBare = CandidateFinder.parseBangState("!g ")
    XCTAssertEqual(confirmedBare?.token, "g")
    XCTAssertTrue(confirmedBare?.confirmed ?? false)

    // Confirmation with a remainder — the user is composing the bang's
    // query argument.
    let confirmedWithArgs = CandidateFinder.parseBangState("!g rust language")
    XCTAssertEqual(confirmedWithArgs?.token, "g")
    XCTAssertTrue(confirmedWithArgs?.confirmed ?? false)
    XCTAssertEqual(confirmedWithArgs?.remainder, "rust language")

    // Even an exact match against a known bang is **not** confirmed
    // without trailing whitespace — `!google` could still be the prefix
    // of `!googlemaps`, so we let the user keep typing instead of
    // locking the bang in prematurely.
    let exactNoSpace = CandidateFinder.parseBangState("!google")
    XCTAssertEqual(exactNoSpace?.token, "google")
    XCTAssertFalse(exactNoSpace?.confirmed ?? true)

    let exactWithSpace = CandidateFinder.parseBangState("!google ")
    XCTAssertEqual(exactWithSpace?.token, "google")
    XCTAssertTrue(exactWithSpace?.confirmed ?? false)

    // A trailing `!` (another bang start) is not whitespace and must
    // not validate the first bang — it's the boundary between two
    // tokens, not a confirmation.
    let twoBangs = CandidateFinder.parseBangState("!google!foo")
    XCTAssertEqual(twoBangs?.token, "google")
    XCTAssertFalse(twoBangs?.confirmed ?? true)
  }

  func testBangDisplayTitleCarriesDescription() {
    let described = CandidateFinder.prepare(
      candidate(
        kind: .plugin("bang"), source: "bang", name: "!g",
        subtitle: "Google search", bundleIdentifier: ""))
    XCTAssertEqual(described.displayTitle, "[bang] !g (Google search)")

    let bare = CandidateFinder.prepare(
      candidate(
        kind: .plugin("bang"), source: "bang", name: "!yt",
        subtitle: "", bundleIdentifier: ""))
    XCTAssertEqual(bare.displayTitle, "[bang] !yt")
  }

  func testBrowserTabDisplayTitleUsesUnifiedDotSeparator() {
    // Browser tabs render with the same `·` rhythm as tmux candidates so
    // the flashlight list reads consistently across sources. Verified
    // with both raw URL-only candidates and title+url candidates.
    let titled = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "Gmail",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/")))
    XCTAssertEqual(titled.displayTitle, "[firefox] Gmail · https://mail.google.com/")

    // When the title is missing we fall through to URL-only display —
    // no stray trailing `·`.
    let urlOnly = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/")))
    XCTAssertEqual(urlOnly.displayTitle, "[firefox] https://mail.google.com/")
  }

  func testPrecedenceTableDefaultsUseCandidateKinds() {
    // Fallbacks use semantic candidate kinds, so code paths that score
    // without the live registry still keep the same visible order:
    // bangs > tmux > browser tabs > active apps > inactive apps > rest.
    let bang = candidate(
      kind: .plugin("bang"), source: "bang", name: "!g",
      subtitle: "", bundleIdentifier: "")
    let tmux = candidate(
      kind: .plugin("tmux_window"), source: "tmux.windows", name: "scratch:1",
      subtitle: "tmux", bundleIdentifier: "")
    let tab = candidate(
      kind: .plugin("browser_tab"), source: "firefox.tabs", name: "Gmail",
      subtitle: "browser tab", bundleIdentifier: "", pid: 100)
    let activeApp = candidate(
      kind: .app, source: "core.apps", name: "Safari",
      subtitle: "app", bundleIdentifier: "com.apple.Safari", pid: 4242)
    let inactiveApp = candidate(
      kind: .app, source: "core.apps", name: "Notes",
      subtitle: "app", bundleIdentifier: "com.apple.notes")
    let note = candidate(
      kind: .plugin("note"), source: "notes.notes", name: "shopping",
      subtitle: "note", bundleIdentifier: "")

    let table = CandidateFinder.PrecedenceTable.default
    XCTAssertEqual(table.weight(for: bang), CandidateFinder.PrecedenceTable.bangWeight)
    XCTAssertEqual(table.weight(for: tmux), 100)
    XCTAssertEqual(table.weight(for: tab), 90)  // 80 + alive bonus
    XCTAssertEqual(table.weight(for: activeApp), 50)  // 40 + alive bonus
    XCTAssertEqual(table.weight(for: inactiveApp), 40)
    XCTAssertEqual(table.weight(for: note), 0)
  }

  func testPrecedenceTableHonoursLongestPatternFirst() {
    // A user can pin a sub-source above its parent: `firefox.bookmarks`
    // > `firefox`. Longer pattern wins regardless of dict ordering.
    let table = CandidateFinder.PrecedenceTable(
      sources: [CandidateSourceDescriptor(name: "firefox", kind: .browserTabs)],
      overrides: ["firefox.bookmarks": 120],
      aliveBonus: 0)
    let tab = candidate(
      kind: .plugin("browser_tab"), source: "firefox.tabs", name: "Gmail",
      subtitle: "tab", bundleIdentifier: "")
    let bookmark = candidate(
      kind: .plugin("bookmark"), source: "firefox.bookmarks", name: "Inbox",
      subtitle: "bookmark", bundleIdentifier: "")
    XCTAssertEqual(table.weight(for: tab), 80)
    XCTAssertEqual(table.weight(for: bookmark), 120)
  }

  func testPrecedenceTableUsesSourceDescriptors() {
    let table = CandidateFinder.PrecedenceTable(
      sources: [
        CandidateSourceDescriptor(name: "terminal.windows", kind: .tmuxTabs),
        CandidateSourceDescriptor(name: "web.pages", kind: .browserTabs),
      ],
      overrides: [:],
      aliveBonus: 0)
    let terminal = candidate(
      kind: .plugin("window"), source: "terminal.windows", name: "scratch:1",
      subtitle: "window", bundleIdentifier: "")
    let web = candidate(
      kind: .plugin("page"), source: "web.pages", name: "Inbox",
      subtitle: "page", bundleIdentifier: "")

    XCTAssertEqual(table.weight(for: terminal), 100)
    XCTAssertEqual(table.weight(for: web), 80)
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(terminal, precedence: table))
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(web, precedence: table))
  }

  func testDefaultFlashlightVisibilityUsesDescriptorsWithoutTreatingOverridesAsOptIn() {
    let table = CandidateFinder.PrecedenceTable(
      sources: [
        CandidateSourceDescriptor(name: "terminal.windows", kind: .tmuxTabs),
        CandidateSourceDescriptor(name: "notes.notes", kind: .standard),
      ],
      overrides: [
        "terminal.windows": 5,
        "bookmarks": 500,
      ],
      aliveBonus: 0)
    let terminal = candidate(
      kind: .plugin("window"), source: "terminal.windows", name: "scratch:1",
      subtitle: "window", bundleIdentifier: "")
    let note = candidate(
      kind: .plugin("note"), source: "notes.notes", name: "shopping",
      subtitle: "note", bundleIdentifier: "")
    let bookmark = candidate(
      kind: .plugin("bookmark"), source: "bookmarks", name: "Inbox",
      subtitle: "bookmark", bundleIdentifier: "")

    XCTAssertEqual(table.weight(for: terminal), 5)
    XCTAssertEqual(table.weight(for: bookmark), 500)
    XCTAssertTrue(CandidateFinder.isDefaultFlashlightCandidate(terminal, precedence: table))
    XCTAssertFalse(CandidateFinder.isDefaultFlashlightCandidate(note, precedence: table))
    XCTAssertFalse(CandidateFinder.isDefaultFlashlightCandidate(bookmark, precedence: table))
  }

  func testInsertsTextOnlyForEmojiKind() {
    // `app_open?name=` resolution skips text-insertion candidates so a
    // glyph in the emoji pool can't be typed into the focused field.
    // Bangs are not "text insertion" — selecting one canonicalizes the
    // buffer in the flashlight, not the focused app.
    let emoji = candidate(
      kind: .plugin("emoji"), source: "emoji", name: "fire",
      subtitle: "emoji", bundleIdentifier: "")
    let bang = candidate(
      kind: .plugin("bang"), source: "bang", name: "!g",
      subtitle: "", bundleIdentifier: "")
    let app = candidate(
      kind: .app, source: "core.apps", name: "Safari",
      subtitle: "app", bundleIdentifier: "com.apple.Safari")
    XCTAssertTrue(CandidateFinder.insertsText(emoji))
    XCTAssertFalse(CandidateFinder.insertsText(bang))
    XCTAssertFalse(CandidateFinder.insertsText(app))
  }

  func testCandidateFinderScoreReturnsNilForUnmatchableQuery() {
    let safari = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "core.apps", name: "Safari",
        subtitle: "app", bundleIdentifier: "com.apple.Safari"))
    XCTAssertNotNil(CandidateFinder.score(query: "safari", candidate: safari))
    XCTAssertNotNil(CandidateFinder.score(query: "saf", candidate: safari))
    // Letters not in the candidate's presence mask should reject via the
    // prefilter without invoking the full scorer.
    XCTAssertNil(
      CandidateFinder.score(query: "xqz", candidate: safari),
      "letters missing from the candidate fail the presence-mask prefilter")
  }

  func testCandidateFinderScoreUsesUrlFieldForDomainQueries() throws {
    // The URL field is searchable so `:flashlight gmail.com` ranks a
    // tab whose URL contains the domain even when the title doesn't
    // mention it — this is the workhorse for "switch to that tab"
    // muscle memory.
    let tab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox", name: "Inbox",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox",
        pid: 4242,
        url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))
    let titleQuery = try XCTUnwrap(CandidateFinder.score(query: "Inbox", candidate: tab))
    let urlQuery = try XCTUnwrap(CandidateFinder.score(query: "gmail.com", candidate: tab))
    XCTAssertGreaterThan(titleQuery, 0)
    XCTAssertGreaterThan(urlQuery, 0)
  }

  func testEmojiAliasScoresAboveUnicodeNameMatches() throws {
    // Slack-style shortcode aliases are a dedicated high tier. Typing
    // `pray` should surface 🙏 from its alias before Unicode names like
    // "prayer beads" that merely prefix-match the query.
    let foldedHands = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"),
        source: "emojis.glyphs",
        name: "🙏 folded hands",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "pray prayer thanks"))
    let prayerBeads = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"),
        source: "emojis.glyphs",
        name: "📿 prayer beads",
        subtitle: "emoji",
        bundleIdentifier: ""))

    let foldedScore = try XCTUnwrap(CandidateFinder.score(query: "pray", candidate: foldedHands))
    let beadsScore = try XCTUnwrap(CandidateFinder.score(query: "pray", candidate: prayerBeads))
    XCTAssertGreaterThan(foldedScore, beadsScore)

    let sorted = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: prayerBeads, score: beadsScore),
      CandidateMatch(candidate: foldedHands, score: foldedScore),
    ])
    XCTAssertEqual(sorted.map(\.candidate.title), ["🙏 folded hands", "📿 prayer beads"])
  }

  func testEmojiCandidatesWithoutLocalColorGlyphAreHiddenFromCommandBar() {
    let supported = Candidate(
      kind: CandidateFinder.emojiKind,
      sourceID: "plugin:emojis",
      source: "emojis.glyphs",
      title: "🙏 person with folded hands",
      subtitle: "emoji",
      sourcePayload: "🙏")
    let unsupported = Candidate(
      kind: CandidateFinder.emojiKind,
      sourceID: "plugin:emojis",
      source: "emojis.glyphs",
      title: "🕲 no piracy",
      subtitle: "emoji",
      sourcePayload: "🕲")

    XCTAssertTrue(AppDelegate.candidateCanRenderInCommandBar(supported))
    XCTAssertFalse(AppDelegate.candidateCanRenderInCommandBar(unsupported))
  }

  func testEmojiAliasPreparationTokenizesNormalizedAliases() throws {
    let candidate = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"),
        source: "emojis.glyphs",
        name: "😂 face with tears of joy",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "joy lol cry_laugh"))

    XCTAssertEqual(
      candidate.normalizedScoringFields.titleTokens, ["face", "with", "tears", "of", "joy"])
    XCTAssertEqual(candidate.normalizedScoringFields.aliases, ["joy", "lol", "cry", "laugh"])
    XCTAssertNotNil(CandidateFinder.score(query: "joy", candidate: candidate))
    XCTAssertNotNil(CandidateFinder.score(query: "cry", candidate: candidate))
    XCTAssertNotNil(CandidateFinder.score(query: "laugh", candidate: candidate))
  }

  func testExpandEmoticonsRewritesStandaloneTokens() {
    // The faces the user asked for, with and without noses, plus a couple of
    // case-folded and multi-token forms.
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(":)"), "slightly_smiling_face")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(":-)"), "slightly_smiling_face")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(":("), "slightly_frowning_face")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(":-("), "slightly_frowning_face")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(";)"), "wink")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(";-)"), "wink")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons(":D"), "grinning")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons("XD"), "laughing")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons("<3"), "heart")
    // Ordinary queries are untouched (and skip the work via the punctuation
    // guard), including a colon that isn't a standalone emoticon.
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons("fire"), "fire")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons("slack general"), "slack general")
    XCTAssertEqual(NormalModeDispatcher.expandEmoticons("foo:bar"), "foo:bar")
    // Only the emoticon token is rewritten in a mixed query.
    XCTAssertEqual(
      NormalModeDispatcher.expandEmoticons("happy :)"), "happy slightly_smiling_face")
  }

  func testEmoticonQuerySurfacesIntendedGlyph() throws {
    // End-to-end: mirror the coordinator pipeline (expand → score → sort) and
    // assert each emoticon ranks its intended glyph first.
    let smiling = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"), source: "emojis.glyphs", name: "🙂 slightly smiling face",
        subtitle: "emoji", bundleIdentifier: "", searchAliases: "slightly_smiling_face"))
    let frowning = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"), source: "emojis.glyphs", name: "🙁 slightly frowning face",
        subtitle: "emoji", bundleIdentifier: "", searchAliases: "slightly_frowning_face"))
    let winking = CandidateFinder.prepare(
      candidate(
        kind: .plugin("emoji"), source: "emojis.glyphs", name: "😉 winking face",
        subtitle: "emoji", bundleIdentifier: "", searchAliases: "wink winking"))
    let pool = [smiling, frowning, winking]

    func topGlyph(for emoticon: String) throws -> String {
      let query = NormalModeDispatcher.expandEmoticons(emoticon)
      let scored = pool.compactMap { candidate -> CandidateMatch? in
        guard let score = CandidateFinder.score(query: query, candidate: candidate) else {
          return nil
        }
        return CandidateMatch(candidate: candidate, score: score)
      }
      return try XCTUnwrap(CandidateFinder.sortedMatches(scored).first).candidate.title
    }

    XCTAssertEqual(try topGlyph(for: ":)"), "🙂 slightly smiling face")
    XCTAssertEqual(try topGlyph(for: ":-)"), "🙂 slightly smiling face")
    XCTAssertEqual(try topGlyph(for: ":("), "🙁 slightly frowning face")
    XCTAssertEqual(try topGlyph(for: ":-("), "🙁 slightly frowning face")
    XCTAssertEqual(try topGlyph(for: ";)"), "😉 winking face")
    XCTAssertEqual(try topGlyph(for: ";-)"), "😉 winking face")
  }

  func testSourceCompletionCandidateHasStableShapeAndRanksByToken() throws {
    let firefox = CandidateFinder.prepare(
      CandidateFinder.sourceCompletionCandidate("firefox.tabs"))
    let slack = CandidateFinder.prepare(
      CandidateFinder.sourceCompletionCandidate("slack.channels"))

    XCTAssertEqual(firefox.kind, CandidateFinder.sourceKind)
    XCTAssertEqual(firefox.source, "source")
    XCTAssertEqual(firefox.sourcePayload, "firefox.tabs")
    XCTAssertEqual(firefox.displayTitle, "[source] @firefox.tabs")
    XCTAssertNil(firefox.url)
    XCTAssertFalse(firefox.finishesCommand)

    let query = NormalModeDispatcher.normalizedSearchText("fire")
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let matches = CandidateFinder.scoreMatches(
      pool: [slack, firefox],
      normalizedQuery: query,
      fuzzyScore: fuzzy,
      allowParallel: false)
    let sorted = CandidateFinder.sortedMatches(matches)
    XCTAssertEqual(sorted.first?.candidate.sourcePayload, "firefox.tabs")
  }

  func testCommandInsertionTextUsesCanonicalTokensAndSourceQualifiedTitles() {
    XCTAssertEqual(
      CandidateFinder.commandInsertionText(
        CandidateFinder.sourceCompletionCandidate("firefox.tabs")),
      "@firefox.tabs ")
    XCTAssertEqual(
      CandidateFinder.commandInsertionText(
        candidate(
          kind: CandidateFinder.bangKind,
          source: "bang",
          name: "!google",
          subtitle: "Google search",
          bundleIdentifier: "",
          sourcePayload: "google")),
      "!google ")
    XCTAssertEqual(
      CandidateFinder.commandInsertionText(
        candidate(
          kind: .app,
          source: "core.apps",
          name: "Messages",
          subtitle: "app",
          bundleIdentifier: "com.apple.MobileSMS")),
      "@apps Messages ")
    XCTAssertEqual(
      CandidateFinder.commandInsertionText(
        candidate(
          kind: .plugin("browser_tab"),
          source: "firefox",
          name: "Gmail",
          subtitle: "browser tab",
          bundleIdentifier: "org.mozilla.firefox")),
      "@firefox Gmail ")
  }

  func testCandidateSelectionFinishesForFinalDestinationsMarkedRowsAndExactPrimaryTitle() {
    let app = candidate(
      kind: .app,
      source: "core.apps",
      name: "Messages",
      subtitle: "app",
      bundleIdentifier: "com.apple.MobileSMS")
    let tmux = candidate(
      kind: .plugin("tmux_window"),
      source: "tmux.windows",
      name: "scratch:1 flash",
      subtitle: "scratch:1 · zsh · ~/workspace/flash",
      bundleIdentifier: "")
    let browserTab = candidate(
      kind: CandidateFinder.browserTabKind,
      source: "firefox.tabs",
      name: "Gmail",
      subtitle: "browser tab",
      bundleIdentifier: "org.mozilla.firefox")

    XCTAssertTrue(CandidateFinder.isFinalDestination(app))
    XCTAssertTrue(CandidateFinder.selectionFinishes(app, query: "mes"))
    XCTAssertTrue(CandidateFinder.selectionFinishes(app, query: "@apps Messages "))
    XCTAssertTrue(CandidateFinder.isFinalDestination(browserTab))
    XCTAssertTrue(CandidateFinder.selectionFinishes(browserTab, query: "gmail"))
    XCTAssertTrue(CandidateFinder.isFinalDestination(tmux))
    XCTAssertTrue(CandidateFinder.selectionFinishes(tmux, query: "scr"))
    var source = CandidateFinder.sourceCompletionCandidate("tmux.windows")
    source.metadata[CandidateMetadataKey.finishesCommand] = "1"
    XCTAssertFalse(CandidateFinder.isFinalDestination(source))
    XCTAssertFalse(CandidateFinder.selectionFinishes(source, query: "@tmux"))
    XCTAssertFalse(CandidateFinder.selectionFinishes(source, query: "@tmux.windows "))
    XCTAssertTrue(
      CandidateFinder.selectionFinishes(
        candidate(
          kind: .plugin("notes.note"),
          source: "notes",
          name: "Inbox",
          subtitle: "note",
          bundleIdentifier: "",
          finishesCommand: true),
        query: "in"))
    XCTAssertTrue(
      CandidateFinder.selectionFinishes(
        candidate(
          kind: CandidateFinder.emojiKind,
          source: "emoji",
          name: "grinning face",
          subtitle: "emoji",
          bundleIdentifier: "",
          sourcePayload: "😀"),
        query: "grin"))
  }

  func testTabSelectionSubmitsOnlyFinalDestinationRowsIncludingBrowserTabs() {
    let app = candidate(
      kind: .app,
      source: "core.apps",
      name: "System Settings",
      subtitle: "app",
      bundleIdentifier: "com.apple.systempreferences")
    let tmux = candidate(
      kind: .plugin("tmux_window"),
      source: "tmux.windows",
      name: "scratch:1 flash",
      subtitle: "scratch:1 · zsh · ~/workspace/flash",
      bundleIdentifier: "")
    let browserTab = candidate(
      kind: .plugin("browser_tab"),
      source: "firefox.tabs",
      name: "System Design",
      subtitle: "browser tab",
      bundleIdentifier: "org.mozilla.firefox")
    var source = CandidateFinder.sourceCompletionCandidate("tmux.windows")
    source.metadata[CandidateMetadataKey.finishesCommand] = "1"

    XCTAssertTrue(
      CandidateFinder.selectionSubmits(
        app,
        query: "syst",
        submit: false,
        allowFinisher: false,
        submitFinalDestinations: true))
    XCTAssertTrue(
      CandidateFinder.selectionSubmits(
        tmux,
        query: "flash",
        submit: false,
        allowFinisher: false,
        submitFinalDestinations: true))
    XCTAssertTrue(
      CandidateFinder.selectionSubmits(
        browserTab,
        query: "system",
        submit: false,
        allowFinisher: false,
        submitFinalDestinations: true))
    XCTAssertFalse(
      CandidateFinder.selectionSubmits(
        source,
        query: "@tmux",
        submit: false,
        allowFinisher: false,
        submitFinalDestinations: true))
  }

  func testBangCompletionStateAcceptsBareBangAndRejectsConfirmedBang() {
    let bare = CandidateFinder.bangCompletionState(query: "!")
    XCTAssertEqual(bare?.token, "")

    let partial = CandidateFinder.bangCompletionState(query: "!fire")
    XCTAssertEqual(partial?.token, "fire")

    XCTAssertNil(CandidateFinder.bangCompletionState(query: "!fire "))
    XCTAssertNil(CandidateFinder.bangCompletionState(query: "! fire"))
  }

  func testPrimaryTitleOutranksExactSecondaryMatch() throws {
    let primary = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"),
        source: "firefox.tabs",
        name: "Fire notes",
        subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://example.test/notes")))
    let secondary = CandidateFinder.prepare(
      candidate(
        kind: .plugin("tmux_window"),
        source: "tmux.windows",
        name: "scratch",
        subtitle: "fire",
        bundleIdentifier: ""))

    let primaryScore = try XCTUnwrap(CandidateFinder.score(query: "fire", candidate: primary))
    let secondaryScore = try XCTUnwrap(CandidateFinder.score(query: "fire", candidate: secondary))

    XCTAssertGreaterThan(primaryScore, secondaryScore)
  }

  func testSourceNameQueryRanksAllTmuxWindowsBeforeUnrelatedFuzzyHits() {
    let tmuxRows = [
      ("btop", "headquarter:1 · btop · ~/workspace/aymericbeaumet/flash"),
      ("nvtop", "headquarter:2 · nvtop · ~/workspace/aymericbeaumet/flash"),
      ("lazydocker", "headquarter:3 · zsh · ~/workspace/aymericbeaumet/flash"),
      (".dotfiles", "scratch:1 · ssh · ~/.dotfiles"),
      ("flash", "scratch:2 · node · ~/workspace/aymericbeaumet/flash"),
      ("moria", "scratch:3 · claude.exe · ~/workspace/aymericbeaumet/moria"),
      ("beside-agentic", "beside:1 · codex-aarch64-a · ~/workspace/beside/beside-agentic"),
    ].map { title, subtitle in
      CandidateFinder.prepare(
        candidate(
          kind: .plugin("tmux_window"),
          source: "tmux.windows",
          name: title,
          subtitle: subtitle,
          bundleIdentifier: "",
          pid: 4242))
    }
    let noise = [
      CandidateFinder.prepare(
        candidate(
          kind: CandidateFinder.browserTabKind,
          source: "safari.tabs",
          name: "Numbers | CallRail",
          subtitle: "browser tab",
          bundleIdentifier: "com.apple.Safari",
          url: URL(string: "https://app.callrail.com/settings/a/215502720/routing/calls"))),
      CandidateFinder.prepare(
        candidate(
          kind: .app,
          source: "core.apps",
          name: "TextInputMenuAgent",
          subtitle: "app",
          bundleIdentifier: "com.apple.TextInputMenuAgent")),
    ]
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let matches = CandidateFinder.scoreMatches(
      pool: tmuxRows + noise,
      normalizedQuery: NormalModeDispatcher.normalizedSearchText("tmux"),
      fuzzyScore: fuzzy,
      allowParallel: false)
    let sorted = CandidateFinder.sortedMatches(matches, limit: 10)

    XCTAssertEqual(sorted.prefix(tmuxRows.count).map(\.candidate.source), tmuxRows.map(\.source))
    XCTAssertTrue(
      sorted.dropFirst(tmuxRows.count).allSatisfy { $0.candidate.source != "tmux.windows" })
  }

  func testIncrementalCacheKeepsRowsOutsideDisplayLimitForLongerSourceQuery() {
    let tmuxRows = [
      ".dotfiles", "flash", "moria", "beside-agentic",
    ].map { title in
      CandidateFinder.prepare(
        candidate(
          kind: .plugin("tmux_window"),
          source: "tmux.windows",
          name: title,
          subtitle: "scratch:1 · zsh · ~/workspace/\(title)",
          bundleIdentifier: "",
          pid: 4242))
    }
    let topNoise = (0..<40).map { index in
      CandidateMatch(
        candidate: CandidateFinder.prepare(
          candidate(
            kind: .plugin("tmux_window"),
            source: "tmux.windows",
            name: "temporary noise \(index)",
            subtitle: "scratch:\(index) · zsh · /tmp/noise",
            bundleIdentifier: "",
            pid: pid_t(index + 1000))),
        score: 20_000 - index)
    }
    let firstKeystrokeMatches =
      topNoise
      + tmuxRows.map { CandidateMatch(candidate: $0, score: 1_000) }

    let ranked = CandidateFinder.displayAndIncrementalMatches(
      firstKeystrokeMatches,
      limit: 10)

    XCTAssertFalse(
      ranked.display.contains { match in
        tmuxRows.contains { $0.title == match.candidate.title }
      })
    XCTAssertEqual(ranked.incremental.count, firstKeystrokeMatches.count)

    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let narrowed = CandidateFinder.scoreMatches(
      pool: ranked.incremental.map(\.candidate),
      normalizedQuery: NormalModeDispatcher.normalizedSearchText("moria"),
      fuzzyScore: fuzzy,
      allowParallel: false)
    let sorted = CandidateFinder.sortedMatches(narrowed, limit: 10)

    XCTAssertEqual(sorted.first?.candidate.title, "moria")
  }

  func testTmuxWindowDisplayShowsPrimaryTitleBeforeSecondaryMetadata() {
    let tmux = CandidateFinder.prepare(
      candidate(
        kind: .plugin("tmux_window"),
        source: "tmux.windows",
        name: "flash",
        subtitle: "scratch:2 · zsh · ~/workspace/flash",
        bundleIdentifier: ""))

    XCTAssertEqual(
      tmux.displayTitle,
      "[tmux.windows] flash · scratch:2 · zsh · ~/workspace/flash")
  }

  func testBoundedSortMatchesFullSortPrefixForFlashlightMix() {
    var pool: [CandidateMatch] = []
    let names = [
      ("core.apps", CandidateKind.app, "Messages", pid_t(42)),
      ("core.apps", CandidateKind.app, "System Settings", nil),
      ("firefox.tabs", CandidateKind.plugin("browser_tab"), "Gmail", pid_t(55)),
      ("tmux", CandidateKind.plugin("tmux_window"), "scratch:1 flash", pid_t(77)),
      ("notes.notes", CandidateKind.plugin("note"), "Flash notes", nil),
      ("bang", CandidateFinder.bangKind, "!google", nil),
      ("emojis.glyphs", CandidateFinder.emojiKind, "🔥 fire", nil),
    ]
    for i in 0..<120 {
      let item = names[i % names.count]
      let candidate = CandidateFinder.prepare(
        candidate(
          kind: item.1,
          source: item.0,
          name: "\(item.2) \(i)",
          subtitle: "test",
          bundleIdentifier: item.0,
          pid: item.3))
      pool.append(CandidateMatch(candidate: candidate, score: 10_000 - (i % 17)))
    }

    let full = CandidateFinder.sortedMatches(pool)
    for limit in [1, 2, 5, 17, 64] {
      let bounded = CandidateFinder.sortedMatches(pool, limit: limit)
      XCTAssertEqual(
        bounded.map(\.candidate.sourceID),
        full.prefix(limit).map(\.candidate.sourceID),
        "bounded sort diverged from full sorted prefix at limit \(limit)")
      XCTAssertEqual(
        bounded.map(\.candidate.title),
        full.prefix(limit).map(\.candidate.title),
        "bounded sort returned a different candidate order at limit \(limit)")
    }
    XCTAssertTrue(CandidateFinder.sortedMatches(pool, limit: 0).isEmpty)
  }

  func testSequentialAndParallelScoreMatchesAgreeForEmojiPool() {
    let pool = (0..<900).map { i in
      CandidateFinder.prepare(
        candidate(
          kind: CandidateFinder.emojiKind,
          source: "emojis.glyphs",
          name: "emoji sample \(i) fire flame heart",
          subtitle: "emoji",
          bundleIdentifier: "",
          searchAliases: i % 3 == 0 ? "spark hot" : ""))
    }
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    for query in ["fire", "flame", "spark", "heart", "sample 42", "zzz"] {
      let normalized = NormalModeDispatcher.normalizedSearchText(query)
      let parallel = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalized,
        fuzzyScore: fuzzy,
        allowParallel: true)
      let sequential = CandidateFinder.scoreMatches(
        pool: pool,
        normalizedQuery: normalized,
        fuzzyScore: fuzzy,
        allowParallel: false)
      XCTAssertEqual(
        sequential.map(\.candidate.title),
        parallel.map(\.candidate.title),
        "sequential and parallel candidate streams diverged for \(query)")
      XCTAssertEqual(
        sequential.map(\.score),
        parallel.map(\.score),
        "sequential and parallel scores diverged for \(query)")
    }
  }

  // MARK: - @<source> narrow

  func testSourceFilterParsesAtSourceAndPreservesResidualText() {
    let none = NormalModeDispatcher.candidateFinderSourceFilter("inbox")
    XCTAssertNil(none.sourceFilter)
    XCTAssertEqual(none.text, "inbox")

    let bare = NormalModeDispatcher.candidateFinderSourceFilter("@firefox.tabs gmail")
    XCTAssertEqual(bare.sourceFilter, "firefox.tabs")
    XCTAssertEqual(bare.text, "gmail")

    // Just a confirmed source with no residual — lists every candidate from
    // that source.
    let empty = NormalModeDispatcher.candidateFinderSourceFilter("@emojis.glyphs ")
    XCTAssertEqual(empty.sourceFilter, "emojis.glyphs")
    XCTAssertEqual(empty.text, "")

    // Bare `@` (no token) is not a source filter.
    let dangling = NormalModeDispatcher.candidateFinderSourceFilter("@")
    XCTAssertNil(dangling.sourceFilter)
    XCTAssertEqual(dangling.text, "@")
  }

  func testCandidateMatchesSourceFilterAcceptsExactAndPrefix() {
    let firefoxTabs = candidate(
      kind: .plugin("browser_tab"), source: "firefox.tabs",
      name: "Inbox", subtitle: "browser tab",
      bundleIdentifier: "org.mozilla.firefox",
      url: URL(string: "https://mail.example.test/"))
    let app = candidate(
      kind: .app, source: "core.apps",
      name: "Safari", subtitle: "app",
      bundleIdentifier: "com.apple.Safari")

    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTabs, filter: "firefox.tabs"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTabs, filter: "firefox"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(app, filter: "apps"))
    XCTAssertFalse(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTabs, filter: "safari"))
  }

  private func candidate(
    kind: CandidateKind,
    source: String,
    name: String,
    subtitle: String,
    bundleIdentifier: String,
    pid: pid_t? = nil,
    url: URL? = nil,
    sourcePayload: String? = nil,
    searchAliases: String = "",
    finishesCommand: Bool = false
  ) -> Candidate {
    Candidate(
      kind: kind,
      sourceID: source,
      source: source,
      pid: pid,
      title: name,
      subtitle: subtitle,
      bundleIdentifier: bundleIdentifier,
      url: url,
      sourcePayload: sourcePayload,
      searchAliases: searchAliases,
      finishesCommand: finishesCommand)
  }
}

private enum DummyRunningApplication {
  static var app: NSRunningApplication {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil }
      ?? NSRunningApplication.current
  }
}

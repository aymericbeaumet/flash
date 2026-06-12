import AppKit
import FlashCore
import XCTest

@testable import flash

final class SourceCandidateTests: XCTestCase {
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

    XCTAssertEqual(sorted.map(\.candidate.name), ["Zulu", "Alpha"])
  }

  func testStrongerMatchWinsOverWeakerMatchAcrossSources() throws {
    // Score is the primary ordering: a stronger fuzzy match on an app
    // beats a weaker match on a browser tab even though the tab's tier
    // is technically higher. Tier is consulted only when scores agree.
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

    // Whichever candidate scores higher comes first.
    let expectedFirst = deadScore >= aliveScore ? "Finder Pro" : "Finder notes"
    XCTAssertEqual(sorted.first?.candidate.name, expectedFirst)
  }

  func testStrongerScoredAppOutranksWeakerBrowserTab() throws {
    // The motivating regression: typing `mes` must surface the
    // `Messages` app (full-string prefix on the app name) above a
    // browser tab whose title merely contains `mes`. The earlier
    // strict-tier sort buried the app under any tab; match quality
    // must lead.
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
    XCTAssertEqual(sorted.map(\.candidate.name), ["Messages", "Important message inbox"])
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

    // But when scores differ, the higher score wins regardless of tier:
    // the matcher's view of relevance is authoritative.
    let scoreDrivenOrder = CandidateFinder.sortedMatches([
      CandidateMatch(candidate: browserTab, score: 14_000),
      CandidateMatch(candidate: tmuxWindow, score: 10_120),
    ])
    XCTAssertEqual(scoreDrivenOrder.map(\.candidate.source), ["firefox", "tmux"])
  }

  func testFlashlightTieBreakOrderBangTmuxBrowserActiveAppInactiveAppThenRest() {
    // At equal scores the tier order settles the tie. Bangs are the
    // only STRICT band: they always come above non-bangs, score
    // independent. Other tiers (tmux > browser > active app > inactive
    // app > rest) only matter on score ties.
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
      CandidateMatch(candidate: bang, score: 0),
    ])

    XCTAssertEqual(
      sorted.map(\.candidate.name),
      ["z-bang", "z-tmux", "z-tab", "z-active", "z-inactive", "z-note"])
  }

  func testCandidateMatchesSourceFilterDottedConvention() {
    // Sources follow `<plugin>.<subsource>`. The filter matches:
    //   - exact (`@notes.notes` == `notes.notes`)
    //   - parent prefix (`@notes` matches `notes.notes`, `notes.tags`, …)
    //   - group aliases (`@tabs` folds every `*.tabs`)
    // Loose substrings (`@note` against `notes.notes`) no longer
    // match — explicit aliases handle the shorthand case.
    let note = CandidateFinder.prepare(
      candidate(
        kind: .plugin("note"), source: "notes.notes", name: "Inbox",
        subtitle: "note", bundleIdentifier: ""))
    let firefoxTab = CandidateFinder.prepare(
      candidate(
        kind: .plugin("browser_tab"), source: "firefox.tabs", name: "Gmail",
        subtitle: "browser tab", bundleIdentifier: "org.mozilla.firefox"))
    let app = CandidateFinder.prepare(
      candidate(
        kind: .app, source: "core.apps", name: "Finder",
        subtitle: "app", bundleIdentifier: "com.apple.finder"))

    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(note, filter: "notes.notes"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(note, filter: "notes"))
    XCTAssertFalse(
      CandidateFinder.candidateMatchesSourceFilter(note, filter: "note"))
    XCTAssertFalse(
      CandidateFinder.candidateMatchesSourceFilter(note, filter: "app"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "firefox.tabs"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "firefox"))
    XCTAssertFalse(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "fire"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "browser"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(firefoxTab, filter: "tabs"))
    XCTAssertTrue(
      CandidateFinder.candidateMatchesSourceFilter(app, filter: "apps"))
    XCTAssertFalse(
      CandidateFinder.candidateMatchesSourceFilter(app, filter: "browser"))
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

    XCTAssertEqual(sorted.map(\.candidate.name), ["System Settings", "Messages"])
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

    XCTAssertEqual(sorted.map(\.candidate.name), ["!yt", "YouTube"])
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
          "prefilter wrongly rejected '\(entry.name)' for query '\(query)'")
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

  func testPrecedenceTableDefaultsMirrorPreviousOrder() {
    // Defaults preserve the prior hard-coded ladder so users who
    // never touch `[flashlight.precedence]` see the same flashlight
    // ordering: bangs > tmux > browser tabs > active apps > inactive
    // apps > everything else.
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
    XCTAssertEqual(table.weight(for: tab), 90)         // 80 + alive bonus
    XCTAssertEqual(table.weight(for: activeApp), 50)   // 40 + alive bonus
    XCTAssertEqual(table.weight(for: inactiveApp), 40)
    XCTAssertEqual(table.weight(for: note), 0)
  }

  func testPrecedenceTableHonoursLongestPatternFirst() {
    // A user can pin a sub-source above its parent: `firefox.bookmarks`
    // > `firefox`. Longer pattern wins regardless of dict ordering.
    let table = CandidateFinder.PrecedenceTable(
      weights: ["firefox": 80, "firefox.bookmarks": 120],
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
    XCTAssertEqual(sorted.map(\.candidate.name), ["🙏 folded hands", "📿 prayer beads"])
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

    XCTAssertEqual(candidate.normalizedScoringFields.titleTokens, ["face", "with", "tears", "of", "joy"])
    XCTAssertEqual(candidate.normalizedScoringFields.aliases, ["joy", "lol", "cry", "laugh"])
    XCTAssertNotNil(CandidateFinder.score(query: "joy", candidate: candidate))
    XCTAssertNotNil(CandidateFinder.score(query: "cry", candidate: candidate))
    XCTAssertNotNil(CandidateFinder.score(query: "laugh", candidate: candidate))
  }

  func testEmojiMatchesUseAliasTierAndBoundedResults() {
    let foldedHands = CandidateFinder.prepare(
      candidate(
        kind: CandidateFinder.emojiKind,
        source: "emojis.glyphs",
        name: "🙏 folded hands",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "pray prayer thanks"))
    let prayerBeads = CandidateFinder.prepare(
      candidate(
        kind: CandidateFinder.emojiKind,
        source: "emojis.glyphs",
        name: "📿 prayer beads",
        subtitle: "emoji",
        bundleIdentifier: ""))
    let fire = CandidateFinder.prepare(
      candidate(
        kind: CandidateFinder.emojiKind,
        source: "emojis.glyphs",
        name: "🔥 fire",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "flame hot"))

    let matches = CandidateFinder.emojiMatches(
      pool: [prayerBeads, fire, foldedHands],
      normalizedQuery: NormalModeDispatcher.normalizedSearchText("pray"),
      limit: 1)

    XCTAssertEqual(matches.map(\.candidate.name), ["🙏 folded hands"])
  }

  func testEmojiMatchesKeepCheapTypoTolerance() {
    let fire = CandidateFinder.prepare(
      candidate(
        kind: CandidateFinder.emojiKind,
        source: "emojis.glyphs",
        name: "🔥 fire",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "flame hot"))
    let grin = CandidateFinder.prepare(
      candidate(
        kind: CandidateFinder.emojiKind,
        source: "emojis.glyphs",
        name: "😀 grinning face",
        subtitle: "emoji",
        bundleIdentifier: "",
        searchAliases: "grin smile"))

    let aliasTypo = CandidateFinder.emojiMatches(
      pool: [fire, grin],
      normalizedQuery: NormalModeDispatcher.normalizedSearchText("flme"),
      limit: 5)
    XCTAssertEqual(aliasTypo.first?.candidate.name, "🔥 fire")

    let titleTypo = CandidateFinder.emojiMatches(
      pool: [fire, grin],
      normalizedQuery: NormalModeDispatcher.normalizedSearchText("grinnng"),
      limit: 5)
    XCTAssertEqual(titleTypo.first?.candidate.name, "😀 grinning face")
  }

  func testEmojiMatchesFastOnLargePool() {
    let pool = (0..<2_500).map { i in
      CandidateFinder.prepare(
        candidate(
          kind: CandidateFinder.emojiKind,
          source: "emojis.glyphs",
          name: "emoji sample \(i) fire flame heart party grin smile",
          subtitle: "emoji",
          bundleIdentifier: "",
          searchAliases: i % 5 == 0 ? "rocket launch fast" : ""))
    }
    func assertFast(_ query: String) {
      let started = Date()
      let matches = CandidateFinder.emojiMatches(
        pool: pool,
        normalizedQuery: NormalModeDispatcher.normalizedSearchText(query),
        limit: 64)
      let elapsedMs = Date().timeIntervalSince(started) * 1_000

      XCTAssertEqual(matches.count, 64)
      XCTAssertLessThan(
        elapsedMs, 20,
        "emoji fast path for \(query) took \(elapsedMs)ms for 2.5k candidates (budget 20ms)")
    }

    assertFast("")
    assertFast("f")
    assertFast("fire")
  }

  func testSourceCompletionCandidateHasStableShapeAndRanksByToken() throws {
    let firefox = CandidateFinder.prepare(
      CandidateFinder.sourceCompletionCandidate("firefox.tabs"))
    let slack = CandidateFinder.prepare(
      CandidateFinder.sourceCompletionCandidate("slack.channels"))

    XCTAssertEqual(firefox.kind, CandidateFinder.sourceKind)
    XCTAssertEqual(firefox.source, "source")
    XCTAssertEqual(firefox.sourcePayload, "firefox.tabs")
    XCTAssertEqual(firefox.displayTitle, "[source] @firefox.tabs (source filter)")
    XCTAssertNil(firefox.url)

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
        bounded.map(\.candidate.name),
        full.prefix(limit).map(\.candidate.name),
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
        sequential.map(\.candidate.name),
        parallel.map(\.candidate.name),
        "sequential and parallel candidate streams diverged for \(query)")
      XCTAssertEqual(
        sequential.map(\.score),
        parallel.map(\.score),
        "sequential and parallel scores diverged for \(query)")
    }
  }

  func testAttributeFilterFieldAliasesMatchCanonicalFields() {
    let candidates = [
      candidate(
        kind: .plugin("browser_tab"), source: "firefox",
        name: "Inbox", subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.example.test/")),
      candidate(
        kind: .app, source: "core.apps",
        name: "Messages", subtitle: "chat app",
        bundleIdentifier: "com.apple.MobileSMS"),
    ]

    let title = CandidateFinder.CompiledAttributeFilter.parse(field: "title", pattern: "Inbox")
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [title]).map(\.name),
      ["Inbox"])

    let bundle = CandidateFinder.CompiledAttributeFilter.parse(
      field: "bundle_id", pattern: "com.apple.MobileSMS")
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [bundle]).map(\.name),
      ["Messages"])

    let description = CandidateFinder.CompiledAttributeFilter.parse(
      field: "description", pattern: "*app")
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [description]).map(\.name),
      ["Messages"])
  }

  // MARK: - @field:pattern attribute filter

  func testAttributeFilterParsesStructuredAndLegacyForms() {
    // Legacy `@<source>` survives untouched (back-compat with users
    // who have `@notes inbox` in their muscle memory).
    let legacy = NormalModeDispatcher.candidateFinderSourceFilter("@notes inbox")
    XCTAssertEqual(legacy.sourceFilters, ["notes"])
    XCTAssertTrue(legacy.attributeFilters.isEmpty)
    XCTAssertEqual(legacy.text, "inbox")

    // Structured `@<field>:<pattern>` is parsed as an attribute filter
    // and removed from the search text.
    let structured = NormalModeDispatcher.candidateFinderSourceFilter("@source:firefox foo")
    XCTAssertEqual(
      structured.attributeFilters,
      [
        NormalModeDispatcher.AttributeFilter(field: "source", pattern: "firefox")
      ])
    XCTAssertEqual(structured.sourceFilters, [])
    XCTAssertEqual(structured.text, "foo")

    // Multiple attribute filters and mixed order with residual text.
    let mixed = NormalModeDispatcher.candidateFinderSourceFilter(
      "rust @source:firefox @url:*google*")
    XCTAssertEqual(mixed.attributeFilters.map(\.field), ["source", "url"])
    XCTAssertEqual(mixed.attributeFilters.map(\.pattern), ["firefox", "*google*"])
    XCTAssertEqual(mixed.text, "rust")

    // Pathological syntax falls back to literal text, so a typo doesn't
    // silently swallow the user's query.
    let empty = NormalModeDispatcher.candidateFinderSourceFilter("@:foo @bar:")
    XCTAssertEqual(empty.attributeFilters, [])
    XCTAssertEqual(empty.text, "@:foo @bar:")
  }

  func testAttributeFilterCompiledWildcardSemantics() {
    let candidates = [
      candidate(
        kind: .plugin("browser_tab"), source: "firefox",
        name: "Gmail", subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/")),
      candidate(
        kind: .plugin("browser_tab"), source: "safari",
        name: "Gmail Safari", subtitle: "browser tab",
        bundleIdentifier: "com.apple.safari",
        url: URL(string: "https://mail.google.com/")),
      candidate(
        kind: .plugin("browser_tab"), source: "firefox",
        name: "Hacker News", subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://news.ycombinator.com/")),
      candidate(
        kind: .app, source: "core.apps", name: "Calculator", subtitle: "app",
        bundleIdentifier: "com.apple.Calculator"),
    ]

    let exact = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "firefox")
    XCTAssertEqual(exact.kind, .exact)
    XCTAssertEqual(CandidateFinder.applyAttributeFilters(candidates, filters: [exact]).count, 2)

    let prefix = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "fire*")
    XCTAssertEqual(prefix.kind, .prefix)
    XCTAssertEqual(CandidateFinder.applyAttributeFilters(candidates, filters: [prefix]).count, 2)

    let suffix = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "*fox")
    XCTAssertEqual(suffix.kind, .suffix)
    XCTAssertEqual(CandidateFinder.applyAttributeFilters(candidates, filters: [suffix]).count, 2)

    let contains = CandidateFinder.CompiledAttributeFilter.parse(
      field: "url", pattern: "*google*")
    XCTAssertEqual(contains.kind, .contains)
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [contains]).map(\.name).sorted(),
      ["Gmail", "Gmail Safari"])

    let catchall = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "*")
    XCTAssertEqual(catchall.kind, .any)
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [catchall]).count,
      candidates.count)

    // Unknown field → match nothing rather than silently passing
    // (helps surface typos like `@srouce:firefox`).
    let unknown = CandidateFinder.CompiledAttributeFilter.parse(
      field: "srouce", pattern: "firefox")
    XCTAssertEqual(unknown.field, .unknown)
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(candidates, filters: [unknown]).count, 0)
  }

  func testAttributeFilterOrsWithinFieldAndAndsAcrossFields() {
    let candidates = [
      candidate(
        kind: .plugin("browser_tab"), source: "firefox",
        name: "Gmail Firefox", subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/")),
      candidate(
        kind: .plugin("browser_tab"), source: "safari",
        name: "Gmail Safari", subtitle: "browser tab",
        bundleIdentifier: "com.apple.safari",
        url: URL(string: "https://mail.google.com/")),
      candidate(
        kind: .plugin("browser_tab"), source: "chromium",
        name: "Hacker News", subtitle: "browser tab",
        bundleIdentifier: "com.google.Chrome",
        url: URL(string: "https://news.ycombinator.com/")),
    ]

    // `(source=firefox OR source=safari) AND url contains "google"`:
    // both Gmail rows pass; HN fails the URL test.
    let firefoxFilter = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "firefox")
    let safariFilter = CandidateFinder.CompiledAttributeFilter.parse(
      field: "source", pattern: "safari")
    let urlFilter = CandidateFinder.CompiledAttributeFilter.parse(
      field: "url", pattern: "*google*")
    let names = CandidateFinder.applyAttributeFilters(
      candidates,
      filters: [firefoxFilter, safariFilter, urlFilter]
    ).map(\.name).sorted()
    XCTAssertEqual(names, ["Gmail Firefox", "Gmail Safari"])
  }

  func testAttributeFilterSurvivesAcrossPoolBuildPath() {
    // End-to-end: parsing → compile → apply, mirroring the host's
    // candidate-finder pipeline. Ensures the `@source:` selector
    // produces the same effective filter as the parser/applier
    // composition tested above.
    let parsed = NormalModeDispatcher.candidateFinderSourceFilter("@source:firefox @url:*goog*")
    XCTAssertEqual(parsed.text, "")
    let compiled = parsed.attributeFilters.map {
      CandidateFinder.CompiledAttributeFilter.parse(field: $0.field, pattern: $0.pattern)
    }
    let pool = [
      candidate(
        kind: .plugin("browser_tab"), source: "firefox",
        name: "Gmail", subtitle: "browser tab",
        bundleIdentifier: "org.mozilla.firefox",
        url: URL(string: "https://mail.google.com/")),
      candidate(
        kind: .plugin("browser_tab"), source: "safari",
        name: "Gmail Safari", subtitle: "browser tab",
        bundleIdentifier: "com.apple.safari",
        url: URL(string: "https://mail.google.com/")),
    ]
    XCTAssertEqual(
      CandidateFinder.applyAttributeFilters(pool, filters: compiled).map(\.name),
      ["Gmail"])
  }

  func testAttributeFilterFastOnLargePools() {
    // Performance gate: 5 000 mixed candidates × 3 filters (source OR
    // OR + url contains) should resolve in ≪10 ms on the test runner.
    // The filter pipeline runs once per keystroke and the compile step
    // is pre-amortised, so this matches the hot path.
    var pool: [Candidate] = []
    pool.reserveCapacity(5_000)
    let sources = ["firefox", "safari", "chromium", "tmux", "app"]
    for i in 0..<5_000 {
      let source = sources[i % sources.count]
      pool.append(
        candidate(
          kind: .plugin("browser_tab"),
          source: source,
          name: "Item \(i)",
          subtitle: "perf",
          bundleIdentifier: "test.\(source)",
          url: URL(
            string: "https://example.test/\(i)/\(i % 3 == 0 ? "google" : "other")")))
    }
    let filters = [
      CandidateFinder.CompiledAttributeFilter.parse(field: "source", pattern: "firefox"),
      CandidateFinder.CompiledAttributeFilter.parse(field: "source", pattern: "safari"),
      CandidateFinder.CompiledAttributeFilter.parse(field: "url", pattern: "*google*"),
    ]
    let started = Date()
    let result = CandidateFinder.applyAttributeFilters(pool, filters: filters)
    let elapsedMs = Date().timeIntervalSince(started) * 1_000
    XCTAssertFalse(result.isEmpty)
    XCTAssertLessThan(
      elapsedMs, 50,
      "attribute filter took \(elapsedMs)ms for 5k candidates × 3 filters (budget 50ms)")
  }

  private func candidate(
    kind: CandidateKind,
    source: String,
    name: String,
    subtitle: String,
    bundleIdentifier: String,
    pid: pid_t? = nil,
    url: URL? = nil,
    searchAliases: String = ""
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
      searchAliases: searchAliases)
  }
}

private enum DummyRunningApplication {
  static var app: NSRunningApplication {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil }
      ?? NSRunningApplication.current
  }
}

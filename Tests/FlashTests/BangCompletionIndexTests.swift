import FlashCore
import Foundation
import XCTest

@testable import flash

/// The `!` list over ten thousand bangs: a keystroke scores only the bangs
/// whose trigger starts with the token, and lists exactly what scoring every
/// bang would list whenever that prefix tier fills the display.
final class BangCompletionIndexTests: XCTestCase {
  private static let stems = [
    "g", "go", "goo", "git", "gh", "you", "yt", "w", "wiki", "am", "amaz", "red", "rust", "py",
    "x", "zz",
  ]

  /// Ten thousand bangs the way the searchproviders catalog publishes them,
  /// plus a declared bang with aliases.
  private static let catalog: [Candidate] = {
    var rows = (0..<10_000).map { index -> Candidate in
      let stem = stems[index % stems.count]
      let trigger = "\(stem)\(index / stems.count)"
      return bang(
        trigger: trigger, subtitle: "Site \(trigger) · Tech › Programming",
        priority: [FlashPriority.high, .normal, .low][index % 3])
    }
    rows.append(bang(trigger: "files", subtitle: "Files", aliases: "f fd"))
    return rows
  }()

  private static func bang(
    trigger: String, subtitle: String, aliases: String = "", priority: FlashPriority = .normal
  ) -> Candidate {
    Candidate(
      kind: CandidateFinder.bangKind, sourceID: "plugin:searchproviders",
      source: "searchproviders.bangs", pid: nil, title: "!\(trigger)", subtitle: subtitle,
      bundleIdentifier: "", url: nil, sourcePayload: trigger, searchAliases: aliases,
      finishesCommand: false, isLocation: false, isCurrentLocation: false, priority: priority)
  }

  private let limit = 30
  private lazy var index = BangCompletionIndex(
    candidates: Self.catalog, precedence: .default, limit: limit)

  private func full(_ token: String) -> [String] {
    let normalized = NormalModeDispatcher.normalizedSearchText(token)
    let scored = CandidateFinder.scoreMatches(
      pool: index.rows, normalizedQuery: normalized,
      fuzzyScore: NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalized))
    return CandidateFinder.sortedMatches(scored, precedence: .default, limit: limit)
      .map(\.candidate.title)
  }

  private func listed(_ token: String) -> (titles: [String], final: Bool) {
    let normalized = NormalModeDispatcher.normalizedSearchText(token)
    let result = index.matches(normalizedToken: normalized, precedence: .default, limit: limit)
    return (result.matches.map(\.candidate.title), result.final)
  }

  func testAFinalPrefixListIsTheListScoringEveryBangShows() {
    var finals = 0
    for token in ["g", "go", "goo", "gh", "git", "you", "yt", "w", "amaz", "rust", "py1", "f"] {
      let listed = listed(token)
      guard listed.final else { continue }
      finals += 1
      XCTAssertEqual(listed.titles, full(token), token)
    }
    XCTAssertGreaterThan(finals, 8, "most short tokens fill the display from their prefix")
  }

  func testATokenWhosePrefixTierIsShortIsNotFinal() {
    for token in ["goo99", "oogle", "qqq", "files"] {
      let listed = listed(token)
      XCTAssertFalse(listed.final, token)
      // What it does list is the head of the complete list.
      XCTAssertEqual(Array(full(token).prefix(listed.titles.count)), listed.titles, token)
    }
  }

  func testABareBangListsEveryBangUnscoredInDisplayOrder() {
    let listed = listed("")
    XCTAssertTrue(listed.final)
    XCTAssertEqual(listed.titles.count, limit)
    let unscored = CandidateFinder.sortedMatches(
      index.rows.map { CandidateMatch(candidate: $0, score: 0) }, precedence: .default,
      limit: limit)
    XCTAssertEqual(listed.titles, unscored.map(\.candidate.title))
  }

  /// The regression: `!goo` ran the general scorer, fuzzy ladder and all,
  /// over all ten thousand bangs on the main thread. Now a keystroke reads
  /// only the prefix range, and scores it from the trigger alone.
  func testAKeystrokeReadsOnlyThePrefixRange() {
    let range = index.prefixRows("goo")
    XCTAssertEqual(
      range.count,
      index.rows.filter { $0.normalizedScoringFields.title.hasPrefix("goo") }.count)
    XCTAssertLessThan(range.count, index.rows.count / 10)
    XCTAssertTrue(index.matches(normalizedToken: "goo", precedence: .default, limit: limit).final)
  }

  /// The trigger-only score is the full scorer's for every prefix row.
  func testAPrefixScoreIsTheFullScorersScore() {
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    for token in ["g", "goo", "gh", "f", "fd", "files", "zz1"] {
      for row in index.prefixRows(token).map({ index.rows[$0] }) {
        let full = CandidateFinder.evaluate(
          normalizedQuery: token, candidate: row, fuzzyScore: fuzzy)
        let quick = BangCompletionIndex.prefixScore(token, row.normalizedScoringFields)
        XCTAssertEqual(quick?.score, full?.score, "\(token) \(row.title)")
        XCTAssertEqual(quick?.tier, full?.tier, "\(token) \(row.title)")
      }
    }
  }

  func testAliasesReachTheirRowOnceAndTokensAreKnown() {
    let rows = index.prefixRows("f")
    XCTAssertEqual(rows.filter { index.rows[$0].title == "!files" }.count, 1)
    XCTAssertTrue(index.tokens.contains("files"))
    XCTAssertTrue(index.tokens.contains("goo3"))
    XCTAssertFalse(index.tokens.contains("nope"))
  }

  /// Every bang shares its source label and display, so they no longer
  /// score: the label's letters let every query through the prefilter.
  func testABangIsNotMatchedThroughTheLabelEveryBangShares() {
    let row = CandidateFinder.prepare(Self.bang(trigger: "zz", subtitle: "Foo"))
    XCTAssertEqual(row.scoringMask & CandidateFinder.presenceMask("v"), 0)
    XCTAssertNil(
      CandidateFinder.evaluate(
        normalizedQuery: "searchproviders", candidate: row,
        fuzzyScore: NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)))
    XCTAssertEqual(
      CandidateFinder.evaluate(
        normalizedQuery: "zz", candidate: row,
        fuzzyScore: NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:))?.tier,
      .exact)
    // The display keeps the source.
    XCTAssertEqual(row.displayTitle, "[searchproviders.bangs] !zz (Foo)")
  }
}

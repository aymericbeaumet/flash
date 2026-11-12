import FlashCore
import XCTest

@testable import flash

final class FileSearchSourceTests: XCTestCase {
  // MARK: - The `mdfind -name` query

  func testQueryMatchesNamePrefixesIgnoringCaseAndDiacritics() {
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "Safari"), #"(kMDItemDisplayName = "Safari*"cdw)"#)
    // Words split on any Unicode white space and U+200B, joined by one space;
    // a multi-word phrase is tokenized (`t`).
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "  Activity\t\u{00A0}Monitor\n"),
      #"(kMDItemDisplayName = "Activity Monitor*"cdwt)"#)
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "news\u{200B}f"),
      #"(kMDItemDisplayName = "news f*"cdwt)"#)
  }

  func testBlankNamesRunNoQuery() {
    for text in ["", "   ", "\t\n", "\u{200B}", "\u{3000}"] {
      XCTAssertNil(SpotlightNameSearch.query(forName: text), text.debugDescription)
    }
  }

  func testQuerySyntaxInTheNameStaysLiteral() {
    // Quotes, apostrophes, `*` and backslashes are escaped, so only the
    // trailing `*` is a wildcard; `?` and parentheses are literal already.
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: #"a"b'c*d\e"#),
      #"(kMDItemDisplayName = "a\"b\'c\*d\\e*"cdw)"#)
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "x?(y) -z"),
      #"(kMDItemDisplayName = "x?(y) -z*"cdwt)"#)
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: #"" OR kMDItemFSName = "*"#),
      #"(kMDItemDisplayName = "\" OR kMDItemFSName = \"\**"cdwt)"#)
  }

  func testNamesAreCanonicallyDecomposed() {
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "caf\u{00E9}"),
      "(kMDItemDisplayName = \"cafe\u{0301}*\"cdw)")
  }

  func testIdeographicKanaAndHangulNamesUseTheSegmenter() {
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "日本"), #"(kMDItemDisplayName = "日本*"cdws)"#)
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "x 日本"), #"(kMDItemDisplayName = "x 日本*"cdwts)"#)
    // One unit is too short to segment.
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "日"), #"(kMDItemDisplayName = "日*"cdw)"#)
    // Hangul syllables decompose into conjoining jamo (U+1100...U+11FF).
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "한")?.hasSuffix("*\"cdws)"), true)
    // Half-width katakana is in range; full-width Latin is not.
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "ｱｲ"), #"(kMDItemDisplayName = "ｱｲ*"cdws)"#)
    XCTAssertEqual(
      SpotlightNameSearch.query(forName: "ＡＢ"), #"(kMDItemDisplayName = "ＡＢ*"cdw)"#)
  }

  // MARK: - Rows

  func testFileURLsPercentEncodeEverythingButUnreservedAndSlashes() {
    XCTAssertEqual(
      FileSearchSource.fileURLString(forPath: "/Users/me/My File.txt"),
      "file:///Users/me/My%20File.txt")
    XCTAssertEqual(
      FileSearchSource.fileURLString(forPath: "/tmp/100%?#[] .md"),
      "file:///tmp/100%25%3F%23%5B%5D%20.md")
    // Multi-byte UTF-8 encodes per byte.
    XCTAssertEqual(FileSearchSource.fileURLString(forPath: "/tmp/é"), "file:///tmp/%C3%A9")
    XCTAssertEqual(
      FileSearchSource.fileURLString(forPath: "/plain/path-2.rs~"), "file:///plain/path-2.rs~")
  }

  func testRowsCarryTheNameThePathAndAFileURL() throws {
    let candidate = try XCTUnwrap(FileSearchSource.candidate(forPath: "/Users/me/Notes/read me.md"))
    XCTAssertEqual(candidate.title, "read me.md")
    XCTAssertEqual(candidate.url?.absoluteString, "file:///Users/me/Notes/read%20me.md")
    XCTAssertEqual(candidate.url?.path, "/Users/me/Notes/read me.md")
    XCTAssertEqual(candidate.source, "files.results")
    XCTAssertEqual(candidate.sourceID, "core.files")
    XCTAssertEqual(candidate.kind, .plugin("file"))
    XCTAssertEqual(candidate.metadata[CandidateMetadataKey.subtitle], "/Users/me/Notes/read me.md")
    XCTAssertNil(candidate.effect)
    XCTAssertFalse(candidate.isLocation)
  }

  func testUnshapeablePathsAreDropped() {
    XCTAssertNil(FileSearchSource.candidate(forPath: "relative/path"))
    XCTAssertNil(FileSearchSource.candidate(forPath: ""))
    // A bare root has no file name to title the row with.
    XCTAssertNil(FileSearchSource.candidate(forPath: "/"))
    XCTAssertNil(FileSearchSource.candidate(forPath: "/tmp/.."))
    let longest = "/" + String(repeating: "x", count: FileSearchSource.maxPathBytes - 1)
    XCTAssertNotNil(FileSearchSource.candidate(forPath: longest))
    XCTAssertNil(FileSearchSource.candidate(forPath: longest + "x"))
  }

  // MARK: - Source wiring

  func testFilesAreALiveSourceOnlyReachedThroughItsScope() {
    let registry = SourceRegistry(
      descriptors: [
        SourceDescriptor(identifier: FileSearchSource.sourceID, activationPolicy: .always) {
          FileSearchSource()
        }
      ],
      isTerminalEmulator: { _ in false },
      runningApplications: [])
    XCTAssertEqual(
      registry.liveCandidateSources(matching: .type("files")).map(\.identifier), ["core.files"])
    XCTAssertTrue(registry.liveCandidateSources(matching: .type("files.results")).isEmpty)
    XCTAssertTrue(registry.liveCandidateSources(matching: .type("menus")).isEmpty)
    XCTAssertTrue(registry.initialCandidateSnapshotSources().isEmpty)
  }

  func testTheFileBangScopesToTheFileSource() throws {
    let bang = try XCTUnwrap(CoreBangs.bang(token: "F"))
    XCTAssertEqual(bang.scope, .type("files"))
    XCTAssertNil(CoreBangs.bang(token: "fh"))
    let row = try XCTUnwrap(CoreBangs.candidates.first { $0.sourcePayload == "f" })
    XCTAssertEqual(row.kind, CandidateFinder.bangKind)
    XCTAssertEqual(row.title, "!f")
    XCTAssertEqual(CandidateFinder.commandInsertionText(row), "!f ")
  }

  func testBlankQueryAnswersEmptyOnMain() {
    let answered = expectation(description: "answered")
    FileSearchSource().liveCandidates(
      matching: " \t", in: FlashSourceEnvironment(runningApplications: []), scope: .all
    ) { candidates in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertTrue(candidates.isEmpty)
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
  }

  // MARK: - Spotlight (tolerant of an unindexed or disabled index)

  private func search(
    _ engine: SpotlightNameSearch, _ name: String, limit: Int = 200,
    deadline: DispatchTimeInterval = .seconds(5)
  ) -> SearchReply {
    let box = SearchReply(expectation(description: "search \(name)"))
    engine.search(
      query: SpotlightNameSearch.query(forName: name)!, limit: limit, deadline: deadline
    ) { result in
      box.result = result
      box.expectation.fulfill()
    }
    return box
  }

  func testSpotlightFindsSystemAppsByName() throws {
    let engine = SpotlightNameSearch()
    let found = search(engine, "Calculator")
    wait(for: [found.expectation], timeout: 10)
    let result = try XCTUnwrap(found.result)
    guard !result.paths.isEmpty else {
      throw XCTSkip("Spotlight answered nothing (outcome \(result.outcome.rawValue))")
    }
    XCTAssertEqual(result.outcome, .finished)
    XCTAssertTrue(result.paths.allSatisfy { $0.hasPrefix("/") }, "\(result.paths)")
    XCTAssertTrue(
      result.paths.contains { $0.hasSuffix("/Calculator.app") }, "\(result.paths)")
  }

  func testBroadQueriesStopAtTheLimit() throws {
    let engine = SpotlightNameSearch()
    let found = search(engine, "a", limit: 7)
    wait(for: [found.expectation], timeout: 10)
    let result = try XCTUnwrap(found.result)
    XCTAssertLessThanOrEqual(result.paths.count, 7)
    if result.paths.count == 7 {
      XCTAssertEqual(result.outcome, .limited)
    }
  }

  func testANewerQuerySupersedesTheOneInFlight() throws {
    let engine = SpotlightNameSearch()
    let first = search(engine, "a")
    let second = search(engine, "Calculator")
    wait(for: [first.expectation, second.expectation], timeout: 10)
    let older = try XCTUnwrap(first.result)
    try skipUnlessSpotlightAnswered(older)
    XCTAssertEqual(older.outcome, .superseded)
    XCTAssertTrue(older.paths.isEmpty)
    XCTAssertNotEqual(second.result?.outcome, .superseded)
  }

  func testTheDeadlineAnswersWithWhatWasGathered() throws {
    let engine = SpotlightNameSearch()
    // Far below the thousands of names starting with "a": only the deadline
    // can end this query this early.
    let found = search(engine, "a", limit: 1_000, deadline: .milliseconds(0))
    wait(for: [found.expectation], timeout: 10)
    let result = try XCTUnwrap(found.result)
    try skipUnlessSpotlightAnswered(result)
    XCTAssertEqual(result.outcome, .deadline)
    XCTAssertLessThanOrEqual(result.paths.count, 1_000)
  }

  /// An unindexed or disabled Spotlight refuses or instantly finishes empty.
  private func skipUnlessSpotlightAnswered(_ result: SpotlightNameSearch.Result) throws {
    if result.outcome == .failed || (result.outcome == .finished && result.paths.isEmpty) {
      throw XCTSkip("Spotlight answered nothing (outcome \(result.outcome.rawValue))")
    }
  }

  func testAMalformedQueryFailsWithoutRows() {
    let engine = SpotlightNameSearch()
    let answered = expectation(description: "answered")
    engine.search(query: "(kMDItemDisplayName = ", limit: 10, deadline: .seconds(1)) { result in
      XCTAssertEqual(result.outcome, .failed)
      XCTAssertTrue(result.paths.isEmpty)
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
  }

  func testReleasingTheSearchStillAnswersEveryRequest() {
    var engine: SpotlightNameSearch? = SpotlightNameSearch()
    let answered = expectation(description: "answered")
    answered.expectedFulfillmentCount = 2
    for name in ["a", "Calculator"] {
      engine?.search(
        query: SpotlightNameSearch.query(forName: name)!, limit: 200, deadline: .seconds(5)
      ) { _ in answered.fulfill() }
    }
    engine = nil
    wait(for: [answered], timeout: 10)
  }
}

/// One asynchronous search reply, read after its expectation is fulfilled.
private final class SearchReply: @unchecked Sendable {
  let expectation: XCTestExpectation
  var result: SpotlightNameSearch.Result?

  init(_ expectation: XCTestExpectation) {
    self.expectation = expectation
  }
}

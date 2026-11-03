import AppKit
import FlashCore
import XCTest

@testable import flash

final class ClipboardFlashlightTests: XCTestCase {
  private func entry(
    _ id: Character, _ text: String, kind: String = "text", pinned: Bool = false,
    mime: String? = nil, files: [String] = [], width: Int? = nil, height: Int? = nil
  ) -> ClipboardListing {
    ClipboardListing(
      id: String(repeating: id, count: 32), kind: kind, text: text, mime: mime, files: files,
      width: width, height: height, pinned: pinned)
  }

  /// The rows `flashlight` holds once `listing` is built, read on main.
  private func rows(
    _ listing: [ClipboardListing], registers: [RegisterStore.Entry] = []
  ) -> [Candidate] {
    let flashlight = ClipboardFlashlight { registers }
    let built = expectation(description: "rows built")
    flashlight.onChange = { built.fulfill() }
    flashlight.update(listing)
    wait(for: [built], timeout: 5)
    return flashlight.rows()
  }

  private var precedence: CandidateFinder.PrecedenceTable {
    let source = ClipboardFlashlightSource(flashlight: ClipboardFlashlight { [] })
    return CandidateFinder.PrecedenceTable(
      sources: source.candidateSourceDescriptors, overrides: [:], aliveBonus: 10)
  }

  /// The flashlight's own ranking of `pool` for `query`, as a scoped query
  /// ranks it.
  private func ranked(_ pool: [Candidate], query: String) -> [String] {
    let normalized = NormalModeDispatcher.normalizedSearchText(query)
    let scored = CandidateFinder.scoreMatches(
      pool: pool, normalizedQuery: normalized,
      fuzzyScore: NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalized),
      allowParallel: false)
    return CandidateFinder.sortedMatches(scored, precedence: precedence).map(\.candidate.title)
  }

  // MARK: - Rows

  func testRowsSayWhatWasCopied() {
    XCTAssertEqual(
      ClipboardFlashlight.title(for: entry("a", "\n  \n  first   line\nsecond")), "first line")
    XCTAssertEqual(
      ClipboardFlashlight.title(for: entry("a", "", kind: "html")), "Formatted text")
    XCTAssertEqual(
      ClipboardFlashlight.title(
        for: entry("a", "", kind: "image", mime: "image/png", width: 1280, height: 800)),
      "Image 1280×800 PNG")
    XCTAssertEqual(
      ClipboardFlashlight.title(for: entry("a", "", kind: "image", mime: "image/jpeg")),
      "Image JPEG")
    XCTAssertEqual(
      ClipboardFlashlight.title(
        for: entry("a", "", kind: "files", files: ["/tmp/report.pdf"])), "report.pdf")
    XCTAssertEqual(
      ClipboardFlashlight.title(
        for: entry("a", "", kind: "files", files: ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"])),
      "a.txt and 2 more")
    let long = String(repeating: "x", count: 500)
    XCTAssertEqual(
      ClipboardFlashlight.title(for: entry("a", long)).count, ClipboardFlashlight.titleLimit)
    XCTAssertEqual(
      ClipboardFlashlight.excerpt(String(repeating: "word ", count: 1_000)).count,
      ClipboardFlashlight.excerptLimit)
    XCTAssertEqual(
      ClipboardFlashlight.excerpt(for: entry("a", "\n first line\n  then   more\n")),
      "then more", "the excerpt is what follows the title")
    XCTAssertEqual(
      ClipboardFlashlight.excerpt(
        for: entry("a", "", kind: "files", files: ["/tmp/a.txt", "/tmp/b.txt"])),
      "/tmp/a.txt /tmp/b.txt")
  }

  func testTheListIsBoundedButKeepsEveryPin() {
    var listing = [entry("p", "pinned", pinned: true)]
    for index in 0..<(ClipboardFlashlight.historyRowLimit + 5) {
      listing.append(
        ClipboardListing(
          id: String(format: "%032x", index), kind: "text", text: "copy \(index)", files: [],
          pinned: false))
    }
    let listed = ClipboardFlashlight.listed(listing)
    XCTAssertEqual(listed.count, ClipboardFlashlight.historyRowLimit + 1)
    XCTAssertEqual(listed.first?.text, "pinned")
    XCTAssertEqual(listed.last?.text, "copy \(ClipboardFlashlight.historyRowLimit - 1)")
  }

  func testHistoryRowsArePreparedFinishersOfTheirPinGroup() throws {
    let built = rows([entry("a", "kept", pinned: true), entry("b", "recent")])
    XCTAssertEqual(built.map(\.title), ["kept", "recent"])
    XCTAssertEqual(
      built.map(\.source), [ClipboardFlashlight.pinnedLabel, ClipboardFlashlight.historyLabel])
    XCTAssertEqual(built.map(\.sourceOrder), [0, 1])
    XCTAssertTrue(built.allSatisfy { !$0.sortKey.isEmpty }, "prepared off main")
    XCTAssertTrue(built.allSatisfy(\.finishesCommand), "Return pastes")
    XCTAssertTrue(built.allSatisfy { !$0.isLocation }, "a copy is no place to go")
    XCTAssertEqual(built.first?.sourcePayload, String(repeating: "a", count: 32))
    XCTAssertEqual(built.first?.sourceID, ClipboardFlashlight.sourceID)
  }

  func testRegisterRowsFollowTheHistory() {
    let built = rows(
      [entry("a", "copied")],
      registers: [
        RegisterStore.Entry(name: "0", text: "yanked", kind: "yank", truncated: false),
        RegisterStore.Entry(name: "a", text: "kept\nin a", kind: "named", truncated: false),
      ])
    XCTAssertEqual(built.map(\.title), ["copied", "\"0 yanked", "\"a kept"])
    XCTAssertEqual(built.last?.source, ClipboardFlashlight.registersLabel)
    XCTAssertEqual(built.last?.sourcePayload, "a")
    XCTAssertEqual(built.last?.kind, ClipboardFlashlight.registerKind)
  }

  func testNamedRegistersSkipTheSystemClipboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("flash-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let store = RegisterStore(pasteboard: pasteboard)
    store.write("yanked", register: nil)
    store.write("named", register: "b")
    XCTAssertEqual(store.namedSnapshot().map(\.name), ["0", "b"])
    XCTAssertEqual(store.snapshot().map(\.name), ["\"", "+", "0", "b"])
  }

  // MARK: - Ranking

  func testAnEmptyQueryListsPinsThenNewestCopiesThenRegisters() {
    let built = rows(
      [
        entry("p", "zz pinned", pinned: true),
        entry("n", "newest copy"), entry("m", "middle copy"), entry("o", "an oldest copy"),
      ],
      registers: [RegisterStore.Entry(name: "a", text: "aaa", kind: "named", truncated: false)])
    XCTAssertEqual(
      ranked(built.shuffled(), query: ""),
      ["zz pinned", "newest copy", "middle copy", "an oldest copy", "\"a aaa"])
  }

  func testATypedQueryRanksByMatchThenRecency() {
    let built = rows([
      entry("a", "notes two"), entry("b", "notes one"), entry("c", "older notes"),
      entry("d", "notes"),
    ])
    // The exact title wins whatever its age; equal matches keep newest first
    // rather than falling back to the alphabet.
    XCTAssertEqual(
      ranked(built.shuffled(), query: "notes").prefix(3), ["notes", "notes two", "notes one"])
  }

  func testPinnedRowsLeadTheirMatchTier() {
    let built = rows([
      entry("p", "deploy script", pinned: true), entry("n", "deploy notes"),
    ])
    XCTAssertEqual(ranked(built, query: "deploy"), ["deploy script", "deploy notes"])
  }

  // MARK: - Scope

  func testTheClipBangScopesEveryClipboardSource() throws {
    let bang = try XCTUnwrap(CoreBangs.bang(token: "CLIP"))
    XCTAssertEqual(bang.scope, .type("clipboard"))
    let source = ClipboardFlashlightSource(flashlight: ClipboardFlashlight { [] })
    XCTAssertEqual(source.candidateSourceDescriptors.count, 3)
    for descriptor in source.candidateSourceDescriptors {
      XCTAssertTrue(bang.scope.matches(descriptor), descriptor.name)
    }
    XCTAssertTrue(CoreBangs.candidates.contains { $0.sourcePayload == "clip" })
  }

  func testAConfirmedSourceBangScopesTheRestOfTheQuery() {
    let scope: (String) -> SourceScope? = { CoreBangs.bang(token: $0)?.scope }
    XCTAssertEqual(
      CandidateFinder.boundBangScope("!clip ", scope: scope)?.scope, .type("clipboard"))
    XCTAssertEqual(CandidateFinder.boundBangScope("!clip ", scope: scope)?.remainder, "")
    XCTAssertEqual(
      CandidateFinder.boundBangScope("!clip deploy  key", scope: scope)?.remainder, "deploy  key")
    XCTAssertNil(CandidateFinder.boundBangScope("!clip", scope: scope), "not confirmed yet")
    XCTAssertNil(CandidateFinder.boundBangScope("!g rust", scope: scope), "a site bang")
    XCTAssertNil(CandidateFinder.boundBangScope("clip", scope: scope))
  }

  func testTheClipboardSourceIsPulledOncePerScope() {
    let clipboard = ClipboardFlashlightSource(flashlight: ClipboardFlashlight { [] })
    XCTAssertFalse(clipboard.liveCandidatesDependOnText)
    XCTAssertEqual(AppDelegate.liveQueryText("deploy", sources: [clipboard]), "")
    XCTAssertEqual(
      AppDelegate.liveQueryText("deploy", sources: [clipboard, FileSearchSource()]), "deploy")

    var live = CandidateLiveQuery<Candidate>()
    let filter = ClipboardFlashlight.bang.scope.signature
    XCTAssertNotNil(
      live.begin(.init(filter: filter, text: "", sourceIDs: [ClipboardFlashlight.sourceID])))
    XCTAssertNil(
      live.begin(.init(filter: filter, text: "", sourceIDs: [ClipboardFlashlight.sourceID])),
      "the next keystroke keeps the rows it has")
  }

  func testTheRegistryServesClipboardRowsOnlyThroughTheirScope() {
    let flashlight = ClipboardFlashlight { [] }
    let registry = SourceRegistry(
      descriptors: [], isTerminalEmulator: { _ in false }, runningApplications: [],
      clipboard: flashlight)
    XCTAssertEqual(
      registry.liveCandidateSources(matching: .type("clipboard")).map(\.identifier),
      [ClipboardFlashlight.sourceID])
    XCTAssertEqual(
      registry.liveCandidateSources(matching: .source(ClipboardFlashlight.pinnedLabel))
        .map(\.identifier),
      [ClipboardFlashlight.sourceID])
    XCTAssertTrue(
      registry.liveCandidateSources(matching: .type("clipboard.pinned")).isEmpty,
      "a source name is no type")
    XCTAssertFalse(
      registry.initialCandidateSnapshotSources().contains {
        $0.identifier == ClipboardFlashlight.sourceID
      })
    XCTAssertEqual(registry.registeredResourceTypeProviders().map(\.type), ["clipboard"])
    let types = registry.resourceTypesBySource()
    XCTAssertEqual(types[ClipboardFlashlight.historyLabel], "clipboard")
    XCTAssertEqual(types[ClipboardFlashlight.registersLabel], "clipboard")
  }

  func testModifiedReturnPicksTheDelivery() {
    XCTAssertEqual(ClipboardRowDelivery(nil), .paste)
    XCTAssertEqual(ClipboardRowDelivery(.shift), .pastePlain)
    XCTAssertEqual(ClipboardRowDelivery(.option), .copy)
    XCTAssertTrue(ClipboardRowDelivery.pastePlain.plain)
    XCTAssertFalse(ClipboardRowDelivery.copy.pastes)
  }

  // MARK: - Restoring to the pasteboard

  private func pasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("flash-test-\(UUID().uuidString)"))
  }

  private let id = String(repeating: "e", count: 32)

  func testAFormattedEntryIsRestoredWholeAndMarked() throws {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    let payload = ClipboardEntryPayload(
      id: id, kind: "html", text: "hello", html: "<b>hello</b>", files: [])
    XCTAssertTrue(ClipboardRestore.write(payload, plain: false, to: board))
    XCTAssertEqual(board.string(forType: .html), "<b>hello</b>")
    XCTAssertEqual(board.string(forType: .string), "hello")
    XCTAssertEqual(ClipboardMonitor.restoredEntryID(board, types: board.types ?? []), id)
    let read = try XCTUnwrap(ClipboardCapture.read(board))
    XCTAssertEqual(read.kind, .html)
    XCTAssertEqual(read.html, "<b>hello</b>")
  }

  func testPlainTextKeepsOnlyTheText() {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    let payload = ClipboardEntryPayload(
      id: id, kind: "html", text: "hello", html: "<b>hello</b>", files: [])
    XCTAssertTrue(ClipboardRestore.write(payload, plain: true, to: board))
    let types = board.types ?? []
    XCTAssertFalse(types.contains(.html), "\(types)")
    XCTAssertTrue(types.contains(ClipboardMonitor.restoredEntryType))
    XCTAssertEqual(board.string(forType: .string), "hello")
    XCTAssertEqual(ClipboardCapture.read(board)?.kind, .text)
  }

  func testImagesAndFilesRestoreTheirOwnTypes() throws {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let image = ClipboardEntryPayload(
      id: id, kind: "image", text: "", files: [], mime: "image/png", image: png)
    // An image has no text to keep plain: it is written whole either way.
    XCTAssertTrue(ClipboardRestore.write(image, plain: true, to: board))
    XCTAssertEqual(board.data(forType: .png), png)
    XCTAssertNil(board.string(forType: .string))

    let files = ClipboardEntryPayload(
      id: id, kind: "files", text: "a.txt\nb.txt", files: ["/tmp/a.txt", "/tmp/b b.txt"])
    XCTAssertTrue(ClipboardRestore.write(files, plain: false, to: board))
    let urls = try XCTUnwrap(
      board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        as? [URL])
    XCTAssertEqual(urls.map(\.path), ["/tmp/a.txt", "/tmp/b b.txt"])
    XCTAssertEqual(board.string(forType: .string), "a.txt\nb.txt")
    XCTAssertEqual(ClipboardMonitor.restoredEntryID(board, types: board.types ?? []), id)
  }

  func testNothingToWriteLeavesThePasteboardAlone() {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("before", forType: .string)
    let missing = ClipboardEntryPayload(
      id: id, kind: "image", text: "", files: [], mime: "image/png", image: nil)
    XCTAssertFalse(ClipboardRestore.write(missing, plain: false, to: board))
    XCTAssertEqual(board.string(forType: .string), "before")
  }

  func testOnlyAWellFormedMarkNamesARestoredEntry() {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.declareTypes([.string, ClipboardMonitor.restoredEntryType], owner: nil)
    board.setString("x", forType: .string)
    board.setData(Data("not-an-id".utf8), forType: ClipboardMonitor.restoredEntryType)
    XCTAssertNil(ClipboardMonitor.restoredEntryID(board, types: board.types ?? []))
    board.clearContents()
    board.setString("x", forType: .string)
    XCTAssertNil(ClipboardMonitor.restoredEntryID(board, types: board.types ?? []))
  }
}

import XCTest
@testable import FlashSearch

final class SearchQueryEngineTests: XCTestCase {
  private func makeBundle() throws -> (SearchStore, SearchIndexer, SearchQueryEngine) {
    let store = try SearchStore.inMemory()
    return (store, SearchIndexer(store: store), SearchQueryEngine(store: store))
  }

  private func doc(
    _ key: String, _ title: String, kind: String = "test",
    body: String? = nil, url: String? = nil,
    sourceID: String = "core:test", meta: [String: String] = [:]
  ) -> SearchDocument {
    SearchDocument(
      docKey: key, title: title, kind: kind, sourceID: sourceID,
      body: body, url: url, meta: meta)
  }

  func testBuildMatchExpressionStripsSpecials() {
    XCTAssertEqual(SearchQueryEngine.buildMatchExpression(""), nil)
    XCTAssertEqual(SearchQueryEngine.buildMatchExpression("  "), nil)
    XCTAssertEqual(
      SearchQueryEngine.buildMatchExpression("foo bar"),
      "\"foo\"* \"bar\"*")
    XCTAssertEqual(
      SearchQueryEngine.buildMatchExpression("a\"b c:d (e)"),
      "\"ab\"* \"cd\"* \"e\"*")
    // Only specials, no tokens.
    XCTAssertEqual(SearchQueryEngine.buildMatchExpression("(:)"), nil)
  }

  func testPrefixHit() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [
        doc("a", "Aardvark"), doc("b", "Banana"),
      ])
    let hits = try engine.querySync(SearchQuery(text: "aar"))
    XCTAssertEqual(hits.map(\.document.docKey), ["a"])
  }

  func testCaseAndDiacriticsFold() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Café Olé")])
    XCTAssertEqual(
      try engine.querySync(SearchQuery(text: "cafe")).map(\.document.docKey),
      ["a"])
    XCTAssertEqual(
      try engine.querySync(SearchQuery(text: "OLE")).map(\.document.docKey),
      ["a"])
  }

  func testCollectionScoping() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:a", owner: "core",
      documents: [doc("x", "Common")])
    _ = try indexer.upsertSync(
      collection: "core:b", owner: "core",
      documents: [doc("y", "Common")])
    let hits = try engine.querySync(
      SearchQuery(text: "common", collections: ["core:a"]))
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits[0].collection, "core:a")
  }

  func testFilterOnSource() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [
        doc("a", "Apple", sourceID: "core:browser-history"),
        doc("b", "Apple", sourceID: "core:file-index"),
      ])
    let filtered = try engine.querySync(SearchQuery(
      text: "apple",
      filters: [SearchFilter.parse(field: "source", pattern: "core:browser-history")]))
    XCTAssertEqual(filtered.map(\.document.docKey), ["a"])
  }

  func testFilterOnMetaJson() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [
        doc("a", "Note", meta: ["pinned": "true"]),
        doc("b", "Note", meta: ["pinned": "false"]),
      ])
    let pinned = try engine.querySync(SearchQuery(
      text: "note",
      filters: [SearchFilter.parse(field: "meta.pinned", pattern: "true")]))
    XCTAssertEqual(pinned.map(\.document.docKey), ["a"])
  }

  func testUnknownFilterReturnsNoRows() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    // `foo` is not a recognised field — same safe-fail policy as the
    // in-memory matcher: explicit "no rows".
    let hits = try engine.querySync(SearchQuery(
      text: "apple",
      filters: [SearchFilter.parse(field: "foo", pattern: "*")]))
    XCTAssertEqual(hits.count, 0)
  }

  func testLimitIsRespected() throws {
    let (_, indexer, engine) = try makeBundle()
    let docs = (0..<200).map { i in
      doc("k\(i)", "Apple \(i)")
    }
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core", documents: docs)
    let hits = try engine.querySync(SearchQuery(text: "apple", limit: 25))
    XCTAssertEqual(hits.count, 25)
  }

  func testHiddenCollectionExcludedFromDefaultPool() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:visible", owner: "core",
      documents: [doc("v", "Apple")])
    _ = try indexer.upsertSync(
      collection: "plugin:c:hidden", owner: "plugin:c",
      documents: [doc("h", "Apple")],
      hidden: true)

    let defaultHits = try engine.querySync(SearchQuery(text: "apple"))
    XCTAssertEqual(defaultHits.map(\.document.docKey), ["v"])

    // Explicit collection name: the owner can still read from its own
    // hidden collection.
    let explicit = try engine.querySync(SearchQuery(
      text: "apple", collections: ["plugin:c:hidden"]))
    XCTAssertEqual(explicit.map(\.document.docKey), ["h"])

    // includeHidden=true: dashboard-style queries that want both sides.
    let both = try engine.querySync(SearchQuery(text: "apple", includeHidden: true))
    XCTAssertEqual(Set(both.map(\.document.docKey)), Set(["v", "h"]))
  }

  func testEmptyQueryEmptyFiltersEmptyCollectionsReturnsEmpty() throws {
    let (_, indexer, engine) = try makeBundle()
    _ = try indexer.upsertSync(
      collection: "core:test", owner: "core",
      documents: [doc("a", "Apple")])
    let hits = try engine.querySync(SearchQuery(text: ""))
    XCTAssertEqual(hits.count, 0)
  }
}

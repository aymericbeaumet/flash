import XCTest
import FlashCore
import FlashSearch
@testable import flash

/// Locks in the unified `SearchService.search` contract:
/// * `onResults` fires synchronously first with the in-memory pool.
/// * If the DB has matching rows, `onResults` fires again
///   asynchronously with the merged set.
/// * Stale generations are dropped silently.
final class SearchServiceTests: XCTestCase {
  private func makeService() throws -> SearchService {
    var config = Config.Search()
    config.databasePath = "/private/tmp/_flash_search_svc_\(UUID().uuidString).db"
    config.queryMinChars = 1  // tests poke 1-2 char queries
    return SearchService(config: config)!
  }

  private func candidate(_ name: String, source: String = "test") -> Candidate {
    let c = Candidate(
      kind: .plugin(source),
      sourceID: "core:test",
      source: source,
      pid: nil,
      name: name,
      subtitle: "",
      bundleIdentifier: "",
      url: nil,
      sourcePayload: nil)
    return CandidateFinder.prepare(c)
  }

  func testSynchronousFirstFire() throws {
    let service = try makeService()
    defer { service.shutdown() }
    let scope = CandidateFinderSearchScope(
      pool: [candidate("Apple"), candidate("Banana")],
      scoringText: "appl",
      indexQueryText: nil,   // no DB query — only sync fire
      attributeFilters: [], indexCollections: nil)

    var fires: [[String]] = []
    service.search(scope: scope, generation: 1) { _, matches in
      fires.append(matches.map { $0.candidate.name })
    }
    // With no DB query, only the synchronous fire happens.
    XCTAssertEqual(fires.count, 1)
    XCTAssertEqual(fires[0].first, "Apple")
  }

  func testIndexHitsArriveAsynchronously() throws {
    let service = try makeService()
    defer { service.shutdown() }
    // Seed the DB with a row that ISN'T in the live pool.
    _ = try service.indexer.upsertSync(
      collection: "core:notes", owner: "core",
      documents: [
        SearchDocument(
          docKey: "k1", title: "Hidden gem",
          kind: "note", sourceID: "core:test"),
      ])
    let scope = CandidateFinderSearchScope(
      pool: [candidate("Other")],
      scoringText: "hidden",
      indexQueryText: "hidden",
      attributeFilters: [], indexCollections: ["core:notes"])

    let exp = expectation(description: "two fires")
    exp.expectedFulfillmentCount = 2
    var fires: [[String]] = []
    service.search(scope: scope, generation: 1) { _, matches in
      fires.append(matches.map { $0.candidate.name })
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
    XCTAssertEqual(fires.count, 2)
    // Second fire (async) must include the DB hit.
    XCTAssertTrue(fires[1].contains("Hidden gem"),
      "expected DB hit in second fire, got \(fires[1])")
  }

  func testStaleGenerationDoesNotPollute() throws {
    let service = try makeService()
    defer { service.shutdown() }
    let scope = CandidateFinderSearchScope(
      pool: [candidate("Apple")],
      scoringText: "appl",
      indexQueryText: nil,
      attributeFilters: [], indexCollections: nil)
    var seenGenerations: [UInt64] = []
    service.search(scope: scope, generation: 7) { gen, _ in
      seenGenerations.append(gen)
    }
    XCTAssertEqual(seenGenerations, [7])
  }

  func testRecordOpenWritesAFrecencyEntry() throws {
    let service = try makeService()
    defer { service.shutdown() }
    // recordOpen needs a stable item key. The mapper derives it from
    // bundle id, URL, or a sourcePayload envelope; a plain plugin
    // candidate with none of those returns `nil` and the open is a
    // no-op. Anchor the test on a URL.
    let c = Candidate(
      kind: .plugin("test"),
      sourceID: "core:test",
      source: "test", pid: nil,
      name: "Apricot",
      subtitle: "",
      bundleIdentifier: "",
      url: URL(string: "https://apricot.example/"),
      sourcePayload: nil)
    service.recordOpen(c)
    service.frecency.drain()
    let snapshot = (try? service.frecency.snapshotBoosts()) ?? [:]
    XCTAssertFalse(snapshot.isEmpty, "expected a frecency entry after recordOpen")
  }
}

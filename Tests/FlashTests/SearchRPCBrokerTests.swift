import XCTest
import FlashCore
import FlashSearch
@testable import flash

/// Locks in the broker's contract: plugin writes are forced into the
/// `plugin:<id>:<suffix>` namespace and a roundtrip through `upsert →
/// query` returns the same row regardless of which queue called.
final class SearchRPCBrokerTests: XCTestCase {
  private func makeBundle() throws -> (SearchService, SearchRPCBroker) {
    var searchConfig = Config.Search()
    searchConfig.databasePath = "/private/tmp/_flash_search_broker_\(UUID().uuidString).db"
    let service = SearchService(config: searchConfig)!
    return (service, SearchRPCBroker(service: service))
  }

  func testUpsertAutoPrefixesCollectionName() throws {
    let (service, broker) = try makeBundle()
    let exp = expectation(description: "upsert reply")
    broker.handle(
      method: "search.upsert",
      params: [
        "collection": "history",
        "documents": [[
          "doc_key": "k1",
          "title": "Hello world",
          "kind": "clipboard-entry",
        ]],
      ],
      pluginID: "clipboard"
    ) { reply in
      XCTAssertEqual(reply["ok"] as? Bool, true)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
    let hits = try service.queryEngine.querySync(SearchQuery(text: "hello"))
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits[0].collection, "plugin:clipboard:history")
    XCTAssertEqual(hits[0].document.docKey, "k1")
    service.shutdown()
  }

  func testCrossPluginCollectionIsRejected() throws {
    let (service, broker) = try makeBundle()
    // First plugin claims its namespace.
    let setup = expectation(description: "setup")
    broker.handle(
      method: "search.upsert",
      params: [
        "collection": "history",
        "documents": [["doc_key": "k1", "title": "Foo", "kind": "x"]],
      ],
      pluginID: "owner"
    ) { _ in setup.fulfill() }
    waitForExpectations(timeout: 5)

    // A different plugin asking for the owner's fully-qualified name
    // must be rejected — the broker prepends its own prefix, can't
    // match the existing row, and the indexer's ownership check fires.
    let exp = expectation(description: "rejected")
    broker.handle(
      method: "search.upsert",
      params: [
        "collection": "plugin:owner:history",
        "documents": [["doc_key": "k2", "title": "Bar", "kind": "x"]],
      ],
      pluginID: "evil"
    ) { reply in
      XCTAssertEqual(reply["ok"] as? Bool, false)
      XCTAssertNotNil(reply["error"])
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
    service.shutdown()
  }

  func testDeleteRoundtrips() throws {
    let (service, broker) = try makeBundle()
    let setup = expectation(description: "setup")
    broker.handle(
      method: "search.upsert",
      params: [
        "collection": "items",
        "documents": [
          ["doc_key": "a", "title": "Alpha", "kind": "note"],
          ["doc_key": "b", "title": "Beta", "kind": "note"],
        ],
      ],
      pluginID: "p"
    ) { _ in setup.fulfill() }
    waitForExpectations(timeout: 5)

    let exp = expectation(description: "delete")
    broker.handle(
      method: "search.delete",
      params: ["collection": "items", "doc_keys": ["a"]],
      pluginID: "p"
    ) { reply in
      XCTAssertEqual(reply["ok"] as? Bool, true)
      XCTAssertEqual(reply["removed"] as? Int, 1)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
    let remaining = try service.queryEngine.querySync(SearchQuery(text: "alpha"))
    XCTAssertEqual(remaining.count, 0)
    service.shutdown()
  }
}

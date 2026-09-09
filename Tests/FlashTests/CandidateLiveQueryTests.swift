import XCTest

@testable import flash

final class CandidateLiveQueryTests: XCTestCase {
  func testLateReplyAndTimeoutCannotReplaceNewerPreparedRows() throws {
    var state = CandidateLiveQuery<String>()
    let old = try XCTUnwrap(state.begin(.init(filter: "files", text: "a", sourceIDs: ["files"])))
    let current = try XCTUnwrap(
      state.begin(.init(filter: "files", text: "ab", sourceIDs: ["files"])))
    XCTAssertTrue(state.receive(["new"], sourceID: "files", token: current))
    XCTAssertFalse(state.receive(["old"], sourceID: "files", token: old))
    XCTAssertFalse(state.receive([], sourceID: "files", token: old))
    XCTAssertEqual(state.rows, ["new"])
  }

  func testChangeDuringPreparationRejectsPublicationAndClearsPreviousRows() throws {
    var state = CandidateLiveQuery<String>()
    let old = try XCTUnwrap(state.begin(.init(filter: "files", text: "a", sourceIDs: ["files"])))
    XCTAssertTrue(state.isCurrent(old))
    XCTAssertTrue(state.receive(["a"], sourceID: "files", token: old))
    _ = state.begin(.init(filter: "notes", text: "a", sourceIDs: ["notes"]))
    XCTAssertTrue(state.rows.isEmpty)
    XCTAssertFalse(state.receive(["prepared old"], sourceID: "files", token: old))
  }

  func testLeavingAndReturningToSameQueryStartsFreshRequest() throws {
    var state = CandidateLiveQuery<String>()
    let query = CandidateLiveQuery<String>.Query(filter: "files", text: "a", sourceIDs: ["files"])
    let old = try XCTUnwrap(state.begin(query))
    XCTAssertNil(state.begin(query))
    state.cancel()
    let current = try XCTUnwrap(state.begin(query))
    XCTAssertNotEqual(old, current)
    XCTAssertFalse(state.receive(["old"], sourceID: "files", token: old))
    XCTAssertFalse(state.receive(["foreign"], sourceID: "other", token: current))
    XCTAssertTrue(state.receive([], sourceID: "files", token: current))
  }

  func testFanInOrderIsStableAndEachSourceReplacesItsOwnRows() throws {
    var state = CandidateLiveQuery<String>()
    let token = try XCTUnwrap(state.begin(.init(filter: "all", text: "a", sourceIDs: ["a", "b"])))
    XCTAssertTrue(state.receive(["b"], sourceID: "b", token: token))
    XCTAssertTrue(state.receive(["a"], sourceID: "a", token: token))
    XCTAssertEqual(state.rows, ["a", "b"])
    XCTAssertTrue(state.receive([], sourceID: "b", token: token))
    XCTAssertEqual(state.rows, ["a"])
  }
}

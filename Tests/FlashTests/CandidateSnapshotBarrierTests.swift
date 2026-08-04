import FlashCore
import XCTest

@testable import flash

final class CandidateSnapshotBarrierTests: XCTestCase {
  func testRepliesPublishInDeterministicSourceOrder() {
    var barrier = CandidateSnapshotBarrier(
      generation: 7,
      startedNs: 10,
      expectedSourceIDs: ["plugin:z", "plugin:a", "plugin:a"])

    XCTAssertEqual(barrier.expectedSourceCount, 2)
    XCTAssertEqual(
      barrier.record(
        sourceID: "plugin:z",
        candidates: [candidate(sourceID: "plugin:z", title: "Z")],
        latencyMs: 31),
      .accepted)
    XCTAssertFalse(barrier.isSettled)
    XCTAssertEqual(
      barrier.record(
        sourceID: "plugin:a",
        candidates: [candidate(sourceID: "plugin:a", title: "A")],
        latencyMs: 12),
      .accepted)
    XCTAssertTrue(barrier.isSettled)

    let snapshot = barrier.finalize(reason: .allSourcesSettled)
    XCTAssertEqual(snapshot?.generation, 7)
    XCTAssertEqual(snapshot?.replies.map(\.sourceID), ["plugin:a", "plugin:z"])
    XCTAssertEqual(snapshot?.replies.map(\.latencyMs), [12, 31])
    XCTAssertEqual(snapshot?.sourceLatencies, "plugin:a:12,plugin:z:31")
    XCTAssertEqual(snapshot?.missingSourceIDs, [])
  }

  func testEmptyReplySettlesItsSource() {
    var barrier = CandidateSnapshotBarrier(
      generation: 1,
      startedNs: 0,
      expectedSourceIDs: ["plugin:empty"])

    XCTAssertEqual(
      barrier.record(sourceID: "plugin:empty", candidates: [], latencyMs: 4),
      .accepted)
    XCTAssertTrue(barrier.isSettled)
    XCTAssertEqual(
      barrier.finalize(reason: .allSourcesSettled)?.replies.first?.candidates.count,
      0)
  }

  func testBudgetFinalizationFreezesPartialSnapshotAndRejectsLateReply() {
    var barrier = CandidateSnapshotBarrier(
      generation: 2,
      startedNs: 0,
      expectedSourceIDs: ["plugin:fast", "plugin:slow"])
    XCTAssertEqual(
      barrier.record(
        sourceID: "plugin:fast",
        candidates: [candidate(sourceID: "plugin:fast", title: "Fast")],
        latencyMs: 20),
      .accepted)

    let snapshot = barrier.finalize(reason: .firstPaintBudget)
    XCTAssertEqual(snapshot?.reason, .firstPaintBudget)
    XCTAssertEqual(snapshot?.replies.map(\.sourceID), ["plugin:fast"])
    XCTAssertEqual(snapshot?.missingSourceIDs, ["plugin:slow"])
    XCTAssertEqual(
      barrier.record(
        sourceID: "plugin:slow",
        candidates: [candidate(sourceID: "plugin:slow", title: "Slow")],
        latencyMs: 120),
      .finalized)
    XCTAssertNil(barrier.finalize(reason: .allSourcesSettled))
  }

  func testDuplicateAndUnknownRepliesDoNotSettleBarrier() {
    var barrier = CandidateSnapshotBarrier(
      generation: 3,
      startedNs: 0,
      expectedSourceIDs: ["plugin:known"])
    XCTAssertEqual(
      barrier.record(sourceID: "plugin:other", candidates: [], latencyMs: 1),
      .unknownSource)
    XCTAssertFalse(barrier.isSettled)
    XCTAssertEqual(
      barrier.record(sourceID: "plugin:known", candidates: [], latencyMs: 2),
      .accepted)
    XCTAssertEqual(
      barrier.record(sourceID: "plugin:known", candidates: [], latencyMs: 3),
      .duplicate)
  }

  func testNoExpectedSourcesFinalizeImmediately() {
    var barrier = CandidateSnapshotBarrier(
      generation: 4,
      startedNs: 0,
      expectedSourceIDs: [])

    XCTAssertTrue(barrier.isSettled)
    let snapshot = barrier.finalize(reason: .allSourcesSettled)
    XCTAssertEqual(snapshot?.replies.count, 0)
    XCTAssertEqual(snapshot?.missingSourceIDs, [])
  }

  private func candidate(sourceID: String, title: String) -> Candidate {
    Candidate(
      kind: .app,
      sourceID: sourceID,
      source: sourceID,
      pid: nil,
      title: title,
      subtitle: "",
      bundleIdentifier: "",
      url: nil)
  }
}

import XCTest

@testable import flash

final class ActivationLifecycleTests: XCTestCase {
  func testNewDiscoveryRejectsOlderCompletion() {
    var lifecycle = ActivationLifecycle<String>()
    let old = lifecycle.begin()
    let current = lifecycle.begin()
    XCTAssertFalse(lifecycle.complete(token: old))
    XCTAssertEqual(lifecycle.phase, .discovering(current))
    XCTAssertTrue(lifecycle.complete(token: current))
    XCTAssertEqual(lifecycle.phase, .idle)
  }

  func testReplacementCancelsPendingClickBeforeItPosts() throws {
    var lifecycle = ActivationLifecycle<String>()
    let click = try XCTUnwrap(lifecycle.prepareCommit())
    XCTAssertTrue(lifecycle.requestReplacement("new target"))
    let discovery = lifecycle.begin()
    XCTAssertFalse(lifecycle.startCommit(token: click))
    XCTAssertNil(lifecycle.completeCommit(token: click))
    XCTAssertEqual(lifecycle.phase, .discovering(discovery))
  }

  func testActiveGestureRetainsOwnershipAndOnlyLatestReplacement() throws {
    var lifecycle = ActivationLifecycle<String>()
    let click = try XCTUnwrap(lifecycle.prepareCommit())
    XCTAssertTrue(lifecycle.startCommit(token: click))
    XCTAssertFalse(lifecycle.requestReplacement("first"))
    XCTAssertFalse(lifecycle.requestReplacement("latest"))
    XCTAssertEqual(lifecycle.phase, .committing(click, handoff: nil))
    XCTAssertNil(lifecycle.prepareCommit())
    let completion = try XCTUnwrap(lifecycle.completeCommit(token: click))
    XCTAssertFalse(completion.applyOutcome)
    XCTAssertEqual(completion.replacement, "latest")
    let next = lifecycle.begin()
    XCTAssertNil(lifecycle.completeCommit(token: click))
    XCTAssertEqual(lifecycle.phase, .discovering(next))
  }

  func testCancellationDropsQueuedActivationButStillAllowsGestureRelease() throws {
    var lifecycle = ActivationLifecycle<String>()
    let click = try XCTUnwrap(lifecycle.prepareCommit())
    XCTAssertTrue(lifecycle.startCommit(token: click))
    XCTAssertFalse(lifecycle.requestReplacement("target"))
    lifecycle.invalidate()
    XCTAssertTrue(lifecycle.inFlight)
    let completion = try XCTUnwrap(lifecycle.completeCommit(token: click))
    XCTAssertFalse(completion.applyOutcome)
    XCTAssertNil(completion.replacement)
    XCTAssertFalse(lifecycle.inFlight)
  }

  func testUninterruptedGestureAppliesItsOutcomeExactlyOnce() throws {
    var lifecycle = ActivationLifecycle<String>()
    let click = try XCTUnwrap(lifecycle.prepareCommit())
    XCTAssertTrue(lifecycle.startCommit(token: click))
    XCTAssertTrue(try XCTUnwrap(lifecycle.completeCommit(token: click)).applyOutcome)
    XCTAssertNil(lifecycle.completeCommit(token: click))
  }

  /// A commit that raised its target waits for that app's activation. The
  /// activation it waited for — and the focus loss raising it causes — is the
  /// handoff, not a cancellation; before and during the gesture alike, so the
  /// click still posts and its outcome still applies.
  func testActivatingTheAwaitedAppIsTheHandoffNotACancellation() throws {
    var lifecycle = ActivationLifecycle<String>()
    let click = try XCTUnwrap(lifecycle.prepareCommit(handoffTo: 501))
    XCTAssertEqual(lifecycle.phase, .pendingCommit(click, handoff: 501))
    XCTAssertTrue(lifecycle.isHandoff(.activated(501)))
    XCTAssertTrue(lifecycle.isHandoff(.focusLost))
    XCTAssertFalse(lifecycle.isHandoff(.activated(777)), "another app's activation cancels")
    XCTAssertTrue(lifecycle.startCommit(token: click))
    XCTAssertEqual(lifecycle.phase, .committing(click, handoff: 501))
    XCTAssertTrue(lifecycle.isHandoff(.activated(501)), "the timeout can beat the activation")
    XCTAssertTrue(try XCTUnwrap(lifecycle.completeCommit(token: click)).applyOutcome)
    XCTAssertFalse(lifecycle.isHandoff(.activated(501)), "nothing is owed once idle")
  }

  func testCommitWithoutHandoffOrSupersededIsNeverAHandoff() throws {
    var lifecycle = ActivationLifecycle<String>()
    let local = try XCTUnwrap(lifecycle.prepareCommit())
    XCTAssertFalse(lifecycle.isHandoff(.activated(501)))
    XCTAssertFalse(lifecycle.isHandoff(.focusLost))
    XCTAssertTrue(lifecycle.startCommit(token: local))
    XCTAssertNotNil(lifecycle.completeCommit(token: local))

    let awaited = try XCTUnwrap(lifecycle.prepareCommit(handoffTo: 501))
    XCTAssertTrue(lifecycle.requestReplacement("newer"))
    XCTAssertFalse(lifecycle.isHandoff(.activated(501)), "a replaced commit owes nothing")
    XCTAssertFalse(lifecycle.startCommit(token: awaited))
    _ = lifecycle.begin()
    XCTAssertFalse(lifecycle.isHandoff(.focusLost), "discovery is cancelled by focus loss")
  }

  func testSearchWithNoMatchesStillOwnsItsInteractionUntilReset() {
    var session = HintSession()
    session.phase = .search(.init())
    XCTAssertTrue(session.isActive)
    session = HintSession()
    XCTAssertFalse(session.isActive)
  }
}

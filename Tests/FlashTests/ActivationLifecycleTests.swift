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
    XCTAssertEqual(lifecycle.phase, .committing(click))
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

  func testFinishingHintSessionReleasesHeldInputExactlyOnce() {
    var session = HintSession()
    session.pointerModeActive = true
    session.didPressPrimaryButton()
    XCTAssertEqual(session.finish(), [.releasePrimaryButton])
    XCTAssertEqual(session.finish(), [])
    XCTAssertFalse(session.pointerModeActive)
    XCTAssertFalse(session.pointerDragActive)
    session.pointerModeActive = true
    session.didPressPrimaryButton()
    XCTAssertEqual(session.releasePrimaryButton(), .releasePrimaryButton)
    XCTAssertEqual(session.finish(), [])
  }

  func testSearchWithNoMatchesStillOwnsItsInteractionUntilReset() {
    var session = HintSession()
    session.searchActive = true
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.finish(), [])
    XCTAssertFalse(session.isActive)
  }
}

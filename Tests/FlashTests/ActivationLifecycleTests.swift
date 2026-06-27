import XCTest

@testable import flash

final class ActivationLifecycleTests: XCTestCase {
  func testBeginStartsAWalkAndReturnsItsToken() {
    var lifecycle = ActivationLifecycle()
    XCTAssertFalse(lifecycle.inFlight)

    let first = lifecycle.begin()
    XCTAssertTrue(lifecycle.inFlight)
    XCTAssertEqual(lifecycle.inFlightGeneration, first)
    XCTAssertTrue(lifecycle.isCurrent(first))

    let second = lifecycle.begin()
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(lifecycle.isCurrent(second))
    XCTAssertFalse(lifecycle.isCurrent(first))
  }

  func testCompleteOnlyOpensTheGateForTheOutstandingWalk() {
    var lifecycle = ActivationLifecycle()
    let token = lifecycle.begin()
    lifecycle.complete(token: token)
    XCTAssertFalse(lifecycle.inFlight)
    XCTAssertNil(lifecycle.inFlightGeneration)
  }

  func testStaleWalkCompletionDoesNotDisturbTheCurrentWalk() {
    // The core correctness: walk A starts, walk B supersedes it, then A's slow
    // completion arrives. It must NOT clear B's in-flight gate or render.
    var lifecycle = ActivationLifecycle()
    let a = lifecycle.begin()
    let b = lifecycle.begin()  // B supersedes A

    lifecycle.complete(token: a)  // A's late completion
    XCTAssertTrue(lifecycle.inFlight, "B's walk is still outstanding")
    XCTAssertEqual(lifecycle.inFlightGeneration, b)
    XCTAssertFalse(lifecycle.isCurrent(a), "A's result must be rejected")
    XCTAssertTrue(lifecycle.isCurrent(b))
  }

  func testSupersedeBumpsGenerationButLeavesInFlight() {
    // The commit path bumps the generation to drop any pending render while it
    // manually holds the gate closed across the click dispatch.
    var lifecycle = ActivationLifecycle()
    let token = lifecycle.begin()
    lifecycle.supersede()
    XCTAssertTrue(lifecycle.inFlight)
    XCTAssertFalse(lifecycle.isCurrent(token))
  }

  func testInvalidateBumpsGenerationAndOpensTheGate() {
    var lifecycle = ActivationLifecycle()
    let token = lifecycle.begin()
    lifecycle.invalidate()
    XCTAssertFalse(lifecycle.inFlight)
    XCTAssertNil(lifecycle.inFlightGeneration)
    XCTAssertFalse(lifecycle.isCurrent(token))
  }
}

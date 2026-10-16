import XCTest

@testable import flash

final class SteppedWalkTests: XCTestCase {
  /// A walk cancelled between two steps stops there: the remaining steps
  /// never run, and the caller hears that it was superseded.
  func testACancelledWalkStopsAfterTheStepInProgress() {
    let queue = DispatchQueue(label: "stepped.walk.tests")
    let finished = expectation(description: "the walk reports itself superseded")
    var stepped: [Int] = []
    var polls = 0
    SteppedWalk.run(
      count: 3, on: queue,
      isCurrent: {
        polls += 1
        return polls < 2
      },
      step: { stepped.append($0) },
      done: { completed in
        XCTAssertFalse(completed)
        finished.fulfill()
      })
    wait(for: [finished], timeout: 5)
    queue.sync { XCTAssertEqual(stepped, [0, 1]) }
  }

  func testAWalkThatStaysCurrentRunsEveryStepInOrder() {
    let queue = DispatchQueue(label: "stepped.walk.tests.complete")
    let finished = expectation(description: "the walk completes")
    var stepped: [Int] = []
    SteppedWalk.run(
      count: 3, on: queue, isCurrent: { true }, step: { stepped.append($0) },
      done: { completed in
        XCTAssertTrue(completed)
        finished.fulfill()
      })
    wait(for: [finished], timeout: 5)
    queue.sync { XCTAssertEqual(stepped, [0, 1, 2]) }
    let empty = expectation(description: "an empty walk completes at once")
    SteppedWalk.run(
      count: 0, on: queue, isCurrent: { true }, step: { _ in XCTFail() },
      done: {
        XCTAssertTrue($0)
        empty.fulfill()
      })
    wait(for: [empty], timeout: 5)
  }

  /// Observer registration, which can wait on a slow app for seconds, no
  /// longer sits in front of a walk: the two queues are independent.
  func testAWalkDoesNotWaitBehindObserverRegistration() {
    let monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    let release = DispatchSemaphore(value: 0)
    monitor.observerQueue.async { release.wait() }
    let walked = expectation(description: "the walk queue runs")
    monitor.axQueue.async { walked.fulfill() }
    wait(for: [walked], timeout: 0.5)
    release.signal()
  }
}

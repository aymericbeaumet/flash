import FlashCore
import XCTest

@testable import flash

final class ApplicationSourceSnapshotTests: XCTestCase {
  func testColdIndexReleasedAtThirtyMillisecondsJoinsFirstPublication() {
    let scanStarted = expectation(description: "scan started")
    let published = expectation(description: "first snapshot published")
    let release = DispatchSemaphore(value: 0)
    let installed = installedCandidate()
    let source = ApplicationSource(
      installedAppScanner: {
        scanStarted.fulfill()
        release.wait()
        return [installed]
      },
      watchesApplicationDirectories: false)
    wait(for: [scanStarted], timeout: 1)

    var barrier = CandidateSnapshotBarrier(
      generation: 1,
      startedNs: DispatchTime.now().uptimeNanoseconds,
      expectedSourceIDs: ["core.apps"])
    var snapshot: CandidateSnapshotBarrier.Snapshot?
    let deadline = DispatchWorkItem {
      if let frozen = barrier.finalize(reason: .firstPaintBudget) {
        snapshot = frozen
        published.fulfill()
      }
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(AppDelegate.candidateFinderFirstPaintBudgetMs),
      execute: deadline)

    source.snapshotCandidates(
      in: FlashSourceEnvironment(runningApplications: []),
      scope: .all
    ) { candidates in
      XCTAssertEqual(
        barrier.record(
          sourceID: source.identifier,
          candidates: candidates,
          latencyMs: 30),
        .accepted)
      if barrier.isSettled, let frozen = barrier.finalize(reason: .allSourcesSettled) {
        deadline.cancel()
        snapshot = frozen
        published.fulfill()
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
      release.signal()
    }

    wait(for: [published], timeout: 1)
    XCTAssertEqual(snapshot?.reason, .allSourcesSettled)
    XCTAssertEqual(snapshot?.replies.flatMap(\.candidates).map(\.title), ["Indexed App"])
    XCTAssertEqual(snapshot?.missingSourceIDs, [])
  }

  func testIndexReleasedAfterBudgetDoesNotRepaintAndJoinsNextSession() {
    let scanStarted = expectation(description: "scan started")
    let firstPublished = expectation(description: "budget snapshot published")
    let lateReply = expectation(description: "late app reply")
    let release = DispatchSemaphore(value: 0)
    let installed = installedCandidate()
    let source = ApplicationSource(
      installedAppScanner: {
        scanStarted.fulfill()
        release.wait()
        return [installed]
      },
      watchesApplicationDirectories: false)
    wait(for: [scanStarted], timeout: 1)

    var firstBarrier = CandidateSnapshotBarrier(
      generation: 1,
      startedNs: DispatchTime.now().uptimeNanoseconds,
      expectedSourceIDs: ["core.apps"])
    var firstSnapshot: CandidateSnapshotBarrier.Snapshot?
    var lateRecord: CandidateSnapshotBarrier.RecordResult?
    source.snapshotCandidates(
      in: FlashSourceEnvironment(runningApplications: []),
      scope: .all
    ) { candidates in
      lateRecord = firstBarrier.record(
        sourceID: source.identifier,
        candidates: candidates,
        latencyMs: AppDelegate.candidateFinderFirstPaintBudgetMs + 30)
      lateReply.fulfill()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(AppDelegate.candidateFinderFirstPaintBudgetMs)
    ) {
      firstSnapshot = firstBarrier.finalize(reason: .firstPaintBudget)
      firstPublished.fulfill()
    }
    DispatchQueue.global().asyncAfter(
      deadline: .now()
        + .milliseconds(AppDelegate.candidateFinderFirstPaintBudgetMs + 30)
    ) {
      release.signal()
    }

    wait(for: [firstPublished, lateReply], timeout: 1)
    XCTAssertEqual(firstSnapshot?.reason, .firstPaintBudget)
    XCTAssertEqual(firstSnapshot?.replies.count, 0)
    XCTAssertEqual(firstSnapshot?.missingSourceIDs, ["core.apps"])
    XCTAssertEqual(lateRecord, .finalized)

    var nextBarrier = CandidateSnapshotBarrier(
      generation: 2,
      startedNs: DispatchTime.now().uptimeNanoseconds,
      expectedSourceIDs: ["core.apps"])
    var nextCallbackWasSynchronous = false
    source.snapshotCandidates(
      in: FlashSourceEnvironment(runningApplications: []),
      scope: .all
    ) { candidates in
      nextCallbackWasSynchronous = true
      XCTAssertEqual(
        nextBarrier.record(
          sourceID: source.identifier,
          candidates: candidates,
          latencyMs: 0),
        .accepted)
    }
    XCTAssertTrue(nextCallbackWasSynchronous)
    let nextSnapshot = nextBarrier.finalize(reason: .allSourcesSettled)
    XCTAssertEqual(nextSnapshot?.replies.flatMap(\.candidates).map(\.title), ["Indexed App"])
  }

  private func installedCandidate() -> Candidate {
    Candidate(
      kind: .app,
      sourceID: "core.apps",
      source: "core.apps",
      title: "Indexed App",
      subtitle: "app",
      bundleIdentifier: "test.indexed",
      url: URL(fileURLWithPath: "/Applications/Indexed App.app"))
  }
}

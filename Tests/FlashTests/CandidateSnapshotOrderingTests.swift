import XCTest

@testable import flash

final class CandidateSnapshotOrderingTests: XCTestCase {
  /// Two requests for one source answered in the wrong order: the newer
  /// reply stands and the older one is dropped, whichever arrives first.
  /// Sources are ordered independently.
  func testOnlyTheNewestReplyPerSourceIsAccepted() {
    var ordering = CandidateSnapshotOrdering()
    let first = ordering.stamp("apps")
    let second = ordering.stamp("apps")
    let other = ordering.stamp("emoji")
    XCTAssertTrue(ordering.accept("apps", stamp: second))
    XCTAssertFalse(ordering.accept("apps", stamp: first), "the older reply lost the race")
    XCTAssertFalse(ordering.accept("apps", stamp: second), "a reply is accepted once")
    XCTAssertTrue(ordering.accept("emoji", stamp: other), "another source is independent")

    var inOrder = CandidateSnapshotOrdering()
    let a = inOrder.stamp("apps")
    let b = inOrder.stamp("apps")
    XCTAssertTrue(inOrder.accept("apps", stamp: a))
    XCTAssertTrue(inOrder.accept("apps", stamp: b))
  }
}

import XCTest

@testable import flash

/// Stall reports name what main was doing from this ring; the stall itself is
/// measured by the run-loop observer, with no timer pinging main.
final class MainThreadActivityTests: XCTestCase {
  func testTheRingKeepsTheMostRecentLabelsNewestFirst() {
    let labels: [StaticString] = [
      "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    ]
    for label in labels { MainThreadActivity.note(label) }
    let recent = MainThreadActivity.recent().split(separator: ",").map {
      String($0.prefix { $0 != "(" })
    }
    XCTAssertEqual(recent, ["ten", "nine", "eight", "seven", "six", "five", "four", "three"])
    XCTAssertEqual(recent.count, MainThreadActivity.ringSize)
  }
}

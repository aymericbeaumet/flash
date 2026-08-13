import ApplicationServices
import Darwin
import XCTest

@testable import flash

final class AXBrokerTests: XCTestCase {
  func testElementIdentityDeduplicatesEquivalentAXHandles() {
    let first = AXUIElementCreateApplication(getpid())
    let equivalent = AXUIElementCreateApplication(getpid())
    var identities = AXElementIdentitySet()

    XCTAssertTrue(identities.insert(first))
    XCTAssertFalse(identities.insert(equivalent))
  }
}

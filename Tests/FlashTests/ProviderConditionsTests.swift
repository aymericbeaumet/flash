import FlashCore
import XCTest

final class ProviderConditionsTests: XCTestCase {
  func testUnconditionalMatchesEveryContext() {
    let conditions = ProviderConditions()
    XCTAssertTrue(conditions.isUnconditional)
    XCTAssertTrue(conditions.matches(bundleID: nil, mode: nil))
    XCTAssertTrue(conditions.matches(bundleID: "com.example.app", mode: .insert))
  }

  func testBundleIDGateExcludesOtherAndUnknownApps() {
    let conditions = ProviderConditions(bundleIDs: ["com.example.app"])
    XCTAssertFalse(conditions.isUnconditional)
    XCTAssertTrue(conditions.matches(bundleID: "com.example.app"))
    XCTAssertFalse(conditions.matches(bundleID: "com.other.app"))
    // A gated axis the caller can't supply (nil) excludes the provider.
    XCTAssertFalse(conditions.matches(bundleID: nil))
  }

  func testModeGateExcludesOtherAndUnknownModes() {
    let conditions = ProviderConditions(modes: [.normal])
    XCTAssertTrue(conditions.matches(bundleID: "com.example.app", mode: .normal))
    XCTAssertFalse(conditions.matches(bundleID: "com.example.app", mode: .insert))
    XCTAssertFalse(conditions.matches(bundleID: "com.example.app", mode: nil))
    // An empty bundle axis stays unconditional even while the mode axis gates.
    XCTAssertTrue(conditions.matches(bundleID: nil, mode: .normal))
  }

  func testBothAxesMustAdmit() {
    let conditions = ProviderConditions(bundleIDs: ["com.example.app"], modes: [.normal])
    XCTAssertTrue(conditions.matches(bundleID: "com.example.app", mode: .normal))
    XCTAssertFalse(conditions.matches(bundleID: "com.example.app", mode: .insert))
    XCTAssertFalse(conditions.matches(bundleID: "com.other.app", mode: .normal))
    XCTAssertFalse(conditions.matches(bundleID: nil, mode: .normal))
  }
}

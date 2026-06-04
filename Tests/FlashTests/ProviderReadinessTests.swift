import FlashCore
import FlashProviders
import XCTest

final class ProviderReadinessTests: XCTestCase {
  func testProviderDefaultIsActivationOnly() {
    let provider = StubProvider()
    XCTAssertEqual(provider.readinessPolicy, .activationOnly)
    XCTAssertFalse(provider.resultsAreVolatile)
  }

  func testBuiltInProviderPolicies() {
    XCTAssertEqual(AccessibilityProvider().readinessPolicy, .continuous)
    XCTAssertEqual(TmuxProvider().readinessPolicy, .volatile)
    XCTAssertTrue(TmuxProvider().resultsAreVolatile)
  }
}

private final class StubProvider: JumpProvider {
  let identifier = "stub"
  let priority = 0

  func supports(_ context: AppContext) -> Bool { false }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    []
  }
}

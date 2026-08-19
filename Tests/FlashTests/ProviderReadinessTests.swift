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
  }

  func testAccessibilityProviderTreatsComboboxAsEditableTarget() {
    XCTAssertTrue(AccessibilityProvider.roles.contains("AXComboBox"))
    XCTAssertTrue(AccessibilityProvider.webClickableRoles.contains("AXComboBox"))
  }

  func testAccessibilityProviderIncludesNativeControlRolesFromAXPeers() {
    XCTAssertTrue(AccessibilityProvider.roles.contains("AXSlider"))
    XCTAssertTrue(AccessibilityProvider.roles.contains("AXIncrementor"))
    XCTAssertTrue(AccessibilityProvider.roles.contains("AXHandle"))
    XCTAssertFalse(AccessibilityProvider.webClickableRoles.contains("AXSlider"))
  }

  func testAccessibilityWakeDoesNotPoisonFirefoxWindowManagement() {
    XCTAssertFalse(
      AccessibilityProvider.shouldExplicitlyWakeAccessibility(
        bundleIdentifier: "org.mozilla.firefox"))
    XCTAssertFalse(
      AccessibilityProvider.shouldExplicitlyWakeAccessibility(
        bundleIdentifier: "org.mozilla.firefoxdeveloperedition"))
    XCTAssertFalse(
      AccessibilityProvider.shouldExplicitlyWakeAccessibility(
        bundleIdentifier: "org.mozilla.nightly"))
    XCTAssertFalse(
      AccessibilityProvider.shouldExplicitlyWakeAccessibility(bundleIdentifier: "com.apple.Notes"))
    XCTAssertTrue(
      AccessibilityProvider.shouldExplicitlyWakeAccessibility(
        bundleIdentifier: "com.google.Chrome"))
  }

  func testExtensionPopupRolesStayScopedToExtensionDocuments() {
    XCTAssertFalse(AccessibilityProvider.webClickableRoles.contains("AXGroup"))
    XCTAssertFalse(AccessibilityProvider.webClickableRoles.contains("AXOption"))
    XCTAssertTrue(AccessibilityProvider.webExtensionPopupPressRoles.contains("AXGroup"))
    XCTAssertTrue(AccessibilityProvider.webExtensionPopupPressRoles.contains("AXOption"))
    XCTAssertTrue(
      AccessibilityProvider.isExtensionDocumentURL("chrome-extension://abc/popup.html"))
    XCTAssertTrue(
      AccessibilityProvider.isExtensionDocumentURL("moz-extension://abc/popup.html"))
    XCTAssertTrue(
      AccessibilityProvider.isExtensionDocumentURL("safari-web-extension://abc/popup.html"))
    XCTAssertFalse(AccessibilityProvider.isExtensionDocumentURL("https://example.com"))
  }

}

private final class StubProvider: FlashSource {
  let identifier = "stub"
  let priority = 0

  func supports(_ context: AppContext) -> Bool { false }

  func discover(in context: AppContext) throws -> [JumpTarget] {
    []
  }
}

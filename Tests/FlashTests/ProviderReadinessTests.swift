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

  /// The enhanced-UI flags go only to runtimes that gate their tree on them:
  /// Gecko is scoped per operation, and native apps never get them.
  func testAccessibilityWakeFollowsTheRuntimeNotTheApp() {
    XCTAssertTrue(AppTraits(engine: .chromium).needsAccessibilityWake)
    XCTAssertTrue(AppTraits(engine: .flutter).needsAccessibilityWake)
    XCTAssertFalse(AppTraits(engine: .gecko).needsAccessibilityWake)
    XCTAssertFalse(AppTraits().needsAccessibilityWake)
  }

  func testRuntimeIsReadFromTheBundleLayout() {
    func engine(xul: Bool = false, _ frameworks: [String], helpers: [String: [String]] = [:])
      -> AppTraits.Engine?
    {
      AppTraits.engine(hasXUL: xul, frameworks: frameworks) { helpers[$0] ?? [] }
    }
    XCTAssertEqual(engine(xul: true, []), .gecko)
    XCTAssertEqual(
      engine(
        ["Google Chrome Framework.framework"],
        helpers: ["Google Chrome Framework.framework": ["Google Chrome Helper (Renderer).app"]]),
      .chromium, "a browser keeps its renderer helpers inside its framework")
    XCTAssertEqual(
      engine(["Electron Framework.framework", "Slack Helper (Renderer).app"]), .chromium,
      "an Electron app keeps them beside it")
    XCTAssertEqual(engine(["FlutterMacOS.framework"]), .flutter)
    XCTAssertNil(engine(["Sparkle.framework"], helpers: ["Sparkle.framework": ["Updater.app"]]))
  }

  func testWebBrowsersAreAppsThatHandleBothWebSchemes() {
    func info(_ schemes: [String]) -> [String: Any] {
      ["CFBundleURLTypes": [["CFBundleURLSchemes": schemes]]]
    }
    XCTAssertTrue(AppTraits.handlesWebURLs(infoDictionary: info(["file", "HTTP", "https"])))
    XCTAssertFalse(AppTraits.handlesWebURLs(infoDictionary: info(["slack"])))
    XCTAssertFalse(AppTraits.handlesWebURLs(infoDictionary: info(["https"])))
    XCTAssertFalse(AppTraits.handlesWebURLs(infoDictionary: [:]))
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

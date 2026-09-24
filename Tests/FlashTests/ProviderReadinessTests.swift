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
    func engine(
      xul: Bool = false, shim: Bool = false, _ frameworks: [String],
      helpers: [String: [String]] = [:]
    ) -> AppTraits.Engine? {
      AppTraits.engine(hasXUL: xul, isChromiumAppShim: shim, frameworks: frameworks) {
        helpers[$0] ?? []
      }
    }
    XCTAssertEqual(engine(xul: true, []), .gecko)
    XCTAssertEqual(
      engine(shim: true, []), .chromium,
      "a Chromium app shim embeds no framework: the browser renders its windows")
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

  /// Installed web apps (PWAs) are small shim bundles Chrome, Edge or Brave
  /// write from the browser's `app_mode-Info.plist` template: the executable
  /// is the browser's `app_mode_loader`, and the plist names the shortcut.
  func testChromiumWebAppShimsWakeAccessibility() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-app-traits-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    func bundle(_ name: String, executable: String, info: [String: Any]) throws -> URL {
      let url = root.appendingPathComponent("\(name).app")
      let macOS = url.appendingPathComponent("Contents/MacOS")
      try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
      FileManager.default.createFile(
        atPath: macOS.appendingPathComponent(executable).path, contents: Data())
      var plist = info
      plist["CFBundleExecutable"] = executable
      plist["CFBundleIdentifier"] = "com.example.\(name)"
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
      return url
    }

    let shim = try bundle(
      "Shim", executable: "app_mode_loader",
      info: ["CrAppModeShortcutID": "abcdefghijklmnop", "CrAppModeShortcutURL": "https://x.test"])
    XCTAssertEqual(AppTraits.read(bundleURL: shim).engine, .chromium)
    XCTAssertTrue(AppTraits.read(bundleURL: shim).needsAccessibilityWake)

    let renamedLoader = try bundle(
      "Renamed", executable: "Web App", info: ["CrAppModeShortcutID": "abcdefghijklmnop"])
    XCTAssertEqual(
      AppTraits.read(bundleURL: renamedLoader).engine, .chromium,
      "the shortcut key alone identifies a shim")

    let loaderOnly = try bundle("LoaderOnly", executable: "app_mode_loader", info: [:])
    XCTAssertEqual(
      AppTraits.read(bundleURL: loaderOnly).engine, .chromium,
      "the loader alone identifies a shim")

    let native = try bundle("Native", executable: "Native", info: [:])
    XCTAssertNil(AppTraits.read(bundleURL: native).engine)
    XCTAssertFalse(AppTraits.read(bundleURL: native).needsAccessibilityWake)
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

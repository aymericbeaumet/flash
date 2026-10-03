import AppKit
import FlashCore
import XCTest

@testable import flash

/// The inspector's "How actions resolve in <App>": for the focused app, each
/// action's sources, then its winning binding and who declared it.
final class ActionResolutionInspectorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testRowsShowSourcesThenTheWinningBindingAndItsPlugin() throws {
    let index = ActionBindingIndex(manifests: try SourceActionFallbackTests.officialManifests())
    let rows = AppDelegate.actionResolutionRows(
      resolutions: index.resolutions(in: PluginSelectorContext(bundleID: "com.apple.Notes"))
    ) { action in
      action == .tabNext ? ["plugin:tmux", "accessibility"] : []
    }
    func row(_ name: String) throws -> [String: Any] {
      try XCTUnwrap(rows.first { $0["action"] as? String == name }, name)
    }
    XCTAssertEqual(rows.count, SourceActionName.allCases.count, "one row per action")
    XCTAssertEqual(rows.map { $0["action"] as? String }, SourceActionName.allCases.map(\.rawValue))

    let next = try row("tab_next")
    XCTAssertEqual(next["binding"] as? String, "cmd+shift+]")
    XCTAssertEqual(next["source"] as? String, "defaults")
    XCTAssertEqual(next["claimed_by"] as? [String], ["source:tmux", "source:accessibility"])

    let tabNew = try row("tab_new")
    XCTAssertEqual(tabNew["binding"] as? String, "none", "Notes has no tabs")
    XCTAssertEqual(tabNew["source"] as? String, "defaults")

    let reload = try row("app_reload")
    XCTAssertTrue(reload["binding"] is NSNull, "nothing binds reload in Notes")
    XCTAssertTrue(reload["source"] is NSNull)

    let resourceNext = try row("resource_next")
    XCTAssertEqual(resourceNext["binding"] as? String, "scroll down")
    XCTAssertEqual(resourceNext["source"] as? String, "flash")

    XCTAssertEqual(
      try row("window_close")["claimed_by"] as? [String], ["flash:close_button"],
      "the close button comes before the binding")
    XCTAssertNotNil(try JSONSerialization.data(withJSONObject: rows))
  }

  func testDebugStateCarriesTheResolution() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    let mappings = try XCTUnwrap(delegate.debugStateJSON()["mappings"] as? [String: Any])
    let actions = try XCTUnwrap(mappings["actions"] as? [[String: Any]])
    XCTAssertEqual(actions.count, SourceActionName.allCases.count)
  }

  /// The committed inspector bundle renders the resolution on the Mappings
  /// page.
  func testCommittedInspectorRendersTheResolution() throws {
    let html = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/flash/Resources/inspector.html"),
      encoding: .utf8)
    XCTAssertTrue(html.contains("How actions resolve in"))
  }
}

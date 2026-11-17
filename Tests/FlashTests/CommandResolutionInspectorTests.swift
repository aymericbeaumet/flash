import AppKit
import FlashCore
import XCTest

@testable import flash

/// The inspector's "How commands resolve in <App>": for the focused app, each
/// command's sources, then its winning binding and who declared it.
final class CommandResolutionInspectorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testRowsShowSourcesThenTheWinningBindingAndItsPlugin() throws {
    let index = CommandBindingIndex(manifests: try SourceCommandFallbackTests.officialManifests())
    let rows = AppDelegate.commandResolutionRows(
      resolutions: index.resolutions(in: PluginSelectorContext(bundleID: "com.apple.Notes"))
    ) { name in
      name == CommandName("tab", "next") ? ["plugin:tmux", "accessibility"] : []
    }
    func row(_ key: String) throws -> [String: Any] {
      try XCTUnwrap(rows.first { $0["command"] as? String == key }, key)
    }
    let keys = URLEventHandler.sourceCommandBindingKeys
    XCTAssertEqual(rows.count, keys.count, "one row per binding key")
    XCTAssertEqual(rows.map { $0["command"] as? String }, keys.map(\.description))

    let next = try row("tab next")
    XCTAssertEqual(next["binding"] as? String, "cmd+shift+]")
    XCTAssertEqual(next["source"] as? String, "defaults")
    XCTAssertEqual(next["claimed_by"] as? [String], ["source:tmux", "source:accessibility"])

    let tabNew = try row("tab new")
    XCTAssertEqual(tabNew["binding"] as? String, "none", "Notes has no tabs")
    XCTAssertEqual(tabNew["source"] as? String, "defaults")

    let reload = try row("app reload")
    XCTAssertTrue(reload["binding"] is NSNull, "nothing binds reload in Notes")
    XCTAssertTrue(reload["source"] is NSNull)
    XCTAssertTrue(try row("app reload --force")["binding"] is NSNull, "a flag variant is a row")

    let resourceNext = try row("resource next")
    XCTAssertEqual(resourceNext["binding"] as? String, "scroll down")
    XCTAssertEqual(resourceNext["source"] as? String, "flash")

    XCTAssertEqual(
      try row("window close")["claimed_by"] as? [String], ["flash:close_button"],
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
    let commands = try XCTUnwrap(mappings["commands"] as? [[String: Any]])
    XCTAssertEqual(commands.count, URLEventHandler.sourceCommandBindingKeys.count)
    XCTAssertNil(mappings["actions"], "the retired key is gone")
  }

  /// The committed inspector bundle renders the resolution on the Mappings
  /// page.
  func testCommittedInspectorRendersTheResolution() throws {
    let html = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/flash/Resources/inspector.html"),
      encoding: .utf8)
    XCTAssertTrue(html.contains("How commands resolve in"))
    XCTAssertFalse(html.contains("How actions resolve in"))
  }
}

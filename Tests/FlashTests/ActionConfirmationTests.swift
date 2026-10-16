import AppKit
import FlashCore
import XCTest

@testable import flash

/// `action_confirmations`: the question a plugin declares before an action it
/// performs destructively, its validation, and which plugin's question the
/// host asks in the focused app.
final class ActionConfirmationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testDecodesAPromptPerDeclaredAction() throws {
    let manifest = try load(
      """
      "exec": ["./plugin"],
      "actions": ["tab_close", "pane_close"],
      "action_confirmations": { "tab_close": " Close this window? " }
      """)
    XCTAssertEqual(manifest.actionConfirmations, [.tabClose: "Close this window?"])
  }

  func testMalformedConfirmationsRejectTheManifest() {
    let malformed: [(String, String)] = [
      (
        #""exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "nope": "x" }"#,
        "unknown action"
      ),
      (
        #""exec": ["./p"], "actions": ["tab_new"], "action_confirmations": { "tab_close": "x" }"#,
        "an action the plugin does not perform"
      ),
      (
        #""exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": " " }"#,
        "empty prompt"
      ),
      (
        #""exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": 1 }"#,
        "non-string prompt"
      ),
      (#""action_confirmations": { "tab_close": "x" }"#, "manifest-only plugin performs nothing"),
    ]
    for (fragment, reason) in malformed {
      XCTAssertThrowsError(try load(fragment), reason)
    }
  }

  func testTheBundledTmuxPluginGatesItsKills() throws {
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "tmux" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.actionConfirmations,
      [.tabClose: "Close this tmux window?", .paneClose: "Close this tmux pane?"])
  }

  func testAMatchingSelectorBeatsPriorityWhichBeatsPluginID() throws {
    let generic = try manifest(
      id: "generic",
      #""priority": 90, "exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "generic?" }"#
    )
    let scoped = try manifest(
      id: "scoped",
      #""priority": 10, "only_bundle_ids": ["com.x"], "exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "scoped?" }"#
    )
    let index = ActionConfirmationIndex(manifests: [generic, scoped])
    XCTAssertEqual(index.prompt(for: .tabClose, in: context("com.x")), "scoped?")
    XCTAssertEqual(index.prompt(for: .tabClose, in: context("com.y")), "generic?")
    XCTAssertNil(index.prompt(for: .paneClose, in: context("com.x")))

    let low = try manifest(
      id: "low",
      #""priority": 10, "exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "low?" }"#
    )
    let high = try manifest(
      id: "high",
      #""priority": 20, "exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "high?" }"#
    )
    XCTAssertEqual(
      ActionConfirmationIndex(manifests: [low, high]).prompt(for: .tabClose, in: context("com.x")),
      "high?")

    let first = try manifest(
      id: "aa",
      #""exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "aa?" }"#)
    let second = try manifest(
      id: "bb",
      #""exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "bb?" }"#)
    XCTAssertEqual(
      ActionConfirmationIndex(manifests: [first, second]).prompt(
        for: .tabClose, in: context("com.x")),
      "aa?", "an exact tie keeps the first plugin by id")
  }

  func testOnlyTerminalsGatesTheQuestionToDeclaredEmulators() throws {
    let index = ActionConfirmationIndex(manifests: [
      try manifest(
        id: "term",
        #""only_terminals": true, "exec": ["./p"], "actions": ["tab_close"], "action_confirmations": { "tab_close": "Close the window?" }"#
      )
    ])
    XCTAssertEqual(
      index.prompt(for: .tabClose, in: context("com.mitchellh.ghostty")), "Close the window?")
    XCTAssertNil(index.prompt(for: .tabClose, in: context("com.apple.finder")))
  }

  // MARK: - Helpers

  private func context(_ bundle: String) -> PluginSelectorContext {
    PluginSelectorContext(bundleID: bundle)
  }

  private func load(_ fragment: String) throws -> PluginManifest {
    try manifest(id: "example", fragment)
  }

  private func manifest(id: String, _ fragment: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-action-confirmations-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let json = """
      {
        "id": "\(id)", "name": "\(id)", "version": "0.1.0", "description": "test",
        \(fragment)
      }
      """
    try json.write(
      to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }
}

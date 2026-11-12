import AppKit
import FlashCore
import XCTest

@testable import flash

/// `confirm` on a `commands[]` entry: the question a plugin declares before a
/// core command it performs destructively, its validation, and which plugin's
/// question the host asks in the focused app.
final class CommandConfirmationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    TerminalEmulatorFixture.declareOfficial()
  }

  func testDecodesAPromptPerPerformedCommand() throws {
    let manifest = try load(
      """
      "exec": ["./plugin"],
      "commands": [
        { "command": "tab", "subcommand": "close", "confirm": " Close this window? " },
        { "command": "pane", "subcommand": "close" }
      ]
      """)
    XCTAssertEqual(manifest.confirmations, [CommandName("tab", "close"): "Close this window?"])
    XCTAssertEqual(
      manifest.sourceCommands, [CommandName("tab", "close"), CommandName("pane", "close")])
    XCTAssertEqual(manifest.pluginCommands, [])
  }

  func testMalformedConfirmationsRejectTheManifest() {
    let malformed: [(String, String)] = [
      (
        #""exec": ["./p"], "commands": [{ "command": "example", "subcommand": "run", "confirm": "x" }]"#,
        "a plugin's own command is never gated by the host"
      ),
      (
        #""exec": ["./p"], "commands": [{ "command": "tab", "subcommand": "close", "confirm": " " }]"#,
        "empty prompt"
      ),
      (
        #""exec": ["./p"], "commands": [{ "command": "tab", "subcommand": "close", "confirm": 1 }]"#,
        "non-string prompt"
      ),
      (
        #""commands": [{ "command": "tab", "subcommand": "close", "confirm": "x" }]"#,
        "manifest-only plugin performs nothing"
      ),
    ]
    for (fragment, reason) in malformed {
      XCTAssertThrowsError(try load(fragment), reason)
    }
  }

  func testTheBundledTerminalsPluginGatesItsTmuxKills() throws {
    let root = try XCTUnwrap(
      PluginRepository.officialPluginRoots().first { $0.lastPathComponent == "terminals" })
    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(
      manifest.confirmations,
      [
        CommandName("tab", "close"): "Close this tmux window?",
        CommandName("pane", "close"): "Close this tmux pane?",
      ])
  }

  func testAMatchingSelectorBeatsPriorityWhichBeatsPluginID() throws {
    func closes(_ prompt: String) -> String {
      #""exec": ["./p"], "commands": [{ "command": "tab", "subcommand": "close", "confirm": "\#(prompt)" }]"#
    }
    let generic = try manifest(id: "generic", #""priority": 90, "# + closes("generic?"))
    let scoped = try manifest(
      id: "scoped", #""priority": 10, "only_bundle_ids": ["com.x"], "# + closes("scoped?"))
    let index = CommandConfirmationIndex(manifests: [generic, scoped])
    let tabClose = CommandName("tab", "close")
    XCTAssertEqual(index.prompt(for: tabClose, in: context("com.x")), "scoped?")
    XCTAssertEqual(index.prompt(for: tabClose, in: context("com.y")), "generic?")
    XCTAssertNil(index.prompt(for: CommandName("pane", "close"), in: context("com.x")))

    let low = try manifest(id: "low", #""priority": 10, "# + closes("low?"))
    let high = try manifest(id: "high", #""priority": 20, "# + closes("high?"))
    XCTAssertEqual(
      CommandConfirmationIndex(manifests: [low, high]).prompt(for: tabClose, in: context("com.x")),
      "high?")

    let first = try manifest(id: "aa", closes("aa?"))
    let second = try manifest(id: "bb", closes("bb?"))
    XCTAssertEqual(
      CommandConfirmationIndex(manifests: [first, second]).prompt(
        for: tabClose, in: context("com.x")),
      "aa?", "an exact tie keeps the first plugin by id")
  }

  func testOnlyTerminalsGatesTheQuestionToDeclaredEmulators() throws {
    let index = CommandConfirmationIndex(manifests: [
      try manifest(
        id: "term",
        #""only_terminals": true, "exec": ["./p"], "commands": [{ "command": "tab", "subcommand": "close", "confirm": "Close the window?" }]"#
      )
    ])
    let tabClose = CommandName("tab", "close")
    XCTAssertEqual(
      index.prompt(for: tabClose, in: context("com.mitchellh.ghostty")), "Close the window?")
    XCTAssertNil(index.prompt(for: tabClose, in: context("com.apple.finder")))
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
      .appendingPathComponent("flash-command-confirmations-\(UUID().uuidString)")
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

import AppKit
import FlashCore
import XCTest

@testable import flash

/// A plugin's own command and a flashlight row that declare `confirm`, driven
/// through a real `AppDelegate` and `PluginManager` against a fixture plugin:
/// the host asks through its one confirmation phase, sends nothing until the
/// answer is yes, and marks the perform that follows as confirmed.
final class PluginConfirmationFlowTests: XCTestCase {
  private static let officialIDs: Set<String> = Set(
    PluginRepository.officialPluginRoots().compactMap {
      (try? PluginManifest.load(from: $0))?.id
    })

  private var fixture: PluginFixtureKit.Fixture!
  private var delegate: AppDelegate!
  /// Where the resident's own manager keeps the fixture's data: inside the
  /// test runner, a temporary directory.
  private var dataDir: URL!

  private let erase = URLCommand.pluginCommand(command: "danger", subcommand: "erase", args: [])
  private let list = URLCommand.pluginCommand(command: "danger", subcommand: "list", args: [])

  override func setUpWithError() throws {
    _ = NSApplication.shared
    fixture = try PluginFixtureKit.make(
      id: "danger",
      manifest: PluginFixtureKit.manifest(
        id: "danger",
        extra: """
          "commands": [
            { "command": "danger", "subcommand": "erase", "description": "x",
              "confirm": "Erase everything?" },
            { "command": "danger", "subcommand": "list", "description": "x" }
          ],
          "sources": [{ "name": "danger.rows", "type": "dangers", "live": "per_scope" }]
          """),
      script: PluginFixtureKit.script(
        onPerform: """
          printf '%s\\n' "$line" >> "$D/performs"
          case "$line" in
          *'"title":"Broken"'*)
            printf '{"id":%s,"result":{"ok":false,"error":"the row broke"}}\\n' "$id" ;;
          *)
            \(PluginFixtureKit.performOK) ;;
          esac
          """))
    dataDir = PluginRepository.defaultDataDir().appendingPathComponent("danger")
    XCTAssertTrue(
      dataDir.path.hasPrefix(FileManager.default.temporaryDirectory.path),
      "the test runner's plugin data is temporary: \(dataDir.path)")
    try? FileManager.default.removeItem(at: dataDir)
    delegate = AppDelegate()
    var config = Config()
    config.plugins.thirdParty = [try XCTUnwrap(PluginReference.parse("file:\(fixture.root.path)"))]
    config.plugins.disabled = Self.officialIDs
    config.plugins.watchingEnabled = false
    delegate.config = config
    let manager = delegate.pluginManager
    delegate.registry = SourceRegistry(
      descriptors: [], runningApplications: [], pluginSourcesProvider: { manager.sources })
    delegate.monitor = AppMonitor(registry: delegate.registry, config: config)
    delegate.overlay = OverlayPanel()
    manager.start(config: config)
    waitUntilTrue("the fixture loaded") {
      manager.pluginStatuses().contains { $0.id == "danger" }
    }
  }

  override func tearDown() {
    delegate?.pluginManager.stop()
    delegate?.overlay?.dismissAlert()
    delegate?.overlay?.orderOut(nil)
    fixture?.cleanup()
    if let dataDir, dataDir.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
      try? FileManager.default.removeItem(at: dataDir)
    }
  }

  /// One line per spawn of the fixture, as its script records them.
  private func spawnCount() -> Int {
    let text = (try? String(contentsOf: dataDir.appendingPathComponent("spawns"), encoding: .utf8))
    return text?.split(separator: "\n").count ?? 0
  }

  /// The `perform` frames the fixture received, in order.
  private func performs() -> [[String: Any]] {
    let text =
      (try? String(contentsOf: dataDir.appendingPathComponent("performs"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["params"]
        as? [String: Any]
    }
  }

  private func waitForPerforms(_ count: Int) throws -> [[String: Any]] {
    waitUntilTrue("\(count) perform(s) reached the plugin") { self.performs().count == count }
    // A wait that failed has said so; never index what it left short.
    let sent = performs()
    guard sent.count == count else { throw CocoaError(.fileReadUnknown) }
    return sent
  }

  func testAnOwnCommandAsksFirstAndRunsConfirmedOnYes() throws {
    XCTAssertEqual(
      delegate.pluginManager.ownCommandConfirmation(command: "danger", subcommand: "erase"),
      "Erase everything?")
    XCTAssertEqual(
      delegate.pluginManager.ownCommandConfirmation(command: "Danger", subcommand: "ERASE"),
      "Erase everything?", "resolved as dispatch resolves the words")
    XCTAssertNil(
      delegate.pluginManager.ownCommandConfirmation(command: "danger", subcommand: "list"))
    XCTAssertNil(
      delegate.pluginManager.ownCommandConfirmation(command: "other", subcommand: "erase"))

    // From a key, with a count: the question is the outcome.
    var outcomes: [NormalModeCommandOutcome] = []
    delegate.performMappedCommand(erase, repeatCount: 3) { outcomes.append($0) }
    XCTAssertEqual(outcomes, [.performed], "asking counts as run")
    XCTAssertEqual(
      delegate.hintSession.confirmation,
      HintSession.Confirmation(prompt: "Erase everything?", command: erase, repeatCount: 3))
    settleRunLoop(0.3)
    XCTAssertEqual(performs().count, 0, "nothing is sent before the answer")
    XCTAssertEqual(spawnCount(), 0, "not even a process")

    // Any other key: the question closes and nothing runs.
    delegate.overlayDidConfirm(accepted: false)
    XCTAssertNil(delegate.hintSession.confirmation)
    settleRunLoop(0.3)
    XCTAssertEqual(performs().count, 0)

    delegate.performMappedCommand(erase, repeatCount: 3)
    delegate.overlayDidConfirm(accepted: true)
    XCTAssertNil(delegate.hintSession.confirmation, "one answer, one question")
    let sent = try waitForPerforms(1)
    XCTAssertEqual(sent[0]["subcommand"] as? String, "erase")
    XCTAssertEqual(PluginJSON.boolean(sent[0]["confirmed"]), true)
    XCTAssertEqual(sent[0]["count"] as? Int, 3, "the count survives the question")
  }

  /// The CLI and the command line reach a plugin command through
  /// `handleURLCommand`: they ask the same question.
  func testTheCommandLineAndTheCLIAskTheSameQuestion() throws {
    var replies: [NormalModeCommandOutcome] = []
    XCTAssertTrue(delegate.handleURLCommand(erase) { outcome, _ in replies.append(outcome) })
    XCTAssertEqual(replies, [.performed])
    XCTAssertEqual(
      delegate.hintSession.confirmation,
      HintSession.Confirmation(prompt: "Erase everything?", command: erase))
    delegate.overlayDidConfirm(accepted: true)
    let sent = try waitForPerforms(1)
    XCTAssertEqual(PluginJSON.boolean(sent[0]["confirmed"]), true)
    XCTAssertNil(sent[0]["count"])

    // A command without `confirm` runs at once and says nothing of consent.
    XCTAssertTrue(delegate.handleURLCommand(list))
    XCTAssertNil(delegate.hintSession.confirmation)
    let both = try waitForPerforms(2)
    XCTAssertEqual(both[1]["subcommand"] as? String, "list")
    XCTAssertNil(both[1]["confirmed"], "absent, never false")
  }

  /// `alert confirm` wraps a line: its `y` is the user's consent, so the
  /// wrapped command runs confirmed and its own question is not asked again.
  func testAlertConfirmAsksOnceAndItsYesConfirmsTheWrappedCommand() throws {
    let wrapped = URLCommand.confirm(ConfirmCommand(prompt: "Really?", command: erase))
    XCTAssertTrue(delegate.handleURLCommand(wrapped))
    XCTAssertEqual(
      delegate.hintSession.confirmation,
      HintSession.Confirmation(prompt: "Really?", command: erase))
    delegate.overlayDidConfirm(accepted: true)
    XCTAssertNil(delegate.hintSession.confirmation, "the manifest's question is not asked too")
    let sent = try waitForPerforms(1)
    XCTAssertEqual(sent[0]["subcommand"] as? String, "erase")
    XCTAssertEqual(PluginJSON.boolean(sent[0]["confirmed"]), true)

    XCTAssertTrue(
      delegate.handleURLCommand(.confirm(ConfirmCommand(prompt: "List?", command: list))))
    delegate.overlayDidConfirm(accepted: true)
    let both = try waitForPerforms(2)
    XCTAssertEqual(PluginJSON.boolean(both[1]["confirmed"]), true)
  }

  /// A row that carries `confirm` asks before its resolve is sent; a plain
  /// row resolves at once, unmarked.
  func testARowAsksBeforeItsResolveIsSent() throws {
    func row(_ title: String, confirm: String? = nil) -> Candidate {
      CandidateFinder.prepare(
        Candidate(
          title: title,
          metadata: [
            CandidateMetadataKey.source: "danger.rows",
            CandidateMetadataKey.sourceID: "plugin:danger",
            CandidateMetadataKey.kind: "plugin",
          ], confirm: confirm))
    }
    let restart = row("Restart Mac", confirm: "Restart this Mac?")
    delegate.openSourceItem(restart, recordMovement: false)
    let asked = try XCTUnwrap(delegate.hintSession.confirmation)
    XCTAssertEqual(asked.prompt, "Restart this Mac?")
    XCTAssertEqual(
      asked.action, .row(.init(candidate: restart, recordMovement: false)))
    settleRunLoop(0.3)
    XCTAssertEqual(performs().count, 0, "no resolve before the answer")

    delegate.overlayDidConfirm(accepted: false)
    settleRunLoop(0.3)
    XCTAssertEqual(performs().count, 0, "a cancelled row resolves nothing")

    delegate.openSourceItem(restart, recordMovement: false)
    delegate.overlayDidConfirm(accepted: true)
    XCTAssertNil(delegate.hintSession.confirmation)
    let sent = try waitForPerforms(1)
    XCTAssertEqual(sent[0]["kind"] as? String, "resolve")
    XCTAssertEqual(PluginJSON.boolean(sent[0]["confirmed"]), true)
    let echoed = try XCTUnwrap(sent[0]["row"] as? [String: Any])
    XCTAssertEqual(echoed["title"] as? String, "Restart Mac")
    XCTAssertEqual(echoed["confirm"] as? String, "Restart this Mac?", "the row as it was sent")

    delegate.openSourceItem(row("Lock screen"), recordMovement: false)
    XCTAssertNil(delegate.hintSession.confirmation)
    let both = try waitForPerforms(2)
    XCTAssertEqual(both[1]["kind"] as? String, "resolve")
    XCTAssertNil(both[1]["confirmed"])
    XCTAssertNil((both[1]["row"] as? [String: Any])?["confirm"])
  }

  /// A row the user picked whose resolve fails says why, in its plugin's
  /// words, as a command does.
  func testARowThatFailsShowsItsPluginsReason() throws {
    let broken = CandidateFinder.prepare(
      Candidate(
        title: "Broken",
        metadata: [
          CandidateMetadataKey.source: "danger.rows",
          CandidateMetadataKey.sourceID: "plugin:danger",
        ]))
    let resolved = expectation(description: "resolved")
    var resolution = CandidateResolution.unresolved
    delegate.registry.resolveCandidate(broken) {
      resolution = $0
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 15)
    XCTAssertFalse(resolution.didResolve)
    XCTAssertEqual(resolution.failureReason, "the row broke")

    XCTAssertNil(delegate.overlay.toast)
    delegate.openSourceItem(broken, recordMovement: false)
    waitUntilTrue("the failure alert shows") {
      self.delegate.overlay.toast?.outlivesTeardown == true
    }
  }

  /// A row's question gates its host effect too: nothing is copied until
  /// the user answers yes.
  func testARowsQuestionGatesItsHostEffect() throws {
    let pasteboard = NSPasteboard.general
    let before = pasteboard.changeCount
    let row = CandidateFinder.prepare(
      Candidate(
        title: "Token",
        metadata: [
          CandidateMetadataKey.source: "danger.rows",
          CandidateMetadataKey.sourceID: "plugin:danger",
        ], effect: .copyText("flash-confirm-test"), confirm: "Copy it?"))
    delegate.openSourceItem(row, recordMovement: false)
    XCTAssertEqual(delegate.hintSession.confirmation?.prompt, "Copy it?")
    XCTAssertEqual(pasteboard.changeCount, before, "the effect waits for the answer")
    delegate.overlayDidConfirm(accepted: false)
    XCTAssertEqual(pasteboard.changeCount, before)
    XCTAssertEqual(performs().count, 0)
  }
}

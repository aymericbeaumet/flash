import Foundation
import XCTest

@testable import flash

/// `core:status.observed`: the host tells each listening plugin which of its
/// own status segments a live surface shows — once after every initialize,
/// then only when that set changes.
final class PluginStatusObservedTests: XCTestCase {
  /// Records every `core:status.observed` frame it receives, one per line.
  private static let recorder = """
    #!/bin/sh
    D="$FLASH_PLUGIN_DATA_DIR"
    printf 'spawn\\n' >> "$D/spawns"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
      *'"method":"initialize"'*)
        \(PluginFixtureKit.initializeOK)
        ;;
      *'core:status.observed'*)
        printf '%s\\n' "$line" >> "$D/observed"
        ;;
      esac
    done
    exit 0
    """

  private func makeProcess(
    id: String, listen: Bool, observed: Set<String>
  ) throws -> (PluginProcess, PluginFixtureKit.Fixture) {
    let listening = listen ? #""listen": ["core:status.observed"], "# : ""
    let fixture = try PluginFixtureKit.make(
      id: id,
      manifest: PluginFixtureKit.manifest(
        id: id, extra: listening + #""status": ["top_cpu", "top_mem", "state"]"#),
      script: Self.recorder)
    let process = PluginProcess(
      root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
      origin: .official, baseDataDir: fixture.baseDataDir, watchFiles: false,
      observedStatusSegments: observed)
    return (process, fixture)
  }

  private func received(_ fixture: PluginFixtureKit.Fixture) -> [[String]] {
    guard
      let text = try? String(
        contentsOf: fixture.dataDir.appendingPathComponent("observed"), encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
      let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      let params = frame?["params"] as? [String: Any]
      let payload = params?["payload"] as? [String: Any]
      return payload?["segments"] as? [String]
    }
  }

  func testTheSetArrivesAfterInitializeAndAgainOnlyWhenItChanges() throws {
    let (process, fixture) = try makeProcess(
      id: "observer", listen: true, observed: ["top_mem", "top_cpu", "undeclared", ""])
    defer {
      process.stopAndWait(reason: "test")
      fixture.cleanup()
    }
    process.start()
    waitUntilTrue("the initial set") { received(fixture).count == 1 }
    XCTAssertEqual(
      received(fixture), [["top_cpu", "top_mem"]],
      "declared names only, nonempty, unique and sorted")

    process.setObservedStatusSegments(["top_cpu", "top_mem", "undeclared"])
    process.setObservedStatusSegments(["state"])
    waitUntilTrue("the changed set") { received(fixture).count == 2 }
    process.setObservedStatusSegments([])
    waitUntilTrue("the authoritative empty set") { received(fixture).count == 3 }
    settleRunLoop(0.3)
    XCTAssertEqual(
      received(fixture), [["top_cpu", "top_mem"], ["state"], []],
      "an unchanged set is never repeated")

    // A restarted child starts from the truth: the current set, once.
    process.setObservedStatusSegments(["top_mem"])
    waitUntilTrue("the set before the reload") { received(fixture).count == 4 }
    process.reload(reason: "test")
    waitUntilTrue("respawned") { fixture.spawnCount() == 2 }
    waitUntilTrue("the set after the reload") { received(fixture).count == 5 }
    settleRunLoop(0.3)
    XCTAssertEqual(received(fixture).suffix(2), [["top_mem"], ["top_mem"]])
  }

  func testAnEmptySetIsStillSentAndOnlyToListeners() throws {
    let (listener, listenerFixture) = try makeProcess(
      id: "listener", listen: true, observed: [])
    let (other, otherFixture) = try makeProcess(id: "other", listen: false, observed: ["state"])
    defer {
      listener.stopAndWait(reason: "test")
      other.stopAndWait(reason: "test")
      listenerFixture.cleanup()
      otherFixture.cleanup()
    }
    listener.start()
    other.start()
    waitUntilTrue("the empty set") { received(listenerFixture) == [[]] }
    waitUntilTrue("the other plugin running") { other.runtimeStateSnapshot() == .running }
    other.setObservedStatusSegments(["top_cpu"])
    settleRunLoop(0.3)
    XCTAssertEqual(received(otherFixture), [], "a plugin that does not listen hears nothing")
  }

  // MARK: - A value its plugin clears while nobody shows it

  private func segments(_ process: PluginProcess) -> [String: PluginStatusSegment] {
    process.statusBarInfo().statusSegments
  }

  /// A plugin told nobody shows a value stops sampling and clears it. It was
  /// asked to stop, not to blank the surface that shows the value next, so
  /// the host keeps what it last published until the plugin publishes that
  /// segment again.
  func testAValueClearedWhileNobodyShowsItStaysUntilItsPluginPublishesAgain() throws {
    let (process, fixture) = try makeProcess(id: "kept", listen: true, observed: ["top_cpu"])
    defer { fixture.cleanup() }
    var notifications = 0
    process.onStatusChanged = { notifications += 1 }
    process.applyStatusSegments(["segments": ["top_cpu": "Xcode 12%", "state": "on"]])
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, [])
    settleRunLoop(0.05)
    XCTAssertEqual(notifications, 1)

    process.setObservedStatusSegments([])
    process.applyStatusSegments(["segments": ["top_cpu": "", "top_mem": ""]])
    XCTAssertEqual(segments(process), ["top_cpu": .text("Xcode 12%"), "state": .text("on")])
    XCTAssertEqual(
      process.statusBarInfo().heldStatusSegments, ["top_cpu"],
      "kept, and known to be what the plugin last said before it stopped")
    settleRunLoop(0.05)
    XCTAssertEqual(notifications, 1, "keeping a value changes nothing on screen")
    process.applyStatusSegments(["segments": ["state": ""]])
    XCTAssertEqual(
      segments(process), ["top_cpu": .text("Xcode 12%")],
      "a value nobody ever showed was sampled for nobody: its empty value clears")

    // Shown again: the kept value stays until the fresh one lands.
    process.setObservedStatusSegments(["top_cpu"])
    XCTAssertEqual(segments(process)["top_cpu"], .text("Xcode 12%"))
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, ["top_cpu"])
    process.applyStatusSegments(["segments": ["top_cpu": "Safari 3%"]])
    XCTAssertEqual(segments(process)["top_cpu"], .text("Safari 3%"))
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, [])

    // A value the plugin publishes again while nobody shows it is fresh.
    process.setObservedStatusSegments([])
    process.applyStatusSegments(["segments": ["top_cpu": ""]])
    process.applyStatusSegments(["segments": ["top_cpu": "Mail 1%"]])
    XCTAssertEqual(segments(process)["top_cpu"], .text("Mail 1%"))
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, [])
  }

  /// An empty value published once the segment is shown again is the
  /// plugin's answer, and so is one published while it is shown.
  func testAnEmptyValuePublishedWhileShownClears() throws {
    let (process, fixture) = try makeProcess(id: "cleared", listen: true, observed: ["top_cpu"])
    defer { fixture.cleanup() }
    process.applyStatusSegments(["segments": ["top_cpu": "Xcode 12%"]])
    process.applyStatusSegments(["segments": ["top_cpu": ""]])
    XCTAssertEqual(segments(process), [:], "shown: an empty value clears at once")

    process.applyStatusSegments(["segments": ["top_cpu": "Xcode 12%"]])
    process.setObservedStatusSegments([])
    process.applyStatusSegments(["segments": ["top_cpu": ""]])
    process.setObservedStatusSegments(["top_cpu"])
    XCTAssertEqual(segments(process)["top_cpu"], .text("Xcode 12%"))
    process.applyStatusSegments(["segments": ["top_cpu": ""]])
    XCTAssertEqual(segments(process), [:], "shown again: the plugin says there is none")
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, [])
  }

  /// A plugin with nothing to say about a segment shown again (it already
  /// said empty) leaves the kept value on screen only for the bounded
  /// revalidation window.
  func testAKeptValueGoesWhenItsPluginSaysNothingOnceItIsShownAgain() throws {
    let (process, fixture) = try makeProcess(
      id: "silent", listen: true, observed: ["top_cpu", "top_mem"])
    defer { fixture.cleanup() }
    var notifications = 0
    process.onStatusChanged = { notifications += 1 }
    process.applyStatusSegments(["segments": ["top_cpu": "Xcode 12%", "top_mem": "Xcode 2G"]])
    process.setObservedStatusSegments([])
    process.applyStatusSegments(["segments": ["top_cpu": "", "top_mem": ""]])
    settleRunLoop(PluginProcess.statusRevalidateSeconds + 0.2)
    XCTAssertEqual(
      segments(process).count, 2, "nobody shows them: nothing expires, whatever the time")

    process.setObservedStatusSegments(["top_cpu"])
    XCTAssertEqual(segments(process)["top_cpu"], .text("Xcode 12%"))
    waitUntilTrue("the kept value expired") { self.segments(process)["top_cpu"] == nil }
    XCTAssertEqual(segments(process), ["top_mem": .text("Xcode 2G")], "only the one shown")
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, ["top_mem"])
    waitUntilTrue("the surfaces evaluate again") { notifications == 2 }
  }

  /// Only a plugin that hears `core:status.observed` was asked to stop: any
  /// other publishes on its own terms, and its empty value clears.
  func testAPluginThatDoesNotListenClearsAtOnce() throws {
    let (process, fixture) = try makeProcess(id: "deaf", listen: false, observed: [])
    defer { fixture.cleanup() }
    process.applyStatusSegments(["segments": ["top_cpu": "Xcode 12%"]])
    process.applyStatusSegments(["segments": ["top_cpu": ""]])
    XCTAssertEqual(segments(process), [:])
    XCTAssertEqual(process.statusBarInfo().heldStatusSegments, [])
  }

  // MARK: - Before the host knows what is shown

  /// A child that initializes before the status controller's first report
  /// is told nothing yet, then the real set, once: never an empty set the
  /// host did not know to be true.
  func testAChildStartedBeforeTheHostKnowsHearsTheRealSetOnce() throws {
    let fixture = try PluginFixtureKit.make(
      id: "early",
      manifest: PluginFixtureKit.manifest(
        id: "early",
        extra: #""listen": ["core:status.observed"], "status": ["top_cpu", "top_mem", "state"]"#),
      script: Self.recorder)
    defer { fixture.cleanup() }
    let process = PluginProcess(
      root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
      origin: .official, baseDataDir: fixture.baseDataDir, watchFiles: false,
      observedStatusSegments: nil)
    defer { process.stopAndWait(reason: "test") }
    process.start()
    waitUntilTrue("running") { process.runtimeStateSnapshot() == .running }
    settleRunLoop(0.3)
    XCTAssertEqual(received(fixture), [], "nothing is known yet")
    process.setObservedStatusSegments(["top_mem"])
    waitUntilTrue("the real set") { self.received(fixture).count == 1 }
    process.reload(reason: "test")
    waitUntilTrue("respawned") { fixture.spawnCount() == 2 }
    waitUntilTrue("the set after the reload") { self.received(fixture).count == 2 }
    settleRunLoop(0.3)
    XCTAssertEqual(received(fixture), [["top_mem"], ["top_mem"]])
  }
}

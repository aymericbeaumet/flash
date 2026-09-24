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
}

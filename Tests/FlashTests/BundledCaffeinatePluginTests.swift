import FlashCore
import IOKit.pwr_mgt
import XCTest

@testable import flash

/// The built `caffeinate` plugin, spawned under its sandbox profile by a
/// real `PluginManager`: its commands take and release real power assertions
/// in the plugin's own process, which powerd lists by pid. The test holds
/// the Mac awake for the moment between `on` and `off`, nothing more.
final class BundledCaffeinatePluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!

  override func setUpWithError() throws {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "caffeinate" })
    let binary = root.appendingPathComponent("flash-plugin-caffeinate").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the caffeinate plugin must be built")
      }
      throw XCTSkip("caffeinate is not built: run `mise run build:plugins`")
    }
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-caffeinate-plugin-\(UUID().uuidString)")
    manager = PluginManager(baseDataDir: dataDir)
    var config = Config()
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["caffeinate"])
    config.plugins.watchingEnabled = false
    manager.start(config: config)
    waitUntilTrue("caffeinate loaded") { self.status != nil }
  }

  override func tearDown() {
    manager?.stop()
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private var status: PluginStatus? {
    manager.pluginStatuses().first { $0.id == "caffeinate" }
  }

  private func run(_ subcommand: String, _ args: [String] = []) -> PluginCommandResult {
    let answered = expectation(description: "caffeinate \(subcommand)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: "caffeinate", subcommand: subcommand, args: args) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  /// One power assertion powerd holds for a process.
  private struct Assertion: Hashable {
    var type: String
    var name: String
  }

  /// The assertions powerd lists for `pid`, as `pmset -g assertions` does.
  private func assertions(of pid: Int) throws -> Set<Assertion> {
    var copied: Unmanaged<CFDictionary>?
    XCTAssertEqual(IOPMCopyAssertionsByProcess(&copied), kIOReturnSuccess)
    let byProcess = try XCTUnwrap(copied?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
    let held = byProcess.first { $0.key.intValue == pid }?.value ?? []
    return Set(
      held.map {
        Assertion(
          type: $0[kIOPMAssertionTypeKey] as? String ?? "",
          name: $0[kIOPMAssertionNameKey] as? String ?? "")
      })
  }

  private func alert(_ state: String) -> PluginCommandResult {
    PluginCommandResult(
      ok: true, message: "caffeinate \(state)",
      alert: PluginAlert(title: "caffeinate", value: state, widestValue: "off"))
  }

  /// What `caffeinate -dimsu` holds, under the plugin's name.
  private static let held: Set<Assertion> = Set(
    [
      "PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventDiskIdle",
      "PreventSystemSleep",
    ].map { Assertion(type: $0, name: "Flash caffeinate") })

  func testOnTakesTheAssertionsInThePluginsSandboxedProcessAndOffReleasesThem() throws {
    // Nothing shows its segment and no mapping runs it: no process yet.
    XCTAssertEqual(status?.activation, "on_demand")
    XCTAssertNil(status?.pid, "the plugin costs nothing before its first command")

    XCTAssertEqual(
      run("status"), PluginCommandResult(ok: true, message: "caffeinate off"),
      "a question shows no alert")
    let pid = try XCTUnwrap(status?.pid, "the first command spawned it")
    XCTAssertEqual(try assertions(of: pid), [])

    XCTAssertEqual(run("on", ["--minutes=1"]), alert("on"))
    let taken = try assertions(of: pid)
    XCTAssertTrue(taken.isSuperset(of: Self.held), "\(taken)")
    XCTAssertTrue(taken.allSatisfy { $0.name == "Flash caffeinate" }, "\(taken)")
    waitUntilTrue("the segment reads on") { self.status?.statusSegments["state"] == "on" }
    XCTAssertEqual(run("status").message, "caffeinate on")

    XCTAssertEqual(run("off"), alert("off"))
    XCTAssertEqual(try assertions(of: pid), [], "off released every assertion")
    waitUntilTrue("the segment cleared") {
      (self.status?.statusSegments["state"] ?? "").isEmpty
    }
    XCTAssertEqual(status?.pid, pid, "the same process served every command")
  }

  /// Stopping the plugin (Flash quitting, a reload) ends the hold with it.
  func testStoppingThePluginReleasesWhatItHolds() throws {
    XCTAssertEqual(run("toggle"), alert("on"))
    let pid = try XCTUnwrap(status?.pid)
    XCTAssertTrue(try assertions(of: pid).isSuperset(of: Self.held))
    manager.stop()
    XCTAssertEqual(try assertions(of: pid), [])
  }

  func testAMalformedBoundTakesNothing() throws {
    XCTAssertEqual(
      run("on", ["--minutes=0"]),
      PluginCommandResult(ok: false, error: "usage: caffeinate on [--minutes=<n>]"))
    XCTAssertEqual(
      run("on", ["5"]),
      PluginCommandResult(ok: false, error: "usage: caffeinate on [--minutes=<n>]"))
    let pid = try XCTUnwrap(status?.pid)
    XCTAssertEqual(try assertions(of: pid), [])
  }
}

import FlashCore
import Foundation
import XCTest

@testable import flash

/// PluginManager reconciliation: file/github third-party materialization,
/// the `[plugins] disabled` gate, `reloadAll`, and the config-generation
/// guard. Every config built here disables all discoverable official
/// plugins so reconciles only ever spawn the test fixtures.
final class PluginManagerReloadTests: XCTestCase {

  /// IDs of every loadable official manifest (discovered from the repo's
  /// `Plugins/` via cwd, like production). Disabled wholesale in every test
  /// config so `reloadDesiredPlugins` never launches a real plugin.
  private static let officialIDs: Set<String> = Set(
    PluginRepository.officialPluginRoots().compactMap {
      (try? PluginManifest.load(from: $0))?.id
    })

  private func testConfig(
    thirdParty: [String], disabled: Set<String> = []
  ) -> Config {
    var config = Config()
    config.plugins.thirdParty = thirdParty.compactMap { PluginReference.parse($0) }
    XCTAssertEqual(config.plugins.thirdParty.count, thirdParty.count, "unparseable test ref")
    config.plugins.disabled = Self.officialIDs.union(disabled)
    config.plugins.watchingEnabled = false
    return config
  }

  private func status(_ manager: PluginManager, _ id: String) -> PluginStatus? {
    manager.pluginStatuses().first { $0.id == id }
  }

  private func residentFixture(id: String, baseDataDir: URL? = nil) throws
    -> PluginFixtureKit.Fixture
  {
    try PluginFixtureKit.make(
      id: id,
      manifest: PluginFixtureKit.manifest(id: id),
      script: PluginFixtureKit.script(),
      baseDataDir: baseDataDir)
  }

  // MARK: - file: refs

  func testFileReferenceLoadsRunsAndStopsThirdPartyPlugin() throws {
    let fixture = try residentFixture(id: "mgrfile")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("plugin running under the manager") {
      self.status(manager, "mgrfile")?.state == "running"
    }
    let running = try XCTUnwrap(status(manager, "mgrfile"))
    XCTAssertEqual(running.origin, "file:\(fixture.root.path)")
    XCTAssertEqual(running.activation, "resident")
    let pid = try XCTUnwrap(running.pid)
    manager.stop()
    XCTAssertTrue(manager.pluginStatuses().isEmpty)
    waitUntilTrue("child exits after manager stop") { kill(pid_t(pid), 0) != 0 }
  }

  // MARK: - [plugins] disabled

  func testDisabledListPreventsAnyProcessForTheDisabledID() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-disabled-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let off = try residentFixture(id: "mgroff", baseDataDir: base)
    let on = try residentFixture(id: "mgron", baseDataDir: base)
    defer {
      off.cleanup()
      on.cleanup()
    }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    manager.start(
      config: testConfig(
        thirdParty: ["file:\(off.root.path)", "file:\(on.root.path)"],
        disabled: ["mgroff"]))
    // The enabled sibling reaching `running` proves the reconcile completed.
    waitUntilTrue("enabled sibling running") { self.status(manager, "mgron")?.state == "running" }
    XCTAssertNil(status(manager, "mgroff"), "a disabled plugin is skipped, not failed")
    XCTAssertEqual(off.spawnCount(), 0, "no process may ever spawn for a disabled id")
  }

  // MARK: - reloadAll

  func testReloadAllRestartsRunningPluginsWithoutBlockingTheMainThread() throws {
    let fixture = try residentFixture(id: "mgrreload")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    manager.start(config: testConfig(thirdParty: ["file:\(fixture.root.path)"]))
    waitUntilTrue("running before reload") { self.status(manager, "mgrreload")?.state == "running" }
    XCTAssertEqual(fixture.spawnCount(), 1)

    // Called from the main thread; returns synchronously with the affected
    // ids while the restarts run asynchronously off the snapshot.
    let started = CFAbsoluteTimeGetCurrent()
    let ids = manager.reloadAll()
    XCTAssertLessThan(
      CFAbsoluteTimeGetCurrent() - started, 0.5,
      "reloadAll must never block the main thread on the manager queue")
    XCTAssertTrue(ids.contains("mgrreload"))
    waitUntilTrue("respawned by reloadAll") { fixture.spawnCount() >= 2 }
    waitUntilTrue("running after reload") { self.status(manager, "mgrreload")?.state == "running" }
  }

  // MARK: - github: refs (local git fixture, no network)

  func testGithubMaterializationEnforcesTheCommitPin() throws {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory
      .appendingPathComponent("flash-mgr-github-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: temp) }
    let work = temp.appendingPathComponent("work")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    try PluginFixtureKit.manifest(id: "ghfix").write(
      to: work.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try runGit(["init", "-q"], in: work)
    try runGit(["add", "manifest.json"], in: work)
    try runGit(
      [
        "-c", "user.name=fixture", "-c", "user.email=fixture@test", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init",
      ], in: work)
    let sha = try runGit(["rev-parse", "HEAD"], in: work)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(sha.count, 40)
    let bare = temp.appendingPathComponent("upstream.git")
    try runGit(["clone", "-q", "--bare", work.path, bare.path], in: temp)
    // The materializer fetches the pinned SHA directly; local transports
    // need the explicit want-any-sha opt-in a hosting forge enables.
    try runGit(["config", "uploadpack.allowAnySHA1InWant", "true"], in: bare)

    let originalBuilder = PluginRepository.remoteURLBuilder
    defer { PluginRepository.remoteURLBuilder = originalBuilder }
    PluginRepository.remoteURLBuilder = { _, _ in bare.path }
    let repository = PluginRepository(baseDataDir: temp.appendingPathComponent("data"))

    // Correct pinned SHA: checkout succeeds and lands under the SHA-stamped root.
    let ref = try XCTUnwrap(PluginReference.parse("github:owner/repo@\(sha)"))
    let materialized = try XCTUnwrap(repository.materialize(ref))
    XCTAssertTrue(
      fm.fileExists(atPath: materialized.root.appendingPathComponent("manifest.json").path))
    XCTAssertTrue(materialized.root.path.contains("github/owner-repo-\(sha)"))
    XCTAssertEqual(materialized.origin.label, "github:owner/repo@\(sha)")

    // A populated, pin-verified root short-circuits the network entirely
    // (previously vetted plugins keep working offline).
    PluginRepository.remoteURLBuilder = { _, _ in "/nonexistent/upstream.git" }
    XCTAssertNotNil(repository.materialize(ref), "cached checkout must not refetch")

    // A wrong pinned SHA (valid repo, nonexistent commit) is refused.
    PluginRepository.remoteURLBuilder = { _, _ in bare.path }
    let wrongSHA = String(sha.dropLast()) + (sha.hasSuffix("0") ? "1" : "0")
    let wrongRef = try XCTUnwrap(PluginReference.parse("github:owner/repo@\(wrongSHA)"))
    XCTAssertNil(
      repository.materialize(wrongRef),
      "a mismatched commit pin must refuse the checkout")
  }

  // MARK: - Config-generation race

  func testStaleConfigGenerationIsDroppedWholesale() throws {
    // Two rapid reconciles: the older config is still materializing (slowed
    // through the remote-URL seam) when the newer one bumps the generation.
    // Pinned behavior: the superseded reload is dropped WHOLE — its plugins
    // never spawn, nothing from it clobbers the newer state.
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-mgr-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let stale = try residentFixture(id: "mgrstale", baseDataDir: base)
    let fresh = try residentFixture(id: "mgrfresh", baseDataDir: base)
    defer {
      stale.cleanup()
      fresh.cleanup()
    }
    let originalBuilder = PluginRepository.remoteURLBuilder
    defer { PluginRepository.remoteURLBuilder = originalBuilder }
    PluginRepository.remoteURLBuilder = { _, _ in
      // Keep config A inside its materialize phase until config B has
      // superseded it, then fail the fetch fast.
      Thread.sleep(forTimeInterval: 0.4)
      return "/nonexistent/slow.git"
    }
    let manager = PluginManager(baseDataDir: base)
    defer { manager.stop() }
    let slowSHA = String(repeating: "a", count: 40)
    manager.start(
      config: testConfig(
        thirdParty: ["github:slow/slow@\(slowSHA)", "file:\(stale.root.path)"]))
    manager.updateConfig(testConfig(thirdParty: ["file:\(fresh.root.path)"]))

    waitUntilTrue("newer config applies") { self.status(manager, "mgrfresh")?.state == "running" }
    XCTAssertNil(status(manager, "mgrstale"), "the stale generation must not land")
    XCTAssertEqual(stale.spawnCount(), 0, "the stale config's plugin must never spawn")
    // And it stays that way once the stale pipeline has fully drained.
    settleRunLoop(0.6)
    XCTAssertNil(status(manager, "mgrstale"))
    XCTAssertEqual(stale.spawnCount(), 0)
    XCTAssertEqual(status(manager, "mgrfresh")?.state, "running")
  }

  // MARK: - git helper

  @discardableResult
  private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw PluginError.failure("git \(arguments.joined(separator: " ")) failed")
    }
    return String(
      data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }
}

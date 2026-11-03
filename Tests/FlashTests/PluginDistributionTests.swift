import Foundation
import XCTest

@testable import flash

final class PluginDistributionTests: XCTestCase {
  func testPackagedAppNeverDiscoversOfficialPluginsFromWorkingDirectory() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-discovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let bundle = temp.appendingPathComponent("Flash.app")
    let resources = bundle.appendingPathComponent("Contents/Resources")
    let workingDirectory = temp.appendingPathComponent("untrusted")
    let bundled = resources.appendingPathComponent("Plugins/bundled")
    let injected = workingDirectory.appendingPathComponent("Plugins/injected")
    for root in [bundled, injected] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try "{}".write(
        to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }
    XCTAssertEqual(
      PluginRepository.officialPluginRoots(
        bundleURL: bundle, resourceURL: resources, workingDirectory: workingDirectory
      ).map(\.path),
      [bundled.path])
    try FileManager.default.removeItem(at: resources.appendingPathComponent("Plugins"))
    XCTAssertTrue(
      PluginRepository.officialPluginRoots(
        bundleURL: bundle, resourceURL: resources, workingDirectory: workingDirectory
      ).isEmpty,
      "a broken bundle must never substitute plugins from its launch directory")
    XCTAssertEqual(
      PluginRepository.officialPluginRoots(
        bundleURL: temp.appendingPathComponent("flash"), resourceURL: nil,
        workingDirectory: workingDirectory
      ).map(\.path),
      [injected.path], "standalone development binaries can discover their source tree")
  }

  func testNewCheckoutInstallsEvenWhenPluginVersionAndInstallCommandAreUnchanged() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-install-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let baseDataDir = temp.appendingPathComponent("data")
    let manifest = PluginFixtureKit.manifest(
      id: "installidentity",
      extra:
        #""status":["state"],"install":"printf 'installed\\n' >> \"$FLASH_PLUGIN_DATA_DIR/installs\"; touch ready""#
    )
    let script = PluginFixtureKit.script(prologue: "test -f ready || exit 44")
    let first = try PluginFixtureKit.make(
      id: "installidentity", manifest: manifest, script: script, baseDataDir: baseDataDir)
    let second = try PluginFixtureKit.make(
      id: "installidentity", manifest: manifest, script: script, baseDataDir: baseDataDir)
    defer {
      first.cleanup()
      second.cleanup()
    }
    func process(_ fixture: PluginFixtureKit.Fixture) throws -> PluginProcess {
      PluginProcess(
        root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
        origin: .file("file:\(fixture.root.path)"), baseDataDir: baseDataDir, watchFiles: false,
        installLogDirectory: temp.appendingPathComponent("logs"))
    }
    let original = try process(first)
    defer { original.stopAndWait(reason: "test") }
    original.start()
    waitUntilTrue("original checkout installed") { original.runtimeStateSnapshot() == .running }
    original.reload(reason: "test_reuse_checkout")
    waitUntilTrue("same checkout restarted") {
      first.spawnCount() == 2 && original.runtimeStateSnapshot() == .running
    }
    let originalLog = try String(contentsOf: first.dataDir.appendingPathComponent("installs"))
    XCTAssertEqual(originalLog.split(separator: "\n").count, 1, "same checkout reuses its install")
    original.stopAndWait(reason: "test_replace_checkout")
    let replacement = try process(second)
    defer { replacement.stopAndWait(reason: "test") }
    replacement.start()
    waitUntilTrue(timeout: 3, "replacement checkout installed") {
      FileManager.default.fileExists(atPath: second.root.appendingPathComponent("ready").path)
    }
    waitUntilTrue("replacement running") { replacement.runtimeStateSnapshot() == .running }
    let log = try String(contentsOf: first.dataDir.appendingPathComponent("installs"))
    XCTAssertEqual(log.split(separator: "\n").count, 2)
  }

  func testRequiredSandboxNeverFallsBackToUncontainedRuntimeOrInstaller() throws {
    for install in [false, true] {
      let id = install ? "missing-sandbox-install" : "missing-sandbox-runtime"
      let extra =
        install
        ? #""status":["state"],"install":"touch installed-without-sandbox""#
        : #""status":["state"]"#
      let fixture = try PluginFixtureKit.make(
        id: id, manifest: PluginFixtureKit.manifest(id: id, extra: extra, sandboxed: true),
        script: PluginFixtureKit.script())
      let missing = fixture.root.appendingPathComponent("missing-sandbox-exec").path
      let process = PluginProcess(
        root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
        origin: .file("file:\(fixture.root.path)"), baseDataDir: fixture.baseDataDir,
        watchFiles: false,
        sandboxExecPath: missing,
        installLogDirectory: fixture.baseDataDir.appendingPathComponent("logs"))
      defer {
        process.stopAndWait(reason: "test")
        fixture.cleanup()
      }
      process.start()
      waitUntilTrue("sandbox preflight settled") {
        process.statusSnapshot().lastError != nil || process.runtimeStateSnapshot() == .running
      }
      XCTAssertEqual(fixture.spawnCount(), 0, "a required sandbox must never fail open")
      XCTAssertTrue(process.statusSnapshot().lastError?.contains(missing) == true)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("installed-without-sandbox").path))
    }
  }

  func testExplicitSandboxDisableDoesNotRequireTheSandboxExecutable() throws {
    // The user's `[plugins.<id>] sandbox = false` and a manifest's
    // `"sandbox": false` both run the child uncontained.
    let cases: [(id: String, sandboxed: Bool, settings: [String: PluginConfigValue])] = [
      ("sandbox-disabled-by-config", true, ["sandbox": .bool(false)]),
      ("sandbox-disabled-by-manifest", false, [:]),
    ]
    for (id, sandboxed, settings) in cases {
      let fixture = try PluginFixtureKit.make(
        id: id, manifest: PluginFixtureKit.manifest(id: id, sandboxed: sandboxed),
        script: PluginFixtureKit.script())
      let process = PluginProcess(
        root: fixture.root, manifest: try PluginManifest.load(from: fixture.root),
        origin: .file("file:\(fixture.root.path)"), baseDataDir: fixture.baseDataDir,
        watchFiles: false, settings: settings,
        sandboxExecPath: fixture.root.appendingPathComponent("missing-sandbox-exec").path,
        installLogDirectory: fixture.baseDataDir.appendingPathComponent("logs"))
      defer {
        process.stopAndWait(reason: "test")
        fixture.cleanup()
      }
      process.start()
      waitUntilTrue("\(id): explicitly uncontained child running") {
        process.runtimeStateSnapshot() == .running
      }
      XCTAssertEqual(fixture.spawnCount(), 1, id)
      XCTAssertNil(process.statusSnapshot().lastError, id)
    }
  }

  func testManifestRejectsIDsThatEscapeOrConfuseItsDataDirectory() throws {
    for id in [
      "../escape", "/tmp/escape", ".", "..", "nested/plugin", "nested\\plugin", "two words",
      "quote\"id", "line\nbreak", " leading", "trailing ", "MixedCase",
    ] {
      let data = try JSONSerialization.data(withJSONObject: [
        "id": id, "name": "Fixture", "version": "1.0.0", "description": "fixture",
      ])
      let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
      XCTAssertThrowsError(try manifest.validate(), "unsafe id accepted: \(id.debugDescription)")
    }
    for id in ["example", "2fa", "my-plugin", "my_plugin", "my.plugin"] {
      let data = try JSONSerialization.data(withJSONObject: [
        "id": id, "name": "Fixture", "version": "1.0.0", "description": "fixture",
      ])
      let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
      XCTAssertNoThrow(try manifest.validate(), id)
    }
  }
}

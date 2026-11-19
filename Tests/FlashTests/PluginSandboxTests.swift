import XCTest

@testable import flash

/// Every plugin process runs under the deny-default seatbelt profile built
/// from its manifest's `sandbox` spec (absent: the empty spec), unless the
/// manifest declares `"sandbox": false` or the user's `[plugins.<id>]
/// sandbox = false` kill switch disables it.
final class PluginSandboxTests: XCTestCase {
  private func specManifest(
    _ capabilities: Set<PluginCapability> = [], spec: PluginSandboxSpec = PluginSandboxSpec()
  ) -> PluginManifest {
    manifest(capabilities, sandbox: .spec(spec))
  }

  private func manifest(
    _ capabilities: Set<PluginCapability> = [], sandbox: PluginSandboxDeclaration?
  ) -> PluginManifest {
    PluginManifest(
      id: "test", name: "Test", version: "1", description: "",
      install: "true", exec: ["./flash-plugin-test"], sandbox: sandbox,
      capabilities: capabilities)
  }

  private let root = URL(fileURLWithPath: "/tmp/plugin-root")
  private let dataDir = URL(fileURLWithPath: "/tmp/plugin-data")

  func testSandboxSpecGeneratesDenyDefault() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest(), settings: [:], root: root, dataDir: dataDir)
    XCTAssertEqual(resolved.mode, "deny_default")
    let profile = try! XCTUnwrap(resolved.profile)
    XCTAssertTrue(profile.contains("(deny default)"))
    XCTAssertTrue(profile.contains("(subpath \"/tmp/plugin-root\")"))
    XCTAssertTrue(profile.contains("(subpath \"/tmp/plugin-data\")"))
    XCTAssertFalse(profile.contains("network-outbound"))
    // Base always allows exec of the plugin's own root (sandbox-exec's
    // execvp) but nothing beyond it without a spec.
    XCTAssertTrue(profile.contains("(allow process-exec (subpath \"/tmp/plugin-root\"))"))
    XCTAssertFalse(profile.contains("(allow process-exec (literal"))
    // Secrets and other plugins' data are read-denied.
    XCTAssertTrue(profile.contains(".ssh"))
    XCTAssertTrue(profile.contains("Keychains"))
    XCTAssertTrue(profile.contains("(deny file-read* (subpath"))
  }

  func testSandboxSpecComposesNetworkCapability() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest([.network]), settings: [:], root: root, dataDir: dataDir)
    XCTAssertTrue(resolved.profile?.contains("(allow network-outbound)") == true)
    XCTAssertTrue(resolved.profile?.contains("(deny default)") == true)
  }

  /// A sandboxed plugin forks nothing and runs nothing but its own binary
  /// (and a runtime outside its root): there is no exec allowance to widen.
  func testTheProfileExecsOnlyThePluginItself() throws {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest(), settings: [:], root: root, dataDir: dataDir)
    let profile = try XCTUnwrap(resolved.profile)
    XCTAssertFalse(profile.contains("(allow process-fork)"))
    XCTAssertFalse(profile.contains("launchservicesd"))
    XCTAssertFalse(profile.contains("appleevent"))
    let interpreted = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest(), settings: [:], root: root, dataDir: dataDir,
        executablePath: "/usr/bin/python3"
      ).profile)
    XCTAssertTrue(interpreted.contains("(allow process-exec (literal \"/usr/bin/python3\")"))
    XCTAssertFalse(interpreted.contains("(allow process-fork)"))
  }

  func testSandboxSpecComposesMachAllowances() throws {
    let spec = PluginSandboxSpec(mach: ["com.apple.PowerManagement.control"])
    let profile = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest(spec: spec), settings: [:], root: root, dataDir: dataDir
      ).profile)
    XCTAssertTrue(
      profile.contains("(allow mach-lookup (global-name \"com.apple.PowerManagement.control\"))"))
  }

  /// Seatbelt's `(deny default)` leaves the `process-info*` family open, so
  /// the profile denies it by name: a plugin reads its own process alone,
  /// and cannot list pids. No rule relies on its position among the others.
  func testOtherProcessesAreDeniedByNameWithoutTheCapability() throws {
    let profile = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest(), settings: [:], root: root, dataDir: dataDir
      ).profile)
    XCTAssertTrue(profile.contains("(deny process-info* (target others))"))
    XCTAssertTrue(profile.contains("(deny process-info-listpids)"))
    XCTAssertTrue(profile.contains("(allow process-info* (target self))"))
    XCTAssertFalse(profile.contains("(allow process-info-listpids)"))
    XCTAssertFalse(profile.contains("(allow process-info-pidinfo"))
  }

  /// `process_info` opens exactly the libproc reads a process table needs,
  /// for other processes: the pid list, `proc_pidinfo` (which serves the
  /// path too), the descriptor list and `proc_pid_rusage`. The operations
  /// it does not name stay denied for other processes, and the deny names
  /// only those, so no allow has to reopen it.
  func testProcessInfoCapabilityOpensTheLibprocReadsOfOtherProcesses() throws {
    let profile = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest([.processInfo]), settings: [:], root: root, dataDir: dataDir
      ).profile)
    XCTAssertTrue(profile.contains("(allow process-info* (target self))"))
    XCTAssertTrue(profile.contains("(allow process-info-listpids)"))
    XCTAssertTrue(
      profile.contains(
        "(allow process-info-pidinfo process-info-pidfdinfo process-info-rusage"
          + " (target others))"))
    XCTAssertTrue(
      profile.contains(
        "(deny process-info-pidfileportinfo process-info-setcontrol process-info-dirtycontrol"
          + " process-info-codesignature process-info-ledger (target others))"))
    XCTAssertFalse(profile.contains("(deny process-info* (target others))"))
    XCTAssertFalse(profile.contains("(deny process-info-listpids)"))
    XCTAssertEqual(
      Set(PluginSandbox.processInfoOperations).intersection(
        PluginSandbox.deniedProcessInfoOperations), [], "an operation is opened or denied")
    // The capability widens nothing else.
    XCTAssertFalse(profile.contains("network-outbound"))
    XCTAssertFalse(profile.contains("(allow process-fork)"))
  }

  func testConfigKillSwitchDisablesSandboxLoudly() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest(), settings: ["sandbox": .bool(false)],
      root: root, dataDir: dataDir)
    XCTAssertNil(resolved.profile)
    XCTAssertEqual(resolved.mode, "disabled_by_config")
  }

  func testManifestWithoutSandboxRunsUnderTheEmptyDenyDefaultSpec() throws {
    let absent = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest([.network], sandbox: nil), settings: [:], root: root,
      dataDir: dataDir)
    let empty = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest([.network]), settings: [:], root: root, dataDir: dataDir)
    XCTAssertEqual(absent.mode, "deny_default")
    XCTAssertEqual(absent.profile, empty.profile)
    let profile = try XCTUnwrap(absent.profile)
    XCTAssertTrue(profile.contains("(deny default)"))
    XCTAssertFalse(profile.contains("(allow default)"))
    XCTAssertFalse(profile.contains("(allow process-exec (literal"))
  }

  func testManifestSandboxFalseRunsUnsandboxed() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest([.open], sandbox: .disabled), settings: [:], root: root,
      dataDir: dataDir)
    XCTAssertNil(resolved.profile)
    XCTAssertEqual(resolved.mode, "disabled_by_manifest")
  }
}

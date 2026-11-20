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
  /// and cannot list pids. The wildcard leaves the code-signature reads
  /// open, so every operation is named too. No rule relies on its position
  /// among the others.
  func testOtherProcessesAreDeniedByNameInEveryProfile() throws {
    let profile = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest(), settings: [:], root: root, dataDir: dataDir
      ).profile)
    XCTAssertTrue(profile.contains("(deny process-info* (target others))"))
    XCTAssertTrue(
      profile.contains(
        "(deny process-info-pidinfo process-info-pidfdinfo process-info-rusage"
          + " process-info-pidfileportinfo process-info-setcontrol process-info-dirtycontrol"
          + " process-info-codesignature process-info-ledger (target others))"))
    XCTAssertTrue(profile.contains("(deny process-info-listpids)"))
    XCTAssertTrue(profile.contains("(allow process-info* (target self))"))
    XCTAssertFalse(profile.contains("(allow process-info-listpids)"))
    XCTAssertFalse(profile.contains("(allow process-info-pidinfo"))
  }

  /// No capability opens another process: the profile of a plugin holding
  /// every one of them, the one that reads the process table through the
  /// host included, carries the same denial and no allow beside its own
  /// process.
  func testNoCapabilityOpensAnotherProcess() throws {
    let plain = try XCTUnwrap(
      PluginSandbox.resolvedSandboxProfile(
        manifest: specManifest([]), settings: [:], root: root, dataDir: dataDir
      ).profile)
    for capabilities in [Set(PluginCapability.allCases), [.processTable], [.processSignal]] {
      let profile = try XCTUnwrap(
        PluginSandbox.resolvedSandboxProfile(
          manifest: specManifest(capabilities), settings: [:], root: root, dataDir: dataDir
        ).profile)
      let rules = { (text: String) in
        text.split(separator: "\n").filter { $0.contains("process-info") }
      }
      XCTAssertEqual(rules(profile), rules(plain), "\(capabilities.map(\.rawValue).sorted())")
      XCTAssertEqual(rules(profile).count, 4)
      XCTAssertEqual(
        rules(profile).filter { $0.hasPrefix("(allow") }, ["(allow process-info* (target self))"])
    }
    XCTAssertNil(PluginCapability(rawValue: "process_info"), "the capability is gone")
  }

  /// `sysctl-read` is an allow-list in every plugin profile, whatever the
  /// capabilities: no blanket allow, one filtered allow, and the process
  /// subtrees denied after it, because the last matching filtered rule of an
  /// operation decides.
  func testSysctlReadsAreAnAllowListFollowedByTheProcessDeny() throws {
    for capabilities: Set<PluginCapability> in [[], [.processTable], [.network]] {
      let profile = try XCTUnwrap(
        PluginSandbox.resolvedSandboxProfile(
          manifest: specManifest(capabilities), settings: [:], root: root, dataDir: dataDir
        ).profile)
      let lines = profile.components(separatedBy: "\n")
      XCTAssertFalse(lines.contains("(allow sysctl-read)"), "no blanket allow")
      XCTAssertFalse(profile.contains("sysctl*"))
      XCTAssertFalse(profile.contains("sysctl-write"))
      let allows = lines.indices.filter { lines[$0].hasPrefix("(allow sysctl-read ") }
      XCTAssertEqual(allows.count, 1, "one allow, filtered")
      let allow = try XCTUnwrap(allows.first)
      XCTAssertTrue(lines[allow].contains("(sysctl-name \"kern.boottime\" "))
      XCTAssertTrue(lines[allow].contains("\"hw.\""))
      let deny = try XCTUnwrap(
        lines.firstIndex(of: "(deny sysctl-read (sysctl-name-prefix \"kern.proc\"))"))
      XCTAssertGreaterThan(deny, allow, "the deny follows the allow it bounds")
      XCTAssertTrue(
        lines.contains("(deny sysctl-read (with no-report) (sysctl-name \"kern.bootargs\"))"))
    }
  }

  /// The list names no process node, and none of its prefixes reaches one: a
  /// prefix that `kern.proc` itself starts with (`kern.`) would open the
  /// process list and every process's arguments and environment.
  func testTheSysctlAllowListNamesNoProcessNode() {
    let denied = PluginSandbox.deniedSysctlPrefix
    XCTAssertEqual(denied, "kern.proc")
    let names = PluginSandbox.sysctlNames
    let prefixes = PluginSandbox.sysctlNamePrefixes
    XCTAssertEqual(Set(names).count, names.count, "each name once")
    XCTAssertEqual(Set(prefixes).count, prefixes.count, "each prefix once")
    for name in names {
      XCTAssertFalse(name.hasPrefix(denied), name)
      XCTAssertNotEqual(name, "kern.bootargs")
      // An exact name: a node addressed with a numeric tail needs its own.
      XCTAssertFalse(name.hasSuffix("."), name)
    }
    for prefix in prefixes {
      XCTAssertFalse(prefix.hasPrefix(denied), prefix)
      XCTAssertFalse(denied.hasPrefix(prefix), "\(prefix) covers the process subtrees")
      XCTAssertFalse("kern.bootargs".hasPrefix(prefix), prefix)
      // `net.` holds every socket's owner (`net.inet.tcp.pcblist_n`).
      XCTAssertFalse("net.inet.".hasPrefix(prefix), prefix)
    }
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

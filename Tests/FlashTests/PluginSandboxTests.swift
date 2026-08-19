import XCTest

@testable import flash

/// The plugin network sandbox: a plugin without a `network` (or `subprocess`)
/// capability is spawned under a seatbelt profile that denies outbound network,
/// so a compromised or buggy plugin can't exfiltrate.
final class PluginSandboxTests: XCTestCase {
  private func manifest(_ capabilities: Set<PluginCapability>) -> PluginManifest {
    PluginManifest(
      id: "test", name: "Test", version: "1", description: "",
      install: "true", exec: ["./flash-plugin-test"], capabilities: capabilities)
  }

  func testPluginWithoutCapabilitiesIsNetworkDenied() {
    let profile = PluginSandbox.networkSandboxProfile(for: manifest([]))
    XCTAssertNotNil(profile)
    XCTAssertTrue(profile?.contains("(deny network*)") == true, profile ?? "nil")
    XCTAssertTrue(profile?.contains("(allow default)") == true, profile ?? "nil")
  }

  func testUnrelatedCapabilityIsStillNetworkDenied() {
    // A non-network capability (accessibility) does not grant network access.
    XCTAssertNotNil(PluginSandbox.networkSandboxProfile(for: manifest([.accessibility])))
  }

  func testNetworkCapabilityOptsOutOfTheSandbox() {
    XCTAssertNil(PluginSandbox.networkSandboxProfile(for: manifest([.network])))
  }

  func testSubprocessCapabilityOptsOutOfTheSandbox() {
    // Legacy behavior for spec-less plugins (tmux execs setgid /bin/ps for
    // its process tree): subprocess still opts out of the transitional
    // profile until the plugin declares a deny-default spec.
    XCTAssertNil(PluginSandbox.networkSandboxProfile(for: manifest([.subprocess])))
  }

  private func specManifest(
    _ capabilities: Set<PluginCapability> = [], spec: PluginSandboxSpec = PluginSandboxSpec()
  ) -> PluginManifest {
    PluginManifest(
      id: "test", name: "Test", version: "1", description: "",
      install: "true", exec: ["./flash-plugin-test"], sandbox: spec,
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

  func testSandboxSpecComposesExecAllowlist() {
    let spec = PluginSandboxSpec(exec: ["/usr/bin/osascript"], read: ["~/Library/Notes"])
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest(spec: spec), settings: [:], root: root, dataDir: dataDir)
    let profile = try! XCTUnwrap(resolved.profile)
    XCTAssertTrue(profile.contains("(allow process-exec (literal \"/usr/bin/osascript\"))"))
    XCTAssertTrue(profile.contains("(allow process-fork)"))
    XCTAssertTrue(profile.contains("Library/Notes"))
    XCTAssertFalse(profile.contains("~"), "tilde must be expanded in profile paths")
  }

  func testConfigKillSwitchDisablesSandboxLoudly() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: specManifest(), settings: ["sandbox": .bool(false)],
      root: root, dataDir: dataDir)
    XCTAssertNil(resolved.profile)
    XCTAssertEqual(resolved.mode, "disabled_by_config")
  }

  func testLegacyProfileStillAppliesWithoutSpec() {
    let resolved = PluginSandbox.resolvedSandboxProfile(
      manifest: manifest([]), settings: [:],
      root: root, dataDir: dataDir)
    XCTAssertEqual(resolved.mode, "network_denied")
    XCTAssertTrue(resolved.profile?.contains("(allow default)") == true)
  }
}

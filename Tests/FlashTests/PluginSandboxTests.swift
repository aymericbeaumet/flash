import XCTest

@testable import flash

/// The plugin network sandbox: a plugin without a `network` (or `subprocess`)
/// capability is spawned under a seatbelt profile that denies outbound network,
/// so a compromised or buggy plugin can't exfiltrate.
final class PluginSandboxTests: XCTestCase {
  private func manifest(_ capabilities: Set<PluginCapability>) -> PluginManifest {
    PluginManifest(
      id: "test", name: "Test", version: "1", description: "",
      install: "true", start: "exec ./flash-plugin-test", capabilities: capabilities)
  }

  func testPluginWithoutCapabilitiesIsNetworkDenied() {
    let profile = PluginProcess.networkSandboxProfile(for: manifest([]))
    XCTAssertNotNil(profile)
    XCTAssertTrue(profile?.contains("(deny network*)") == true, profile ?? "nil")
    XCTAssertTrue(profile?.contains("(allow default)") == true, profile ?? "nil")
  }

  func testUnrelatedCapabilityIsStillNetworkDenied() {
    // A non-network capability (accessibility) does not grant network access.
    XCTAssertNotNil(PluginProcess.networkSandboxProfile(for: manifest([.accessibility])))
  }

  func testNetworkCapabilityOptsOutOfTheSandbox() {
    XCTAssertNil(PluginProcess.networkSandboxProfile(for: manifest([.network])))
  }

  func testSubprocessCapabilityOptsOutOfTheSandbox() {
    // processes/tmux exec setgid /bin/ps, which seatbelt refuses — so they must
    // run unsandboxed.
    XCTAssertNil(PluginProcess.networkSandboxProfile(for: manifest([.subprocess])))
  }
}

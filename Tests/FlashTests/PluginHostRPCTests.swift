import Carbon.HIToolbox
import XCTest

@testable import flash

final class PluginHostRPCTests: XCTestCase {
  func testGlobalSyntheticKeyChordParsesValidatedModifiers() throws {
    let chord = try XCTUnwrap(
      PluginHostRPC.globalSyntheticKeyChord(from: [
        "key_code": Int(kVK_ANSI_Q),
        "modifiers": ["command", "control"],
      ]))
    XCTAssertEqual(chord.key, CGKeyCode(kVK_ANSI_Q))
    XCTAssertEqual(chord.flags, [.maskCommand, .maskControl])

    XCTAssertNil(
      PluginHostRPC.globalSyntheticKeyChord(from: [
        "key_code": Int(kVK_ANSI_Q),
        "modifiers": ["unknown"],
      ]))
  }

  func testGlobalKeyPostingRequiresAccessibilityCapability() {
    let rpc = PluginHostRPC()
    let replied = expectation(description: "host reply")
    rpc.handleHostRequest(
      method: "host.post_global_key",
      params: [
        "key_code": Int(kVK_ANSI_Q),
        "modifiers": ["command", "control"],
      ],
      pluginID: "test",
      capabilities: []
    ) { response in
      XCTAssertEqual(response["ok"] as? Bool, false)
      XCTAssertEqual(response["error"] as? String, "missing accessibility capability")
      replied.fulfill()
    }
    wait(for: [replied], timeout: 1)
  }

  func testGlobalKeyPostingRoutesValidatedChord() {
    let rpc = PluginHostRPC()
    let replied = expectation(description: "host reply")
    rpc.onGlobalSyntheticKeyRequested = { key, flags in
      XCTAssertEqual(key, CGKeyCode(kVK_ANSI_Q))
      XCTAssertEqual(flags, [.maskCommand, .maskControl])
      return true
    }
    rpc.handleHostRequest(
      method: "host.post_global_key",
      params: [
        "key_code": Int(kVK_ANSI_Q),
        "modifiers": ["command", "control"],
      ],
      pluginID: "test",
      capabilities: [.accessibility]
    ) { response in
      XCTAssertEqual(response["ok"] as? Bool, true)
      replied.fulfill()
    }
    wait(for: [replied], timeout: 1)
  }
}

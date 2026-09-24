import Carbon.HIToolbox
import XCTest

@testable import flash

final class PluginHostRPCTests: XCTestCase {
  func testNativePIDBoundariesRejectOverflowAndCoercionBeforeSideEffects() throws {
    let rpc = PluginHostRPC()
    let previousSignal = PluginHostRPC.signalSender
    defer { PluginHostRPC.signalSender = previousSignal }
    PluginHostRPC.signalSender = { _ in
      XCTFail("invalid PID reached signal sender")
      return 0
    }
    rpc.onSyntheticKeysRequested = { _, _, _ in XCTFail("invalid PID reached input synthesis") }
    for raw in ["2147483648", "9223372036854775807", "true", "1.5", "1.0", "-1", "0"] {
      let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
      for method in [
        "host.activate", "host.post_keys", "host.process_table", "host.signal", "host.ax_snapshot",
      ] {
        let replied = expectation(description: "\(method) rejects \(raw)")
        rpc.handleHostRequest(
          method: method, params: ["pid": value, "keys": ["cmd+s"]], pluginID: "test",
          capabilities: [.appControl, .accessibility, .processControl]
        ) { response in
          XCTAssertEqual(response["ok"] as? Bool, false, "\(method) accepted \(raw)")
          replied.fulfill()
        }
        wait(for: [replied], timeout: 1)
      }
    }
  }

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

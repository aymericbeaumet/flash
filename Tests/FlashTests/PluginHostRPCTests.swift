import XCTest

@testable import flash

final class PluginHostRPCTests: XCTestCase {
  func testNativePIDBoundariesRejectOverflowAndCoercionBeforeSideEffects() throws {
    let rpc = PluginHostRPC()
    rpc.onSyntheticKeysRequested = { _, _, _ in XCTFail("invalid PID reached input synthesis") }
    for raw in ["2147483648", "9223372036854775807", "true", "1.5", "1.0", "-1", "0"] {
      let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
      for method in ["host.activate", "host.post_keys", "host.ax_snapshot"] {
        let replied = expectation(description: "\(method) rejects \(raw)")
        rpc.handleHostRequest(
          method: method, params: ["pid": value, "keys": ["cmd+s"]], pluginID: "test",
          capabilities: [.appControl, .accessibility],
          scope: PluginHostRequestScope(isCurrent: { true })
        ) { response in
          XCTAssertEqual(response["ok"] as? Bool, false, "\(method) accepted \(raw)")
          replied.fulfill()
        }
        wait(for: [replied], timeout: 1)
      }
    }
  }
}

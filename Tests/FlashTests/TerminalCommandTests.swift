import XCTest

@testable import flash

final class TerminalCommandTests: XCTestCase {
  func testRestartTargetsExplicitOrFocusedSession() {
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_restart", args: [:]),
      .terminalRestart(name: nil))
    XCTAssertEqual(
      URLEventHandler.parse(verb: "terminal_restart", args: ["name": "system"]),
      .terminalRestart(name: "system"))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_restart", args: ["name": ""]))
    XCTAssertNil(URLEventHandler.parse(verb: "terminal_restart", args: ["unknown": "x"]))
  }
}

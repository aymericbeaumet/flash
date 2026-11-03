import FlashTerminal
import Foundation
import XCTest

/// How long a test waits on a terminal session's child. Spawning can stall
/// for seconds while macOS's exec policy daemon is busy; an expectation
/// still fulfills as soon as its condition holds.
let terminalChildTimeout: TimeInterval = 30

extension XCTestCase {
  func frameFromPTY(
    _ output: String, columns: Int, rows: Int, command: [String]? = nil
  ) throws -> TerminalFrame {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: command ?? ["/usr/bin/printf", "%s", output], columns: columns, rows: rows))
    defer { session.shutdown() }
    let finished = expectation(
      for: NSPredicate { _, _ in
        switch session.state {
        case .exited, .failed: return true
        default: return false
        }
      }, evaluatedWith: nil)
    session.start()
    wait(for: [finished], timeout: terminalChildTimeout)
    XCTAssertEqual(session.state, .exited(code: 0))
    return try XCTUnwrap(session.frame)
  }
}

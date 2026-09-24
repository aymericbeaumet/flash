import FlashTerminal
import Foundation
import XCTest

extension XCTestCase {
  func frameFromPTY(_ output: String, columns: Int, rows: Int) throws -> TerminalFrame {
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: ["/usr/bin/printf", "%s", output], columns: columns, rows: rows))
    defer { session.shutdown() }
    let finished = expectation(
      for: NSPredicate { _, _ in
        switch session.state {
        case .exited, .failed: return true
        default: return false
        }
      }, evaluatedWith: nil)
    session.start()
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(session.state, .exited(code: 0))
    return try XCTUnwrap(session.frame)
  }
}

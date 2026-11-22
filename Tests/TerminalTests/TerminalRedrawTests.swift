import FlashTerminal
import Foundation
import XCTest

/// A pager reload (`gR`) repaints `less`'s whole screen in several writes,
/// scrolling each line up from the bottom. A frame published between two of
/// them shows the page shifted by however far the repaint has got; a redraw
/// Flash asks for publishes only the page it ends on.
final class TerminalRedrawTests: XCTestCase {
  func testAPagerReloadNeverPublishesAShiftedPage() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-redraw-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("document")
    let lines = 60
    func document(_ tick: Int) -> Data {
      Data(
        (0..<lines).map { index in
          index == 0
            ? "\u{1B}[1mtop \(tick)\u{1B}[0m"
            : "\u{1B}[2mrow \(index)\u{1B}[0m "
              + String(repeating: "#", count: (index * 7 + tick) % 50)
        }.joined(separator: "\n").utf8)
    }
    try document(0).write(to: file)
    // The registry's pager, on a grid one row taller than the document.
    let session = TerminalSession(
      configuration: TerminalConfiguration(
        command: [
          "/usr/bin/less", "-R", "--mouse", "--wheel-lines=3", "-~", "-Ps\u{1B}[27m", file.path,
        ],
        environment: [
          "LESS": "", "LESSOPEN": "", "LESSHISTFILE": "-", "LESSSECURE": "1",
          "TERM": "xterm-256color",
        ], columns: 80, rows: lines + 1, scrollbackLines: 0))
    defer { session.shutdown() }
    var frames: [String] = []
    session.onFrame = { frames.append($0.text) }
    let shown = expectation(
      for: NSPredicate { _, _ in frames.last?.hasPrefix("top 0") == true }, evaluatedWith: nil)
    session.start()
    wait(for: [shown], timeout: terminalChildTimeout)

    for tick in 1...5 {
      let first = frames.count
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: document(tick))
      try handle.close()
      session.sendRedraw(Data("gR".utf8))
      let reloaded = expectation(
        for: NSPredicate { _, _ in frames.last?.hasPrefix("top \(tick)") == true },
        evaluatedWith: nil)
      wait(for: [reloaded], timeout: terminalChildTimeout)
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      for frame in frames[first...] {
        XCTAssertTrue(
          frame.hasPrefix("top "), "a frame mid-repaint: \(frame.prefix(60).debugDescription)")
      }
    }
  }
}

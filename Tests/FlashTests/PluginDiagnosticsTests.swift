import Darwin
import FlashCore
import XCTest

@testable import flash

/// Plugin diagnostics stay truthful and bounded: CPU time in real units,
/// stderr as capped, rate-limited lines, and a malformed reply failing its
/// request instead of timing out.
final class PluginDiagnosticsTests: XCTestCase {
  func testRusageTicksConvertToNanoseconds() {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks: UInt64 = 24_000_000
    XCTAssertEqual(
      MachTime.nanoseconds(fromTicks: ticks),
      ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    XCTAssertEqual(MachTime.nanoseconds(fromTicks: .max), .max, "saturates instead of trapping")
  }

  func testStderrIsSplitIntoCappedLines() {
    var lines = PluginStderrLines()
    XCTAssertEqual(lines.append(Data("partial".utf8), now: 1).lines, [], "waits for the newline")
    XCTAssertEqual(
      lines.append(Data(" line\nnext\n\n".utf8), now: 2).lines, ["partial line", "next"])
    let long = Data(repeating: UInt8(ascii: "x"), count: PluginStderrLines.maxLineBytes + 10)
    let output = lines.append(long, now: 3)
    XCTAssertEqual(output.lines.count, 1)
    XCTAssertTrue(output.lines[0].hasSuffix("…"))
    XCTAssertEqual(output.lines[0].count, PluginStderrLines.maxLineBytes + 1)
  }

  func testStderrFloodsAreCountedNotLogged() {
    var lines = PluginStderrLines()
    let flood = Data(String(repeating: "boom\n", count: 50).utf8)
    let first = lines.append(flood, now: 1)
    XCTAssertEqual(first.lines.count, PluginStderrLines.maxLines)
    XCTAssertEqual(first.suppressed, 0)
    let nextWindow = lines.append(Data("again\n".utf8), now: 1 + PluginStderrLines.windowNs)
    XCTAssertEqual(nextWindow.suppressed, 50 - PluginStderrLines.maxLines)
    XCTAssertEqual(nextWindow.lines, ["again"])
  }

  func testAMalformedReplyStillNamesTheRequestItAnswers() {
    XCTAssertEqual(
      PluginWireCodec.responseID(inMalformedFrame: Data(#"{"id":5,"error":"x"}"#.utf8)), 5)
    XCTAssertNil(
      PluginWireCodec.responseID(inMalformedFrame: Data(#"{"id":5,"method":"x","bad":1}"#.utf8)))
    XCTAssertNil(PluginWireCodec.responseID(inMalformedFrame: Data("not json".utf8)))
    XCTAssertNil(PluginWireCodec.responseID(inMalformedFrame: Data(#"{"id":0}"#.utf8)))
  }

  func testRunningApplicationsSignatureIgnoresOrderAndNames() {
    let a: [[String: Any]] = [
      ["pid": 2, "bundle_id": "b", "localized_name": "B"],
      ["pid": 1, "bundle_id": "a", "localized_name": "A"],
    ]
    let reordered: [[String: Any]] = [
      ["pid": 1, "bundle_id": "a", "localized_name": "Renamed"],
      ["pid": 2, "bundle_id": "b", "localized_name": "B"],
    ]
    XCTAssertEqual(
      PluginManager.runningApplicationsSignature(a),
      PluginManager.runningApplicationsSignature(reordered))
    XCTAssertNotEqual(
      PluginManager.runningApplicationsSignature(a),
      PluginManager.runningApplicationsSignature(Array(a.prefix(1))))
  }

  func testAFailedSourceActionKeepsItsReasonAndSource() {
    let result = SourceActionResult.failed(reason: "tmux action failed").attributed(
      to: "plugin:tmux")
    XCTAssertEqual(result.disposition, .failed)
    XCTAssertEqual(result.failureReason, "tmux action failed")
    XCTAssertEqual(result.source, "plugin:tmux")
  }
}

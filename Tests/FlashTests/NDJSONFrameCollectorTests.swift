import XCTest

@testable import flash

final class NDJSONFrameCollectorTests: XCTestCase {
  private func data(_ text: String) -> Data {
    Data(text.utf8)
  }

  func testReassemblesFramesSplitAcrossChunks() {
    var collector = NDJSONFrameCollector()
    XCTAssertEqual(collector.append(data("{\"id\"")), [])
    XCTAssertEqual(
      collector.append(data(":1}\n{\"id\":2}\n")),
      [.frame(data("{\"id\":1}")), .frame(data("{\"id\":2}"))])
  }

  func testEmptyLinesAreSkipped() {
    var collector = NDJSONFrameCollector()
    XCTAssertEqual(
      collector.append(data("\n\n{\"a\":1}\n\n")),
      [.frame(data("{\"a\":1}"))])
  }

  func testOversizedLineWithNewlineInSameChunkIsReported() {
    var collector = NDJSONFrameCollector(maxLineBytes: 8)
    XCTAssertEqual(
      collector.append(data("0123456789ABC\n{\"a\":1}\n")),
      [.oversized(13), .frame(data("{\"a\":1}"))])
  }

  func testStreamSelfHealsAfterOversizedPartialLine() {
    var collector = NDJSONFrameCollector(maxLineBytes: 8)
    // An over-long line with no newline yet starts discarding...
    XCTAssertEqual(collector.append(data("0123456789")), [])
    XCTAssertEqual(collector.append(data("ABCDEF")), [])
    // ...and the next newline reports it once and resumes clean framing.
    XCTAssertEqual(
      collector.append(data("GH\n{\"a\":1}\n")),
      [.oversized(18), .frame(data("{\"a\":1}"))])
  }

  func testScansLargeCoalescedBatchWithoutLosingOrder() {
    var collector = NDJSONFrameCollector()
    let expected = (0..<10_000).map { data("{\"id\":\($0)}") }
    let batch = data(
      expected.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n") + "\n")

    XCTAssertEqual(collector.append(batch), expected.map(NDJSONFrameCollector.Output.frame))
    XCTAssertEqual(collector.append(data("{\"id\":10000}\n")), [.frame(data("{\"id\":10000}"))])
  }
}

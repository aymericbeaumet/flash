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

  /// A long frame arriving in many reads is scanned once: each read searches
  /// only the bytes it added, and a newline split across reads still ends
  /// the frame at the right byte.
  func testLongFrameSplitAcrossManyReadsIsScannedIncrementally() {
    var collector = NDJSONFrameCollector()
    let body = String(repeating: "x", count: 64 * 1024)
    let line = "{\"body\":\"\(body)\"}"
    let bytes = Array(line.utf8)
    var offset = 0
    while offset < bytes.count {
      let end = min(bytes.count, offset + 4096)
      XCTAssertEqual(collector.append(Data(bytes[offset..<end])), [])
      offset = end
    }
    XCTAssertEqual(
      collector.append(data("\n{\"id\":1}\n")),
      [.frame(data(line)), .frame(data("{\"id\":1}"))])
    // The collector is clean afterwards: the next partial line scans from
    // its own start.
    XCTAssertEqual(collector.append(data("{\"id\"")), [])
    XCTAssertEqual(collector.append(data(":2}\n")), [.frame(data("{\"id\":2}"))])
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

import Foundation
import XCTest

@testable import flash

/// The host's length-prefixed MessagePack frame parser — the IPC engine's stream
/// decoder, which the audit flagged as untested. Covers partial tails split
/// across reads, several frames in one chunk, zero-length frames, and the
/// oversized-length desync/reset path.
final class MessagePackFrameCollectorTests: XCTestCase {
  private func framed(_ payload: [UInt8]) -> Data {
    let length = UInt32(payload.count)
    var data = Data([
      UInt8(truncatingIfNeeded: length >> 24),
      UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8),
      UInt8(truncatingIfNeeded: length),
    ])
    data.append(contentsOf: payload)
    return data
  }

  private func collector() -> MessagePackFrameCollector {
    MessagePackFrameCollector(maxFrameBytes: 1024)
  }

  func testSingleCompleteFrame() {
    var collector = collector()
    XCTAssertEqual(collector.append(framed([1, 2, 3])), [.frame(Data([1, 2, 3]))])
  }

  func testTwoFramesInOneChunk() {
    var collector = collector()
    var chunk = framed([1, 2])
    chunk.append(framed([3, 4, 5]))
    XCTAssertEqual(collector.append(chunk), [.frame(Data([1, 2])), .frame(Data([3, 4, 5]))])
  }

  func testFrameSplitAcrossReads() {
    var collector = collector()
    let whole = framed([10, 20, 30, 40])  // 8 bytes total
    XCTAssertEqual(collector.append(Data(whole.prefix(5))), [])  // prefix + 1 payload byte
    XCTAssertEqual(collector.append(Data(whole.dropFirst(5))), [.frame(Data([10, 20, 30, 40]))])
  }

  func testPartialPrefixIsBuffered() {
    var collector = collector()
    XCTAssertEqual(collector.append(Data([0, 0])), [])  // fewer than 4 prefix bytes
    XCTAssertEqual(collector.append(Data([0, 3, 7, 8, 9])), [.frame(Data([7, 8, 9]))])
  }

  func testZeroLengthFrame() {
    var collector = collector()
    XCTAssertEqual(collector.append(framed([])), [.frame(Data())])
  }

  func testOversizedLengthDesyncsAndDropsBuffer() {
    var collector = collector()
    let bogus = Data([0x7F, 0xFF, 0xFF, 0xFF, 9, 9, 9])  // declared length 0x7FFFFFFF
    XCTAssertEqual(collector.append(bogus), [.desynced(length: 0x7FFF_FFFF)])
    // The buffer was dropped, so a fresh valid frame parses cleanly afterward.
    XCTAssertEqual(collector.append(framed([1])), [.frame(Data([1]))])
  }

  func testFrameFollowedByPartialNextFrame() {
    var collector = collector()
    var chunk = framed([1])
    chunk.append(contentsOf: [0, 0, 0, 2, 5])  // next frame's prefix + 1 of its 2 payload bytes
    XCTAssertEqual(collector.append(chunk), [.frame(Data([1]))])
    XCTAssertEqual(collector.append(Data([6])), [.frame(Data([5, 6]))])
  }
}

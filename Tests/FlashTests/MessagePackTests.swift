import CoreGraphics
import FlashCore
import Foundation
import XCTest

final class MessagePackTests: XCTestCase {
  // MARK: Encoder golden vectors

  func testEncodeScalarsMatchSpec() throws {
    try assertEncodes(NSNull(), to: [0xc0])
    try assertEncodes(false, to: [0xc2])
    try assertEncodes(true, to: [0xc3])

    // Positive ints: fixint, uint8, uint16, uint32 boundaries.
    try assertEncodes(0, to: [0x00])
    try assertEncodes(127, to: [0x7f])
    try assertEncodes(128, to: [0xcc, 0x80])
    try assertEncodes(255, to: [0xcc, 0xff])
    try assertEncodes(256, to: [0xcd, 0x01, 0x00])
    try assertEncodes(65535, to: [0xcd, 0xff, 0xff])
    try assertEncodes(65536, to: [0xce, 0x00, 0x01, 0x00, 0x00])

    // Negative ints: negative fixint, int8, int16, int32 boundaries. The
    // library prefers the int8 form only for the negative-fixint range and
    // widens earlier than strictly necessary for everything else — both
    // representations are spec-compliant and rmp-serde decodes either.
    try assertEncodes(-1, to: [0xff])
    try assertEncodes(-32, to: [0xe0])
    try assertEncodes(-33, to: [0xd0, 0xdf])
    try assertEncodes(-128, to: [0xd1, 0xff, 0x80])
    try assertEncodes(-129, to: [0xd1, 0xff, 0x7f])
    try assertEncodes(-32768, to: [0xd2, 0xff, 0xff, 0x80, 0x00])
    try assertEncodes(-32769, to: [0xd2, 0xff, 0xff, 0x7f, 0xff])

    // Double (and CGFloat, which the wire uses for frames) → float64.
    try assertEncodes(1.5 as Double, to: [0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    try assertEncodes(
      CGFloat(1.5), to: [0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  }

  func testEncodeStringsAndContainers() throws {
    try assertEncodes("", to: [0xa0])
    try assertEncodes("a", to: [0xa1, 0x61])
    try assertEncodes("hello", to: [0xa5, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
    try assertEncodes([1, 2, 3] as [Any], to: [0x93, 0x01, 0x02, 0x03])
    try assertEncodes(["a": 1] as [String: Any], to: [0x81, 0xa1, 0x61, 0x01])
  }

  /// The classic Foundation pitfall: a boolean must not be encoded as the
  /// integer 0/1 (or vice versa). This is the single most load-bearing
  /// distinction for the protocol's many `ok`/`did_*` flags.
  func testBoolAndIntDoNotCollide() throws {
    XCTAssertEqual(Array(try MessagePack.encode(true)), [0xc3])
    XCTAssertEqual(Array(try MessagePack.encode(1)), [0x01])
    XCTAssertEqual(Array(try MessagePack.encode(false)), [0xc2])
    XCTAssertEqual(Array(try MessagePack.encode(0)), [0x00])
  }

  // MARK: Decoder golden vectors

  func testDecodeKnownBytes() throws {
    XCTAssertTrue(try MessagePack.decode(Data([0xc0])) is NSNull)
    XCTAssertEqual(try MessagePack.decode(Data([0xc3])) as? Bool, true)
    XCTAssertEqual(try MessagePack.decode(Data([0xc2])) as? Bool, false)
    XCTAssertEqual(try MessagePack.decode(Data([0x7f])) as? Int, 127)
    XCTAssertEqual(try MessagePack.decode(Data([0xe0])) as? Int, -32)
    XCTAssertEqual(try MessagePack.decode(Data([0xcc, 0x80])) as? Int, 128)
    XCTAssertEqual(try MessagePack.decode(Data([0xd0, 0x80])) as? Int, -128)
    XCTAssertEqual(
      try MessagePack.decode(Data([0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        as? Double, 1.5)
    XCTAssertEqual(try MessagePack.decode(Data([0xa1, 0x61])) as? String, "a")
    XCTAssertEqual(try MessagePack.decode(Data([0x93, 0x01, 0x02, 0x03])) as? [Int], [1, 2, 3])

    // A uint64 above Int.max stays a UInt64 rather than wrapping negative.
    let big = try MessagePack.decode(Data([0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
    XCTAssertEqual(big as? UInt64, UInt64.max)
  }

  func testDecodeFloat32() throws {
    // float32 of 1.5 = 0x3FC00000; widened to Double on decode.
    XCTAssertEqual(
      try MessagePack.decode(Data([0xca, 0x3f, 0xc0, 0x00, 0x00])) as? Double, 1.5)
  }

  // MARK: Round-trips

  func testProtocolFrameRoundTrip() throws {
    let original: [String: Any] = [
      "id": 7,
      "jsonrpc": "2.0",
      "method": "command.invoke",
      "params": [
        "args": ["--version", "x"],
        "n": -5,
        "ratio": 2.5,
        "flag": true,
        "nothing": NSNull(),
        "nested": ["k": 1_000_000],
      ] as [String: Any],
    ]

    let encoded = try MessagePack.encode(original)
    let decoded = try XCTUnwrap(try MessagePack.decode(encoded) as? [String: Any])

    XCTAssertEqual(decoded["id"] as? Int, 7)
    XCTAssertEqual(decoded["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(decoded["method"] as? String, "command.invoke")

    let params = try XCTUnwrap(decoded["params"] as? [String: Any])
    // The same `as? [String]` cast the host uses to read `argv`.
    XCTAssertEqual(params["args"] as? [String], ["--version", "x"])
    XCTAssertEqual(params["n"] as? Int, -5)
    XCTAssertEqual(params["ratio"] as? Double, 2.5)
    XCTAssertEqual(params["flag"] as? Bool, true)
    XCTAssertTrue(params["nothing"] is NSNull)
    let nested = try XCTUnwrap(params["nested"] as? [String: Any])
    XCTAssertEqual(nested["k"] as? Int, 1_000_000)
  }

  func testIntegerBoundaryRoundTrips() throws {
    let values = [
      0, 1, -1, 31, 32, 127, 128, 255, 256, 65535, 65536,
      -32, -33, -128, -129, -32768, -32769, Int(Int32.max), Int(Int32.min),
      Int(Int32.max) + 1, 1_700_000_000_000,
    ]
    for value in values {
      let decoded = try MessagePack.decode(try MessagePack.encode(value)) as? Int
      XCTAssertEqual(decoded, value, "round-trip failed for \(value)")
    }
  }

  // MARK: Errors

  func testTruncatedPayloadThrows() {
    // str8 declaring 5 bytes but only 2 follow.
    XCTAssertThrowsError(try MessagePack.decode(Data([0xd9, 0x05, 0x61, 0x62])))
  }

  func testTrailingBytesThrow() {
    // A valid "a" string followed by an extra nil is not one complete frame.
    XCTAssertThrowsError(try MessagePack.decode(Data([0xa1, 0x61, 0xc0])))
  }

  func testNonStringMapKeyThrows() {
    // Flash protocol objects are JSON-shaped dictionaries; accepting an int
    // key would silently drop data when bridging to [String: Any].
    XCTAssertThrowsError(try MessagePack.decode(Data([0x81, 0x01, 0xa1, 0x78])))
  }

  func testUnknownFormatByteThrows() {
    XCTAssertThrowsError(try MessagePack.decode(Data([0xc1])))
  }

  // MARK: Helpers

  private func assertEncodes(
    _ value: Any?, to expected: [UInt8], file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertEqual(Array(try MessagePack.encode(value)), expected, file: file, line: line)
  }
}

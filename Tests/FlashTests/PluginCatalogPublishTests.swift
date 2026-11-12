import FlashCore
import Foundation
import XCTest

@testable import flash

extension PluginWireCodec.DecodedPublish {
  /// A publish as the store receives it, every row costing `bytesPerRow` on
  /// the wire.
  static func rows(
    _ rows: [Candidate], source: String? = nil, bytesPerRow: Int = 10
  ) -> PluginWireCodec.DecodedPublish {
    PluginWireCodec.DecodedPublish(
      source: source, rows: rows, rowBytes: Array(repeating: bytesPerRow, count: rows.count))
  }
}

extension PluginWireCodec {
  /// Decode `rows` the way the reader does: from the compact publish frame a
  /// conformant plugin writes.
  static func publishedRows(
    _ rows: [[String: Any]], source: String? = nil, sourceID: String,
    allowedSources: Set<String>
  ) -> DecodedPublish? {
    var params: [String: Any] = ["rows": rows]
    if let source { params["source"] = source }
    guard let line = try? encodeFrame(["method": "publish", "params": params]),
      let object = try? decodeFrame(line)
    else { return nil }
    return publish(frame: line, object: object, sourceID: sourceID, allowedSources: allowedSources)
  }
}

/// The `publish` notification host-side: the byte quota counted from the
/// frame the reader already holds, a per-source publish merged into the
/// plugin's catalog, and the quotas applied to that catalog after the merge.
final class PluginCatalogPublishTests: XCTestCase {
  private func frame(_ rows: [[String: Any]], source: String? = nil) throws -> Data {
    var params: [String: Any] = ["rows": rows]
    if let source { params["source"] = source }
    return try PluginWireCodec.encodeFrame(["method": "publish", "params": params])
  }

  private func decode(
    _ line: Data, allowed: Set<String> = ["s", "t"]
  ) throws -> PluginWireCodec.DecodedPublish? {
    let object = try PluginWireCodec.decodeFrame(line)
    return PluginWireCodec.publish(
      frame: line, object: object, sourceID: "plugin:p", allowedSources: allowed)
  }

  private func compactBytes(_ value: Any) throws -> Int {
    try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]).count
  }

  // MARK: - Byte counting from the frame

  /// Each row's bytes are read off the frame, so the count is what the
  /// plugin wrote: exactly the compact encoding for a compact frame, more
  /// for one padded inside its rows. The envelope's own whitespace and key
  /// order never count.
  func testRowSpansAreMeasuredFromTheFrameTheReaderHolds() throws {
    let rows: [[String: Any]] = [
      ["source": "s", "title": "a\"b\\c\n"],
      ["source": "s", "title": "é🚀", "url": "https://example.com/p?q=1"],
      ["source": "t", "title": "three", "metadata": ["k": "v"]],
    ]
    let compact = try frame(rows)
    let spans = try XCTUnwrap(PluginWireCodec.rowByteSpans(inPublishFrame: compact))
    XCTAssertEqual(spans, try rows.map { try compactBytes($0) })
    let decoded = try XCTUnwrap(try decode(compact))
    XCTAssertEqual(decoded.encodedBytes, try compactBytes(rows))
    XCTAssertEqual(decoded.rows.map(\.title), ["a\"b\\c\n", "é🚀", "three"])

    // Whitespace around the envelope and a `source` key before `rows` leave
    // the row spans alone; padding inside a row is the plugin's to pay for.
    let padded = Data(
      #"{ "method" : "publish" , "params" : { "source" : "s" , "rows" : [ {"source":"s","title":"x"} ,  {"source":"s", "title":"y"} ] } }"#
        .utf8 + [0x0A])
    let firstRow = #"{"source":"s","title":"x"}"#.utf8.count
    let paddedRow = #"{"source":"s", "title":"y"}"#.utf8.count
    XCTAssertEqual(PluginWireCodec.rowByteSpans(inPublishFrame: padded), [firstRow, paddedRow])
    let scoped = try XCTUnwrap(try decode(padded))
    XCTAssertEqual(scoped.source, "s")
    XCTAssertEqual(scoped.encodedBytes, firstRow + paddedRow + 2 + 1)

    // An empty catalog is the two brackets.
    let empty = try XCTUnwrap(try decode(try frame([])))
    XCTAssertEqual(empty.encodedBytes, 2)
    XCTAssertTrue(empty.rows.isEmpty)
  }

  /// At the boundary the wire count decides: a catalog whose rows are
  /// exactly the quota on the wire is accepted, one byte more is rejected
  /// whole — without ever re-encoding the rows.
  func testPublishAcceptsExactlyTheCatalogByteQuotaMeasuredFromTheFrame() throws {
    // 1,023 rows of exactly 4,096 bytes (`{"source":"s","title":"<4,071>"}`
    // is 25 + 4,071) and a last row sized to land the compact array —
    // brackets, rows and the separators between them — on `totalBytes`.
    func catalog(totalBytes: Int) -> [[String: Any]] {
      let full = 1_023
      var rows = Array(
        repeating: ["source": "s", "title": String(repeating: "x", count: 4_071)] as [String: Any],
        count: full)
      let lastRow = totalBytes - 2 - full * 4_096 - full
      rows.append(["source": "s", "title": String(repeating: "y", count: lastRow - 25)])
      return rows
    }
    let exact = catalog(totalBytes: PluginProtocol.maxCatalogBytes)
    XCTAssertEqual(try compactBytes(exact), PluginProtocol.maxCatalogBytes)
    let accepted = try XCTUnwrap(try decode(try frame(exact)))
    XCTAssertEqual(accepted.encodedBytes, PluginProtocol.maxCatalogBytes)
    XCTAssertEqual(accepted.rows.count, 1_024)

    let over = catalog(totalBytes: PluginProtocol.maxCatalogBytes + 1)
    XCTAssertEqual(try compactBytes(over), PluginProtocol.maxCatalogBytes + 1)
    XCTAssertNil(try decode(try frame(over)))

    // The row count quota is the same atomic rejection.
    let tooMany = Array(
      repeating: ["source": "s", "title": "r"] as [String: Any],
      count: PluginProtocol.maxCatalogRows + 1)
    XCTAssertNil(try decode(try frame(tooMany)))
  }

  /// A `source` publish names a declared source and carries only its rows;
  /// anything else — a row of another source, an undeclared source, an
  /// unknown params key — rejects the publish whole.
  func testASourcePublishIsRejectedWholeUnlessEveryRowBelongsToIt() throws {
    let own = try XCTUnwrap(try decode(try frame([["source": "s", "title": "a"]], source: "s")))
    XCTAssertEqual(own.source, "s")
    XCTAssertEqual(own.rows.map(\.title), ["a"])
    XCTAssertNil(
      try decode(
        try frame([["source": "s", "title": "a"], ["source": "t", "title": "b"]], source: "s")))
    XCTAssertNil(try decode(try frame([["source": "u", "title": "a"]], source: "u")))
    XCTAssertNil(try decode(try frame([], source: "u")))
    let extra = try PluginWireCodec.encodeFrame([
      "method": "publish", "params": ["rows": [], "source": "s", "reason": "refresh"],
    ])
    XCTAssertNil(try decode(extra))
    // A whole-catalog publish still mixes sources freely.
    let whole = try XCTUnwrap(
      try decode(try frame([["source": "s", "title": "a"], ["source": "t", "title": "b"]])))
    XCTAssertNil(whole.source)
    XCTAssertEqual(whole.rows.count, 2)
  }

  // MARK: - The store's per-source merge

  private func candidate(_ title: String, source: String) -> Candidate {
    Candidate(title: title, metadata: [CandidateMetadataKey.source: source])
  }

  /// A source publish replaces that source's rows alone: the others keep
  /// theirs, a new source joins at the end, an empty one leaves, and an
  /// unchanged one does not advance the generation.
  func testASourcePublishReplacesThatSourceAlone() throws {
    let store = PluginCatalogStore()
    let a1 = candidate("A1", source: "a")
    let b1 = candidate("B1", source: "b")
    let b2 = candidate("B2", source: "b")
    let c1 = candidate("C1", source: "c")
    XCTAssertEqual(store.publish(pluginID: "p", .rows([a1, b1])), .stored)
    XCTAssertEqual(store.publish(pluginID: "p", .rows([b2], source: "b")), .stored)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["A1", "B2"])
    XCTAssertEqual(store.entry(for: "p")?.generation, 2)
    XCTAssertEqual(store.publish(pluginID: "p", .rows([b2], source: "b")), .unchanged)
    XCTAssertEqual(store.entry(for: "p")?.generation, 2)
    XCTAssertEqual(store.publish(pluginID: "p", .rows([c1], source: "c")), .stored)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["A1", "B2", "C1"])
    XCTAssertEqual(store.publish(pluginID: "p", .rows([], source: "a")), .stored)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["B2", "C1"])
    XCTAssertEqual(store.publish(pluginID: "p", .rows([], source: "a")), .unchanged)
    // A whole-catalog publish starts over, grouped by source in order.
    XCTAssertEqual(store.publish(pluginID: "p", .rows([c1, a1, b1])), .stored)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["C1", "A1", "B1"])
    XCTAssertEqual(store.publish(pluginID: "p", .rows([b2], source: "b")), .stored)
    XCTAssertEqual(store.rows(for: "p").map(\.title), ["C1", "A1", "B2"])
    // A source publish before any catalog is that catalog.
    XCTAssertEqual(store.publish(pluginID: "q", .rows([b1], source: "b")), .stored)
    XCTAssertEqual(store.rows(for: "q").map(\.title), ["B1"])
  }

  /// The row and byte quotas bound the plugin's catalog after the merge: a
  /// source publish that would push the whole over is rejected and the
  /// previous rows of that source stay.
  func testQuotasBoundTheWholeCatalogAfterAMerge() throws {
    let store = PluginCatalogStore()
    let rows = { (count: Int, source: String) -> [Candidate] in
      (0..<count).map { self.candidate("\(source)\($0)", source: source) }
    }
    let rowLimit = PluginProtocol.maxCatalogRows
    XCTAssertEqual(store.publish(pluginID: "p", .rows(rows(6_000, "a"), source: "a")), .stored)
    XCTAssertEqual(
      store.publish(pluginID: "p", .rows(rows(rowLimit - 6_000, "b"), source: "b")), .stored)
    XCTAssertEqual(store.rows(for: "p").count, rowLimit)
    XCTAssertEqual(
      store.publish(pluginID: "p", .rows(rows(rowLimit - 6_000 + 1, "b"), source: "b")),
      .overQuota)
    XCTAssertEqual(store.rows(for: "p").count, rowLimit, "the rejected publish changed nothing")
    XCTAssertEqual(store.entry(for: "p")?.generation, 2)

    // Bytes: the merged array is every row's span, a separator per row and
    // the brackets — four rows leave quota - 5 bytes of spans. Exactly the
    // quota is accepted, one more byte is not.
    let byteStore = PluginCatalogStore()
    let spans = PluginProtocol.maxCatalogBytes - 5
    let perRow = spans / 4
    let a = PluginWireCodec.DecodedPublish(
      source: "a", rows: rows(2, "a"), rowBytes: [perRow, perRow])
    XCTAssertEqual(byteStore.publish(pluginID: "p", a), .stored)
    let b = PluginWireCodec.DecodedPublish(
      source: "b", rows: rows(2, "b"), rowBytes: [perRow, perRow + spans % 4])
    XCTAssertEqual(byteStore.publish(pluginID: "p", b), .stored)
    XCTAssertEqual(byteStore.entry(for: "p")?.encodedBytes, PluginProtocol.maxCatalogBytes)
    // A changed source one byte larger: identical rows would be unchanged
    // before any quota is looked at.
    let over = PluginWireCodec.DecodedPublish(
      source: "b", rows: [candidate("b0", source: "b"), candidate("b1+", source: "b")],
      rowBytes: [perRow, perRow + spans % 4 + 1])
    XCTAssertEqual(byteStore.publish(pluginID: "p", over), .overQuota)
    XCTAssertEqual(byteStore.entry(for: "p")?.encodedBytes, PluginProtocol.maxCatalogBytes)
    // A whole-catalog publish is bounded the same way: two rows, their two
    // separators and the brackets, one byte past the quota.
    let wholeOver = PluginWireCodec.DecodedPublish(
      source: nil, rows: rows(2, "a"), rowBytes: [spans / 2 + 2, spans / 2 + 2])
    XCTAssertEqual(byteStore.publish(pluginID: "p", wholeOver), .overQuota)
    XCTAssertEqual(byteStore.rows(for: "p").map(\.title), ["a0", "a1", "b0", "b1"])
  }
}

import FlashCore
import Foundation
import XCTest

@testable import flash

/// Where a large `publish` spends its time on the host: one synthetic frame
/// the size of the browsers plugin's tab-plus-history catalog (about 3,200
/// rows, 700 KB), timed phase by phase. Report-only — it asserts the
/// decode is correct, never a duration — so the numbers can be compared
/// across builds with `swift test --filter PluginPublishBenchmarkTests`.
final class PluginPublishBenchmarkTests: XCTestCase {
  static let rowCount = 3_187

  /// Rows shaped like the browsers plugin's: a per-browser source, a page
  /// title, a URL and the metadata a tab or history row carries.
  static func syntheticRows(count: Int = rowCount) -> [[String: Any]] {
    (0..<count).map { index -> [String: Any] in
      let tab = index < 24
      return [
        "source": tab ? "firefox.tabs" : (index % 2 == 0 ? "firefox.history" : "chrome.history"),
        "title": "Row \(index): a page title of ordinary length — documentation, issue #\(index)",
        "url":
          "https://example.com/docs/section-\(index % 97)/page-\(index)?ref=flash&tab=\(index)",
        "metadata": [
          "kind": tab ? "browser_tab" : "history",
          "subtitle": tab ? "browser tab" : "history",
          "bundle_id": "org.mozilla.firefox",
          "pid": "4242",
          "payload":
            "{\"bundle_id\":\"org.mozilla.firefox\",\"url\":\"https://example.com/p/\(index)\",\"title\":\"Row \(index)\"}",
          "navigation_url": "flash-browser://4242/\(index)",
        ],
      ]
    }
  }

  static func publishFrame(rows: [[String: Any]], source: String? = nil) throws -> Data {
    var params: [String: Any] = ["rows": rows]
    if let source { params["source"] = source }
    return try PluginWireCodec.encodeFrame(["method": "publish", "params": params])
  }

  private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
  }

  private func timed(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }

  func testPublishPhasesOfABrowsersSizedFrame() throws {
    let rows = Self.syntheticRows()
    let line = try Self.publishFrame(rows: rows)
    let allowed: Set<String> = ["firefox.tabs", "firefox.history", "chrome.history"]
    let store = PluginCatalogStore()
    var parse: [Double] = []
    var count: [Double] = []
    var reencode: [Double] = []
    var decode: [Double] = []
    var compare: [Double] = []
    var decoded: PluginWireCodec.DecodedPublish?
    for _ in 0..<5 {
      var object: [String: Any] = [:]
      parse.append(timed { object = (try? PluginWireCodec.decodeFrame(line)) ?? [:] })
      let raw = try XCTUnwrap((object["params"] as? [String: Any])?["rows"] as? [[String: Any]])
      // The byte count alone, as the reader takes it off the frame.
      count.append(timed { _ = PluginWireCodec.rowByteSpans(inPublishFrame: line) })
      // The count the host used to make: a second serialization of the rows.
      reencode.append(timed { _ = PluginJSON.encodedBytes(raw) })
      // The whole decode: the count above, then validation into candidates.
      decode.append(
        timed {
          decoded = PluginWireCodec.publish(
            frame: line, object: object, sourceID: "plugin:bench", allowedSources: allowed)
        })
      XCTAssertEqual(raw.count, Self.rowCount)
      let publish = try XCTUnwrap(decoded)
      // The first publish stores; the second, identical one is the compare.
      store.publish(pluginID: "bench", publish)
      compare.append(timed { _ = store.publish(pluginID: "bench", publish) })
    }
    let publish = try XCTUnwrap(decoded)
    XCTAssertEqual(publish.rows.count, Self.rowCount)
    XCTAssertEqual(store.rows(for: "bench").count, Self.rowCount)
    let summary = String(
      format:
        "[bench] publish rows=%d frame_bytes=%d rows_bytes=%d parse_ms=%.1f count_ms=%.2f reencode_ms=%.2f decode_ms=%.1f compare_ms=%.2f",
      Self.rowCount, line.count, publish.encodedBytes, median(parse), median(count),
      median(reencode), median(decode), median(compare))
    print(summary)
    FlashLog.info(summary)
  }
}

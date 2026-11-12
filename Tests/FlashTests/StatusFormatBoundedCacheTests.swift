import XCTest

@testable import flash

/// The one bound the status format's memos share: entries and source bytes,
/// oldest out first, oversized work returned but never kept.
final class StatusFormatBoundedCacheTests: XCTestCase {
  func testItMakesAValueOnceAndEvictsTheOldestByCountAndBytes() {
    let cache = StatusFormatBoundedCache<String, Int>(
      maxEntries: 3, maxBytes: 10, maxEntryBytes: 6)
    var made = 0
    func value(_ key: String) -> Int {
      cache.value(for: key, size: key.utf8.count) {
        made += 1
        return key.count
      }
    }
    XCTAssertEqual(value("aa"), 2)
    XCTAssertEqual(value("aa"), 2)
    XCTAssertEqual(made, 1, "a kept value is not made again")
    _ = value("bb")
    _ = value("cc")
    _ = value("dd")
    XCTAssertEqual(cache.count, 3, "the fourth entry retired the oldest")
    XCTAssertEqual(made, 4)
    _ = value("aa")
    XCTAssertEqual(made, 5, "aa was the one retired")
    _ = value("eeeee")
    XCTAssertLessThanOrEqual(cache.count, 3)
    _ = value("fffffff")
    _ = value("fffffff")
    XCTAssertEqual(made, 8, "oversized work is returned but never kept")
  }

  /// The three memos still return what their work made, nil included.
  func testTheStatusFormatMemosKeepTheirAnswers() {
    let regex = StatusFormatRegexCache.shared
    XCTAssertNotNil(regex.regex(pattern: "^a+$", flags: REG_EXTENDED))
    XCTAssertNil(regex.regex(pattern: "(", flags: REG_EXTENDED), "a bad pattern stays nil")
    XCTAssertNil(regex.regex(pattern: "(", flags: REG_EXTENDED))
  }
}

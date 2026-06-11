import XCTest
@testable import FlashSearch

final class SearchFilterCompilerTests: XCTestCase {
  func testParseField() {
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "x").field, .source)
    XCTAssertEqual(SearchFilter.parse(field: "name", pattern: "x").field, .title)
    XCTAssertEqual(SearchFilter.parse(field: "title", pattern: "x").field, .title)
    XCTAssertEqual(SearchFilter.parse(field: "BUNDLE_ID", pattern: "x").field, .bundle)
    if case .meta(let k) = SearchFilter.parse(field: "meta.pinned", pattern: "x").field {
      XCTAssertEqual(k, "pinned")
    } else {
      XCTFail()
    }
    XCTAssertEqual(SearchFilter.parse(field: "meta.bad-key!", pattern: "x").field, .unknown)
    XCTAssertEqual(SearchFilter.parse(field: "totallybogus", pattern: "x").field, .unknown)
  }

  func testParseKind() {
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "*").kind, .any)
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "firefox").kind, .exact)
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "fire*").kind, .prefix)
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "*fox").kind, .suffix)
    XCTAssertEqual(SearchFilter.parse(field: "source", pattern: "*goog*").kind, .contains)
  }

  func testCompileGroupsByField() {
    let filters = [
      SearchFilter.parse(field: "source", pattern: "firefox"),
      SearchFilter.parse(field: "source", pattern: "chrome"),
      SearchFilter.parse(field: "kind", pattern: "page"),
    ]
    let compiled = SearchFilterCompiler.compile(filters)
    XCTAssertNotNil(compiled)
    let sql = compiled!.sql
    // OR inside source group, AND across groups.
    XCTAssertTrue(sql.contains("OR"))
    XCTAssertTrue(sql.contains("AND"))
    XCTAssertEqual(compiled!.arguments.count, 3)
  }

  func testEmptyFiltersIsNil() {
    XCTAssertNil(SearchFilterCompiler.compile([]))
  }

  func testUnknownFieldShortCircuits() {
    let filters = [SearchFilter.parse(field: "totally-unknown", pattern: "x")]
    let compiled = SearchFilterCompiler.compile(filters)
    XCTAssertNotNil(compiled)
    // `0` collapses the AND chain.
    XCTAssertEqual(compiled!.sql, "0")
    XCTAssertEqual(compiled!.arguments.count, 0)
  }

  func testLIKEEscaping() {
    XCTAssertEqual(SearchFilterCompiler.escapeLIKE("100%"), "100\\%")
    XCTAssertEqual(SearchFilterCompiler.escapeLIKE("a_b"), "a\\_b")
    XCTAssertEqual(SearchFilterCompiler.escapeLIKE("c\\d"), "c\\\\d")
    XCTAssertEqual(SearchFilterCompiler.escapeLIKE("plain"), "plain")
  }

  func testNullableFieldAnyTranslatesToIsNotNull() {
    let filter = SearchFilter.parse(field: "subtitle", pattern: "*")
    let compiled = SearchFilterCompiler.compile([filter])
    XCTAssertTrue(compiled!.sql.contains("IS NOT NULL"))
  }

  func testMetaFieldUsesJsonExtract() {
    let filter = SearchFilter.parse(field: "meta.pinned", pattern: "true")
    let compiled = SearchFilterCompiler.compile([filter])
    XCTAssertTrue(compiled!.sql.contains("json_extract(d.meta, '$.pinned')"))
  }
}

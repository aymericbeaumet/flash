import XCTest

@testable import flash

final class ConfigPurgeTests: XCTestCase {
  func testPurgeDropsDefaultAssignmentsAndKeepsTheRest() {
    let defaults = """
      [mode]
      scroll_step_lines = 3.0
      sequence_timeout_ms = 1000
      [hints]
      keys = "<qwerty_homerow+qwerty_toprow>"
      foo = { a = 1, b = 2 }

      """
    let source = """
      # keep this comment
      [mode]
      scroll_step_lines = 3
      sequence_timeout_ms = 250
      note = \"\"\"
      hello
      = still here
      \"\"\"
      [hints]
      keys = "<colemak>"
      foo = { a = 1 }

      [[rules]]
      scroll_step_lines = 3

      """
    let purged = ConfigPurge.purgeDefaults(in: source, defaults: defaults)
    XCTAssertTrue(purged.contains("# keep this comment"))
    XCTAssertTrue(purged.contains("[mode]\nsequence_timeout_ms = 250"))
    XCTAssertFalse(purged.contains("[mode]\nscroll_step_lines = 3"))
    XCTAssertTrue(purged.contains("hello"))
    XCTAssertTrue(purged.contains("= still here"))
    XCTAssertTrue(purged.contains("keys = \"<colemak>\""))
    XCTAssertTrue(purged.contains("foo = { a = 1 }"))
    XCTAssertTrue(purged.contains("[[rules]]\nscroll_step_lines = 3"))
  }

  func testAnEmptyDocumentAndAParseFailureRoundTrip() {
    XCTAssertNil(ConfigPurge.tomlError(in: ""))
    XCTAssertNil(ConfigPurge.tomlError(in: "\n"))
    XCTAssertNotNil(ConfigPurge.tomlError(in: "[unterminated"))
    XCTAssertEqual(
      ConfigPurge.purgeDefaults(in: "keep = 1\n", defaults: "not toml ["), "keep = 1\n")
  }
}

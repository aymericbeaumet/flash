import XCTest

@testable import flash

/// Every plain color key reads one way: `#RRGGBB` or `#RRGGBBAA`, anything
/// else rejected with the message every color key shares.
final class ConfigColorKeysTests: XCTestCase {
  private let keys: [(section: String, key: String, read: (Config) -> String)] = [
    ("overlay", "hint_fg", { $0.overlay.hintFG }),
    ("overlay", "hint_bg_top", { $0.overlay.hintBGTop }),
    ("overlay", "hint_bg_bottom", { $0.overlay.hintBGBottom }),
    ("overlay", "hint_border", { $0.overlay.hintBorder }),
    ("overlay", "important_hint_fg", { $0.overlay.importantHintFG }),
    ("overlay", "important_hint_bg_top", { $0.overlay.importantHintBGTop }),
    ("overlay", "important_hint_bg_bottom", { $0.overlay.importantHintBGBottom }),
    ("overlay", "important_hint_border", { $0.overlay.importantHintBorder }),
    ("debug", "hints_bounds_bg", { $0.debug.hintsBoundsBG }),
    ("debug", "hints_bounds_fg", { $0.debug.hintsBoundsFG }),
  ]

  func testEachColorKeyTakesAHexColorAndRejectsAnythingElse() {
    for entry in keys {
      let accepted = ConfigLoader.parse("[\(entry.section)]\n\(entry.key) = \"#11223344\"\n")
      XCTAssertEqual(accepted.loadingDiagnostics.map(\.message), [], entry.key)
      XCTAssertEqual(entry.read(accepted), "#11223344", entry.key)
      let rejected = ConfigLoader.parse("[\(entry.section)]\n\(entry.key) = \"red\"\n")
      XCTAssertEqual(
        rejected.loadingDiagnostics.map(\.message),
        ["\(entry.section).\(entry.key) must be a hex color like #RRGGBB or #RRGGBBAA"],
        entry.key)
      XCTAssertEqual(entry.read(rejected), entry.read(Config.default), "kept the default")
    }
  }
}

import Foundation
import XCTest

@testable import FlashCore

/// macOS 13's `URL(string:)` returns nil for a string a URL cannot hold;
/// macOS 14 and later repair it. `URLParsing.repaired` is the macOS 13
/// fallback, so it must rewrite each string into exactly what the running
/// macOS (14 or later) parses it as.
final class URLParsingTests: XCTestCase {
  static let corpus = [
    // Valid strings stay as written.
    "https://example.com/a%20b?q=1#top", "https://[::1]:8080/x", "flash-tmux://pane/%251",
    "mailto:a:b", "javascript:alert(1)", "https://EXAMPLE.com/a", "file:///Users/a%20b/c",
    "https://example.com?", "https://example.com/a b#",
    // Invalid characters in one component encode that component whole.
    "https://example.com/a b", "https://ja.wikipedia.org/wiki/日本", "https://example.com/😀",
    "https://example.com/100%off", "https://example.com/a%2", "https://example.com/a%20b c",
    "https://example.com/a%20b?q=x y", "https://example.com/?a=%zz&b=ü",
    "https://example.com/a|b{c}", "https://example.com/a[0]", "https://example.com/?q=\"x\"",
    "https://example.com/a#b#c", "https://example.com/#frag ment#x", "https://example.com/^`\\",
    "https://example.com/a\u{07}b", "https://EXAMPLE.com/Ä", "https://example.com/%7e x",
    "https://us er:p@ss@example.com/", "https://user@/x y", "HTTPS://example.com/ü",
    "https://example.com:/x ", "https://example.com:080/ä", "file:///Users/a b/c",
    "mailto:a b@example.com", "mailto:a:b/c d", "urn:a:b c", "tel:+1 555", "about:blank x",
    "a b", " ", "relative path/ü", "//host/ü", "x/a:b c", "https://a_b.example.com/ü",
    // Hosts: IDNA, IP literal zones, and the schemes whose host is encoded.
    "https://müller.de/straße?q=ä#ü", "https://Müller.DE/", "https://straße.de/", "https://☃.net/",
    "https://日本.jp/", "https://例え.テスト/パス", "https://ｅｘａｍｐｌｅ。日本/", "https://Ｍüller.de/",
    "https://日本.jp./", "https://xn--mller-kva.de/ä", "http://[fe80::1%en0]/", "tel://a b/",
    // Strings macOS gives up on.
    "", "https://exa mple.com/", "https://example.com:80a/", "https://日本..jp/", "a b:c",
    // A leading colon: an empty scheme to URL, a path to URLComponents.
    ":foo", ":foo bar", ":/a b", "://h/a b", ":",
  ]

  func testTheFallbackRewritesAsTheRunningMacOSParses() throws {
    guard #available(macOS 14.0, *) else {
      throw XCTSkip("needs the macOS 14 parser to compare against")
    }
    for string in Self.corpus {
      let expected = URL(string: string)?.absoluteString
      let repaired = URLParsing.repaired(string, allowingEmptyScheme: true)
      let parsed = repaired.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
      XCTAssertEqual(
        parsed?.absoluteString, expected, "\(string.debugDescription) → \(repaired ?? "nil")")
      if let repaired, expected != nil {
        XCTAssertTrue(repaired.utf8.allSatisfy { $0 < 0x80 }, "\(repaired) is ASCII")
      }
      let relative = URLParsing.repaired(string, allowingEmptyScheme: false)
      let components = relative.flatMap {
        URLComponents(string: $0, encodingInvalidCharacters: false)
      }
      XCTAssertEqual(
        components?.string, URLComponents(string: string)?.string,
        "\(string.debugDescription) → \(relative ?? "nil")")
    }
  }

  func testValidStringsAreUntouched() {
    for string in ["https://example.com/a%20b?q=1#top", "mailto:a:b", "https://[::1]:8080/x"] {
      XCTAssertEqual(URLParsing.repaired(string, allowingEmptyScheme: true), string)
    }
  }

  /// RFC 3492's own samples, and the labels the corpus relies on.
  func testPunycodeEncodesLabels() {
    let samples = [
      "müller": "mller-kva", "日本": "wgv71a", "☃": "n3h",
      "例え": "r8jz45g", "テスト": "zckzah", "straße": "strae-oqa",
      "ليهمابتكلموشعربي؟": "egbpdaj6bu4bxfgehfvwxn",
      "他们为什么不说中文": "ihqwcrb4cv8a8dqg056pqjye",
    ]
    for (label, expected) in samples {
      XCTAssertEqual(URLParsing.punycode(Array(label.unicodeScalars)), expected, label)
    }
  }

  /// Every supported macOS reads the same URL: macOS 14 and later through
  /// their own parser, macOS 13 through the repair.
  func testParsingMatchesTheSystemParserFromMacOS14() {
    for string in Self.corpus {
      XCTAssertEqual(URLParsing.url(string), URL(string: string), string.debugDescription)
      XCTAssertEqual(
        URLParsing.components(string)?.string, URLComponents(string: string)?.string,
        string.debugDescription)
    }
  }
}

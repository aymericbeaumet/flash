import Foundation
import XCTest

@testable import flash

/// Every log line is `[area] event` (docs/observability.md). The area is one
/// snake_case word, one word wherever one names it: the command topic
/// (`window`, `app`), the hint surface (`screens`, `dock`) or the subsystem
/// (`tap`, `poll`) the line belongs to. The set below is the whole
/// vocabulary; a new area joins it and the manual's table together.
final class LogAreaTests: XCTestCase {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static let areas: Set<String> = [
    "about", "activation", "app", "apple", "autolaunch", "ax", "bigram", "button",
    "calendar", "capture", "click", "clipboard", "command", "commit", "config", "confirm",
    "cursor", "debug", "discover", "dock", "doctor", "drag", "events", "files", "flashlight",
    "focus", "frecency", "gesture", "history", "input", "ipc", "keyboard", "latency",
    "macro", "mappings", "marks", "menu", "menubar", "menus", "missioncontrol", "mode",
    "monitors", "move", "movement", "multi", "navigation", "normal", "notifications", "notify",
    "overlay", "placement", "plugin", "plugins", "pointer", "poll", "popup", "positions",
    "query", "repeat", "resident", "screen", "screens", "scroll", "search", "source",
    "startup", "statusbar", "step", "surfaces", "switcher", "system", "tap", "telemetry", "text",
    "tiling",
    "trace", "updates", "url", "visual", "warp", "watchdog", "widgets", "window", "words",
  ]

  /// A lowercase ASCII letter, then lowercase letters, digits and `_`.
  static func isSnakeCaseWord(_ word: String) -> Bool {
    guard let first = word.utf8.first, (97...122).contains(first) else { return false }
    return word.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
  }

  /// Every `"[area] ` literal under `directory`, by file, plus the areas
  /// `SystemSurfaceHints` passes to its shared presenter (`area: "dock"`).
  static func literalAreas(under directory: String, suffix: String) throws -> [String: Set<String>]
  {
    let tag = try NSRegularExpression(pattern: #""\[([^\]"\\]+)\] "#)
    let parameter = try NSRegularExpression(pattern: #"area: "([a-z][a-zA-Z0-9_-]*)""#)
    let base = root.appendingPathComponent(directory)
    let files = try XCTUnwrap(
      FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
    var found: [String: Set<String>] = [:]
    for case let url as URL in files where url.pathExtension == suffix {
      let path = url.path
      guard !path.contains("/target/"), !path.contains("/.build/") else { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      let range = NSRange(text.startIndex..., in: text)
      var patterns = [tag]
      if url.lastPathComponent == "SystemSurfaceHints.swift" { patterns.append(parameter) }
      for pattern in patterns {
        for match in pattern.matches(in: text, range: range) {
          guard let area = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else {
            continue
          }
          found[area, default: []].insert(String(path.dropFirst(root.path.count + 1)))
        }
      }
    }
    return found
  }

  func testEveryHostLogLineNamesAnAreaOfTheSet() throws {
    let found = try Self.literalAreas(under: "Sources", suffix: "swift")
    for (area, files) in found {
      XCTAssertTrue(
        Self.isSnakeCaseWord(area), "[\(area)] is not a snake_case word: \(files.sorted())")
    }
    let unlisted = Set(found.keys).subtracting(Self.areas)
    XCTAssertTrue(
      unlisted.isEmpty,
      "unlisted areas: \(unlisted.sorted().map { "\($0) in \(found[$0]!.sorted())" })")
    let unused = Self.areas.subtracting(found.keys)
    XCTAssertTrue(unused.isEmpty, "areas no line uses: \(unused.sorted())")
  }

  /// The lines of `text` where a literal log message opens with something
  /// other than `[`: a direct level call, `FlashLog.log(level, "…")` or
  /// `FlashLog.plugin(…, message: "…")`. A message built at run time is not a
  /// literal and is not judged here.
  static func unnamedLiteralMessages(in text: String) throws -> [Int] {
    let patterns = try [
      #"FlashLog\.(?:trace|debug|info|warn|error)\(\s*"(?!\[)"#,
      #"FlashLog\.log\(\s*[^,()]+,\s*"(?!\[)"#,
      #"FlashLog\.plugin\([^"]{0,200}?message:\s*"(?!\[)"#,
    ].map { try NSRegularExpression(pattern: $0) }
    let range = NSRange(text.startIndex..., in: text)
    var lines: [Int] = []
    for pattern in patterns {
      for match in pattern.matches(in: text, range: range) {
        guard let start = Range(match.range, in: text)?.lowerBound else { continue }
        lines.append(text[..<start].utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 })
      }
    }
    return lines.sorted()
  }

  func testALiteralMessageWithoutAnAreaIsFound() throws {
    let source = """
      FlashLog.info("[tap] installed")
      FlashLog.warn("tap failed")
      FlashLog.log(level, "[poll] tick")
      FlashLog.log(.debug, "tick")
      FlashLog.plugin(
        id, level: .info,
        message: "started")
      FlashLog.plugin(id, level: .info, message: "[plugin] started")
      FlashLog.error(message)
      """
    XCTAssertEqual(try Self.unnamedLiteralMessages(in: source), [2, 4, 5])
  }

  /// Every literal message in the resident's sources is `[area] event`.
  func testEveryLiteralLogMessageStartsWithAnArea() throws {
    var unnamed: [String] = []
    var scanned = 0
    for directory in ["flash", "FlashCore", "FlashProviders", "FlashTerminal"] {
      let base = Self.root.appendingPathComponent("Sources").appendingPathComponent(directory)
      let files = try XCTUnwrap(
        FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
      for case let url as URL in files where url.pathExtension == "swift" {
        scanned += 1
        let text = try String(contentsOf: url, encoding: .utf8)
        let path = url.path.dropFirst(Self.root.path.count + 1)
        unnamed += try Self.unnamedLiteralMessages(in: text).map { "\(path):\($0)" }
      }
    }
    XCTAssertGreaterThan(scanned, 300)
    XCTAssertEqual(unnamed, [], "log messages are named [area] event")
  }

  func testEveryPluginLogLineNamesASnakeCaseArea() throws {
    let found = try Self.literalAreas(under: "Plugins", suffix: "rs")
    XCTAssertFalse(found.isEmpty)
    for (area, files) in found {
      XCTAssertTrue(
        Self.isSnakeCaseWord(area), "[\(area)] is not a snake_case word: \(files.sorted())")
    }
  }

  /// `docs/observability.md`'s areas table lists the set, by family.
  func testTheManualListsEveryArea() throws {
    let manual = try String(
      contentsOf: Self.root.appendingPathComponent("docs/observability.md"), encoding: .utf8)
    let start = try XCTUnwrap(manual.range(of: "\n## Areas\n"))
    let rest = manual[start.upperBound...]
    let section = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
    let word = try NSRegularExpression(pattern: #"`([a-z0-9_]+)`"#)
    var listed: [String] = []
    for line in section.split(separator: "\n") where line.hasPrefix("| ") {
      let cells = line.split(separator: "|", omittingEmptySubsequences: false)
      guard cells.count >= 3, !cells[2].contains("---"), !cells[2].contains("Areas") else {
        continue
      }
      let text = String(cells[2])
      for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) { listed.append(String(text[range])) }
      }
    }
    XCTAssertEqual(listed.count, Set(listed).count, "an area is listed once")
    XCTAssertEqual(Set(listed), Self.areas)
  }
}

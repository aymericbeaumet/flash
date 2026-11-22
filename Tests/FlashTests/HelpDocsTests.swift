import XCTest

@testable import flash

final class HelpDocsTests: XCTestCase {
  /// `routes.json` names every page path and alias the bundled manual
  /// routes; the manual's home has no name of its own beyond its aliases.
  func testManualNamesComeFromTheBundledRoutes() throws {
    let routes = Data(
      #"{"pages":[{"path":"","aliases":["overview"]},{"path":"configuration","aliases":["config"]},{"path":"alternatives/neru","aliases":[]}]}"#
        .utf8)
    XCTAssertEqual(
      HelpDocs.manualNames(routes: routes),
      ["overview", "configuration", "config", "alternatives/neru"])
    XCTAssertEqual(HelpDocs.manualNames(routes: Data("{}".utf8)), [])
    XCTAssertEqual(HelpDocs.manualNames(root: nil), [])

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-routes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try routes.write(to: root.appendingPathComponent("routes.json"))
    XCTAssertEqual(HelpDocs.manualNames(root: root).count, 4)
  }

  /// A plugin topic cannot take a name the manual routes (a page path or one
  /// of its aliases), and the first plugin to claim a name keeps it.
  func testPluginTopicsCannotClaimAManualNameOrAnotherTopic() {
    let first = HelpTopic(
      name: "sample", title: "Sample", summary: "Example plugin", body: "# Sample")
    let conflicting = [
      HelpTopic(name: "Configuration", title: "Shadow", summary: "", body: ""),
      HelpTopic(name: "config", title: "Alias", summary: "", body: ""),
      HelpTopic(name: " SAMPLE ", title: "Second", summary: "", body: ""),
    ]
    let captures = HelpTopic(name: "captures", title: "Captures", summary: "", body: "")
    let topics = HelpDocs.pluginTopics(
      [captures, first] + conflicting, reserved: ["configuration", "config"])
    XCTAssertEqual(topics.map(\.name), ["captures", "sample"])
  }

  /// The bundled plugins' topics keep names the manual does not route, so
  /// `:help screenshot` and the others still reach them; the manual itself
  /// routes the core pages and their short names (`:help mark`).
  func testBundledPluginTopicsDoNotCollideWithTheManual() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let navigation = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: repository.appendingPathComponent("docs/nav.json")))
        as? [String: Any])
    var names = Set<String>()
    func collect(_ items: [[String: Any]]) {
      for item in items {
        if let children = item["items"] as? [[String: Any]] { collect(children) }
        if let page = item["page"] as? String {
          names.insert(page.replacingOccurrences(of: ".md", with: ""))
        }
        names.formUnion(item["aliases"] as? [String] ?? [])
      }
    }
    collect(try XCTUnwrap(navigation["nav"] as? [[String: Any]]))
    XCTAssertTrue(names.isSuperset(of: ["config", "hints", "grid", "status-bar", "marks", "mark"]))
    let plugins = try FileManager.default.contentsOfDirectory(
      at: repository.appendingPathComponent("Plugins"), includingPropertiesForKeys: nil)
    var topics = 0
    for plugin in plugins {
      let manifest = plugin.appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: manifest),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let help = object["help"] as? [String: Any],
        let entries = help["topics"] as? [[String: Any]]
      else { continue }
      for entry in entries {
        let topic = try XCTUnwrap(entry["name"] as? String)
        topics += 1
        XCTAssertFalse(names.contains(topic), "\(plugin.lastPathComponent) topic \(topic)")
      }
    }
    XCTAssertGreaterThan(topics, 0)
  }
}

import XCTest

@testable import flash

final class HelpDocsTests: XCTestCase {
  func testRepositoryReferencesFollowTheInstalledSourceRevision() {
    let revision = String(repeating: "a", count: 40)
    XCTAssertEqual(
      HelpDocs.repositoryRoot(revision: revision),
      "https://github.com/aymericbeaumet/flash/blob/" + revision)
    for revision in [nil, "unknown", "main", "../invalid"] {
      XCTAssertEqual(
        HelpDocs.repositoryRoot(revision: revision),
        "https://github.com/aymericbeaumet/flash/blob/HEAD")
    }
  }

  func testCoreWorkflowsHaveResolvableTopics() {
    let topics = HelpDocs.allTopics(config: .default, showModes: true)
    let expected: Set<String> = [
      "overview", "getting-started", "hints", "mouse-grid", "mappings", "normal-mode",
      "flashlight", "verbs", "config", "statusbar", "status-format", "widgets", "popups",
      "plugins", "privacy", "troubleshooting", "development",
    ]
    XCTAssertTrue(expected.isSubset(of: Set(topics.map(\.name))))

    let names = topics.flatMap { [$0.name] + $0.aliases }.map { $0.lowercased() }
    XCTAssertEqual(names.count, Set(names).count, "Every name must identify exactly one topic")
    for topic in topics {
      for name in [topic.name] + topic.aliases {
        XCTAssertEqual(
          HelpDocs.render(topic: " \(name.uppercased()) ", config: .default, showModes: true),
          topic.body.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
  }

  /// The sidebar, index and previous/next links follow `HelpDocs.groups`;
  /// a built-in topic outside it would fall to the end unnoticed.
  func testEveryBuiltInTopicHasAGroupInReadingOrder() {
    let topics = HelpDocs.allTopics(config: .default, showModes: true)
    let ordered = HelpDocs.groups.flatMap(\.names)
    XCTAssertEqual(topics.map(\.name), ordered, "built-in topics follow the group table")
    for topic in topics {
      XCTAssertNotEqual(topic.group, HelpDocs.pluginGroup, "\(topic.name) needs a built-in group")
      XCTAssertNotNil(topic.manual, "\(topic.name) names its manual page")
    }
    let plugin = HelpTopic(name: "zzz", title: "Z", summary: "", body: "# Z")
    let withPlugin = HelpDocs.allTopics(config: .default, showModes: true, pluginTopics: [plugin])
    XCTAssertEqual(withPlugin.last?.name, "zzz")
    XCTAssertEqual(withPlugin.last?.group, HelpDocs.pluginGroup)
  }

  /// Guides link to browser help pages by path; fragments are reserved for
  /// headings on the same page.
  func testTopicLinksResolveWithinTheInstalledBuiltInInventory() throws {
    let topics = HelpDocs.allTopics(config: .default, showModes: true)
    let names = Set(topics.flatMap { [$0.name] + $0.aliases })
    let expression = try NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
    var guideLinks = 0
    for topic in topics {
      let body = topic.body as NSString
      for match in expression.matches(
        in: topic.body, range: NSRange(location: 0, length: body.length))
      {
        let destination = body.substring(with: match.range(at: 1))
        if destination.hasPrefix("https://") { continue }
        XCTAssertTrue(
          destination.hasPrefix("/"), "\(topic.name) links to \(destination) instead of a page")
        let path = String(destination.prefix { $0 != "#" && $0 != "?" })
        let page = DebugServer.Page(path: path)
        XCTAssertNotNil(page, "\(topic.name) links to unknown page \(destination)")
        if case .docs(let name?) = page {
          guideLinks += 1
          XCTAssertTrue(names.contains(name), "\(topic.name) links to missing \(name)")
        }
      }
    }
    XCTAssertGreaterThan(guideLinks, 0)
  }

  func testPluginTopicsCannotClaimAnExistingNameOrAlias() {
    let first = HelpTopic(
      name: "sample", title: "Sample", summary: "Example plugin", body: "# Sample",
      aliases: ["sample-alias"])
    let conflicting = [
      HelpTopic(name: "configuration", title: "Shadow", summary: "", body: ""),
      HelpTopic(name: "second", title: "Second", summary: "", body: "", aliases: ["SAMPLE"]),
      HelpTopic(name: "sample-alias", title: "Third", summary: "", body: ""),
    ]
    let topics = HelpDocs.allTopics(
      config: .default, showModes: true, pluginTopics: [first] + conflicting)
    XCTAssertEqual(topics.filter { $0.name == "sample" }, [first])
    XCTAssertFalse(
      topics.contains { ["configuration", "second", "sample-alias"].contains($0.name) })
  }
}

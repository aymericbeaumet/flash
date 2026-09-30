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

  func testTopicLinksResolveWithinTheInstalledBuiltInInventory() throws {
    let topics = HelpDocs.allTopics(config: .default, showModes: true)
    let names = Set(topics.flatMap { [$0.name] + $0.aliases })
    let expression = try NSRegularExpression(pattern: #"\]\(#docs/([a-z0-9-]+)\)"#)
    for topic in topics {
      let body = topic.body as NSString
      for match in expression.matches(
        in: topic.body, range: NSRange(location: 0, length: body.length))
      {
        let destination = body.substring(with: match.range(at: 1))
        XCTAssertTrue(names.contains(destination), "\(topic.name) links to missing \(destination)")
      }
    }
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

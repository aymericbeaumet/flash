import Foundation

struct HelpTopic: Equatable {
  var name: String
  var title: String
  var summary: String
  var body: String
}

enum HelpDocs {
  static func render(topic rawTopic: String?, config: Config, showModes: Bool) -> String {
    let topics = allTopics(config: config, showModes: showModes)
    guard let rawTopic,
      !rawTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return index(topics)
    }
    let name = normalize(rawTopic)
    guard let topic = topics.first(where: { normalize($0.name) == name }) else {
      return unknownTopic(name, topics: topics)
    }
    return render(topic)
  }

  static func allTopics(config: Config, showModes: Bool) -> [HelpTopic] {
    [
      overviewTopic,
      NormalModeDispatcher.helpTopic(config: config, showModes: showModes),
      URLEventHandler.helpTopic,
      Config.helpTopic,
      PluginManager.helpTopic,
    ].sorted { $0.name < $1.name }
  }

  private static let overviewTopic = HelpTopic(
    name: "overview",
    title: "Flash Help",
    summary: "How to read Flash help topics.",
    body: """
      # Flash Help

      `:help` opens the topic index.
      `:help <topic>` opens a specific topic, for example `:help plugins`.

      Help topics are Markdown text rendered in the Flash modal. The runtime
      docs are kept in Swift source files next to the feature code they
      describe, so command behavior and help text can change together.
      """)

  private static func index(_ topics: [HelpTopic]) -> String {
    var lines = [
      "# Flash Help",
      "",
      "Use `:help <topic>` to open one of these topics.",
      "",
    ]
    for topic in topics {
      lines.append("- `\(topic.name)` - \(topic.summary)")
    }
    return lines.joined(separator: "\n")
  }

  private static func render(_ topic: HelpTopic) -> String {
    topic.body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func unknownTopic(_ name: String, topics: [HelpTopic]) -> String {
    var lines = [
      "# Unknown Help Topic",
      "",
      "No help topic named `\(name)`.",
      "",
      "Available topics:",
      "",
    ]
    for topic in topics {
      lines.append("- `\(topic.name)`")
    }
    return lines.joined(separator: "\n")
  }

  private static func normalize(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

import Foundation

extension URLEventHandler {
  /// What a topic's commands are for. The browser help groups and colours a
  /// binding by its command's topic; a plugin's command and a program have
  /// categories of their own there.
  enum TopicCategory: String, CaseIterable {
    case pointer, scroll, tabs, windows, modes, system, other
  }

  /// Every topic Flash owns, under its category. This is the one table:
  /// `mise run build:schema` writes it to
  /// `Inspector/src/lib/topic-categories.json`, which the help's mapping
  /// pages read, and `testInspectorTopicTableMatchesTheTopics` fails while a
  /// topic has no category here or the committed copy is stale.
  static let topicsByCategory: [(category: TopicCategory, topics: [String])] = [
    (.pointer, ["mouse", "hints", "selection"]),
    (.scroll, ["scroll", "move", "cursor"]),
    (
      .tabs,
      ["tab", "app", "mark", "history", "movement", "pane", "resource", "document", "url"]
    ),
    (.windows, ["window", "tile", "workspace", "desktop", "missioncontrol", "appwindows"]),
    (
      .modes,
      [
        "mode", "macro", "popup", "help", "mappings", "plugins", "monitors", "telemetry",
        "logs", "commands", "input",
      ]
    ),
    (
      .system,
      ["key", "launchpad", "notificationcenter", "controlcenter", "process"]
    ),
    (
      .other,
      [
        "updates", "status", "menu", "about", "alert", "notify", "metrics", "clipboard",
        "register", "notes", "reminders", "contacts", "calendar", "resident", "config",
        "startup", "cli", "events",
      ]
    ),
  ]

  /// The category of each topic.
  static let topicCategories: [String: TopicCategory] = Dictionary(
    topicsByCategory.flatMap { entry in entry.topics.map { ($0, entry.category) } },
    uniquingKeysWith: { first, _ in first })
}

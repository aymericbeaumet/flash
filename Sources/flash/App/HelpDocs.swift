import Foundation

/// One help topic a plugin manifest contributes (`help.topics[]`). The
/// browser help renders it at `/docs/<name>` when no manual page or alias
/// takes that name; everything else Flash documents is the manual.
struct HelpTopic: Equatable {
  var name: String
  var title: String
  var summary: String
  var body: String
}

/// The manual is `docs/*.md`, ordered by `docs/nav.json` and bundled with
/// the app (`Contents/Resources/docs`); the browser help renders it at
/// `/docs/<page>` and the published site at the same path. `:help <topic>`
/// opens `/docs/<topic>`, where a page's path or one of its aliases names it.
enum HelpDocs {
  /// The names the bundled manual routes, from the build's `routes.json`:
  /// every page path and alias, for `:help` completion and to reserve them
  /// from plugin topics. Read once at launch; empty outside an app bundle.
  static func manualNames(root: URL?) -> [String] {
    guard let root,
      let data = try? Data(contentsOf: root.appendingPathComponent("routes.json"))
    else { return [] }
    return manualNames(routes: data)
  }

  static func manualNames(routes data: Data) -> [String] {
    struct Routes: Decodable {
      struct Page: Decodable {
        var path: String
        var aliases: [String]
      }
      var pages: [Page]
    }
    guard let routes = try? JSONDecoder().decode(Routes.self, from: data) else { return [] }
    return routes.pages.flatMap { page in
      (page.path.isEmpty ? [] : [page.path]) + page.aliases
    }
  }

  /// Plugin topics the help can show: a name the manual routes (a page path
  /// or one of its aliases) stays the manual's, and the first plugin topic
  /// to claim any other name owns it.
  static func pluginTopics(_ topics: [HelpTopic], reserved manual: [String]) -> [HelpTopic] {
    var claimed = Set(manual.map(normalize))
    var accepted: [HelpTopic] = []
    for topic in topics where claimed.insert(normalize(topic.name)).inserted {
      accepted.append(topic)
    }
    return accepted.sorted { $0.name < $1.name }
  }

  private static func normalize(_ value: String) -> String {
    value.trimmed.lowercased()
  }
}

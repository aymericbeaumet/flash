import FlashCore
import Foundation
import XCTest

@testable import flash

/// The query tokens plugins stand in for (manifest `query_aliases`): the host
/// knows no emoticon of its own.
final class QueryAliasesTests: XCTestCase {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func load(_ aliases: String, exec: Bool = false) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-query-aliases-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try """
    {
      "id": "sample", "name": "Sample", "version": "1.0.0", "description": "fixture",
      \(exec ? #""exec": ["/usr/bin/true"], "sandbox": false, "status": ["state"],"# : "")
      "query_aliases": \(aliases)
    }
    """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }

  private func failure(_ aliases: String) -> String {
    do {
      _ = try load(aliases)
      return ""
    } catch {
      return String(describing: error)
    }
  }

  private let faces = QueryAliasTable([
    ":)": "slightly_smiling_face", ":d": "grinning", "<3": "heart",
  ])

  func testATokenIsReplacedByItsWordsWhateverItsCase() {
    XCTAssertEqual(faces.expand(":)"), "slightly_smiling_face")
    XCTAssertEqual(faces.expand(":D"), "grinning")
    XCTAssertEqual(faces.expand(":d"), "grinning")
    // Only the token is rewritten in a mixed query.
    XCTAssertEqual(faces.expand("happy :)  <3"), "happy slightly_smiling_face heart")
    // A query without one is returned as written, spacing included.
    for query in ["fire", "slack  general", "foo:bar", ":)x", ""] {
      XCTAssertEqual(faces.expand(query), query)
    }
    XCTAssertEqual(QueryAliasTable().expand(":)"), ":)", "no plugin declares the token")
  }

  func testATokenAnEarlierPluginDeclaredKeepsItsWords() {
    var table = faces
    table.merge(QueryAliasTable([":)": "smile", ";)": "wink"]))
    XCTAssertEqual(table.expand(":) ;)"), "slightly_smiling_face wink")
  }

  /// A manifest declares them with or without a process to run.
  func testAManifestDeclaresItsQueryAliases() throws {
    for exec in [false, true] {
      XCTAssertEqual(
        try load(#"{":)": "slightly_smiling_face", "<3": "heart"}"#, exec: exec).queryAliases,
        QueryAliasTable([":)": "slightly_smiling_face", "<3": "heart"]))
    }
  }

  /// A token carries punctuation, so no plugin rewrites a word the flashlight
  /// already scores, and its words are ones a row can be indexed under.
  func testAMalformedAliasFailsTheLoad() {
    for (aliases, message) in [
      (#"{"xd": "laughing"}"#, #"query_aliases: "xd" is not a token"#),
      (#"{":D": "grinning"}"#, #"query_aliases: ":D" is not a token"#),
      (#"{": )": "smile"}"#, #"query_aliases: ": )" is not a token"#),
      (#"{"": "smile"}"#, #"query_aliases: "" is not a token"#),
      (#"{":-)-:-)-:-)-:-)-:": "smile"}"#, "is not a token"),
      (#"{":)": ""}"#, "query_aliases.:): words are lowercase letters, digits and _"),
      (#"{":)": "Smile"}"#, "query_aliases.:): words are lowercase letters, digits and _"),
      (#"{":)": "big smile"}"#, "query_aliases.:): words are lowercase letters, digits and _"),
      (#"{":)": 1}"#, "query_aliases"),
      (#"[":)"]"#, "query_aliases"),
    ] {
      let error = failure(aliases)
      XCTAssertTrue(error.contains(message), "\(aliases): \(error)")
    }
    let many = (0...PluginManifest.maxQueryAliases).map { #"":\#($0)": "x""# }
    XCTAssertTrue(
      failure("{\(many.joined(separator: ","))}").contains(
        "query_aliases declares more than \(PluginManifest.maxQueryAliases) tokens"))
  }

  /// The emoticons are the `emojis` plugin's, and the faces people type find
  /// their emoji through its shortcodes.
  func testTheEmojisPluginDeclaresTheEmoticons() throws {
    let table = try PluginManifest.load(
      from: Self.repository.appendingPathComponent("Plugins/emojis")
    ).queryAliases
    for (emoticon, words) in [
      (":)", "slightly_smiling_face"), (":-)", "slightly_smiling_face"),
      (":(", "slightly_frowning_face"), (":-(", "slightly_frowning_face"),
      (";)", "wink"), (";-)", "wink"), (":D", "grinning"), ("X-D", "laughing"), ("<3", "heart"),
    ] {
      XCTAssertEqual(table.expand(emoticon), words, emoticon)
    }
    // Ordinary words stay themselves: an app named XD is searched by name.
    XCTAssertEqual(table.expand("xd"), "xd")
    XCTAssertEqual(table.expand("xp"), "xp")

    let plugins = Self.repository.appendingPathComponent("Plugins")
    for root in try FileManager.default.contentsOfDirectory(
      at: plugins, includingPropertiesForKeys: nil)
    where root.lastPathComponent != "emojis"
      && FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
      && !root.lastPathComponent.hasPrefix("_")
    {
      XCTAssertTrue(
        try PluginManifest.load(from: root).queryAliases.isEmpty, root.lastPathComponent)
    }
  }

  func testTheDeclaredTableIsReplacedWhole() {
    let previous = QueryAliases.declared.table
    defer { QueryAliases.declared.declare(previous) }
    QueryAliases.declared.declare(QueryAliasTable([":)": "smile"]))
    XCTAssertEqual(QueryAliases.declared.table.expand(":)"), "smile")
    QueryAliases.declared.declare(QueryAliasTable(["<3": "heart"]))
    XCTAssertEqual(QueryAliases.declared.table.expand(":)"), ":)")
  }
}

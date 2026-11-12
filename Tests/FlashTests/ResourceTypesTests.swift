import FlashCore
import Foundation
import XCTest

@testable import flash

/// The flashlight's resource types: one word each, declared by every source,
/// checked when a plugin loads, and pinned in `protocol.json` with the SDK.
final class ResourceTypesTests: XCTestCase {
  func testATypeIsOneLowercaseWord() {
    for valid in ["tabs", "history", "emojis", "x11", "a"] {
      XCTAssertTrue(ResourceTypes.isValidName(valid), valid)
    }
    for invalid in ["", "emojis.glyphs", "Tabs", "1tabs", "my-tabs", "my_tabs", "tabs "] {
      XCTAssertFalse(ResourceTypes.isValidName(invalid), invalid)
    }
  }

  func testAPluginSourceFollowsItsTypesContract() {
    XCTAssertNil(ResourceTypes.pluginRejection(type: "tabs", kind: .locations))
    XCTAssertNil(ResourceTypes.pluginRejection(type: "history", kind: .standard))
    XCTAssertNil(ResourceTypes.pluginRejection(type: "recipes", kind: .standard), "a new type")
    XCTAssertEqual(
      ResourceTypes.pluginRejection(type: "", kind: .standard),
      "has no type (one lowercase word such as tabs)")
    XCTAssertTrue(
      ResourceTypes.pluginRejection(type: "emojis.glyphs", kind: .standard)?
        .contains("not one lowercase word") == true)
    XCTAssertTrue(
      ResourceTypes.pluginRejection(type: "apps", kind: .locations)?
        .contains("fed by Flash itself") == true)
    XCTAssertEqual(
      ResourceTypes.pluginRejection(type: "tabs", kind: .standard),
      "type tabs is a locations type; this source is default")
  }

  func testAProviderIsTheAppOrPluginFeedingASource() {
    XCTAssertEqual(ResourceTypes.provider(of: "firefox.tabs", type: "tabs"), "firefox")
    XCTAssertEqual(ResourceTypes.provider(of: "tmux.windows", type: "terminals"), "tmux")
    XCTAssertEqual(
      ResourceTypes.provider(of: "searchproviders.bangs", type: "bangs"), "searchproviders")
    XCTAssertNil(ResourceTypes.provider(of: "core.apps", type: "apps"))
    XCTAssertNil(ResourceTypes.provider(of: "files.results", type: "files"))
    XCTAssertNil(ResourceTypes.provider(of: "clipboard.pinned", type: "clipboard"))
    XCTAssertEqual(ResourceTypes.qualifier(of: "Firefox.Tabs", type: "tabs"), "firefox")
    XCTAssertEqual(ResourceTypes.qualifier(of: "clipboard.pinned", type: "clipboard"), "pinned")
    XCTAssertNil(ResourceTypes.qualifier(of: "windows.windows", type: "windows"))
  }

  /// A row reads `[tabs] title · url`, the word `@tabs` filters by, with its
  /// browser dimmed after it only when several sources feed tabs.
  func testARowIsLabelledWithItsTypeAndItsProviderWhenTheTypeHasSeveral() {
    let labels = ResourceTypeLabels(types: [
      "firefox.tabs": "tabs", "chrome.tabs": "tabs", "tmux.windows": "terminals",
      "core.apps": "apps", "clipboard.pinned": "clipboard", "clipboard.history": "clipboard",
    ])
    func row(_ source: String, kind: CandidateKind = .plugin("row")) -> Candidate {
      CandidateFinder.prepare(Candidate(kind: kind, sourceID: source, source: source, title: "x"))
    }
    func label(_ candidate: Candidate) -> String {
      let (title, detail) = labels.label(candidate, displayTitle: candidate.displayTitle)
      return detail.map { "\(title) | \($0)" } ?? title
    }
    XCTAssertEqual(label(row("firefox.tabs")), "[tabs] x | firefox")
    XCTAssertEqual(label(row("tmux.windows")), "[terminals] x", "the only terminals source")
    XCTAssertEqual(label(row("core.apps", kind: .app)), "[apps] x")
    XCTAssertEqual(label(row("clipboard.pinned")), "[clipboard] x | pinned")
    XCTAssertEqual(label(row("someone.else")), "[someone.else] x", "an untyped source")
    XCTAssertEqual(
      label(
        CandidateFinder.prepare(
          CandidateFinder.sourceCompletionCandidate(type: "tabs", providers: ["chrome", "firefox"]))
      ),
      "[type] @tabs | chrome, firefox")
  }

  func testADottedSourceNameSuggestsTheTypeItMeant() {
    XCTAssertEqual(ResourceTypes.suggestion(for: "emojis.glyphs"), "emojis")
    XCTAssertEqual(ResourceTypes.suggestion(for: "firefox.tabs"), "tabs")
    XCTAssertEqual(ResourceTypes.suggestion(for: "clipboard.history"), "clipboard")
    XCTAssertEqual(ResourceTypes.suggestion(for: "chrome.bookmarks"), "bookmarks")
    XCTAssertEqual(
      ResourceTypes.suggestion(for: "tmux.windows"), "terminals",
      "tmux merged into terminals: its windows are terminal sessions")
    XCTAssertNil(ResourceTypes.suggestion(for: "tabs"), "already a word")
    XCTAssertNil(ResourceTypes.suggestion(for: "foo.bar"))
    XCTAssertEqual(ResourceTypes.firstInvalidToken(in: "@tabs gmail"), nil)
    XCTAssertEqual(ResourceTypes.firstInvalidToken(in: "x @Emojis @notes.notes"), "notes.notes")
    XCTAssertNil(ResourceTypes.firstInvalidToken(in: "mail @ home"), "a bare @ is text")
  }

  /// Plugins may introduce a type; those that share a new one agree on its
  /// kind, or every one of them fails, whatever the load order.
  func testPluginsDecliningToAgreeOnANewTypeAllFailToLoad() throws {
    let agreeing = [
      try manifest(id: "one", sources: #"[{ "name": "one.recipes", "type": "recipes" }]"#),
      try manifest(id: "two", sources: #"[{ "name": "two.recipes", "type": "recipes" }]"#),
    ]
    XCTAssertEqual(ResourceTypes.claimFailures(agreeing), [:])
    let disagreeing = [
      try manifest(id: "one", sources: #"[{ "name": "one.recipes", "type": "recipes" }]"#),
      try manifest(
        id: "two",
        sources: #"[{ "name": "two.recipes", "type": "recipes", "kind": "locations" }]"#),
    ]
    let failures = ResourceTypes.claimFailures(disagreeing)
    XCTAssertEqual(Set(failures.keys), ["one", "two"])
    XCTAssertTrue(failures["one"]?.contains("two (locations)") == true, failures["one"] ?? "")
  }

  /// A plugin's manifest is checked when it loads.
  func testAManifestWithAnInvalidTypeFailsToLoad() throws {
    for (sources, expected) in [
      (#"[{ "name": "x.items" }]"#, "plugin source x.items has no type"),
      (#"[{ "name": "x.apps", "type": "apps" }]"#, "fed by Flash itself"),
      (#"[{ "name": "x.tabs", "type": "tabs" }]"#, "is a locations type"),
      (#"[{ "name": "x.items", "type": "x.items" }]"#, "not one lowercase word"),
    ] {
      XCTAssertThrowsError(try manifest(id: "x", sources: sources), sources) { error in
        XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
      }
    }
  }

  /// Every built-in source declares a built-in type, and every bundled
  /// plugin's sources pass the same rules the host applies at load.
  func testBuiltInAndBundledSourcesDeclareValidTypes() throws {
    let core: [FlashSource] = [
      WindowListSource(rows: { ([], nil) }, focus: { _ in }),
      FileSearchSource(), ProcessListSource(read: { [] }, perform: { _ in }), MenuBarSource(),
      SystemActionSource(perform: { _ in }),
      ClipboardFlashlightSource(flashlight: ClipboardFlashlight { [] }),
    ]
    for source in core {
      for descriptor in source.candidateSourceDescriptors {
        XCTAssertEqual(
          ResourceTypes.byName[descriptor.type]?.owner, .core,
          "\(descriptor.name) declares \(descriptor.type)")
        XCTAssertEqual(
          ResourceTypes.byName[descriptor.type]?.kind, descriptor.kind, descriptor.name)
      }
    }
    for catalog in AppleCatalog.allCases {
      XCTAssertEqual(ResourceTypes.byName[catalog.rawValue]?.owner, .core, catalog.rawValue)
    }
    let plugins = Self.root.appendingPathComponent("Plugins")
    var checked = 0
    for entry in try FileManager.default.contentsOfDirectory(atPath: plugins.path).sorted() {
      let root = plugins.appendingPathComponent(entry)
      guard
        FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
      else { continue }
      let manifest = try PluginManifest.load(from: root)
      for source in manifest.sources {
        XCTAssertNil(
          ResourceTypes.pluginRejection(type: source.type, kind: source.kind), source.name)
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 10)
  }

  /// `protocol.json`'s `source_types` is the table the SDK checks manifests
  /// against at build time; the host's must be the same.
  func testTheContractsAreTheProtocolTable() throws {
    let data = try Data(
      contentsOf: Self.root.appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json"))
    let protocolJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let table = try XCTUnwrap(protocolJSON["source_types"] as? [String: Any])
    let core = try XCTUnwrap(table["core"] as? [String])
    let shared = try XCTUnwrap(table["shared"] as? [String: String])
    XCTAssertEqual(table["pattern"] as? String, "^[a-z][a-z0-9]*$")
    XCTAssertEqual(
      core, ResourceTypes.known.filter { $0.owner == .core }.map(\.name))
    XCTAssertEqual(
      shared,
      Dictionary(
        uniqueKeysWithValues: ResourceTypes.known.filter { $0.owner == .shared }.map {
          ($0.name, $0.kind.rawValue)
        }))
  }

  // MARK: Helpers

  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func manifest(id: String, sources: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-resource-types-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    {
      "id": "\(id)",
      "name": "\(id)",
      "version": "1.0.0",
      "description": "fixture",
      "exec": ["/usr/bin/true"],
      "sources": \(sources)
    }
    """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }
}

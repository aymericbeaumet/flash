import FlashCore
import Foundation

/// The flashlight's resource types: the one word `@<type>` narrows a query
/// to (`@tabs`, `@history`, `@emojis`). Every flashlight source, built in or
/// from a plugin, declares exactly one type; `@<type>` lists every source of
/// that type, so `@tabs` reads Safari's, Chrome's and Firefox's tabs alike.
/// Sources keep an internal name (`firefox.tabs`) for routing, ranking and
/// bang bindings, but users only ever type types.
///
/// The rules, checked when a plugin loads:
/// - A type is one lowercase word: a letter, then letters or digits.
/// - A built-in type (`owner == .core`) is fed only by Flash: its rows carry
///   host behaviour (activating an app, pasting a clipboard entry) a plugin
///   cannot provide, so a plugin declaring one fails to load.
/// - A shared type has one contract every source of it follows; a plugin
///   source whose `kind` differs from its contract fails to load.
/// - A plugin may introduce a new type. Every plugin declaring the same new
///   type must agree on its `kind`, or each of them fails to load.
///
/// `known` mirrors `protocol.json`'s `source_types`, which the plugin SDK
/// checks every bundled manifest against at build time.
enum ResourceTypes {
  enum Owner: String, Equatable, Sendable {
    /// Fed by Flash alone.
    case core
    /// Fed by any plugin that follows the contract.
    case shared
  }

  /// One type's contract: who may feed it, the `kind` of every source of it,
  /// and what a row of it is.
  struct Contract: Equatable, Sendable {
    let name: String
    let owner: Owner
    let kind: CandidateSourceKind
    /// What a row of this type is and what selecting it does.
    let rows: String
  }

  static let known: [Contract] = [
    Contract(
      name: "apps", owner: .core, kind: .locations,
      rows: "an installed or running app; selecting it opens or activates it"),
    Contract(
      name: "windows", owner: .core, kind: .standard,
      rows: "a window of a running app; selecting it focuses that window"),
    Contract(
      name: "clipboard", owner: .core, kind: .standard,
      rows: "a clipboard history entry, pinned entry or named register; selecting it pastes it"),
    Contract(
      name: "notes", owner: .core, kind: .standard,
      rows: "a note in Notes; selecting it opens it"),
    Contract(
      name: "reminders", owner: .core, kind: .standard,
      rows: "a reminder in Reminders; selecting it opens it"),
    Contract(
      name: "contacts", owner: .core, kind: .standard,
      rows: "a contact card; selecting it opens it in Contacts"),
    Contract(
      name: "files", owner: .core, kind: .standard,
      rows: "a file found by name through Spotlight; selecting it opens it"),
    Contract(
      name: "processes", owner: .core, kind: .standard,
      rows: "a running process; selecting it offers to quit it"),
    Contract(
      name: "menus", owner: .core, kind: .standard,
      rows: "a menu item of the frontmost app; selecting it presses it"),
    Contract(
      name: "system", owner: .core, kind: .standard,
      rows: "a system action (lock, sleep, restart…); selecting it runs it"),
    Contract(
      name: "tabs", owner: .shared, kind: .locations,
      rows: "an open browser tab, with its URL; selecting it switches to the tab"),
    Contract(
      name: "history", owner: .shared, kind: .standard,
      rows: "a visited page, with its URL; selecting it opens the URL"),
    Contract(
      name: "bookmarks", owner: .shared, kind: .standard,
      rows: "a bookmark, with its URL; selecting it opens the URL"),
    Contract(
      name: "emojis", owner: .shared, kind: .standard,
      rows: "an emoji or symbol in the title; selecting it types it"),
    Contract(
      name: "bangs", owner: .shared, kind: .standard,
      rows: "a `!token` search shortcut; selecting it completes the bang"),
    Contract(
      name: "snippets", owner: .shared, kind: .standard,
      rows: "a text snippet; selecting it types its text"),
    Contract(
      name: "shortcuts", owner: .shared, kind: .standard,
      rows: "a Shortcuts app shortcut; selecting it runs it"),
    Contract(
      name: "terminals", owner: .shared, kind: .locations,
      rows: "a terminal session (a tmux window); selecting it switches to it"),
    Contract(
      name: "network", owner: .shared, kind: .standard,
      rows: "a network address of this Mac; selecting it copies it"),
  ]

  static let byName: [String: Contract] = Dictionary(
    uniqueKeysWithValues: known.map { ($0.name, $0) })

  /// One lowercase word: a letter, then letters or digits.
  static func isValidName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else {
      return false
    }
    return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
  }

  /// Why a plugin source may not declare `type` with `kind`, or nil when it
  /// may.
  static func pluginRejection(type: String, kind: CandidateSourceKind) -> String? {
    guard !type.isEmpty else { return "has no type (one lowercase word such as tabs)" }
    guard isValidName(type) else {
      return "type \(type) is not one lowercase word (a letter, then letters or digits)"
    }
    guard let contract = byName[type] else { return nil }
    if contract.owner == .core {
      return "type \(type) is fed by Flash itself; plugins cannot declare it"
    }
    if contract.kind != kind {
      return "type \(type) is a \(contract.kind.rawValue) type; this source is \(kind.rawValue)"
    }
    return nil
  }

  /// The app or plugin feeding a source of a type, for the `@` completion:
  /// the source's first name part (`firefox.tabs` → `firefox`, `tmux.windows`
  /// → `tmux`). Nil for a part that is the type itself (`files.results`) or
  /// core (`core.apps`).
  static func provider(of source: String, type: String) -> String? {
    guard let first = source.lowercased().split(separator: ".").first.map(String.init),
      first != type.lowercased(), first != "core"
    else { return nil }
    return first
  }

  /// What sets a source apart among the sources of its type, dimmed after a
  /// row: its provider (`firefox`), else the name part beside the type
  /// (`clipboard.pinned` → `pinned`).
  static func qualifier(of source: String, type: String) -> String? {
    if let provider = provider(of: source, type: type) { return provider }
    let rest = source.lowercased().split(separator: ".").dropFirst().map(String.init)
      .filter { $0 != type.lowercased() }
    return rest.isEmpty ? nil : rest.joined(separator: ".")
  }

  /// Plugins merged into another whose sources now have that plugin's type:
  /// `tmux.windows` lists terminal sessions, not app windows. Used only to
  /// suggest a type; the old dotted names stay rejected.
  static let mergedFamilies: [String: String] = ["tmux": "terminals"]

  /// The one-word type a dotted `@source` from before resource types most
  /// likely meant: its merged plugin's type (`tmux.windows` → `terminals`),
  /// else its first part when that is a known type (the source's own family:
  /// `clipboard.history` → `clipboard`, `emojis.glyphs` → `emojis`), else its
  /// last (the kind across apps: `firefox.tabs` → `tabs`).
  static func suggestion(for token: String) -> String? {
    let parts = token.lowercased().split(separator: ".").map(String.init)
    guard parts.count > 1 else { return nil }
    if let merged = mergedFamilies[parts[0]], byName[merged] != nil { return merged }
    return [parts[0], parts[parts.count - 1]].first { byName[$0] != nil }
  }

  /// A located message for an `@<token>` that is no type name, with the type
  /// it most likely meant.
  static func invalidTokenMessage(_ token: String) -> String {
    let base = "@\(token) is not a resource type: types are one lowercase word, such as @tabs"
    guard let suggested = suggestion(for: token) else { return base + "." }
    return base + "; did you mean @\(suggested)?"
  }

  /// The first `@<token>` word of a flashlight query (an alias value, a
  /// `mode flashlight --query=`) that is no type name, or nil. A bare `@`
  /// is text, as the query parser reads it.
  static func firstInvalidToken(in query: String) -> String? {
    for word in query.split(whereSeparator: { $0.isWhitespace }) where word.hasPrefix("@") {
      let token = String(word.dropFirst())
      if !token.isEmpty, !isValidName(token.lowercased()) { return token }
    }
    return nil
  }

  /// Plugins that disagree on the `kind` of a type no contract fixes: every
  /// one declaring it fails, naming the others, so the outcome does not
  /// depend on load order. Keyed by plugin id.
  static func claimFailures(_ manifests: [PluginManifest]) -> [String: String] {
    var kinds: [String: [(plugin: String, kind: CandidateSourceKind)]] = [:]
    for manifest in manifests {
      for source in manifest.sources where byName[source.type] == nil && isValidName(source.type) {
        kinds[source.type, default: []].append((manifest.id, source.kind))
      }
    }
    var failures: [String: String] = [:]
    for (type, claims) in kinds.sorted(by: { $0.key < $1.key }) {
      guard Set(claims.map(\.kind)).count > 1 else { continue }
      let summary = claims.map { "\($0.plugin) (\($0.kind.rawValue))" }.sorted()
        .joined(separator: ", ")
      for claim in claims {
        let message =
          "plugin \(claim.plugin) failed to load: type \(type) is declared with different "
          + "kinds by \(summary)"
        failures[claim.plugin] = failures[claim.plugin].map { $0 + "; " + message } ?? message
      }
    }
    return failures
  }
}

/// What a flashlight query is narrowed to.
enum SourceScope: Hashable, Sendable {
  /// `@<type>`: every source of that resource type.
  case type(String)
  /// A bang bound to one source (`!fh` reads `firefox.history` only).
  case source(String)

  func matches(_ descriptor: CandidateSourceDescriptor) -> Bool {
    switch self {
    case .type(let type): return descriptor.type == type
    case .source(let name): return descriptor.name.lowercased() == name.lowercased()
    }
  }

  /// Whether `candidate`'s rows belong to this scope; `types` maps lowered
  /// source names to their type (`SourceRegistry.resourceTypesBySource`).
  func matches(_ candidate: Candidate, types: [String: String]) -> Bool {
    let source =
      candidate.loweredSource.isEmpty ? candidate.source.lowercased() : candidate.loweredSource
    switch self {
    case .type(let type):
      return types[source] == type || (candidate.kind == .app && type == "apps")
    case .source(let name):
      return source == name.lowercased()
    }
  }

  /// A stable key for caches keyed by the scope.
  var signature: String {
    switch self {
    case .type(let type): return "@" + type
    case .source(let name): return "!" + name.lowercased()
    }
  }
}

/// How flashlight rows are labelled: with their resource type, the word `@`
/// filters by (`[tabs]`, not `[firefox.tabs]`), and with what sets their
/// source apart dimmed after them when several sources feed that type.
struct ResourceTypeLabels {
  /// Lowered source name to resource type (`SourceRegistry.resourceTypesBySource`).
  let types: [String: String]
  private let sourcesPerType: [String: Int]

  init(types: [String: String]) {
    self.types = types
    var counts: [String: Int] = [:]
    for type in types.values { counts[type, default: 0] += 1 }
    sourcesPerType = counts
  }

  /// `displayTitle` (`[<source>] <name>`) relabelled with the row's type, and
  /// the row's dimmed detail. A row of a source with no type keeps its title;
  /// an `@` completion row shows what feeds its type.
  func label(_ candidate: Candidate, displayTitle: String) -> (title: String, detail: String?) {
    if candidate.kind == CandidateFinder.sourceKind {
      return (displayTitle, candidate.subtitle.isEmpty ? nil : candidate.subtitle)
    }
    let source =
      candidate.loweredSource.isEmpty ? candidate.source.lowercased() : candidate.loweredSource
    guard let type = types[source] ?? (candidate.kind == .app ? "apps" : nil) else {
      return (displayTitle, nil)
    }
    let prefix = "[\(candidate.source)] "
    let title =
      displayTitle.hasPrefix(prefix)
      ? "[\(type)] " + displayTitle.dropFirst(prefix.count) : displayTitle
    let detail =
      sourcesPerType[type, default: 0] > 1
      ? ResourceTypes.qualifier(of: candidate.source, type: type) : nil
    return (title, detail)
  }
}

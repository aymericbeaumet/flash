import Foundation

/// Query tokens a plugin's rows are not indexed under, and the words they
/// stand for: an emoticon and its emoji's shortcode. The flashlight keeps
/// only letters and digits of a query before scoring it, so a token of
/// punctuation would otherwise match nothing.
public struct QueryAliasTable: Equatable, Sendable {
  /// Lowercased token → the words scored in its place.
  public private(set) var aliases: [String: String]

  public init(_ aliases: [String: String] = [:]) {
    self.aliases = aliases
  }

  public var isEmpty: Bool { aliases.isEmpty }

  /// Adds the aliases `other` declares; a token already declared keeps its
  /// words.
  public mutating func merge(_ other: QueryAliasTable) {
    aliases.merge(other.aliases) { declared, _ in declared }
  }

  /// `text` with every whitespace-delimited token that is an alias replaced
  /// by its words, whatever its case. A query with none is returned as it
  /// was written, spacing included.
  public func expand(_ text: String) -> String {
    guard !aliases.isEmpty else { return text }
    var changed = false
    let rewritten = text.split(whereSeparator: { $0.isWhitespace }).map { token -> String in
      if let words = aliases[token.lowercased()] {
        changed = true
        return words
      }
      return String(token)
    }
    return changed ? rewritten.joined(separator: " ") : text
  }
}

/// The aliases plugin manifests declare. Each plugin snapshot replaces the
/// table whole; any thread may read it.
public final class DeclaredQueryAliases: @unchecked Sendable {
  private let lock = NSLock()
  private var current = QueryAliasTable()

  public init() {}

  public var table: QueryAliasTable {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  public func declare(_ table: QueryAliasTable) {
    lock.lock()
    current = table
    lock.unlock()
  }
}

/// The query tokens plugins stand in for (manifest `query_aliases`; the
/// bundled `emojis` plugin declares the emoticons). The host knows no
/// emoticon: with no plugin declaring any, a query is scored as written.
public enum QueryAliases {
  public static let declared = DeclaredQueryAliases()
}

import Foundation

/// Pre-parsed attribute filter, mirroring `CompiledAttributeFilter` in the
/// app's `CandidateFinder`. The hot path is a single `case` switch plus a
/// LIKE comparison — every plugin/UI query pays the parse cost exactly
/// once per submission, never per row.
public struct SearchFilter: Equatable, Sendable {
  public enum Field: Equatable, Sendable {
    case source
    case kind
    case title
    case url
    case bundle
    case subtitle
    case collection
    case meta(String)
    /// A field name the caller typed that this engine doesn't expose.
    /// Compiles to a literal `0` so the query yields no rows — same
    /// safe-fail policy as the in-memory matcher.
    case unknown
  }

  public enum Kind: Equatable, Sendable {
    case any        // `*`
    case exact      // `value`
    case prefix     // `value*`
    case suffix     // `*value`
    case contains   // `*value*`
  }

  public var field: Field
  public var kind: Kind
  /// Pattern with leading/trailing `*` removed and lowercased. `any` keeps
  /// `needle == ""`.
  public var needle: String

  public init(field: Field, kind: Kind, needle: String) {
    self.field = field
    self.kind = kind
    self.needle = needle
  }

  /// Parse the same syntax the in-memory matcher accepts. `field` is the
  /// raw text before `:`, `pattern` the raw text after. `meta.<key>` keys
  /// are accepted only when the key matches `[A-Za-z0-9_]+`; an invalid
  /// key falls through to `.unknown` so a typo doesn't smuggle SQL into a
  /// `json_extract` path.
  public static func parse(field rawField: String, pattern rawPattern: String) -> SearchFilter {
    let field = parseField(rawField)
    let lower = rawPattern.lowercased()
    let leading = lower.hasPrefix("*")
    let trailing = lower.hasSuffix("*")
    let stripped = String(lower.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0))
    let kind: Kind
    let needle: String
    switch (leading, trailing) {
    case (true, true) where stripped.isEmpty:
      kind = .any
      needle = ""
    case (true, true):
      kind = .contains
      needle = stripped
    case (true, false):
      kind = .suffix
      needle = stripped
    case (false, true):
      kind = .prefix
      needle = stripped
    case (false, false):
      kind = .exact
      needle = lower
    }
    return SearchFilter(field: field, kind: kind, needle: needle)
  }

  private static func parseField(_ raw: String) -> Field {
    let normalized = raw.lowercased()
    switch normalized {
    case "source": return .source
    case "kind": return .kind
    case "name", "title": return .title
    case "url": return .url
    case "bundle", "bundle_id", "bundleidentifier", "bundleid": return .bundle
    case "subtitle", "description": return .subtitle
    case "collection": return .collection
    default:
      if normalized.hasPrefix("meta.") {
        let key = String(normalized.dropFirst("meta.".count))
        if !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
          return .meta(key)
        }
      }
      return .unknown
    }
  }
}

/// Translate a filter set into a SQL `WHERE` fragment plus its bound
/// values. Group by field, OR inside the group, AND across groups — exact
/// parity with the in-memory `applyAttributeFilters`. Returns `nil` when
/// the filter set has no effect (empty input).
enum SearchFilterCompiler {
  struct Compiled {
    let sql: String
    let arguments: [DatabaseScalar]
  }

  /// Bound arguments. Plain Swift values get bridged through GRDB at the
  /// call site; this lets the compiler stay free of GRDB types and keeps
  /// the unit tests dependency-free.
  enum DatabaseScalar: Equatable {
    case text(String)
    case integer(Int)
    case null
  }

  static func compile(_ filters: [SearchFilter]) -> Compiled? {
    guard !filters.isEmpty else { return nil }
    var byField: [String: [SearchFilter]] = [:]
    var groupOrder: [String] = []
    for filter in filters {
      let key = fieldKey(filter.field)
      if byField[key] == nil { groupOrder.append(key) }
      byField[key, default: []].append(filter)
    }
    var groupFragments: [String] = []
    var arguments: [DatabaseScalar] = []
    for key in groupOrder {
      let group = byField[key] ?? []
      let pieces = group.map { compileOne($0, into: &arguments) }
      if pieces.count == 1 {
        groupFragments.append(pieces[0])
      } else {
        groupFragments.append("(" + pieces.joined(separator: " OR ") + ")")
      }
    }
    return Compiled(sql: groupFragments.joined(separator: " AND "), arguments: arguments)
  }

  /// Stable key for grouping. `meta.foo` and `meta.bar` are separate
  /// groups (a row may satisfy meta filters for multiple distinct keys).
  private static func fieldKey(_ field: SearchFilter.Field) -> String {
    switch field {
    case .source: return "source"
    case .kind: return "kind"
    case .title: return "title"
    case .url: return "url"
    case .bundle: return "bundle"
    case .subtitle: return "subtitle"
    case .collection: return "collection"
    case .meta(let key): return "meta:\(key)"
    case .unknown: return "unknown"
    }
  }

  private static func compileOne(
    _ filter: SearchFilter,
    into arguments: inout [DatabaseScalar]
  ) -> String {
    let column = columnExpression(for: filter.field)
    // `.unknown` already collapses to a no-match constant; emit `0` so
    // the AND short-circuits the whole row, mirroring the in-memory
    // `CompiledAttributeFilter.matches` policy.
    if case .unknown = filter.field { return "0" }
    let nullable = isColumnNullable(filter.field)
    switch filter.kind {
    case .any:
      return nullable ? "\(column) IS NOT NULL" : "1"
    case .exact:
      arguments.append(.text(filter.needle))
      return "\(column) = ?"
    case .prefix:
      arguments.append(.text(escapeLIKE(filter.needle) + "%"))
      return "\(column) LIKE ? ESCAPE '\\'"
    case .suffix:
      arguments.append(.text("%" + escapeLIKE(filter.needle)))
      return "\(column) LIKE ? ESCAPE '\\'"
    case .contains:
      arguments.append(.text("%" + escapeLIKE(filter.needle) + "%"))
      return "\(column) LIKE ? ESCAPE '\\'"
    }
  }

  /// The SQL expression that yields the value to match against. The
  /// `collection` column on the JOINed `collection` table aside, every
  /// comparable column is lowercased via `lower()` so case-insensitive
  /// matching survives without an extra `lower(?)` on the bind side.
  private static func columnExpression(for field: SearchFilter.Field) -> String {
    switch field {
    case .source: return "lower(d.source_id)"
    case .kind: return "lower(d.kind)"
    case .title: return "lower(d.title)"
    case .url: return "lower(coalesce(d.url, ''))"
    case .bundle: return "lower(coalesce(d.bundle_id, ''))"
    case .subtitle: return "lower(coalesce(d.subtitle, ''))"
    case .collection: return "c.name"
    case .meta(let key):
      // `json_extract` is built into SQLite and is the textbook way to
      // pull a value out of the JSON-text `meta` column. Key was already
      // whitelisted to `[A-Za-z0-9_]+` in `parseField`, so direct
      // interpolation is safe — no SQL injection vector.
      return "lower(coalesce(json_extract(d.meta, '$.\(key)'), ''))"
    case .unknown: return "''"
    }
  }

  /// `true` when the underlying column may be NULL; `any` then maps to
  /// `IS NOT NULL` (matches today's "field is set" semantics).
  private static func isColumnNullable(_ field: SearchFilter.Field) -> Bool {
    switch field {
    case .url, .bundle, .subtitle, .meta: return true
    default: return false
    }
  }

  /// Escape `%`, `_`, and `\` inside a LIKE value so a user-typed
  /// wildcard never reaches SQLite's pattern matcher. Used with
  /// `ESCAPE '\\'`.
  static func escapeLIKE(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count)
    for ch in value {
      switch ch {
      case "\\", "%", "_": out.append("\\"); out.append(ch)
      default: out.append(ch)
      }
    }
    return out
  }
}

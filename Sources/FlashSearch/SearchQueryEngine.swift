import Foundation
import GRDB

/// Read side of the search index. `query` runs through `pool.read` and is
/// concurrent with writes; callers can fire one query per keystroke
/// without throttling because the writer lane is independent.
public final class SearchQueryEngine {
  private let store: SearchStore

  public init(store: SearchStore) {
    self.store = store
  }

  /// Async query. The completion fires on `completionQueue` — typically
  /// the caller's main queue for UI delivery.
  public func query(
    _ q: SearchQuery,
    completionQueue: DispatchQueue,
    completion: @escaping (Result<[SearchHit], Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let hits = try self.querySync(q)
        completionQueue.async { completion(.success(hits)) }
      } catch {
        completionQueue.async { completion(.failure(error)) }
      }
    }
  }

  /// Synchronous variant. Used by tests, by the plugin RPC broker (it
  /// already runs on a dedicated queue), and by SearchService's empty-
  /// query frecency snapshot path.
  public func querySync(_ q: SearchQuery) throws -> [SearchHit] {
    let limit = max(1, q.limit ?? store.configuration.retrievalLimit)
    let filterCompiled = SearchFilterCompiler.compile(q.filters)
    let matchExpr = Self.buildMatchExpression(q.text)

    // No tokens survived sanitization AND no metadata filters — there's
    // no row predicate. Skip the round trip; the caller will fall back
    // to in-memory / frecency-only results.
    if matchExpr == nil, filterCompiled == nil,
       (q.collections == nil || q.collections!.isEmpty)
    {
      return []
    }

    var clauses: [String] = []
    var bindings: [DatabaseValueConvertible?] = []
    if let matchExpr {
      clauses.append("document_fts MATCH ?")
      bindings.append(matchExpr)
    }
    if let compiled = filterCompiled {
      clauses.append(compiled.sql)
      for arg in compiled.arguments {
        switch arg {
        case .text(let s): bindings.append(s)
        case .integer(let i): bindings.append(i)
        case .null: bindings.append(nil)
        }
      }
    }
    if let collections = q.collections, !collections.isEmpty {
      // Explicit collection list = the caller knows exactly what they
      // want. Honour hidden collections too — `:clipboard` reads its
      // own collection by name; the gate is only for the default pool.
      let placeholders = Array(repeating: "?", count: collections.count).joined(separator: ", ")
      clauses.append("c.name IN (\(placeholders))")
      for name in collections { bindings.append(name) }
    } else if !q.includeHidden {
      // Default flashlight queries skip collections their owner marked
      // hidden (clipboard history, future per-app keychains, …). The
      // owner can still query its own data by listing the collection
      // name explicitly.
      clauses.append("c.hidden = 0")
    }
    let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    bindings.append(limit)

    // BM25 column weights match the in-memory `fieldScoreNormalized`
    // tier ordering: title is the strongest signal, url is the second
    // strongest (because it carries domain/path tokens that often hold
    // the actual identity of the row), subtitle/body lower. A lower
    // BM25 score is a better match; consumers sort ascending.
    let sql: String
    if matchExpr != nil {
      sql = """
        SELECT d.id, d.collection_id, d.doc_key, d.title, d.subtitle, d.body,
               d.url, d.kind, d.source_id, d.bundle_id, d.meta,
               c.name AS collection_name,
               bm25(document_fts, 8.0, 2.0, 1.0, 4.0) AS rank
        FROM document_fts
        JOIN document d ON d.id = document_fts.rowid
        JOIN collection c ON c.id = d.collection_id
        \(whereSQL)
        ORDER BY rank
        LIMIT ?;
        """
    } else {
      sql = """
        SELECT d.id, d.collection_id, d.doc_key, d.title, d.subtitle, d.body,
               d.url, d.kind, d.source_id, d.bundle_id, d.meta,
               c.name AS collection_name,
               0.0 AS rank
        FROM document d
        JOIN collection c ON c.id = d.collection_id
        \(whereSQL)
        ORDER BY d.updated_at DESC
        LIMIT ?;
        """
    }

    return try store.pool.read { db in
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(bindings))
      return rows.compactMap(Self.hit(from:))
    }
  }

  // MARK: - Match expression

  /// Build the FTS5 `MATCH` expression from the user's typed query.
  /// Whitespace splits tokens; FTS specials are stripped; each token is
  /// double-quoted with a trailing `*` so prefix matches hit. Returns
  /// `nil` if nothing usable survives.
  static func buildMatchExpression(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let pieces = trimmed.split(whereSeparator: { $0.isWhitespace })
    var tokens: [String] = []
    tokens.reserveCapacity(pieces.count)
    for piece in pieces {
      let sanitized = piece.unicodeScalars.compactMap { scalar -> Character? in
        switch scalar {
        // FTS5 syntax characters — `"`, `*`, `:`, parens, `^`, `+`, `-`
        // are all interpreted by the query parser. We're typing a free-
        // form user query, so strip them; the user can still match the
        // surrounding word.
        case "\"", "*", ":", "(", ")", "^", "+", "-", "[", "]", "{", "}", ",", "'":
          return nil
        default:
          return Character(scalar)
        }
      }
      let token = String(sanitized).lowercased()
      if token.isEmpty { continue }
      tokens.append(token)
    }
    guard !tokens.isEmpty else { return nil }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
  }

  // MARK: - Row decoding

  private static func hit(from row: Row) -> SearchHit? {
    let collection: String = row["collection_name"]
    let docKey: String = row["doc_key"]
    let title: String = row["title"]
    let kind: String = row["kind"]
    let sourceID: String = row["source_id"]
    let subtitle: String? = row["subtitle"]
    let body: String? = row["body"]
    let url: String? = row["url"]
    let bundle: String? = row["bundle_id"]
    let metaText: String? = row["meta"]
    let meta = decodeMeta(metaText)
    let rank: Double = row["rank"] ?? 0.0
    let doc = SearchDocument(
      docKey: docKey, title: title, kind: kind, sourceID: sourceID,
      subtitle: subtitle, body: body, url: url, bundleID: bundle, meta: meta)
    return SearchHit(collection: collection, document: doc, bm25: rank)
  }

  private static func decodeMeta(_ raw: String?) -> [String: String] {
    guard let raw, let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object.compactMapValues { value in
      if let s = value as? String { return s }
      if let n = value as? NSNumber { return n.stringValue }
      return nil
    }
  }
}

/// A submitted query. `limit` is bounded by the store's `retrievalLimit`
/// when unset; the in-memory merge step is responsible for trimming to
/// the user-visible row count.
public struct SearchQuery: Sendable {
  public var text: String
  public var filters: [SearchFilter]
  public var collections: [String]?
  public var limit: Int?
  /// When true, the query reaches into collections marked hidden by
  /// their owner. Default false — the flashlight pool never sees
  /// hidden collections; the owning plugin can flip this on for its
  /// own dashboard queries.
  public var includeHidden: Bool

  public init(
    text: String,
    filters: [SearchFilter] = [],
    collections: [String]? = nil,
    limit: Int? = nil,
    includeHidden: Bool = false
  ) {
    self.text = text
    self.filters = filters
    self.collections = collections
    self.limit = limit
    self.includeHidden = includeHidden
  }
}

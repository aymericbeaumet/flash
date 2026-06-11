import Foundation

/// A row to feed the index. All searchable text lives in `title`/`subtitle`/
/// `body`/`url`; the structural columns (`kind`/`sourceID`/`bundleID`) back
/// the metadata filters. `meta` is a free-form string→string bag persisted as
/// JSON and queried through SQLite's `json_extract`.
public struct SearchDocument: Equatable, Sendable {
  /// Stable key inside the owning collection. Two writes with the same
  /// `(collection, docKey)` upsert the same row.
  public var docKey: String
  /// User-visible label. Indexed and ranked highest in BM25 weighting.
  public var title: String
  /// Optional second label line. Indexed.
  public var subtitle: String?
  /// Long-form text (e.g. clipboard body, file path tokens). Indexed.
  public var body: String?
  /// Optional destination URL. Indexed and matchable via the `url:` filter.
  public var url: String?
  /// Category tag used by metadata filters (`kind:foo`). Required so every
  /// row is filterable by source-defined type.
  public var kind: String
  /// Stable `SourceRegistry` identifier this row resolves through.
  public var sourceID: String
  /// App bundle id this row points at, when applicable.
  public var bundleID: String?
  /// Opaque per-row metadata for source-specific fields. Queried via
  /// `meta.<key>:value` filters. Keys must be `[A-Za-z0-9_]+` to round-trip
  /// safely through `json_extract` paths.
  public var meta: [String: String]

  public init(
    docKey: String,
    title: String,
    kind: String,
    sourceID: String,
    subtitle: String? = nil,
    body: String? = nil,
    url: String? = nil,
    bundleID: String? = nil,
    meta: [String: String] = [:]
  ) {
    self.docKey = docKey
    self.title = title
    self.kind = kind
    self.sourceID = sourceID
    self.subtitle = subtitle
    self.body = body
    self.url = url
    self.bundleID = bundleID
    self.meta = meta
  }

  /// Stable identity hash over indexed columns. Compared against the row
  /// already on disk so a re-index of unchanged content is a no-op (the
  /// upsert's `WHERE content_hash <> excluded.content_hash` short-circuits
  /// the FTS trigger). Order-independent across `meta` keys.
  public var contentHash: String {
    var hasher = StableHasher()
    hasher.write(title)
    hasher.write(subtitle ?? "")
    hasher.write(body ?? "")
    hasher.write(url ?? "")
    hasher.write(kind)
    hasher.write(sourceID)
    hasher.write(bundleID ?? "")
    for key in meta.keys.sorted() {
      hasher.write(key)
      hasher.write(meta[key] ?? "")
    }
    return String(hasher.value, radix: 16)
  }
}

/// A query hit. `bm25` is SQLite's raw BM25 score (lower = better match);
/// callers convert it to their UI's ranking units.
public struct SearchHit: Equatable, Sendable {
  public var collection: String
  public var document: SearchDocument
  public var bm25: Double

  public init(collection: String, document: SearchDocument, bm25: Double) {
    self.collection = collection
    self.document = document
    self.bm25 = bm25
  }
}

/// Tiny FNV-1a-ish 64-bit hash. Stable across runs (no `Hasher.combine`
/// salt) so we can compare `content_hash` columns across processes. Not
/// cryptographic; the only requirement is collision resistance at the
/// level of "did this document's indexed text change."
struct StableHasher {
  private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

  mutating func write(_ string: String) {
    let bytes = string.utf8
    value &+= 0x9e37_79b9_7f4a_7c15
    for byte in bytes {
      value ^= UInt64(byte)
      value = value &* 0x0000_0100_0000_01b3
    }
    value &+= 0x9e37_79b9_7f4a_7c15
  }
}

import Foundation
import GRDB

/// All schema lives here as one `DatabaseMigrator`. The migrator is
/// idempotent and versioned, so dev databases survive package upgrades.
/// All DDL is raw SQL — GRDB is intentionally not used for FTS triggers
/// so a future 6→7 swap is a trivial dependency bump.
enum SearchSchema {
  static func migrator() -> DatabaseMigrator {
    var m = DatabaseMigrator()
    m.registerMigration("v1") { db in
      try installV1(db)
    }
    m.registerMigration("v2_hidden_collections") { db in
      try installV2(db)
    }
    return m
  }

  private static func installV1(_ db: Database) throws {
    // Collections register the namespace a document belongs to. Names like
    // "core:browser_history" / "plugin:clipboard:history" let the broker
    // enforce ownership rules with a prefix check.
    try db.execute(sql: """
      CREATE TABLE collection (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        owner TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      """)

    try db.execute(sql: """
      CREATE TABLE document (
        id INTEGER PRIMARY KEY,
        collection_id INTEGER NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
        doc_key TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        body TEXT,
        url TEXT,
        kind TEXT NOT NULL,
        source_id TEXT NOT NULL,
        bundle_id TEXT,
        meta TEXT,
        content_hash TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (collection_id, doc_key)
      );
      """)
    try db.execute(sql: "CREATE INDEX idx_document_collection ON document(collection_id);")
    try db.execute(sql: "CREATE INDEX idx_document_kind ON document(kind);")
    try db.execute(sql: "CREATE INDEX idx_document_bundle ON document(bundle_id);")

    // External-content FTS5 table: the FTS index stores positions/tokens,
    // not the source text. Tokenizer choices: `unicode61` for Unicode-
    // normalised tokenisation with `remove_diacritics 2` (NFD-aware),
    // `prefix='2 3'` for two- and three-char prefix lookups (which is
    // what `tok*` MATCH expressions hit). 1-char prefix indexes nearly
    // double size for negligible win — the in-memory pool covers very
    // short queries.
    try db.execute(sql: """
      CREATE VIRTUAL TABLE document_fts USING fts5(
        title, subtitle, body, url,
        content='document',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2',
        prefix='2 3'
      );
      """)
    // Hand-written sync triggers, scoped to indexed columns. An UPDATE
    // that only touches `meta`/`content_hash`/`updated_at` fires no FTS
    // rewrite — that's the whole point of the column-scoped `AFTER
    // UPDATE OF`.
    try db.execute(sql: """
      CREATE TRIGGER document_ai AFTER INSERT ON document BEGIN
        INSERT INTO document_fts(rowid, title, subtitle, body, url)
        VALUES (new.id, new.title, coalesce(new.subtitle, ''), coalesce(new.body, ''),
                coalesce(new.url, ''));
      END;
      """)
    try db.execute(sql: """
      CREATE TRIGGER document_ad AFTER DELETE ON document BEGIN
        INSERT INTO document_fts(document_fts, rowid, title, subtitle, body, url)
        VALUES ('delete', old.id, old.title, coalesce(old.subtitle, ''),
                coalesce(old.body, ''), coalesce(old.url, ''));
      END;
      """)
    try db.execute(sql: """
      CREATE TRIGGER document_au AFTER UPDATE OF title, subtitle, body, url ON document BEGIN
        INSERT INTO document_fts(document_fts, rowid, title, subtitle, body, url)
        VALUES ('delete', old.id, old.title, coalesce(old.subtitle, ''),
                coalesce(old.body, ''), coalesce(old.url, ''));
        INSERT INTO document_fts(rowid, title, subtitle, body, url)
        VALUES (new.id, new.title, coalesce(new.subtitle, ''),
                coalesce(new.body, ''), coalesce(new.url, ''));
      END;
      """)

    // Frecency: one row per stable item key (`app.bundle:…`, `url:…`,
    // `doc:…`). `score` decays lazily on read — see `FrecencyStore`.
    try db.execute(sql: """
      CREATE TABLE frecency (
        item_key TEXT PRIMARY KEY,
        score REAL NOT NULL,
        last_at INTEGER NOT NULL,
        open_count INTEGER NOT NULL DEFAULT 0
      );
      """)
  }

  /// v2: per-collection visibility bit. `hidden = 1` keeps a collection
  /// out of the default flashlight pool while still letting the owning
  /// plugin write and query it explicitly. Used by the clipboard plugin
  /// to persist history without surfacing entries through `:flashlight`.
  /// Existing collections default to visible (`hidden = 0`).
  private static func installV2(_ db: Database) throws {
    try db.execute(sql: """
      ALTER TABLE collection ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
      """)
    try db.execute(sql: "CREATE INDEX idx_collection_hidden ON collection(hidden);")
  }
}

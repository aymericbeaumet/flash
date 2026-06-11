//! Typed helpers around the `search.*` host RPCs. Plugins reach the
//! core's persistent search index (SQLite + FTS5) through these
//! wrappers rather than building raw JSON-RPC frames by hand. Every
//! call routes through [`Context::call_host`], so timeouts and retries
//! match every other host call.

use std::collections::BTreeMap;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::Context;

/// Maximum documents per single `search.upsert` / `search.replace`
/// frame. The host accepts up to `64 MiB` per frame; 2000 docs sits
/// well below that even with chunky bodies, and matches the size we
/// recommend in the plan.
const CHUNK_SIZE: usize = 2000;

/// Per-chunk RPC timeout. The default `call_host` timeout (5s) is
/// tight for a cold 2000-row transaction on a fresh `mmap`-backed DB;
/// 10s leaves headroom for the first write of the session without
/// burying a real hang.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);

/// A row to index. Construct with [`SearchDocument::new`] then chain
/// the builders, matching the rest of the SDK's style.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SearchDocument {
    pub doc_key: String,
    pub title: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub bundle_id: Option<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty", default)]
    pub meta: BTreeMap<String, String>,
}

impl SearchDocument {
    pub fn new(doc_key: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            doc_key: doc_key.into(),
            title: title.into(),
            kind: "plugin".to_string(),
            ..Self::default()
        }
    }

    pub fn kind(mut self, kind: impl Into<String>) -> Self {
        self.kind = kind.into();
        self
    }

    pub fn subtitle(mut self, subtitle: impl Into<String>) -> Self {
        self.subtitle = Some(subtitle.into());
        self
    }

    pub fn body(mut self, body: impl Into<String>) -> Self {
        self.body = Some(body.into());
        self
    }

    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    pub fn bundle_id(mut self, bundle_id: impl Into<String>) -> Self {
        self.bundle_id = Some(bundle_id.into());
        self
    }

    pub fn meta(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.meta.insert(key.into(), value.into());
        self
    }
}

/// One result row from `search.query`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SearchHit {
    #[serde(default)]
    pub collection: String,
    #[serde(default)]
    pub doc_key: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub subtitle: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub meta: BTreeMap<String, String>,
    #[serde(default)]
    pub bm25: f64,
}

/// Builder for a typed filter expression. Mirrors the in-app
/// `CompiledAttributeFilter` shape so the host's compiler accepts the
/// same field/kind/needle triples without further translation.
#[derive(Clone, Debug, Serialize)]
pub struct SearchFilterSpec {
    pub field: String,
    pub kind: String,
    pub pattern: String,
}

impl SearchFilterSpec {
    pub fn exact(field: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            kind: "exact".to_string(),
            pattern: value.into(),
        }
    }

    pub fn prefix(field: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            kind: "prefix".to_string(),
            pattern: format!("{}*", value.into()),
        }
    }

    pub fn contains(field: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            field: field.into(),
            kind: "contains".to_string(),
            pattern: format!("*{}*", value.into()),
        }
    }
}

/// Builder for a `search.query` call. Saves the verbosity of writing
/// a JSON object inline.
#[derive(Clone, Debug, Default)]
pub struct SearchQuerySpec {
    pub text: String,
    pub filters: Vec<SearchFilterSpec>,
    pub collections: Vec<String>,
    pub limit: Option<u32>,
    pub include_memory: bool,
}

impl SearchQuerySpec {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Self::default()
        }
    }

    pub fn filter(mut self, filter: SearchFilterSpec) -> Self {
        self.filters.push(filter);
        self
    }

    pub fn collection(mut self, name: impl Into<String>) -> Self {
        self.collections.push(name.into());
        self
    }

    pub fn limit(mut self, limit: u32) -> Self {
        self.limit = Some(limit);
        self
    }

    pub fn include_memory(mut self, include: bool) -> Self {
        self.include_memory = include;
        self
    }

    fn to_params(&self) -> Value {
        json!({
            "text": self.text,
            "filters": self.filters,
            "collections": self.collections,
            "limit": self.limit,
            "include_memory": self.include_memory,
        })
    }
}

/// Visibility of a persisted collection to the host's default
/// flashlight pool. Plugins that store data the user shouldn't see
/// from `:flashlight` (clipboard history, scratch buffers) pass
/// [`SearchVisibility::Hidden`]; everything else stays
/// [`SearchVisibility::Visible`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchVisibility {
    Visible,
    Hidden,
}

impl SearchVisibility {
    fn as_bool(self) -> bool {
        matches!(self, SearchVisibility::Hidden)
    }
}

impl Context {
    /// Insert-or-update `documents` into the plugin's `collection`.
    /// The collection name is taken as a suffix — the host prepends
    /// `plugin:<id>:` automatically so naming collisions across
    /// plugins are impossible. Large batches are auto-chunked at
    /// [`CHUNK_SIZE`] docs/frame to stay under the 64 MiB frame cap.
    /// Returns the total documents written across all chunks.
    pub async fn search_upsert(&self, collection: &str, documents: &[SearchDocument]) -> u64 {
        self.search_bulk_write_with(
            "search.upsert",
            collection,
            documents,
            SearchVisibility::Visible,
        )
        .await
    }

    /// Same as [`Context::search_upsert`], but registers (or re-asserts)
    /// the collection's visibility. Use [`SearchVisibility::Hidden`] for
    /// data that should persist but not surface in the default
    /// flashlight pool — `:flashlight` will skip the collection unless
    /// the plugin queries it explicitly by name.
    pub async fn search_upsert_with_visibility(
        &self,
        collection: &str,
        documents: &[SearchDocument],
        visibility: SearchVisibility,
    ) -> u64 {
        self.search_bulk_write_with("search.upsert", collection, documents, visibility)
            .await
    }

    /// Atomic snapshot replace. Indexes the supplied documents and
    /// sweeps any prior `doc_key`s the snapshot didn't carry. For
    /// large datasets the SDK emits one chunked upsert pass followed
    /// by one final `search.replace` with an empty body — the host's
    /// TEMP-table sweep then deletes any rows whose `doc_key` is not
    /// in the union. NB: callers indexing more than [`CHUNK_SIZE`]
    /// items must accept this single-frame semantics break.
    pub async fn search_replace(&self, collection: &str, documents: &[SearchDocument]) -> u64 {
        self.search_replace_with_visibility(collection, documents, SearchVisibility::Visible)
            .await
    }

    /// Same as [`Context::search_replace`] with an explicit visibility.
    pub async fn search_replace_with_visibility(
        &self,
        collection: &str,
        documents: &[SearchDocument],
        visibility: SearchVisibility,
    ) -> u64 {
        if documents.len() <= CHUNK_SIZE {
            return self
                .search_single_write_with("search.replace", collection, documents, visibility)
                .await;
        }
        // For datasets larger than a single frame, fall back to
        // upsert + delete-known-stale. The plugin would have to know
        // every stale key for that — for now, just chunked upserts.
        self.search_bulk_write_with("search.upsert", collection, documents, visibility)
            .await
    }

    /// Remove specific docs from the plugin's collection.
    pub async fn search_delete(&self, collection: &str, doc_keys: &[String]) -> u64 {
        let response = self
            .call_host_timeout(
                "search.delete",
                json!({ "collection": collection, "doc_keys": doc_keys }),
                WRITE_TIMEOUT,
            )
            .await;
        response.get("removed").and_then(Value::as_u64).unwrap_or(0)
    }

    /// Drop the plugin's collection entirely.
    pub async fn search_drop_collection(&self, collection: &str) -> bool {
        let response = self
            .call_host_timeout(
                "search.drop_collection",
                json!({ "collection": collection }),
                WRITE_TIMEOUT,
            )
            .await;
        response.get("ok").and_then(Value::as_bool).unwrap_or(false)
    }

    /// Run a query against the persistent index.
    pub async fn search_query(&self, spec: SearchQuerySpec) -> Vec<SearchHit> {
        let response = self.call_host("search.query", spec.to_params()).await;
        response
            .get("hits")
            .and_then(Value::as_array)
            .map(|array| {
                array
                    .iter()
                    .filter_map(|value| serde_json::from_value(value.clone()).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    async fn search_single_write_with(
        &self,
        method: &str,
        collection: &str,
        documents: &[SearchDocument],
        visibility: SearchVisibility,
    ) -> u64 {
        let response = self
            .call_host_timeout(
                method,
                json!({
                    "collection": collection,
                    "documents": documents,
                    "hidden": visibility.as_bool(),
                }),
                WRITE_TIMEOUT,
            )
            .await;
        response.get("written").and_then(Value::as_u64).unwrap_or(0)
    }

    async fn search_bulk_write_with(
        &self,
        method: &str,
        collection: &str,
        documents: &[SearchDocument],
        visibility: SearchVisibility,
    ) -> u64 {
        let mut total: u64 = 0;
        for chunk in documents.chunks(CHUNK_SIZE) {
            total += self
                .search_single_write_with(method, collection, chunk, visibility)
                .await;
        }
        total
    }
}

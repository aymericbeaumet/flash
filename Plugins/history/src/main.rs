use flash_plugin::{run, Candidate, Context, RefreshGate};
use rusqlite::{Connection, OpenFlags};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

const SOURCE_URLS: &str = "history.urls";
const SOURCE_BOOKMARKS: &str = "history.bookmarks";
const REFRESH_SECONDS: u64 = 300;
const SLOW_REFRESH_MS: u128 = 1_000;

/// Per-store row caps keep the combined catalog far below the host's
/// 10,000-row / 4 MiB catalog quotas even with every browser populated.
const FIREFOX_HISTORY_LIMIT: usize = 3_000;
const CHROME_HISTORY_LIMIT: usize = 2_000;
const BOOKMARKS_PER_BROWSER_LIMIT: usize = 2_000;
const TOTAL_ROWS_LIMIT: usize = 8_000;
// Compile-time guards: the caps must stay inside the host's catalog quotas.
const _: () = assert!(TOTAL_ROWS_LIMIT < 10_000);
const _: () = assert!(
    FIREFOX_HISTORY_LIMIT + CHROME_HISTORY_LIMIT + 2 * BOOKMARKS_PER_BROWSER_LIMIT <= 10_000
);
const MAX_URL_BYTES: usize = 2_048;
const MAX_TITLE_CHARS: usize = 256;
const MAX_BOOKMARK_DEPTH: usize = 64;

fn firefox_history_sql() -> String {
    format!(
        "SELECT url, title FROM moz_places
         WHERE url NOT LIKE 'place:%' AND url <> ''
         ORDER BY frecency DESC
         LIMIT {FIREFOX_HISTORY_LIMIT}"
    )
}

fn firefox_bookmarks_sql() -> String {
    format!(
        "SELECT p.url, COALESCE(NULLIF(b.title, ''), p.title) FROM moz_bookmarks b
         JOIN moz_places p ON p.id = b.fk
         WHERE b.type = 1 AND p.url NOT LIKE 'place:%' AND p.url <> ''
         LIMIT {BOOKMARKS_PER_BROWSER_LIMIT}"
    )
}

fn chrome_history_sql() -> String {
    format!(
        "SELECT url, title FROM urls
         WHERE url <> ''
         ORDER BY visit_count DESC
         LIMIT {CHROME_HISTORY_LIMIT}"
    )
}

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

/// One page row read from a browser store, before candidate shaping.
#[derive(Clone, Debug, PartialEq)]
struct UrlRow {
    url: String,
    title: String,
}

/// Rows contributed by one browser: `(history, bookmarks)`. `None` means the
/// store exists but could not be read this cycle (transient failure); an
/// absent browser contributes authoritative empty vectors instead.
type BrowserRows = Option<(Vec<UrlRow>, Vec<UrlRow>)>;

struct History;

flash_plugin::plugin!(History);

impl FlashPlugin for History {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply; a failed first build publishes
        // nothing (the host keeps last-good) and retries in the background.
        if !refresh_catalog(&ctx).await {
            log_degraded_initial(&ctx);
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_catalog(&retry_ctx).await;
            });
        }
        drop(
            ctx.interval(Duration::from_secs(REFRESH_SECONDS), |ctx| async move {
                refresh_catalog(&ctx).await;
            }),
        );
    }
}

/// Rebuild and publish the combined catalog. Returns whether a snapshot was
/// published this cycle (a transient failure keeps the last-good snapshot).
async fn refresh_catalog(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, _running| async move {
            let started_at = Instant::now();
            let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
                ctx.publish(Vec::new());
                log_refresh(&ctx, "empty", 0, started_at);
                return true;
            };
            let firefox = firefox_rows(&ctx, &home).await;
            let chrome = chrome_rows(&ctx, &home).await;
            let (Some(firefox), Some(chrome)) = (firefox, chrome) else {
                // Transient store failure: don't publish — the host keeps
                // its last-good catalog.
                log_refresh(&ctx, "failed", 0, started_at);
                return false;
            };
            let candidates = compose_candidates(firefox, chrome);
            let count = candidates.len();
            ctx.publish(candidates);
            log_refresh(
                &ctx,
                if count == 0 { "empty" } else { "ok" },
                count,
                started_at,
            );
            true
        })
        .await
}

// ---------------------------------------------------------------------------
// Firefox
// ---------------------------------------------------------------------------

async fn firefox_rows(ctx: &Context, home: &Path) -> BrowserRows {
    let Some(places) = newest_places_db(home).await else {
        return Some((Vec::new(), Vec::new()));
    };
    let Some(db) = snapshot_sqlite(ctx, &places, "firefox-places.sqlite").await else {
        ctx.log("warn", "[history] copying Firefox places.sqlite failed");
        return None;
    };
    let queried = tokio::task::spawn_blocking(move || {
        let history = read_url_rows(&db, &firefox_history_sql())?;
        let bookmarks = read_url_rows(&db, &firefox_bookmarks_sql())?;
        Ok::<_, rusqlite::Error>((history, bookmarks))
    })
    .await;
    match queried {
        Ok(Ok(rows)) => Some(rows),
        Ok(Err(error)) => {
            ctx.log(
                "warn",
                &format!("[history] Firefox places query failed: {error}"),
            );
            None
        }
        Err(error) => {
            ctx.log(
                "warn",
                &format!("[history] Firefox places task failed: {error}"),
            );
            None
        }
    }
}

/// The default Firefox profile, approximated as the profile whose
/// `places.sqlite` was written most recently — the one the running (or last
/// run) instance owns, without parsing `profiles.ini` installs.
async fn newest_places_db(home: &Path) -> Option<PathBuf> {
    let profiles = home
        .join("Library")
        .join("Application Support")
        .join("Firefox")
        .join("Profiles");
    let mut entries = tokio::fs::read_dir(&profiles).await.ok()?;
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    while let Some(entry) = entries.next_entry().await.ok().flatten() {
        let places = entry.path().join("places.sqlite");
        let Ok(metadata) = tokio::fs::metadata(&places).await else {
            continue;
        };
        let Ok(modified) = metadata.modified() else {
            continue;
        };
        if best.as_ref().is_none_or(|(newest, _)| modified > *newest) {
            best = Some((modified, places));
        }
    }
    best.map(|(_, places)| places)
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

async fn chrome_rows(ctx: &Context, home: &Path) -> BrowserRows {
    let profile = home
        .join("Library")
        .join("Application Support")
        .join("Google")
        .join("Chrome")
        .join("Default");
    if tokio::fs::metadata(&profile).await.is_err() {
        return Some((Vec::new(), Vec::new()));
    }
    let bookmarks = match tokio::fs::read(profile.join("Bookmarks")).await {
        Ok(bytes) => match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(value) => chrome_bookmark_rows(&value),
            Err(error) => {
                ctx.log(
                    "warn",
                    &format!("[history] Chrome Bookmarks unparsable: {error}"),
                );
                Vec::new()
            }
        },
        Err(_) => Vec::new(),
    };
    let history_src = profile.join("History");
    if tokio::fs::metadata(&history_src).await.is_err() {
        return Some((Vec::new(), bookmarks));
    }
    let Some(db) = snapshot_sqlite(ctx, &history_src, "chrome-history.sqlite").await else {
        ctx.log("warn", "[history] copying Chrome History failed");
        return None;
    };
    let queried =
        tokio::task::spawn_blocking(move || read_url_rows(&db, &chrome_history_sql())).await;
    match queried {
        Ok(Ok(history)) => Some((history, bookmarks)),
        Ok(Err(error)) => {
            ctx.log(
                "warn",
                &format!("[history] Chrome History query failed: {error}"),
            );
            None
        }
        Err(error) => {
            ctx.log(
                "warn",
                &format!("[history] Chrome History task failed: {error}"),
            );
            None
        }
    }
}

/// Walk `roots.bookmark_bar` / `roots.other` of Chrome's plain-JSON Bookmarks
/// file, collecting `type: "url"` leaves depth-first.
fn chrome_bookmark_rows(value: &serde_json::Value) -> Vec<UrlRow> {
    let mut rows = Vec::new();
    for root in ["bookmark_bar", "other"] {
        if let Some(node) = value.get("roots").and_then(|roots| roots.get(root)) {
            collect_chrome_bookmarks(node, 0, &mut rows);
        }
    }
    rows
}

fn collect_chrome_bookmarks(node: &serde_json::Value, depth: usize, rows: &mut Vec<UrlRow>) {
    if depth > MAX_BOOKMARK_DEPTH || rows.len() >= BOOKMARKS_PER_BROWSER_LIMIT {
        return;
    }
    if node.get("type").and_then(serde_json::Value::as_str) == Some("url") {
        if let Some(url) = node.get("url").and_then(serde_json::Value::as_str) {
            rows.push(UrlRow {
                url: url.to_string(),
                title: node
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            });
        }
        return;
    }
    if let Some(children) = node.get("children").and_then(serde_json::Value::as_array) {
        for child in children {
            collect_chrome_bookmarks(child, depth + 1, rows);
        }
    }
}

// ---------------------------------------------------------------------------
// SQLite snapshot + read
// ---------------------------------------------------------------------------

/// Copy a browser-owned SQLite database (plus its `-wal` sibling when present)
/// into the plugin cache dir under `name`. The live database stays locked by
/// the browser; SQLite only ever opens our private copy.
async fn snapshot_sqlite(ctx: &Context, src: &Path, name: &str) -> Option<PathBuf> {
    let dst = ctx.cache_dir().join(name);
    let src_wal = sibling(src, "-wal");
    let dst_wal = sibling(&dst, "-wal");
    // Stale sidecars from a previous cycle must never pair with a fresh copy.
    let _ = tokio::fs::remove_file(&dst_wal).await;
    let _ = tokio::fs::remove_file(sibling(&dst, "-shm")).await;
    tokio::fs::copy(src, &dst).await.ok()?;
    if tokio::fs::metadata(&src_wal).await.is_ok() {
        tokio::fs::copy(&src_wal, &dst_wal).await.ok()?;
    }
    Some(dst)
}

fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut os = path.as_os_str().to_os_string();
    os.push(suffix);
    PathBuf::from(os)
}

/// Blocking (call inside `spawn_blocking`). Reads `(url, title)` rows from
/// our private copy, read-only first; a copied WAL can require recovery that
/// a read-only connection may not perform, and the copy is ours, so falling
/// back to a writable open is safe.
fn read_url_rows(db: &Path, sql: &str) -> Result<Vec<UrlRow>, rusqlite::Error> {
    read_url_rows_with(
        db,
        sql,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .or_else(|_| read_url_rows_with(db, sql, OpenFlags::default()))
}

fn read_url_rows_with(
    db: &Path,
    sql: &str,
    flags: OpenFlags,
) -> Result<Vec<UrlRow>, rusqlite::Error> {
    let connection = Connection::open_with_flags(db, flags)?;
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map([], |row| {
        Ok(UrlRow {
            url: row.get(0)?,
            title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        })
    })?;
    rows.collect()
}

// ---------------------------------------------------------------------------
// Candidate shaping
// ---------------------------------------------------------------------------

fn compose_candidates(
    (firefox_history, firefox_bookmarks): (Vec<UrlRow>, Vec<UrlRow>),
    (chrome_history, chrome_bookmarks): (Vec<UrlRow>, Vec<UrlRow>),
) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for row in firefox_bookmarks.into_iter().chain(chrome_bookmarks) {
        if !acceptable_url(&row.url) || !seen.insert(row.url.clone()) {
            continue;
        }
        candidates.push(candidate(row, SOURCE_BOOKMARKS, "bookmark"));
    }
    // History fills whatever the (small) bookmark set left of the total cap,
    // most-frecent/most-visited first.
    let mut seen = HashSet::new();
    for row in firefox_history.into_iter().chain(chrome_history) {
        if candidates.len() >= TOTAL_ROWS_LIMIT {
            break;
        }
        if !acceptable_url(&row.url) || !seen.insert(row.url.clone()) {
            continue;
        }
        candidates.push(candidate(row, SOURCE_URLS, "history"));
    }
    candidates
}

/// A candidate with a `url` opens natively on selection — no resolver.
fn candidate(row: UrlRow, source: &str, kind: &str) -> Candidate {
    let title = tidy_title(&row.title, &row.url);
    Candidate::new(source, title).url(&row.url).kind(kind)
}

fn tidy_title(title: &str, url: &str) -> String {
    let title = title.trim();
    let title = if title.is_empty() { url } else { title };
    title.chars().take(MAX_TITLE_CHARS).collect()
}

/// Openable rows only: `javascript:` bookmarklets and `data:` blobs cannot be
/// handed to LaunchServices, and oversized URLs would bloat the catalog.
fn acceptable_url(url: &str) -> bool {
    if url.is_empty() || url.len() > MAX_URL_BYTES {
        return false;
    }
    let lowered = url
        .get(..11)
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    !(lowered.starts_with("javascript:")
        || lowered.starts_with("data:")
        || url.starts_with("place:"))
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("outcome".to_string(), outcome.to_string()),
        ("candidates".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[history] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[history] warm refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[history] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
            ("candidates".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

fn main() {
    run(History);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(url: &str, title: &str) -> UrlRow {
        UrlRow {
            url: url.to_string(),
            title: title.to_string(),
        }
    }

    #[test]
    fn chrome_bookmarks_walk_recurses_bar_and_other_roots_only() {
        let value: serde_json::Value = serde_json::from_str(
            r#"{
              "roots": {
                "bookmark_bar": {
                  "type": "folder",
                  "children": [
                    { "type": "url", "name": "Rust", "url": "https://rust-lang.org/" },
                    {
                      "type": "folder",
                      "children": [
                        { "type": "url", "name": "Nested", "url": "https://example.com/" }
                      ]
                    }
                  ]
                },
                "other": {
                  "type": "folder",
                  "children": [
                    { "type": "url", "name": "Other", "url": "https://other.example/" }
                  ]
                },
                "synced": {
                  "type": "folder",
                  "children": [
                    { "type": "url", "name": "Synced", "url": "https://synced.example/" }
                  ]
                }
              }
            }"#,
        )
        .unwrap();
        let rows = chrome_bookmark_rows(&value);
        assert_eq!(
            rows,
            vec![
                row("https://rust-lang.org/", "Rust"),
                row("https://example.com/", "Nested"),
                row("https://other.example/", "Other"),
            ]
        );
    }

    #[test]
    fn unopenable_and_oversized_urls_are_rejected() {
        assert!(acceptable_url("https://example.com/"));
        assert!(acceptable_url("http://a"));
        assert!(!acceptable_url(""));
        assert!(!acceptable_url("javascript:void(0)"));
        assert!(!acceptable_url("JavaScript:alert(1)"));
        assert!(!acceptable_url("data:text/html,hi"));
        assert!(!acceptable_url("place:sort=8"));
        assert!(!acceptable_url(&format!(
            "https://example.com/{}",
            "x".repeat(MAX_URL_BYTES)
        )));
    }

    #[test]
    fn titles_fall_back_to_the_url_and_are_length_capped() {
        assert_eq!(
            tidy_title("  ", "https://example.com/"),
            "https://example.com/"
        );
        assert_eq!(tidy_title("Example", "https://example.com/"), "Example");
        assert_eq!(
            tidy_title(&"x".repeat(MAX_TITLE_CHARS + 100), "u")
                .chars()
                .count(),
            MAX_TITLE_CHARS
        );
    }

    #[test]
    fn compose_labels_sources_and_deduplicates_within_each_pool() {
        let firefox = (
            vec![
                row("https://a.example/", "A"),
                row("https://a.example/", "A dup"),
            ],
            vec![row("https://bm.example/", "Bookmark")],
        );
        let chrome = (
            vec![
                row("https://a.example/", "A from Chrome"),
                row("https://b.example/", ""),
            ],
            vec![
                row("https://bm.example/", "Bookmark dup"),
                row("javascript:x", "Bad"),
            ],
        );
        let candidates = compose_candidates(firefox, chrome);
        let summary: Vec<(&str, &str, &str)> = candidates
            .iter()
            .map(|c| {
                (
                    c.title.as_str(),
                    c.url.as_deref().unwrap_or(""),
                    c.source.as_str(),
                )
            })
            .collect();
        assert_eq!(
            summary,
            vec![
                ("Bookmark", "https://bm.example/", SOURCE_BOOKMARKS),
                ("A", "https://a.example/", SOURCE_URLS),
                ("https://b.example/", "https://b.example/", SOURCE_URLS),
            ]
        );
    }

    #[test]
    fn total_row_cap_trims_history_not_bookmarks() {
        let history: Vec<UrlRow> = (0..TOTAL_ROWS_LIMIT + 10)
            .map(|index| row(&format!("https://h.example/{index}"), "h"))
            .collect();
        let bookmarks = vec![row("https://bm.example/", "Bookmark")];
        let candidates = compose_candidates((history, bookmarks), (Vec::new(), Vec::new()));
        assert_eq!(candidates.len(), TOTAL_ROWS_LIMIT);
        assert_eq!(candidates[0].source, SOURCE_BOOKMARKS);
    }
}

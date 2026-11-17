//! Search bangs: `!<bang> <query>` opens the site's own search, resolved
//! here rather than through a search engine's redirect.
//!
//! Kagi's community list (MIT) is vendored at a pinned commit. DuckDuckGo's
//! list carries no licence that permits redistributing it, so the plugin
//! downloads it (`https://duckduckgo.com/bang.js`, no query attached) into its
//! data directory when the flashlight opens and the copy is missing or a week
//! old, at most once an hour after a failure. Until then the Kagi list alone
//! answers. DuckDuckGo's bangs win; Kagi's fill the triggers DuckDuckGo lacks.

mod bangs;

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bangs::{KAGI, List, MAX_LIST_BYTES, Table, cache_fetched_at, duckduckgo_cache};
use flash_plugin::{Candidate, CommandRequest, Context, Event, PerformResponse, host_events, run};
use reqwest::Client;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, OnceCell};

const BANG_LIST_URL: &str = "https://duckduckgo.com/bang.js";
const CACHE_FILE: &str = "duckduckgo-bangs.tsv";
/// The list changes slowly; a week-old copy is refreshed.
const REFRESH_SECONDS: u64 = 7 * 86_400;
/// After a failed download, the next flashlight session tries again an hour
/// later at the earliest.
const RETRY_SECONDS: u64 = 3_600;
const FETCH_TIMEOUT: Duration = Duration::from_secs(30);
/// A smaller list is not DuckDuckGo's: the cached copy stays.
const MIN_LIST_BANGS: usize = 1_000;

#[derive(Default)]
struct State {
    loaded: OnceCell<()>,
    table: RwLock<Arc<Table>>,
    /// When the cached DuckDuckGo list was downloaded; 0 for never.
    fetched_at: AtomicU64,
    last_attempt: AtomicU64,
    fetching: Mutex<()>,
}

impl State {
    fn table(&self) -> Arc<Table> {
        Arc::clone(&self.table.read().unwrap_or_else(|error| error.into_inner()))
    }

    fn install(&self, ctx: &Context, table: Table, rows: Vec<Candidate>) {
        let counts = table.counts();
        let fields = BTreeMap::from([
            (
                "bangs".to_string(),
                (counts.duckduckgo + counts.kagi).to_string(),
            ),
            ("duckduckgo".to_string(), counts.duckduckgo.to_string()),
            ("kagi".to_string(), counts.kagi.to_string()),
            ("dropped".to_string(), counts.dropped.to_string()),
            ("listed".to_string(), rows.len().to_string()),
        ]);
        ctx.publish(rows);
        *self
            .table
            .write()
            .unwrap_or_else(|error| error.into_inner()) = Arc::new(table);
        ctx.log_fields("debug", "[searchproviders] bangs published", fields);
    }

    /// The vendored list and the cached DuckDuckGo copy, once per process,
    /// before any command resolves or a refresh replaces them.
    async fn ensure_loaded(&self, ctx: &Context) {
        self.loaded
            .get_or_init(|| async {
                let cache = read_cache(&ctx.data_dir().join(CACHE_FILE)).await;
                let built = tokio::task::spawn_blocking(move || {
                    let (fetched_at, duckduckgo) = match cache {
                        Some((fetched_at, text)) => (fetched_at, List::duckduckgo(text)),
                        None => (0, List::empty()),
                    };
                    let table = Table::new(duckduckgo, &KAGI);
                    let rows = table.catalog();
                    (fetched_at, table, rows)
                })
                .await;
                if let Ok((fetched_at, table, rows)) = built {
                    self.fetched_at.store(fetched_at, Ordering::Relaxed);
                    self.install(ctx, table, rows);
                }
            })
            .await;
    }
}

/// The cached DuckDuckGo list and when it was fetched; `None` when it is
/// missing, oversized or lacks its header.
async fn read_cache(path: &Path) -> Option<(u64, String)> {
    let size = tokio::fs::metadata(path).await.ok()?.len();
    if size > MAX_LIST_BYTES as u64 {
        return None;
    }
    let text = tokio::fs::read_to_string(path).await.ok()?;
    Some((cache_fetched_at(&text)?, text))
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Whether a flashlight session should download the list now: the copy is
/// missing, a week old or from the future, and no attempt ran in the last
/// hour.
fn refresh_due(fetched_at: u64, last_attempt: u64, now: u64) -> bool {
    let stale = fetched_at == 0
        || fetched_at > now.saturating_add(86_400)
        || now.saturating_sub(fetched_at) >= REFRESH_SECONDS;
    stale && (last_attempt == 0 || now.saturating_sub(last_attempt) >= RETRY_SECONDS)
}

/// Mozilla roots for rustls: the deny-default sandbox blocks the macOS trust
/// service and keychains the platform verifier needs.
fn http_client() -> reqwest::Result<Client> {
    let roots = webpki_root_certs::TLS_SERVER_ROOT_CERTS
        .iter()
        .filter_map(|der| reqwest::Certificate::from_der(der).ok());
    Client::builder()
        .tls_certs_only(roots)
        .timeout(FETCH_TIMEOUT)
        .connect_timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::limited(3))
        .user_agent("Flash searchproviders/0.1")
        .build()
}

async fn download_list(client: &Client) -> Result<String, &'static str> {
    let mut response = client
        .get(BANG_LIST_URL)
        .send()
        .await
        .map_err(|_| "request failed")?
        .error_for_status()
        .map_err(|_| "HTTP error")?;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_LIST_BYTES as u64)
    {
        return Err("list exceeds byte limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "response read failed")? {
        if bytes.len().saturating_add(chunk.len()) > MAX_LIST_BYTES {
            return Err("list exceeds byte limit");
        }
        bytes.extend_from_slice(&chunk);
    }
    String::from_utf8(bytes).map_err(|_| "list is not UTF-8")
}

/// Atomic replace through a sibling temporary file.
async fn write_cache(path: &Path, body: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = tokio::fs::File::create(&temporary).await?;
    let written = async {
        file.write_all(body.as_bytes()).await?;
        file.flush().await
    }
    .await;
    drop(file);
    match written {
        Ok(()) => tokio::fs::rename(&temporary, path).await,
        Err(error) => {
            let _ = tokio::fs::remove_file(&temporary).await;
            Err(error)
        }
    }
}

async fn refresh(ctx: &Context, state: &State) {
    state.ensure_loaded(ctx).await;
    let Ok(_fetching) = state.fetching.try_lock() else {
        return;
    };
    let now = unix_now();
    if !refresh_due(
        state.fetched_at.load(Ordering::Relaxed),
        state.last_attempt.load(Ordering::Relaxed),
        now,
    ) {
        return;
    }
    state.last_attempt.store(now, Ordering::Relaxed);
    match download_cache(now).await {
        Ok(cache) => {
            if write_cache(&ctx.data_dir().join(CACHE_FILE), &cache)
                .await
                .is_err()
            {
                ctx.log(
                    "warn",
                    "[searchproviders] DuckDuckGo bang cache not written",
                );
            }
            let built = tokio::task::spawn_blocking(move || {
                let table = Table::new(List::duckduckgo(cache), &KAGI);
                let rows = table.catalog();
                (table, rows)
            })
            .await;
            if let Ok((table, rows)) = built {
                state.fetched_at.store(now, Ordering::Relaxed);
                state.install(ctx, table, rows);
            }
        }
        Err(reason) => ctx.log_fields(
            "warn",
            "[searchproviders] DuckDuckGo bang list refresh failed",
            BTreeMap::from([("reason".to_string(), reason.to_string())]),
        ),
    }
}

/// Download bang.js and convert it to the cache text, refusing a list too
/// small to be DuckDuckGo's.
async fn download_cache(now: u64) -> Result<String, &'static str> {
    let client = http_client().map_err(|_| "client setup failed")?;
    let body = download_list(&client).await?;
    let (cache, count) = tokio::task::spawn_blocking(move || duckduckgo_cache(&body, now))
        .await
        .map_err(|_| "parser failed")??;
    if count < MIN_LIST_BANGS {
        return Err("too few bangs");
    }
    Ok(cache)
}

#[derive(Default)]
struct SearchProviders {
    state: Arc<State>,
}

flash_plugin::plugin!(SearchProviders);

impl FlashPlugin for SearchProviders {
    async fn on_start(&self, ctx: Context) {
        self.state.ensure_loaded(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name != host_events::SESSION_OPENED
            || !refresh_due(
                self.state.fetched_at.load(Ordering::Relaxed),
                self.state.last_attempt.load(Ordering::Relaxed),
                unix_now(),
            )
        {
            return;
        }
        let state = Arc::clone(&self.state);
        tokio::spawn(async move { refresh(&ctx, &state).await });
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        self.state.ensure_loaded(&ctx).await;
        let resolved = self
            .state
            .table()
            .resolve(&command.subcommand, &command.query());
        let url = match resolved {
            Ok(url) => url,
            Err(error) => return PerformResponse::fail(error),
        };
        match ctx.open_url(&url).await {
            Ok(_) => PerformResponse::ok(),
            Err(error) => PerformResponse::fail(error),
        }
    }
}

fn main() {
    run(SearchProviders::default());
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use serde_json::json;

    #[test]
    fn http_client_verifies_against_every_bundled_root() {
        let parsed = webpki_root_certs::TLS_SERVER_ROOT_CERTS
            .iter()
            .filter(|der| reqwest::Certificate::from_der(der).is_ok())
            .count();
        assert_eq!(parsed, webpki_root_certs::TLS_SERVER_ROOT_CERTS.len());
        assert!(http_client().is_ok());
    }

    #[test]
    fn the_list_downloads_when_missing_or_a_week_old_and_retries_hourly() {
        let now = 10 * REFRESH_SECONDS;
        assert!(refresh_due(0, 0, now), "never downloaded");
        assert!(!refresh_due(now - 60, 0, now), "fresh copy");
        assert!(refresh_due(now - REFRESH_SECONDS, 0, now), "a week old");
        assert!(refresh_due(now + 2 * 86_400, 0, now), "from the future");
        assert!(!refresh_due(0, now - 60, now), "attempted a minute ago");
        assert!(refresh_due(0, now - RETRY_SECONDS, now), "an hour later");
    }

    /// Start publishes the vendored list without touching the network: the
    /// download waits for a flashlight session.
    #[tokio::test]
    async fn start_publishes_the_kagi_list_without_downloading() {
        let mut harness = Harness::new("searchproviders-test");
        SearchProviders::default().on_start(harness.context()).await;
        let frames = harness.drain();
        assert_eq!(frames[0]["method"], "publish");
        let rows = frames[0]["params"]["rows"].as_array().unwrap();
        assert_eq!(rows.len(), bangs::MAX_CATALOG_ROWS);
        assert!(rows.iter().all(|row| row["source"] == bangs::SOURCE));
        assert_eq!(frames[1]["method"], "log");
        assert_eq!(frames[1]["params"]["fields"]["duckduckgo"], "0");
        assert!(
            frames
                .iter()
                .all(|frame| frame["method"] != "request" && frame["method"] != "poll"),
            "{frames:?}"
        );
    }

    #[tokio::test]
    async fn a_cached_duckduckgo_list_wins_over_kagi() {
        let mut harness = Harness::new("searchproviders-test");
        let cache = "# DuckDuckGo bangs (https://duckduckgo.com/bang.js) fetched at 1700000000\n\
                     gh\t11610\thttps://github.com/search?utf8=%E2%9C%93&q={{{s}}}\tGitHub\tgithub.com\tTech\tProgramming\n";
        let path = harness.data_dir().join(CACHE_FILE);
        tokio::fs::create_dir_all(path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&path, cache).await.unwrap();
        let plugin = SearchProviders::default();
        plugin.on_start(harness.context()).await;
        assert_eq!(
            plugin.state.fetched_at.load(Ordering::Relaxed),
            1_700_000_000
        );
        assert_eq!(
            plugin.state.table().resolve("gh", "a b"),
            Ok("https://github.com/search?utf8=%E2%9C%93&q=a%20b".to_string())
        );
        let frames = harness.drain();
        assert_eq!(frames[1]["params"]["fields"]["duckduckgo"], "1");
    }

    #[tokio::test]
    async fn a_bang_opens_its_resolved_url_through_the_host() {
        let mut harness = Harness::new("searchproviders-test");
        let ctx = harness.context();
        let command = CommandRequest {
            subcommand: "GH".to_string(),
            args: vec!["rust".to_string(), "lang".to_string()],
            ..CommandRequest::default()
        };
        let request =
            tokio::spawn(async move { SearchProviders::default().on_command(ctx, command).await });
        let (id, method, params) = loop {
            let next = harness.next_host_request().await.expect("host request");
            if next.1 == "host.open" {
                break next;
            }
        };
        assert_eq!(
            (method.as_str(), params),
            (
                "host.open",
                json!({ "url": "https://github.com/search?q=rust+lang" })
            )
        );
        assert!(harness.reply_host(id, json!({ "ok": true })));
        assert_eq!(
            serde_json::to_value(request.await.unwrap()).unwrap(),
            json!({ "ok": true })
        );
    }

    #[tokio::test]
    async fn an_unknown_bang_fails_without_opening_anything() {
        let harness = Harness::new("searchproviders-test");
        let response = SearchProviders::default()
            .on_command(
                harness.context(),
                CommandRequest {
                    subcommand: "no-such-bang".to_string(),
                    ..CommandRequest::default()
                },
            )
            .await;
        assert_eq!(
            serde_json::to_value(response).unwrap(),
            json!({ "ok": false, "error": "unknown bang" })
        );
    }
}

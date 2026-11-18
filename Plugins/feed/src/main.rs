mod feed;
mod preview;
mod state;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use flash_plugin::{Context, PollPriority, StatusValue, run};
use serde_json::Value;
use url::Url;

struct Settings {
    url: Url,
    refresh_interval: Duration,
    cycle_interval: Duration,
}

fn settings(ctx: &Context) -> Result<Option<Settings>, &'static str> {
    let Some(value) = ctx.config_json::<Value>("url") else {
        return Ok(None);
    };
    let value = value.as_str().ok_or("url must be an HTTPS URL string")?;
    if value.trim().is_empty() {
        return Ok(None);
    }
    // The host fetches it (`host.fetch`), and fetches HTTPS alone.
    let url = feed::web_url(value)
        .filter(|url| url.scheme() == "https")
        .ok_or("url must be an HTTPS URL without credentials")?;
    Ok(Some(Settings {
        url,
        refresh_interval: interval(ctx.config_json("refresh_interval"))?,
        cycle_interval: interval(ctx.config_json("cycle_interval"))?,
    }))
}

/// Seconds. The host delivers the manifest's default when no file sets one.
fn interval(value: Option<Value>) -> Result<Duration, &'static str> {
    value
        .as_ref()
        .and_then(Value::as_u64)
        .filter(|seconds| (1..=86400).contains(seconds))
        .map(Duration::from_secs)
        .ok_or("refresh_interval and cycle_interval must be integer seconds in 1..86400")
}

struct Feed;

flash_plugin::plugin!(Feed);

impl FlashPlugin for Feed {
    async fn on_start(&self, ctx: Context) {
        ctx.status([
            ("summary", StatusValue::empty()),
            ("label", StatusValue::empty()),
        ]);
        let settings = match settings(&ctx) {
            Ok(Some(settings)) => settings,
            Ok(None) => return,
            Err(error) => {
                ctx.log("warn", &format!("[feed] invalid configuration: {error}"));
                return;
            }
        };
        let state = Arc::new(Mutex::new(state::State::new(settings.cycle_interval)));
        let failure_logged = Arc::new(Mutex::new(false));
        // Each tick fetches and, even when the fetch fails, drops the
        // articles that left the window: expiry rides the refresh cadence
        // rather than arming a timer of its own.
        let refresh = {
            let state = Arc::clone(&state);
            let failure_logged = Arc::clone(&failure_logged);
            let url = settings.url.clone();
            move |ctx: Context| {
                let state = Arc::clone(&state);
                let failure_logged = Arc::clone(&failure_logged);
                let url = url.clone();
                async move {
                    let started = Instant::now();
                    let result = fetch_articles(&ctx, &url).await;
                    match &result {
                        Ok(articles) => {
                            ctx.log_fields(
                                "debug",
                                "[feed] refresh",
                                BTreeMap::from([
                                    (
                                        "outcome".to_string(),
                                        if articles.is_empty() { "empty" } else { "ok" }
                                            .to_string(),
                                    ),
                                    ("count".to_string(), articles.len().to_string()),
                                    (
                                        "elapsed_ms".to_string(),
                                        started.elapsed().as_millis().to_string(),
                                    ),
                                ]),
                            );
                            *failure_logged.lock().unwrap() = false;
                        }
                        Err(error) => {
                            let mut logged = failure_logged.lock().unwrap();
                            if !*logged {
                                ctx.log(
                                    "warn",
                                    &format!(
                                        "[feed] refresh outcome=failed reason={error} elapsed_ms={}",
                                        started.elapsed().as_millis()
                                    ),
                                );
                                *logged = true;
                            }
                        }
                    }
                    let segment = state
                        .lock()
                        .unwrap()
                        .refresh(result.map_err(|_| ()), Utc::now().timestamp());
                    publish(&ctx, segment);
                }
            }
        };
        // The authoritative first fetch happens now; the host drives every
        // one after it from the shared clock.
        refresh(ctx.clone()).await;
        // `Low`: a remote pull at the user's interval (minutes by default).
        drop(ctx.interval(settings.refresh_interval, PollPriority::Low, refresh));
    }
}

fn publish(ctx: &Context, segments: Option<state::Segments>) {
    if let Some(segments) = segments {
        ctx.status([("summary", segments.summary), ("label", segments.label)]);
    }
}

/// The feed's articles. The host performs the request (`host.fetch`): the
/// manifest's `fetch_settings` allows the configured URL and its
/// `fetch_limits` bound the response, so the plugin keeps a fully
/// network-denied sandbox. A failure says which kind without the response:
/// the host's own message can name the URL.
async fn fetch_articles(ctx: &Context, url: &Url) -> Result<Vec<feed::Article>, &'static str> {
    let xml = ctx.fetch(url.as_str()).await.map_err(|error| {
        if error.starts_with("HTTP ") {
            "HTTP error"
        } else if error.contains("allowlist") {
            "redirected to another URL"
        } else if error.contains("byte cap") {
            "feed exceeds byte limit"
        } else if error.contains("UTF-8") {
            "feed is not UTF-8"
        } else {
            "request failed"
        }
    })?;
    tokio::task::spawn_blocking(move || feed::parse(&xml, Utc::now().timestamp()))
        .await
        .map_err(|_| "feed parser failed")?
}

fn main() {
    run(Feed);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    /// The host fetches the URL the user configured, within the size the
    /// parser accepts, and the plugin opens no socket.
    #[test]
    fn the_manifest_has_the_host_fetch_the_configured_url() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        assert_eq!(
            manifest["capabilities"],
            serde_json::json!(["network_fetch"])
        );
        assert_eq!(manifest["fetch_settings"], serde_json::json!(["url"]));
        assert_eq!(manifest["fetch_limits"]["max_bytes"], feed::MAX_BYTES);
        assert!(manifest.get("fetch_urls").is_none());
    }

    #[test]
    fn the_manifest_declares_intervals_the_plugin_accepts() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let settings = &manifest["settings"];
        for name in ["refresh_interval", "cycle_interval"] {
            assert_eq!(settings[name]["min"], 1, "{name}");
            assert_eq!(settings[name]["max"], 86400, "{name}");
            assert!(
                interval(Some(settings[name]["default"].clone())).is_ok(),
                "{name}"
            );
        }
    }

    #[test]
    fn intervals_are_bounded_positive_integer_seconds() {
        assert_eq!(
            interval(Some(Value::from(1))).unwrap(),
            Duration::from_secs(1)
        );
        assert_eq!(
            interval(Some(Value::from(86400))).unwrap(),
            Duration::from_secs(86400)
        );
        assert!(interval(None).is_err(), "the host delivers the default");
        for value in [
            Value::from(0),
            Value::from(-1),
            Value::from(86401),
            Value::from("60"),
            Value::from(0.5),
        ] {
            assert!(interval(Some(value)).is_err());
        }
    }

    #[tokio::test]
    async fn unconfigured_plugin_publishes_empty_without_starting_fetch_work() {
        let mut harness = Harness::new("feed");
        Feed.on_start(harness.context()).await;
        let frames = harness.drain();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["method"], "status");
    }

    #[tokio::test]
    async fn carousel_publishes_lines_and_cycle_seconds_without_a_name() {
        let mut harness = Harness::new("feed");
        let mut state = state::State::new(Duration::from_secs(30));
        let article = feed::Article {
            title: "Title".into(),
            url: "https://aggr.example/a".into(),
            original_url: "https://www.source.example/x".into(),
            source: "source.example".into(),
            preview: String::new(),
            published_at: 100,
        };
        let segments = state.refresh(Ok(vec![article]), 101).unwrap();
        publish(&harness.context(), Some(segments));
        let frames = harness.drain();
        let summary = &frames[0]["params"]["segments"]["summary"];
        assert_eq!(summary["cycle_seconds"], 30.0);
        assert_eq!(summary["prefix"].as_str().unwrap(), "");
        let lines = summary["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 1);
        let line = lines[0].as_str().unwrap();
        assert!(line.contains("#[link=https://aggr.example/a]"));
        assert!(line.contains("(source.example)"));
        assert!(line.contains("\u{2197}"));
    }

    #[tokio::test]
    async fn label_carousel_links_the_whole_row_to_the_item_without_popup_or_arrow() {
        let mut harness = Harness::new("feed");
        let mut state = state::State::new(Duration::from_secs(30));
        let article = feed::Article {
            title: "Title".into(),
            url: "https://aggr.example/a".into(),
            original_url: "https://www.source.example/x".into(),
            source: "source.example".into(),
            preview: "A preview".into(),
            published_at: 100,
        };
        let segments = state.refresh(Ok(vec![article]), 101).unwrap();
        publish(&harness.context(), Some(segments));
        let frames = harness.drain();
        let label = &frames[0]["params"]["segments"]["label"];
        assert_eq!(label["cycle_seconds"], 30.0);
        assert_eq!(label["prefix"].as_str().unwrap(), "");
        let lines = label["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 1);
        let line = lines[0].as_str().unwrap();
        // The template owns hover; title and domain share one link to the item.
        assert!(!line.contains("#[popup="));
        assert!(!line.contains("#[fg="));
        assert!(!line.contains("\u{2197}"));
        assert!(!line.contains("#[link=https://www.source.example/x]"));
        assert_eq!(line.matches("#[link=").count(), 1);
        assert!(line.contains("#[link=https://aggr.example/a]"));
        // The visible content is still the headline and its origin domain.
        assert!(line.contains("Title"));
        assert!(line.contains("(source.example)"));
    }

    #[test]
    fn configuration_requires_explicit_safe_web_url() {
        for url in [
            "file:///tmp/feed",
            "javascript:alert(1)",
            "https://user:pass@example.com/rss",
            "http://example.com/feed.xml",
        ] {
            let harness = Harness::with_config("feed", serde_json::json!({"url": url}));
            assert!(settings(&harness.context()).is_err());
        }
        let harness = Harness::with_config(
            "feed",
            serde_json::json!({
                "url": "https://example.com/feed.xml",
                "refresh_interval": 300,
                "cycle_interval": 30,
            }),
        );
        let configured = settings(&harness.context()).unwrap().unwrap();
        assert_eq!(configured.refresh_interval, Duration::from_secs(300));
        assert_eq!(configured.cycle_interval, Duration::from_secs(30));
    }

    /// One fetch answered by the host the way `reply` says.
    async fn fetched(reply: Value) -> Result<Vec<feed::Article>, &'static str> {
        let mut harness = Harness::new("feed");
        let url = Url::parse("https://example.com/feed.xml").unwrap();
        let fetching = {
            let ctx = harness.context();
            tokio::spawn(async move { fetch_articles(&ctx, &url).await })
        };
        let (id, method, params) = harness.next_host_request().await.expect("host request");
        assert_eq!(
            (method.as_str(), params),
            (
                "host.fetch",
                serde_json::json!({ "url": "https://example.com/feed.xml" })
            )
        );
        assert!(harness.reply_host(id, reply));
        fetching.await.unwrap()
    }

    #[tokio::test]
    async fn fetch_distinguishes_authoritative_empty_from_http_parse_and_size_failure() {
        use serde_json::json;
        let empty = "<rss version=\"2.0\"><channel/></rss>";
        assert_eq!(
            fetched(json!({ "ok": true, "status": 200, "body": empty })).await,
            Ok(vec![])
        );
        for (reply, reason) in [
            (
                json!({ "ok": true, "status": 503, "body": "" }),
                "HTTP error",
            ),
            (
                json!({ "ok": false, "error": "response exceeds the host.fetch byte cap" }),
                "feed exceeds byte limit",
            ),
            (
                json!({ "ok": false, "error": "redirect not in the fetch allowlist" }),
                "redirected to another URL",
            ),
            (
                json!({ "ok": false, "error": "response is not UTF-8 text" }),
                "feed is not UTF-8",
            ),
            (
                json!({ "ok": false, "error": "Error Domain=NSURLErrorDomain Code=-1001" }),
                "request failed",
            ),
        ] {
            assert_eq!(fetched(reply).await, Err(reason));
        }
        assert!(
            fetched(json!({ "ok": true, "status": 200, "body": "oops" }))
                .await
                .is_err()
        );
    }
}

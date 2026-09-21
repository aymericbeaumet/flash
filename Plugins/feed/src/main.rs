mod feed;
mod preview;
mod state;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use flash_plugin::{run, Context, StatusSegment, StatusValue};
use reqwest::{Client, Url};
use serde_json::Value;

const FETCH_TIMEOUT: Duration = Duration::from_secs(8);

struct Settings {
    url: Url,
    label: String,
    refresh_interval: Duration,
    cycle_interval: Duration,
}

fn settings(ctx: &Context) -> Result<Option<Settings>, &'static str> {
    let Some(value) = ctx.config_json::<Value>("url") else {
        return Ok(None);
    };
    let value = value.as_str().ok_or("url must be an HTTP(S) URL string")?;
    if value.trim().is_empty() {
        return Ok(None);
    }
    let url = feed::web_url(value).ok_or("url must be an HTTP(S) URL without credentials")?;
    Ok(Some(Settings {
        url,
        label: label(ctx.config_json("label"))?,
        refresh_interval: interval(ctx.config_json("refresh_interval"), 300)?,
        cycle_interval: interval(ctx.config_json("cycle_interval"), 30)?,
    }))
}

fn label(value: Option<Value>) -> Result<String, &'static str> {
    let Some(value) = value else {
        return Ok("FEED".into());
    };
    value
        .as_str()
        .filter(|label| {
            !label.trim().is_empty()
                && label.chars().count() <= 32
                && !label.chars().any(char::is_control)
        })
        .map(str::to_owned)
        .ok_or("label must be a nonempty string of 1..32 characters without control characters")
}

fn interval(value: Option<Value>, default: u64) -> Result<Duration, &'static str> {
    let seconds = match value {
        None => default,
        Some(value) => value
            .as_u64()
            .filter(|value| (1..=86400).contains(value))
            .ok_or("refresh_interval and cycle_interval must be integer seconds in 1..86400")?,
    };
    Ok(Duration::from_secs(seconds))
}

struct Feed;

flash_plugin::plugin!(Feed);

impl FlashPlugin for Feed {
    async fn on_start(&self, ctx: Context) {
        ctx.status([("summary", StatusValue::empty())]);
        let settings = match settings(&ctx) {
            Ok(Some(settings)) => settings,
            Ok(None) => return,
            Err(error) => {
                ctx.log("warn", &format!("[feed] invalid configuration: {error}"));
                return;
            }
        };
        let client = match Client::builder()
            .timeout(FETCH_TIMEOUT)
            .connect_timeout(Duration::from_secs(4))
            .redirect(reqwest::redirect::Policy::limited(3))
            .user_agent("Flash Feed/0.1")
            .build()
        {
            Ok(client) => client,
            Err(_) => {
                ctx.log("warn", "[feed] HTTP client initialization failed");
                return;
            }
        };
        let state = Arc::new(Mutex::new(state::State::new(
            settings.label,
            settings.cycle_interval,
        )));
        let refreshed = Arc::new(tokio::sync::Notify::new());
        drop(tokio::spawn(expire_articles(
            ctx.clone(),
            Arc::clone(&state),
            Arc::clone(&refreshed),
        )));
        drop(tokio::spawn(async move {
            let mut failure_logged = false;
            loop {
                let started = Instant::now();
                let result = fetch_articles(&client, &settings.url).await;
                match &result {
                    Ok(articles) => {
                        ctx.log(
                            "info",
                            &format!(
                                "[feed] refresh outcome={} count={} elapsed_ms={}",
                                if articles.is_empty() { "empty" } else { "ok" },
                                articles.len(),
                                started.elapsed().as_millis()
                            ),
                        );
                        failure_logged = false;
                    }
                    Err(error) if !failure_logged => {
                        ctx.log(
                            "warn",
                            &format!(
                                "[feed] refresh outcome=failed reason={error} elapsed_ms={}",
                                started.elapsed().as_millis()
                            ),
                        );
                        failure_logged = true;
                    }
                    Err(_) => {}
                }
                let segment = state
                    .lock()
                    .unwrap()
                    .refresh(result.map_err(|_| ()), Utc::now().timestamp());
                publish(&ctx, segment);
                refreshed.notify_one();
                tokio::time::sleep(settings.refresh_interval).await;
            }
        }));
    }
}

/// Rotation belongs to the host; the plugin only wakes when the oldest
/// article leaves the window, so the carousel never shows a stale headline.
async fn expire_articles(
    ctx: Context,
    state: Arc<Mutex<state::State>>,
    refreshed: Arc<tokio::sync::Notify>,
) {
    loop {
        let delay = state.lock().unwrap().expires_in(Utc::now().timestamp());
        match delay {
            Some(delay) => {
                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = refreshed.notified() => continue,
                }
            }
            None => {
                refreshed.notified().await;
                continue;
            }
        }
        let segment = state.lock().unwrap().expire(Utc::now().timestamp());
        publish(&ctx, segment);
    }
}

fn publish(ctx: &Context, segment: Option<StatusSegment>) {
    if let Some(segment) = segment {
        ctx.status([("summary", segment)]);
    }
}

async fn fetch_articles(client: &Client, url: &Url) -> Result<Vec<feed::Article>, &'static str> {
    let mut response = client
        .get(url.clone())
        .header(
            reqwest::header::ACCEPT,
            "application/rss+xml, application/xml, text/xml",
        )
        .send()
        .await
        .map_err(|_| "request failed")?
        .error_for_status()
        .map_err(|_| "HTTP error")?;
    if response
        .content_length()
        .is_some_and(|length| length > feed::MAX_BYTES as u64)
    {
        return Err("feed exceeds byte limit");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "response read failed")? {
        if bytes.len().saturating_add(chunk.len()) > feed::MAX_BYTES {
            return Err("feed exceeds byte limit");
        }
        bytes.extend_from_slice(&chunk);
    }
    let xml = String::from_utf8(bytes).map_err(|_| "feed is not UTF-8")?;
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
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn intervals_have_defaults_and_require_bounded_positive_integer_seconds() {
        assert_eq!(interval(None, 300).unwrap(), Duration::from_secs(300));
        assert_eq!(
            interval(Some(Value::from(1)), 60).unwrap(),
            Duration::from_secs(1)
        );
        for value in [
            Value::from(0),
            Value::from(-1),
            Value::from(86401),
            Value::from("60"),
            Value::from(0.5),
        ] {
            assert!(interval(Some(value), 60).is_err());
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
    async fn carousel_publishes_still_prefix_lines_and_cycle_seconds_on_the_wire() {
        let mut harness = Harness::new("feed");
        let mut state = state::State::new("AGGR".into(), Duration::from_secs(30));
        let article = feed::Article {
            title: "Title".into(),
            url: "https://aggr.example/a".into(),
            original_url: "https://www.source.example/x".into(),
            preview: String::new(),
            published_at: 100,
        };
        let segment = state.refresh(Ok(vec![article]), 101).unwrap();
        harness.context().status([("summary", segment)]);
        let frames = harness.drain();
        let summary = &frames[0]["params"]["segments"]["summary"];
        assert_eq!(summary["cycle_seconds"], 30.0);
        assert!(summary["prefix"].as_str().unwrap().contains("AGGR"));
        let lines = summary["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 1);
        let line = lines[0].as_str().unwrap();
        assert!(line.contains("#[link=https://aggr.example/a]"));
        assert!(line.contains("(source.example)"));
        assert!(line.contains("↗"));
        assert!(!line.contains("AGGR"));
    }

    #[test]
    fn configuration_requires_explicit_safe_web_url() {
        for url in [
            "file:///tmp/feed",
            "javascript:alert(1)",
            "https://user:pass@example.com/rss",
        ] {
            let harness = Harness::with_config("feed", serde_json::json!({"url": url}));
            assert!(settings(&harness.context()).is_err());
        }
        let harness = Harness::with_config(
            "feed",
            serde_json::json!({"url": "https://example.com/feed.xml"}),
        );
        let configured = settings(&harness.context()).unwrap().unwrap();
        assert_eq!(configured.refresh_interval, Duration::from_secs(300));
        assert_eq!(configured.cycle_interval, Duration::from_secs(30));
        assert_eq!(configured.label, "FEED");
    }

    #[test]
    fn configuration_accepts_custom_and_unicode_labels() {
        for label in ["AGGR".to_owned(), "🦀".repeat(32), "#[bold]NEWS".to_owned()] {
            let harness = Harness::with_config(
                "feed",
                serde_json::json!({"url": "https://example.com/feed.xml", "label": label}),
            );
            assert_eq!(settings(&harness.context()).unwrap().unwrap().label, label);
        }
    }

    #[test]
    fn configuration_rejects_invalid_labels() {
        for label in [
            Value::from(""),
            Value::from("   "),
            Value::from("A".repeat(33)),
            Value::from("🦀".repeat(33)),
            Value::from("two\nlines"),
            Value::from(123),
            Value::Null,
        ] {
            let harness = Harness::with_config(
                "feed",
                serde_json::json!({"url": "https://example.com/feed.xml", "label": label}),
            );
            assert!(settings(&harness.context()).is_err());
        }
    }

    async fn serve(response: Vec<u8>) -> (Url, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/feed", listener.local_addr().unwrap())).unwrap();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).await;
            let _ = stream.write_all(&response).await;
        });
        (url, task)
    }

    #[tokio::test]
    async fn fetch_distinguishes_authoritative_empty_from_http_parse_and_size_failure() {
        let client = Client::builder()
            .timeout(Duration::from_secs(2))
            .no_proxy()
            .build()
            .unwrap();
        let body = "<rss version=\"2.0\"><channel/></rss>";
        let responses = [
            (
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                )
                .into_bytes(),
                true,
            ),
            (
                b"HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n".to_vec(),
                false,
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\noops".to_vec(),
                false,
            ),
            (
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                    feed::MAX_BYTES + 1
                )
                .into_bytes(),
                false,
            ),
            // No Content-Length: the streamed byte bound must also hold.
            (
                [
                    b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".as_slice(),
                    &vec![b' '; feed::MAX_BYTES + 1],
                ]
                .concat(),
                false,
            ),
        ];
        for (response, should_succeed) in responses {
            let (url, task) = serve(response).await;
            assert_eq!(fetch_articles(&client, &url).await.is_ok(), should_succeed);
            task.await.unwrap();
        }
    }
}

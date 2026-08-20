use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, LiveQueryRequest, LiveQueryResponse,
};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::AsyncBufReadExt;

const SOURCE_ID: &str = "plugin:files";
const SOURCE_RESULTS: &str = "files.results";
const MDFIND: &str = "/usr/bin/mdfind";

/// Internal mdfind budget. The host drops `sources.query` replies after
/// `live_query_timeout_ms` (default 1000 ms); finishing inside 900 ms leaves
/// headroom for wire + decode so a slow Spotlight never produces work the
/// host must throw away. Spotlight's first stdout byte alone routinely takes
/// 500–700 ms, which is why the live-source default budget is a full second.
const MDFIND_TIMEOUT_MS: u64 = 900;
const _: () = assert!(MDFIND_TIMEOUT_MS < 1000);
const MDFIND_TIMEOUT: Duration = Duration::from_millis(MDFIND_TIMEOUT_MS);

/// First-N-lines cap: mdfind can print tens of thousands of hits for a broad
/// name; 200 rows is far more than the flashlight ever shows and keeps the
/// reply far below the 10,000-row / 4 MiB response limits.
const MAX_RESULTS: usize = 200;
const _: () = assert!(MAX_RESULTS < 10_000);

/// Paths longer than this are dropped (URL cap host-side is 16 KiB; percent
/// encoding can triple a path's bytes).
const MAX_PATH_BYTES: usize = 4_096;

struct Files;

flash_plugin::plugin!(Files);

impl FlashPlugin for Files {
    async fn on_start(&self, ctx: Context) {
        // Live source: rows exist only per explicitly scoped query. The
        // canonical warm catalog is still required before initialize may
        // succeed, so publish an authoritative empty snapshot.
        ctx.set_locations(SOURCE_ID, Vec::new());
    }

    /// One `sources.query` pull (`@files.results <name>` or a confirmed
    /// `!f <name>`). Real work is allowed here — this never joins the warm
    /// default pool or the 150 ms first-paint barrier.
    async fn live_query(&self, ctx: Context, request: LiveQueryRequest) -> LiveQueryResponse {
        let query = request.query.trim();
        if query.is_empty() {
            return LiveQueryResponse::default();
        }
        LiveQueryResponse::candidates(search(&ctx, query).await)
    }

    /// The `!f` bang's submit path (Command-Return, or Return before any live
    /// row arrived). Selection of a live row never lands here — rows carry
    /// `file://` URLs and open natively.
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "f" => find_command(&ctx, command.query().trim()).await,
            other => CommandResponse::error(format!("unknown subcommand: {other}")),
        }
    }
}

async fn find_command(ctx: &Context, query: &str) -> CommandResponse {
    if query.is_empty() {
        return CommandResponse::error("usage: !f <name>");
    }
    let results = search(ctx, query).await;
    match results.first().and_then(Candidate::url_value) {
        // The plugin has no `open` capability (nor a LaunchServices fork in
        // its sandbox), so the submit path reports instead of opening; the
        // candidate list is the opening surface.
        Some(top) => CommandResponse::toast(format!(
            "{} file(s) match; top: {top} — pick a row to open",
            results.len()
        )),
        None => CommandResponse::toast(format!("no files match {query:?}")),
    }
}

// ---------------------------------------------------------------------------
// mdfind
// ---------------------------------------------------------------------------

/// Run `/usr/bin/mdfind -name <query>` and shape the first [`MAX_RESULTS`]
/// lines. The child is killed as soon as enough lines arrived or the internal
/// deadline expires — partial output is a valid (truncated) answer, so a slow
/// Spotlight degrades to fewer rows, never to an error.
async fn search(ctx: &Context, query: &str) -> Vec<Candidate> {
    let started_at = Instant::now();
    let mut command = tokio::process::Command::new(MDFIND);
    command
        .arg("-name")
        .arg(query)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            ctx.log(
                "warn",
                &format!(
                    "[files] mdfind spawn failed os_error={}",
                    error.raw_os_error().unwrap_or(-1)
                ),
            );
            return Vec::new();
        }
    };
    let stdout = child
        .stdout
        .take()
        .expect("mdfind stdout was configured as piped");
    let mut lines = tokio::io::BufReader::new(stdout).lines();
    let mut paths: Vec<String> = Vec::new();
    let timed_out = tokio::time::timeout(MDFIND_TIMEOUT, async {
        while paths.len() < MAX_RESULTS {
            match lines.next_line().await {
                Ok(Some(line)) if !line.trim().is_empty() => paths.push(line),
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => break,
            }
        }
    })
    .await
    .is_err();
    // Kill on expiry or early cap — never linger past the reply
    // (`kill_on_drop` backstops the error paths).
    let _ = child.start_kill();
    let _ = tokio::time::timeout(Duration::from_millis(50), child.wait()).await;
    let candidates: Vec<Candidate> = paths
        .iter()
        .filter_map(|path| candidate_for_path(path))
        .collect();
    log_search(ctx, timed_out, candidates.len(), started_at);
    candidates
}

fn log_search(ctx: &Context, timed_out: bool, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[files] mdfind query",
        BTreeMap::from([
            (
                "outcome".to_string(),
                if timed_out { "timeout_partial" } else { "ok" }.to_string(),
            ),
            ("candidates".to_string(), count.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
        ]),
    );
}

// ---------------------------------------------------------------------------
// Candidate shaping
// ---------------------------------------------------------------------------

/// One result row: title = file name, `url` = percent-encoded `file://` URL —
/// selection opens the file natively (LaunchServices, host-side), no resolver.
fn candidate_for_path(path: &str) -> Option<Candidate> {
    if !path.starts_with('/') || path.len() > MAX_PATH_BYTES {
        return None;
    }
    let name = Path::new(path).file_name()?.to_str()?;
    Some(
        Candidate::new(name)
            .url(file_url(path))
            .kind("file")
            .source_id(SOURCE_ID)
            .source(SOURCE_RESULTS)
            .subtitle(path),
    )
}

/// `file://` URL for an absolute path, percent-encoding every byte outside
/// RFC 3986 unreserved plus `/` (kept as the path separator).
fn file_url(path: &str) -> String {
    let mut url = String::with_capacity(7 + path.len());
    url.push_str("file://");
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                url.push(byte as char)
            }
            _ => {
                url.push('%');
                url.push_str(&format!("{byte:02X}"));
            }
        }
    }
    url
}

fn main() {
    run(Files);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    #[test]
    fn file_urls_percent_encode_everything_but_unreserved_and_slashes() {
        assert_eq!(
            file_url("/Users/me/My File.txt"),
            "file:///Users/me/My%20File.txt"
        );
        assert_eq!(
            file_url("/tmp/100%?#[] .md"),
            "file:///tmp/100%25%3F%23%5B%5D%20.md"
        );
        // Multi-byte UTF-8 encodes per byte.
        assert_eq!(file_url("/tmp/é"), "file:///tmp/%C3%A9");
        assert_eq!(file_url("/plain/path-2.rs"), "file:///plain/path-2.rs");
    }

    #[test]
    fn candidates_carry_name_title_file_url_and_source_labels() {
        let candidate = candidate_for_path("/Users/me/Notes/read me.md").expect("candidate");
        assert_eq!(candidate.title, "read me.md");
        assert_eq!(
            candidate.url_value(),
            Some("file:///Users/me/Notes/read%20me.md")
        );
        assert_eq!(candidate.meta("source"), Some(SOURCE_RESULTS));
        assert_eq!(candidate.meta("source_id"), Some(SOURCE_ID));
        assert_eq!(candidate.meta("kind"), Some("file"));
        assert_eq!(
            candidate.meta("subtitle"),
            Some("/Users/me/Notes/read me.md")
        );
        assert!(candidate.effect.is_none());
    }

    #[test]
    fn unshapeable_paths_are_dropped() {
        // mdfind emits absolute paths; anything else is noise.
        assert!(candidate_for_path("relative/path").is_none());
        assert!(candidate_for_path("").is_none());
        // A bare root has no file name to title the row with.
        assert!(candidate_for_path("/").is_none());
        let oversized = format!("/{}", "x".repeat(MAX_PATH_BYTES));
        assert!(candidate_for_path(&oversized).is_none());
    }

    #[tokio::test]
    async fn empty_and_whitespace_queries_answer_empty_without_spawning() {
        let harness = Harness::new("files");
        let ctx = harness.context();
        for query in ["", "   ", "\t\n"] {
            let response = Files
                .live_query(
                    ctx.clone(),
                    LiveQueryRequest {
                        scope: "all".to_string(),
                        query: query.to_string(),
                    },
                )
                .await;
            assert!(response.candidates.is_empty(), "query {query:?}");
        }
    }

    #[tokio::test]
    async fn on_start_publishes_the_authoritative_empty_live_catalog() {
        let harness = Harness::new("files");
        let ctx = harness.context();
        Files.on_start(ctx.clone()).await;
        assert!(ctx.has_locations(SOURCE_ID));
        assert!(ctx.warm_locations().is_empty());
    }

    #[tokio::test]
    async fn bang_submit_requires_a_query() {
        let harness = Harness::new("files");
        let ctx = harness.context();
        let response = find_command(&ctx, "").await;
        assert!(!response.ok);
    }
}

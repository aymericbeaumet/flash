//! GitHub plugin — `gh` CLI catalogs.
//!
//! Two warm sources refreshed together:
//!
//!   - `github.repos` — `gh repo list --limit 100 --json nameWithOwner,url`
//!   - `github.prs`   — `gh search prs --author=@me --state=open --limit 50
//!     --json title,url,repository`
//!
//! Rows carry real `https://` URLs, so selection opens natively through
//! LaunchServices — no resolver. The refresh runs in `on_start` (after the
//! initialize reply) and then every 600 s; each healthy cycle pushes one
//! full-replacement `publish` carrying both sources' rows.
//!
//! ## Degradation
//!
//! `gh` missing, or present but unauthenticated, publishes authoritative
//! empty catalogs and logs once at info — no crash, no retry spin; one
//! delayed retry is scheduled after a degraded startup (gh may still be
//! signing in / the network may still be coming up), then the 600 s interval
//! is the only cadence. Transient failures (network blip, GitHub 5xx) skip
//! the publish while any source is still unknown, so the host keeps its
//! last-good catalog.
//!
//! ## Sandbox posture (deliberate)
//!
//! `subprocess`-capability plugins spawn unsandboxed (the tmux precedent).
//! A manifest `sandbox` spec would force the deny-default seatbelt, under
//! which gh cannot work at all: network-outbound is denied without the
//! `network` capability, `~/.config/gh` is on the host's hard-coded secrets
//! deny list, and gh ≥ 2.24 stores its token in the macOS keychain by
//! default — unreachable from inside the profile (verified empirically:
//! trust evaluation needs trustd mach allowances and the keyring read still
//! 401s). Users who prefer explicit credentials can set
//! `[plugin.github] token`, forwarded to gh as `GH_TOKEN`.

use flash_plugin::process as bounded_process;
use flash_plugin::{run, Candidate, Context, RefreshGate};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::OnceCell;

const SOURCE_REPOS: &str = "github.repos";
const SOURCE_PRS: &str = "github.prs";

const REFRESH_SECONDS: u64 = 600;
/// One delayed retry after a degraded startup; afterwards only the interval.
const RETRY_DELAY: Duration = Duration::from_secs(60);
/// Per-`gh`-invocation budget: two calls run concurrently, so a slow API
/// still fits the startup budget.
const GH_TIMEOUT: Duration = Duration::from_secs(6);
const GH_STDOUT_LIMIT: usize = 4 * 1024 * 1024;
const GH_STDERR_LIMIT: usize = 64 * 1024;

const REPO_ROWS_LIMIT: usize = 100;
const PR_ROWS_LIMIT: usize = 50;
const _: () = assert!(REPO_ROWS_LIMIT + PR_ROWS_LIMIT < 10_000);
const MAX_TITLE_CHARS: usize = 256;
const MAX_URL_BYTES: usize = 2_048;

/// Standard install prefixes probed before PATH/mise/login-shell resolution.
const GH_PREFIXES: [&str; 4] = ["/opt/homebrew", "/usr/local", "/opt/local", "/usr"];

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static GH_PATH: LazyLock<OnceCell<Option<String>>> = LazyLock::new(OnceCell::new);
/// Per-source last-known rows. `publish` is a full replacement across every
/// source, so a cycle only ships once each source has a known state — a
/// transient failure before then skips the publish and the host keeps its
/// last-good catalog.
static CATALOG: Mutex<Catalog> = Mutex::new(Catalog {
    repos: None,
    prs: None,
});
/// One info-level degradation log per process, not one per cycle.
static DEGRADED_LOGGED: AtomicBool = AtomicBool::new(false);
static RETRY_SCHEDULED: AtomicBool = AtomicBool::new(false);

struct Catalog {
    repos: Option<Vec<Candidate>>,
    prs: Option<Vec<Candidate>>,
}

struct Github;

flash_plugin::plugin!(Github);

impl FlashPlugin for Github {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply, so a slow gh never delays the
        // handshake; the flashlight reads the host store meanwhile.
        if !refresh_catalogs(&ctx).await {
            schedule_single_retry(&ctx);
        }
        drop(
            ctx.interval(Duration::from_secs(REFRESH_SECONDS), |ctx| async move {
                refresh_catalogs(&ctx).await;
            }),
        );
    }
}

/// At most one delayed retry per process — a degraded gh must never turn
/// into a retry spin.
fn schedule_single_retry(ctx: &Context) {
    if RETRY_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    let ctx = ctx.clone();
    tokio::spawn(async move {
        tokio::time::sleep(RETRY_DELAY).await;
        refresh_catalogs(&ctx).await;
    });
}

// ---------------------------------------------------------------------------
// Refresh
// ---------------------------------------------------------------------------

/// One fetch's classification.
enum FetchOutcome {
    Rows(Vec<Candidate>),
    /// gh is missing or unauthenticated: rows are impossible until the user
    /// acts. Publish authoritative empty.
    Unusable(&'static str),
    /// Command or decode failure that may heal on its own: keep last-good.
    Transient,
}

/// Refresh both catalogs. Returns whether the cycle was fully healthy.
async fn refresh_catalogs(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, _running| async move {
            let started_at = Instant::now();
            let Some(gh) = resolved_gh_path().await else {
                publish_empty(&ctx);
                log_degraded_once(&ctx, "gh_missing");
                log_refresh(&ctx, "gh_missing", 0, started_at);
                return false;
            };
            let repos = fetch_repos(&ctx, &gh);
            let prs = fetch_prs(&ctx, &gh);
            let (repos, prs) = tokio::join!(repos, prs);
            let mut healthy = true;
            for (source, outcome) in [(SOURCE_REPOS, repos), (SOURCE_PRS, prs)] {
                match outcome {
                    FetchOutcome::Rows(rows) => store_rows(source, rows),
                    FetchOutcome::Unusable(reason) => {
                        healthy = false;
                        store_rows(source, Vec::new());
                        log_degraded_once(&ctx, reason);
                    }
                    // Keep the last-known rows; while a source has none the
                    // union stays unpublishable and the host keeps last-good.
                    FetchOutcome::Transient => healthy = false,
                }
            }
            let count = publish_union(&ctx);
            log_refresh(
                &ctx,
                if healthy { "ok" } else { "degraded" },
                count.unwrap_or(0),
                started_at,
            );
            healthy
        })
        .await
}

fn store_rows(source: &str, rows: Vec<Candidate>) {
    if let Ok(mut catalog) = CATALOG.lock() {
        match source {
            SOURCE_PRS => catalog.prs = Some(rows),
            _ => catalog.repos = Some(rows),
        }
    }
}

fn publish_empty(ctx: &Context) {
    store_rows(SOURCE_REPOS, Vec::new());
    store_rows(SOURCE_PRS, Vec::new());
    publish_union(ctx);
}

/// Publish the repos+prs union as one full replacement; `None` (nothing
/// sent) while any source is still unknown.
fn publish_union(ctx: &Context) -> Option<usize> {
    let rows = {
        let catalog = CATALOG.lock().ok()?;
        let (repos, prs) = (catalog.repos.as_ref()?, catalog.prs.as_ref()?);
        let mut rows = Vec::with_capacity(repos.len() + prs.len());
        rows.extend(repos.iter().cloned());
        rows.extend(prs.iter().cloned());
        rows
    };
    let count = rows.len();
    ctx.publish(rows);
    Some(count)
}

async fn fetch_repos(ctx: &Context, gh: &str) -> FetchOutcome {
    let output = run_gh(
        ctx,
        gh,
        &[
            "repo",
            "list",
            "--limit",
            "100",
            "--json",
            "nameWithOwner,url",
        ],
    )
    .await;
    classify(output, parse_repos)
}

async fn fetch_prs(ctx: &Context, gh: &str) -> FetchOutcome {
    let output = run_gh(
        ctx,
        gh,
        &[
            "search",
            "prs",
            "--author=@me",
            "--state=open",
            "--limit",
            "50",
            "--json",
            "title,url,repository",
        ],
    )
    .await;
    classify(output, parse_prs)
}

struct GhOutput {
    ok: bool,
    stdout: String,
    stderr: String,
}

fn classify(output: GhOutput, parse: fn(&str) -> Option<Vec<Candidate>>) -> FetchOutcome {
    if !output.ok {
        if stderr_is_auth_failure(&output.stderr) {
            return FetchOutcome::Unusable("gh_unauthenticated");
        }
        return FetchOutcome::Transient;
    }
    match parse(&output.stdout) {
        Some(rows) => FetchOutcome::Rows(rows),
        None => FetchOutcome::Transient,
    }
}

/// gh's authentication failures across versions: `gh auth status` phrasing,
/// API 401s, and the login hint.
fn stderr_is_auth_failure(stderr: &str) -> bool {
    let lowered = stderr.to_ascii_lowercase();
    [
        "gh auth login",
        "not logged in",
        "requires authentication",
        "authentication token",
    ]
    .iter()
    .any(|marker| lowered.contains(marker))
}

// ---------------------------------------------------------------------------
// Row shaping
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct RepoRow {
    #[serde(rename = "nameWithOwner", default)]
    name_with_owner: String,
    #[serde(default)]
    url: String,
}

#[derive(Debug, Deserialize)]
struct PrRow {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    repository: Option<PrRepo>,
}

#[derive(Debug, Deserialize)]
struct PrRepo {
    #[serde(rename = "nameWithOwner", default)]
    name_with_owner: String,
}

/// `None` on undecodable output (transient); `Some(rows)` is authoritative.
fn parse_repos(raw: &str) -> Option<Vec<Candidate>> {
    let rows: Vec<RepoRow> = serde_json::from_str(raw).ok()?;
    Some(
        rows.into_iter()
            .take(REPO_ROWS_LIMIT)
            .filter(|row| !row.name_with_owner.trim().is_empty() && acceptable_url(&row.url))
            .map(|row| {
                Candidate::new(SOURCE_REPOS, tidy(&row.name_with_owner))
                    .url(&row.url)
                    .kind("repo")
            })
            .collect(),
    )
}

fn parse_prs(raw: &str) -> Option<Vec<Candidate>> {
    let rows: Vec<PrRow> = serde_json::from_str(raw).ok()?;
    Some(
        rows.into_iter()
            .take(PR_ROWS_LIMIT)
            .filter(|row| !row.title.trim().is_empty() && acceptable_url(&row.url))
            .map(|row| {
                let mut candidate = Candidate::new(SOURCE_PRS, tidy(&row.title))
                    .url(&row.url)
                    .kind("pull_request");
                let repo = row
                    .repository
                    .map(|repo| repo.name_with_owner)
                    .unwrap_or_default();
                if !repo.trim().is_empty() {
                    candidate = candidate.subtitle(tidy(&repo));
                }
                candidate
            })
            .collect(),
    )
}

fn tidy(value: &str) -> String {
    value.trim().chars().take(MAX_TITLE_CHARS).collect()
}

/// Openable rows only: selection hands the URL to LaunchServices.
fn acceptable_url(url: &str) -> bool {
    url.starts_with("https://") && url.len() <= MAX_URL_BYTES
}

// ---------------------------------------------------------------------------
// gh invocation
// ---------------------------------------------------------------------------

/// Resolve gh once: standard prefixes, PATH, `mise which`, then the user's
/// login+interactive shell (version managers activate from rc files a GUI
/// PATH never sources). `None` sticks for the process lifetime — the host
/// restarts plugins cheaply and gh installs are rare events.
async fn resolved_gh_path() -> Option<String> {
    GH_PATH.get_or_init(find_gh).await.clone()
}

async fn find_gh() -> Option<String> {
    for prefix in GH_PREFIXES {
        let path = format!("{prefix}/bin/gh");
        if is_file(&path).await {
            return Some(path);
        }
    }
    if let Some(path) = which("gh").await {
        return Some(path);
    }
    if let Some(path) = find_gh_via_mise().await {
        return Some(path);
    }
    find_gh_via_login_shell().await
}

async fn is_file(path: &str) -> bool {
    tokio::fs::metadata(path)
        .await
        .map(|meta| meta.is_file())
        .unwrap_or(false)
}

async fn which(program: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(program);
        if let Ok(meta) = tokio::fs::metadata(&candidate).await {
            if meta.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    None
}

/// `mise which gh` — mise itself lives in a standard prefix even when the
/// tools it manages do not, and it answers from the user's global config.
async fn find_gh_via_mise() -> Option<String> {
    let mut mise = None;
    for prefix in GH_PREFIXES {
        let path = format!("{prefix}/bin/mise");
        if is_file(&path).await {
            mise = Some(path);
            break;
        }
    }
    let mise = match mise {
        Some(path) => path,
        None => which("mise").await?,
    };
    let out = capture_stdout(&mise, &["which", "gh"], Duration::from_secs(5)).await?;
    let path = out
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('/'))?;
    is_file(path).await.then(|| path.to_string())
}

async fn find_gh_via_login_shell() -> Option<String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let out = capture_stdout(&shell, &["-lic", "command -v gh"], Duration::from_secs(6)).await?;
    let path = out
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('/'))?;
    is_file(path).await.then(|| path.to_string())
}

async fn capture_stdout(program: &str, args: &[&str], timeout: Duration) -> Option<String> {
    let mut command = tokio::process::Command::new(program);
    command.args(args);
    let output = bounded_process::capture(
        &mut command,
        None,
        timeout,
        GH_STDOUT_LIMIT,
        GH_STDERR_LIMIT,
    )
    .await
    .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Run gh with the plugin's own (already scrubbed) environment — gh needs
/// the real `HOME` for `~/.config/gh` + keychain auth, which is exactly why
/// this does not go through `run_command`'s HOME-redirecting sandbox env.
/// `[plugin.github] token` (when set) rides in as `GH_TOKEN`.
async fn run_gh(ctx: &Context, gh: &str, args: &[&str]) -> GhOutput {
    let mut command = tokio::process::Command::new(gh);
    command
        .args(args)
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_PROMPT_DISABLED", "1")
        .env("NO_COLOR", "1");
    let token = ctx.config_str("token");
    if !token.trim().is_empty() {
        command.env("GH_TOKEN", token.trim());
    }
    match bounded_process::capture(
        &mut command,
        None,
        GH_TIMEOUT,
        GH_STDOUT_LIMIT,
        GH_STDERR_LIMIT,
    )
    .await
    {
        Ok(output) => GhOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        },
        Err(error) => GhOutput {
            ok: false,
            stdout: String::new(),
            stderr: error.diagnostic(),
        },
    }
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

fn log_degraded_once(ctx: &Context, reason: &str) {
    if DEGRADED_LOGGED.swap(true, Ordering::SeqCst) {
        return;
    }
    ctx.log_fields(
        "info",
        "[github] gh unavailable; publishing empty catalogs",
        BTreeMap::from([("reason".to_string(), reason.to_string())]),
    );
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[github] warm refresh",
        BTreeMap::from([
            ("outcome".to_string(), outcome.to_string()),
            ("candidates".to_string(), count.to_string()),
            (
                "elapsed_ms".to_string(),
                started_at.elapsed().as_millis().to_string(),
            ),
        ]),
    );
}

fn main() {
    run(Github);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    const REPOS_FIXTURE: &str = r#"[
      { "nameWithOwner": "aymericbeaumet/flash", "url": "https://github.com/aymericbeaumet/flash" },
      { "nameWithOwner": "aymericbeaumet/dotfiles", "url": "https://github.com/aymericbeaumet/dotfiles" },
      { "nameWithOwner": "", "url": "https://github.com/x/empty-name" },
      { "nameWithOwner": "bad/url", "url": "ftp://github.com/bad/url" }
    ]"#;

    const PRS_FIXTURE: &str = r#"[
      {
        "title": "feat(plugins): add github catalogs",
        "url": "https://github.com/aymericbeaumet/flash/pull/12",
        "repository": { "name": "flash", "nameWithOwner": "aymericbeaumet/flash" }
      },
      {
        "title": "no repository field",
        "url": "https://github.com/other/repo/pull/3"
      },
      { "title": "", "url": "https://github.com/other/repo/pull/4" }
    ]"#;

    #[test]
    fn repo_rows_shape_titles_urls_and_sources() {
        let rows = parse_repos(REPOS_FIXTURE).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "aymericbeaumet/flash");
        assert_eq!(
            rows[0].url.as_deref(),
            Some("https://github.com/aymericbeaumet/flash")
        );
        assert_eq!(rows[0].meta("kind"), Some("repo"));
        assert_eq!(rows[0].source, SOURCE_REPOS);
    }

    #[test]
    fn pr_rows_carry_the_repo_subtitle_when_present() {
        let rows = parse_prs(PRS_FIXTURE).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "feat(plugins): add github catalogs");
        assert_eq!(rows[0].meta("subtitle"), Some("aymericbeaumet/flash"));
        assert_eq!(rows[0].source, SOURCE_PRS);
        assert_eq!(rows[1].meta("subtitle"), None);
    }

    #[test]
    fn undecodable_gh_output_is_transient_not_authoritative() {
        assert!(parse_repos("gh: command crashed").is_none());
        assert!(parse_prs("{\"not\":\"a list\"}").is_none());
    }

    #[test]
    fn auth_failures_are_recognized_across_gh_phrasings() {
        assert!(stderr_is_auth_failure(
            "To get started with GitHub CLI, please run:  gh auth login"
        ));
        assert!(stderr_is_auth_failure(
            "HTTP 401: Requires authentication (https://api.github.com/graphql)"
        ));
        assert!(stderr_is_auth_failure(
            "You are not logged in to any GitHub hosts."
        ));
        assert!(!stderr_is_auth_failure(
            "dial tcp: lookup api.github.com: no such host"
        ));
        assert!(!stderr_is_auth_failure(""));
    }

    #[test]
    fn classification_routes_outcomes() {
        let ok = GhOutput {
            ok: true,
            stdout: REPOS_FIXTURE.to_string(),
            stderr: String::new(),
        };
        assert!(matches!(classify(ok, parse_repos), FetchOutcome::Rows(_)));

        let unauth = GhOutput {
            ok: false,
            stdout: String::new(),
            stderr: "please run gh auth login".to_string(),
        };
        assert!(matches!(
            classify(unauth, parse_repos),
            FetchOutcome::Unusable("gh_unauthenticated")
        ));

        let flaky = GhOutput {
            ok: false,
            stdout: String::new(),
            stderr: "connection reset by peer".to_string(),
        };
        assert!(matches!(
            classify(flaky, parse_repos),
            FetchOutcome::Transient
        ));
    }

    #[test]
    fn oversized_urls_are_rejected() {
        assert!(acceptable_url("https://github.com/a/b"));
        assert!(!acceptable_url("http://github.com/a/b"));
        assert!(!acceptable_url(&format!(
            "https://github.com/{}",
            "x".repeat(MAX_URL_BYTES)
        )));
    }

    /// One sequential test: `CATALOG` is process-global state, so the
    /// unknown-source and authoritative-empty behaviors are exercised in
    /// order instead of racing across parallel tests.
    #[tokio::test]
    async fn union_publishes_only_once_every_source_is_known() {
        let mut harness = Harness::new("github");
        let ctx = harness.context();
        if let Ok(mut catalog) = CATALOG.lock() {
            catalog.repos = Some(vec![Candidate::new(SOURCE_REPOS, "a/b")]);
            catalog.prs = None;
        }

        // While prs is unknown nothing ships — the host keeps last-good.
        assert!(publish_union(&ctx).is_none());
        assert!(harness.drain_published_rows().is_none());

        store_rows(SOURCE_PRS, Vec::new());
        assert_eq!(publish_union(&ctx), Some(1));
        assert_eq!(harness.drain_published_rows().unwrap().len(), 1);

        // A degraded gh degrades to one authoritative empty catalog.
        publish_empty(&ctx);
        let rows = harness.drain_published_rows().expect("one publish frame");
        assert!(rows.is_empty());
    }
}

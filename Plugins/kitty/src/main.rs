//! Kitty plugin — tab/window catalog + focus commands over kitty's remote
//! control CLI (`kitten @`).
//!
//! ## Shape: commands + warm catalog, deliberately NO hints provider
//!
//! `kitten @ ls` reports each OS window → tab → window (pane) with ids,
//! titles, and focus state, plus per-pane `lines`/`columns` — but no pixel
//! geometry: no window origin, no cell metrics, no pane rects. Pixel-accurate
//! hint frames are therefore not derivable from remote control, and faking
//! them is worse than not hinting (the core AX walk still covers kitty), so
//! this plugin ships the tmux-model *catalog* half only:
//!
//!   - a warm `kitty.windows` locations source (one row per kitty pane,
//!     `current_location` on the focused one),
//!   - `perform {kind: "resolve"}` via `kitten @ focus-window --match id:<id>`
//!     returning kitty's pid as `target_pid`,
//!   - `:kitty focus-tab <n>` / `:kitty focus-window <id>` commands.
//!
//! ## Degradation
//!
//! Everything degrades to authoritative-empty/no-op without kitty:
//!
//!   - kitty not running → authoritative empty catalog, no subprocess runs.
//!   - kitty running but remote control unavailable (no `allow_remote_control`
//!     in kitty.conf, or no reachable socket) → `kitten @ ls` fails and the
//!     catalog publishes authoritative empty: rows that can never resolve
//!     must not linger. Discovery retries on the next cycle.
//!
//! Socket resolution order for `kitten @`: the `[plugin.kitty] listen_on`
//! config value (`unix:/path`), then a bare invocation (covers an inherited
//! `KITTY_LISTEN_ON`), then unix sockets under the temp dirs whose name
//! contains "kitty". The first working route is cached and re-verified by
//! use; failure clears it.

use flash_plugin::{
    run, run_command, Candidate, CommandRequest, Context, Event, PerformResponse, RefreshGate,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::os::unix::fs::FileTypeExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

const SOURCE_WINDOWS: &str = "kitty.windows";
const KITTY_BUNDLE_ID: &str = "net.kovidgoyal.kitty";

/// kitty.app ships `kitten` inside the bundle; Homebrew and manual installs
/// link it under a standard prefix.
const KITTEN_APP_PATHS: [&str; 2] = [
    "/Applications/kitty.app/Contents/MacOS/kitten",
    "/opt/homebrew/bin/kitten",
];
const KITTEN_PREFIXES: [&str; 3] = ["/usr/local", "/opt/local", "/usr"];

const REFRESH_SECONDS: u64 = 15;
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
const KITTEN_TIMEOUT: Duration = Duration::from_secs(3);
/// Socket-scan bound: how many discovered candidate sockets one discovery
/// pass may probe.
const SOCKET_PROBE_LIMIT: usize = 4;
/// Row cap: interactive kitty sessions are tens of panes, not thousands.
const TOTAL_ROWS_LIMIT: usize = 500;
const _: () = assert!(TOTAL_ROWS_LIMIT < 10_000);
const MAX_TITLE_CHARS: usize = 256;

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static REFRESH_SCHEDULED: AtomicBool = AtomicBool::new(false);
/// The `--to` argument of the last successful `kitten @` invocation
/// (`None` = bare invocation worked or no route known yet).
static WORKING_SOCKET: Mutex<Option<Option<String>>> = Mutex::new(None);

// ---------------------------------------------------------------------------
// kitten @ ls JSON schema (documented shape; unknown keys are ignored)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
struct OsWindow {
    id: u64,
    #[serde(default)]
    is_focused: bool,
    #[serde(default)]
    tabs: Vec<Tab>,
}

#[derive(Clone, Debug, Deserialize)]
struct Tab {
    id: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    is_focused: bool,
    #[serde(default)]
    windows: Vec<KittyWindow>,
}

#[derive(Clone, Debug, Deserialize)]
struct KittyWindow {
    id: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    is_focused: bool,
}

/// Routing payload a row carries for resolution.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct KittyPayload {
    window_id: u64,
    tab_id: u64,
    os_window_id: u64,
}

struct Kitty;

flash_plugin::plugin!(Kitty);

impl FlashPlugin for Kitty {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply, so socket discovery never delays
        // the handshake. Every refresh outcome publishes (rows or
        // authoritative empty — unresolvable rows must not linger).
        refresh_catalog(&ctx).await;
        drop(
            ctx.interval(Duration::from_secs(REFRESH_SECONDS), |ctx| async move {
                refresh_catalog(&ctx).await;
            }),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        let relevant = match event.name.as_str() {
            "core:apps.changed" => true,
            // Focus transitions into/out of kitty bound the interesting
            // catalog changes; other apps' focus churn is noise.
            "core:focus.changed" => event.bundle_id.as_deref() == Some(KITTY_BUNDLE_ID),
            _ => false,
        };
        if relevant {
            schedule_refresh(&ctx);
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "focus-tab" => focus_tab_command(&ctx, &command.query()).await,
            "focus-window" => focus_window_command(&ctx, &command.query()).await,
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        let Some(payload) = row.payload_as::<KittyPayload>() else {
            ctx.log("warn", "[kitty] resolve row missing payload");
            return PerformResponse::unhandled();
        };
        let Some(kitty_pid) = kitty_pid(&ctx) else {
            return PerformResponse::fail("kitty is not running");
        };
        // Focusing a kitty window also focuses its tab and OS window.
        let matcher = format!("id:{}", payload.window_id);
        if run_kitten(&ctx, &["focus-window", "--match", &matcher])
            .await
            .is_none()
        {
            ctx.log("warn", "[kitty] resolve focus-window failed");
            return PerformResponse::fail("kitten focus-window failed");
        }
        PerformResponse::ok().target_pid(kitty_pid)
    }
}

fn schedule_refresh(ctx: &Context) {
    if REFRESH_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    let ctx = ctx.clone();
    tokio::spawn(async move {
        tokio::time::sleep(EVENT_DEBOUNCE).await;
        REFRESH_SCHEDULED.store(false, Ordering::SeqCst);
        refresh_catalog(&ctx).await;
    });
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async fn focus_tab_command(ctx: &Context, arg: &str) -> PerformResponse {
    let Ok(number) = arg.parse::<u64>() else {
        return PerformResponse::fail("usage: :kitty focus-tab <n> (1-based tab number)");
    };
    let Some(matcher) = tab_index_matcher(number) else {
        return PerformResponse::fail("usage: :kitty focus-tab <n> (1-based tab number)");
    };
    let Some(kitty_pid) = kitty_pid(ctx) else {
        return PerformResponse::fail("kitty is not running");
    };
    match run_kitten(ctx, &["focus-tab", "--match", &matcher]).await {
        Some(_) => PerformResponse::ok().target_pid(kitty_pid),
        None => PerformResponse::fail("kitten focus-tab failed (is allow_remote_control on?)"),
    }
}

async fn focus_window_command(ctx: &Context, arg: &str) -> PerformResponse {
    let Ok(id) = arg.parse::<u64>() else {
        return PerformResponse::fail("usage: :kitty focus-window <window-id>");
    };
    let Some(kitty_pid) = kitty_pid(ctx) else {
        return PerformResponse::fail("kitty is not running");
    };
    let matcher = format!("id:{id}");
    match run_kitten(ctx, &["focus-window", "--match", &matcher]).await {
        Some(_) => PerformResponse::ok().target_pid(kitty_pid),
        None => PerformResponse::fail("kitten focus-window failed (is allow_remote_control on?)"),
    }
}

/// kitty tab-bar numbers are 1-based; `--match index:` is 0-based.
fn tab_index_matcher(display_number: u64) -> Option<String> {
    if display_number == 0 {
        return None;
    }
    Some(format!("index:{}", display_number - 1))
}

// ---------------------------------------------------------------------------
// Catalog refresh
// ---------------------------------------------------------------------------

/// Refresh always ends in a publication: rows when `kitten @ ls` works,
/// authoritative empty when kitty is absent or remote control is
/// unreachable (unresolvable rows must not linger).
async fn refresh_catalog(ctx: &Context) {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            let started_at = Instant::now();
            let kitty_pid = running
                .iter()
                .find(|app| app.bundle_id == KITTY_BUNDLE_ID)
                .map(|app| app.pid);
            let Some(kitty_pid) = kitty_pid else {
                publish_empty(&ctx);
                log_refresh(&ctx, "kitty_absent", 0, started_at);
                return;
            };
            let Some(raw) = run_kitten(&ctx, &["ls"]).await else {
                publish_empty(&ctx);
                log_refresh(&ctx, "remote_control_unavailable", 0, started_at);
                return;
            };
            let Some(os_windows) = parse_ls(&raw) else {
                publish_empty(&ctx);
                log_refresh(&ctx, "unparsable", 0, started_at);
                return;
            };
            let candidates = build_candidates(&os_windows, kitty_pid);
            let count = candidates.len();
            ctx.publish(candidates);
            log_refresh(
                &ctx,
                if count == 0 { "empty" } else { "ok" },
                count,
                started_at,
            );
        })
        .await
}

fn publish_empty(ctx: &Context) {
    ctx.publish(Vec::new());
}

fn parse_ls(raw: &str) -> Option<Vec<OsWindow>> {
    serde_json::from_str(raw).ok()
}

fn build_candidates(os_windows: &[OsWindow], kitty_pid: i64) -> Vec<Candidate> {
    let mut out = Vec::new();
    for os_window in os_windows {
        for tab in &os_window.tabs {
            for window in &tab.windows {
                if out.len() >= TOTAL_ROWS_LIMIT {
                    return out;
                }
                out.push(candidate_for_window(os_window, tab, window, kitty_pid));
            }
        }
    }
    out
}

fn candidate_for_window(
    os_window: &OsWindow,
    tab: &Tab,
    window: &KittyWindow,
    kitty_pid: i64,
) -> Candidate {
    let window_title = tidy(&window.title);
    let tab_title = tidy(&tab.title);
    let primary = if window_title.is_empty() && tab_title.is_empty() {
        format!("kitty window {}", window.id)
    } else if window_title.is_empty() {
        format!("kitty · {tab_title}")
    } else {
        format!("kitty · {window_title}")
    };
    let subtitle = if tab_title.is_empty() {
        format!("tab {}", tab.id)
    } else {
        format!("tab · {tab_title}")
    };
    let focused = os_window.is_focused && tab.is_focused && window.is_focused;
    Candidate::new(SOURCE_WINDOWS, primary)
        .kind("kitty_window")
        .location()
        .subtitle(subtitle)
        .aliases(["kitty"])
        .pid(kitty_pid)
        .current_location(focused)
        .payload_json(&KittyPayload {
            window_id: window.id,
            tab_id: tab.id,
            os_window_id: os_window.id,
        })
}

fn tidy(title: &str) -> String {
    title.trim().chars().take(MAX_TITLE_CHARS).collect()
}

fn kitty_pid(ctx: &Context) -> Option<i64> {
    ctx.running_applications()
        .into_iter()
        .find(|app| app.bundle_id == KITTY_BUNDLE_ID)
        .map(|app| app.pid)
}

// ---------------------------------------------------------------------------
// kitten invocation
// ---------------------------------------------------------------------------

async fn find_kitten() -> Option<String> {
    for path in KITTEN_APP_PATHS {
        if is_file(path).await {
            return Some(path.to_string());
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let user_app = std::path::PathBuf::from(home)
            .join("Applications")
            .join("kitty.app")
            .join("Contents")
            .join("MacOS")
            .join("kitten");
        if let Some(path) = user_app.to_str() {
            if is_file(path).await {
                return Some(path.to_string());
            }
        }
    }
    for prefix in KITTEN_PREFIXES {
        let path = format!("{prefix}/bin/kitten");
        if is_file(&path).await {
            return Some(path);
        }
    }
    which("kitten").await
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

/// `kitten @ [--to <socket>] <args…>`.
fn kitten_argv(kitten: &str, to: Option<&str>, args: &[&str]) -> Vec<String> {
    let mut argv = vec![kitten.to_string(), "@".to_string()];
    if let Some(to) = to {
        argv.push("--to".to_string());
        argv.push(to.to_string());
    }
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

/// Candidate `--to` routes, most explicit first: configured `listen_on`,
/// bare (env-derived), then temp-dir sockets whose name contains "kitty".
async fn candidate_sockets(ctx: &Context) -> Vec<Option<String>> {
    let mut routes: Vec<Option<String>> = Vec::new();
    let configured = ctx.config_str("listen_on");
    if !configured.trim().is_empty() {
        routes.push(Some(configured.trim().to_string()));
    }
    routes.push(None);
    let mut roots: Vec<std::path::PathBuf> = vec!["/tmp".into(), "/private/tmp".into()];
    if let Some(tmpdir) = std::env::var_os("TMPDIR") {
        roots.push(tmpdir.into());
    }
    let mut discovered = Vec::new();
    for root in roots {
        let Ok(mut entries) = tokio::fs::read_dir(&root).await else {
            continue;
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            if discovered.len() >= SOCKET_PROBE_LIMIT {
                break;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy().into_owned();
            if !name.contains("kitty") {
                continue;
            }
            let Ok(file_type) = entry.file_type().await else {
                continue;
            };
            if file_type.is_socket() {
                discovered.push(format!("unix:{}", entry.path().to_string_lossy()));
            }
        }
    }
    discovered.sort();
    discovered.dedup();
    routes.extend(discovered.into_iter().map(Some));
    routes
}

/// Run a `kitten @` subcommand, trying the cached route first and falling
/// back to discovery. `None` means every route failed (kitten missing, no
/// socket, or remote control disabled).
async fn run_kitten(ctx: &Context, args: &[&str]) -> Option<String> {
    let kitten = find_kitten().await?;
    let cached = WORKING_SOCKET.lock().ok().and_then(|slot| slot.clone());
    if let Some(route) = cached {
        let argv = kitten_argv(&kitten, route.as_deref(), args);
        let output = run_command(ctx, &argv, KITTEN_TIMEOUT).await;
        if output.ok {
            return Some(output.stdout);
        }
        // The cached route went stale (kitty restarted, socket re-created):
        // clear it and rediscover below.
        if let Ok(mut slot) = WORKING_SOCKET.lock() {
            *slot = None;
        }
    }
    for route in candidate_sockets(ctx).await {
        let argv = kitten_argv(&kitten, route.as_deref(), args);
        let output = run_command(ctx, &argv, KITTEN_TIMEOUT).await;
        if output.ok {
            if let Ok(mut slot) = WORKING_SOCKET.lock() {
                *slot = Some(route);
            }
            return Some(output.stdout);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[kitty] warm refresh",
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
    run(Kitty);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;
    use flash_plugin::RunningApplication;

    /// Canned `kitten @ ls` output following kitty's documented schema:
    /// os_windows[].tabs[].windows[] with id/title/is_focused, plus fields
    /// the plugin must ignore (pid, cwd, lines, columns, is_active, …).
    const LS_FIXTURE: &str = r#"[
      {
        "id": 1,
        "is_focused": true,
        "is_active": true,
        "platform_window_id": 12345,
        "last_focused": true,
        "wm_class": "kitty",
        "tabs": [
          {
            "id": 10,
            "index": 0,
            "title": "~/code",
            "is_focused": true,
            "is_active": true,
            "layout": "splits",
            "windows": [
              {
                "id": 100,
                "title": "nvim main.rs",
                "is_focused": true,
                "is_active": true,
                "pid": 4242,
                "cwd": "/Users/me/code",
                "cmdline": ["/bin/zsh"],
                "env": {},
                "foreground_processes": [],
                "is_self": false,
                "lines": 48,
                "columns": 180
              },
              {
                "id": 101,
                "title": "cargo watch",
                "is_focused": false,
                "is_active": false,
                "pid": 4243,
                "lines": 48,
                "columns": 60
              }
            ]
          },
          {
            "id": 11,
            "index": 1,
            "title": "logs",
            "is_focused": false,
            "is_active": false,
            "layout": "stack",
            "windows": [
              { "id": 102, "title": "", "is_focused": false, "is_active": false }
            ]
          }
        ]
      },
      {
        "id": 2,
        "is_focused": false,
        "tabs": [
          {
            "id": 20,
            "title": "scratch",
            "is_focused": true,
            "windows": [
              { "id": 200, "title": "htop", "is_focused": true }
            ]
          }
        ]
      }
    ]"#;

    #[test]
    fn fixture_parses_into_the_documented_tree() {
        let os_windows = parse_ls(LS_FIXTURE).expect("fixture must parse");
        assert_eq!(os_windows.len(), 2);
        assert_eq!(os_windows[0].tabs.len(), 2);
        assert_eq!(os_windows[0].tabs[0].windows.len(), 2);
        assert!(os_windows[0].is_focused);
        assert!(!os_windows[1].is_focused);
        assert_eq!(os_windows[1].tabs[0].windows[0].id, 200);
    }

    #[test]
    fn malformed_ls_output_is_rejected_not_panicked_on() {
        assert!(parse_ls("").is_none());
        assert!(parse_ls("could not connect to socket").is_none());
        assert!(parse_ls(r#"{"not": "a list"}"#).is_none());
    }

    #[test]
    fn candidates_carry_titles_payloads_and_the_focused_marker() {
        let os_windows = parse_ls(LS_FIXTURE).unwrap();
        let candidates = build_candidates(&os_windows, 777);
        assert_eq!(candidates.len(), 4);

        let first = &candidates[0];
        assert_eq!(first.title, "kitty · nvim main.rs");
        assert_eq!(first.meta("subtitle"), Some("tab · ~/code"));
        assert_eq!(first.meta("kind"), Some("kitty_window"));
        assert_eq!(first.meta("entity"), Some("location"));
        assert_eq!(first.source, SOURCE_WINDOWS);
        assert_eq!(first.pid_value(), Some(777));
        assert_eq!(first.meta("current_location"), Some("1"));
        let payload = first.payload_as::<KittyPayload>().unwrap();
        assert_eq!(
            (payload.window_id, payload.tab_id, payload.os_window_id),
            (100, 10, 1)
        );

        // Only the focused window of the focused tab of the focused OS window
        // is current.
        assert!(candidates[1..]
            .iter()
            .all(|candidate| candidate.meta("current_location").is_none()));

        // Untitled windows fall back to the tab title; the second OS window's
        // rows resolve through their own ids.
        assert_eq!(candidates[2].title, "kitty · logs");
        assert_eq!(candidates[3].title, "kitty · htop");
        assert_eq!(
            candidates[3]
                .payload_as::<KittyPayload>()
                .unwrap()
                .window_id,
            200
        );
    }

    #[test]
    fn kitten_argv_inserts_the_socket_route_before_the_subcommand() {
        assert_eq!(
            kitten_argv("/usr/bin/env-kitten", None, &["ls"]),
            vec!["/usr/bin/env-kitten", "@", "ls"]
        );
        assert_eq!(
            kitten_argv(
                "/a/kitten",
                Some("unix:/tmp/kitty-1"),
                &["focus-window", "--match", "id:7"],
            ),
            vec![
                "/a/kitten",
                "@",
                "--to",
                "unix:/tmp/kitty-1",
                "focus-window",
                "--match",
                "id:7"
            ]
        );
    }

    #[test]
    fn tab_matchers_translate_one_based_display_numbers() {
        assert_eq!(tab_index_matcher(1), Some("index:0".to_string()));
        assert_eq!(tab_index_matcher(4), Some("index:3".to_string()));
        assert_eq!(tab_index_matcher(0), None);
    }

    #[tokio::test]
    async fn refresh_without_kitty_publishes_an_authoritative_empty_catalog() {
        let mut harness = Harness::new("kitty");
        let ctx = harness.context();
        harness.set_running_applications(vec![RunningApplication {
            bundle_id: "com.apple.Safari".to_string(),
            pid: 41,
            localized_name: "Safari".to_string(),
        }]);

        refresh_catalog(&ctx).await;

        let rows = harness.drain_published_rows().expect("one publish frame");
        assert!(rows.is_empty());
    }
}

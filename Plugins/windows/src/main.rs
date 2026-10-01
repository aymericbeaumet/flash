//! Windows plugin — cross-app window switcher rows (`@windows`).
//!
//! ## Warm-catalog contract
//!
//! The catalog is one row per AX window of every regular running app. Each
//! refresh walks `ctx.running_applications()` and asks the host's AX broker
//! (`host.ax_snapshot`, `roots: "windows"`, no child descent) for that app's
//! window titles. The refresh runs:
//!
//!   1. in `on_start` (after the initialize reply, so a wedged AX broker
//!      never delays the handshake; a failed cycle publishes nothing and the
//!      host keeps its last-good catalog),
//!   2. debounced/coalesced on `core:apps.changed` /
//!      `core:window.focus.changed` / `core:focus.changed` (the SDK event
//!      queue is bounded, so a focus storm collapses into one refresh),
//!   3. for an app whose window was retitled, created or destroyed
//!      (`core:ax.changed` naming `AXTitleChanged`, `AXWindowCreated` or
//!      `AXUIElementDestroyed`), once that burst settles; value, selection,
//!      layout and geometry changes — every keystroke among them — cannot
//!      change a window row and are ignored, and
//!   4. as a whole sweep when the flashlight opens (`core:session.opened`),
//!      at most once per [`SWEEP_TTL`]: the host observes AX only in the
//!      focused app, so this is when a background app's retitled windows
//!      catch up.
//!
//! Nothing polls.
//!
//! Each refresh pushes a full-replacement `publish`; the flashlight reads
//! host memory — no AX I/O on the hot path.
//!
//! ## Resolution
//!
//! AX handles are broker-owned and purged per `(owner, pid)` on every fresh
//! snapshot, so rows never carry handles. `on_resolve` re-snapshots the app,
//! finds the window by exact title (index fallback), performs `AXRaise` +
//! `AXMain`/`AXFocused` on it, activates the app, and returns `target_pid`
//! so movement history records the jump. A vanished window degrades to plain
//! app activation.

use flash_plugin::{
    Candidate, Context, Event, PerformResponse, PollPriority, RefreshGate, Settle,
    ax_notifications, run,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

const SOURCE_ITEMS: &str = "windows.items";

/// A flashlight open re-walks every app only when the last sweep is older
/// than this, so reopening it does not queue AX work behind itself.
const SWEEP_TTL: Duration = Duration::from_secs(60);
/// The AX notifications that can change an app's window rows. Focus moves
/// arrive as their own events.
const AX_REFRESH_NOTIFICATIONS: [&str; 3] = [
    ax_notifications::TITLE_CHANGED,
    ax_notifications::WINDOW_CREATED,
    ax_notifications::UI_ELEMENT_DESTROYED,
];
/// Closing a window destroys its whole subtree and a load retitles a window
/// several times, so re-snapshot an app once those notifications have been
/// quiet this long…
const AX_SETTLE: Duration = Duration::from_millis(300);
/// …or this long after its burst began, whichever comes first.
const AX_MAX_WAIT: Duration = Duration::from_secs(10);
/// Event bursts (an app launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
/// A full sweep walks up to `APPS_PER_REFRESH_LIMIT` apps through the host's
/// single AX broker queue, so `apps.changed` bursts coalesce more coarsely.
const FULL_REFRESH_DEBOUNCE: Duration = Duration::from_secs(1);
/// Per-`host.ax_snapshot` RPC deadline. One wedged app must not consume the
/// whole refresh budget.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(2);

/// Row caps. ~300 rows is far beyond what the flashlight shows and keeps the
/// catalog far below the host's 10,000-row / 4 MiB quotas.
const TOTAL_ROWS_LIMIT: usize = 300;
const _: () = assert!(TOTAL_ROWS_LIMIT < 10_000);
/// Apps walked per refresh (running_applications order, i.e. host order).
const APPS_PER_REFRESH_LIMIT: usize = 60;
/// Broker node cap per app: with no child descent every node is a window.
const WINDOWS_PER_APP_LIMIT: usize = 20;
const _: () = assert!(APPS_PER_REFRESH_LIMIT * WINDOWS_PER_APP_LIMIT < 10_000);
const MAX_TITLE_CHARS: usize = 256;

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// One pending coalesced whole refresh: the first event opens a
/// `FULL_REFRESH_DEBOUNCE` window the rest join. `Normal` on every settle
/// here: the window catalog feeds the flashlight, which nobody watches
/// refresh.
static FULL_BURST: Settle<()> = Settle::new(
    FULL_REFRESH_DEBOUNCE,
    FULL_REFRESH_DEBOUNCE,
    PollPriority::Normal,
);
/// The per-app refresh: focus events name their apps inside one
/// `EVENT_DEBOUNCE` window.
static FOCUS_BURST: Settle<i64> = Settle::new(EVENT_DEBOUNCE, EVENT_DEBOUNCE, PollPriority::Normal);
/// Pending `core:ax.changed` burst and the apps it named.
static AX_BURST: Settle<i64> = Settle::new(AX_SETTLE, AX_MAX_WAIT, PollPriority::Normal);
/// When the last whole sweep began.
static LAST_SWEEP: Mutex<Option<Instant>> = Mutex::new(None);
/// Last-good rows per app. A focus or AX event re-snapshots only its own app
/// and republishes the rest from here; a whole sweep rebuilds it.
static ROWS_BY_PID: LazyLock<Mutex<BTreeMap<i64, Vec<Candidate>>>> =
    LazyLock::new(|| Mutex::new(BTreeMap::new()));

/// One flat node from a `host.ax_snapshot` reply.
#[derive(Clone, Debug, Deserialize)]
struct AxNode {
    handle: u64,
    #[serde(default)]
    attrs: HashMap<String, String>,
}

impl AxNode {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

/// One window row before candidate shaping.
#[derive(Clone, Debug, PartialEq)]
struct WindowRow {
    title: String,
    index: usize,
}

struct Windows;

flash_plugin::plugin!(Windows);

impl FlashPlugin for Windows {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply; a failed first cycle publishes
        // nothing (the host keeps last-good) and retries in the background.
        if !refresh_catalog(&ctx).await {
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_catalog(&retry_ctx).await;
            });
        }
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            // A focus change names one app: re-snapshot that app alone instead
            // of walking every running app through the AX broker.
            "core:window.focus.changed" | "core:focus.changed" => match event.pid {
                Some(pid) if pid > 0 => schedule_app_refresh(&ctx, pid),
                _ => schedule_refresh(&ctx),
            },
            "core:ax.changed" if event.is_ax_change(&AX_REFRESH_NOTIFICATIONS) => {
                if let Some(pid) = event.pid.filter(|pid| *pid > 0) {
                    schedule_ax_refresh(&ctx, pid);
                }
            }
            "core:apps.changed" => schedule_refresh(&ctx),
            "core:session.opened" if claim_sweep(Instant::now()) => {
                tokio::spawn(async move {
                    refresh_catalog(&ctx).await;
                });
            }
            _ => {}
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }
}

/// Coalesce event bursts: the first event schedules a refresh
/// [`FULL_REFRESH_DEBOUNCE`] out; followers piggyback on it.
fn schedule_refresh(ctx: &Context) {
    let refresh_ctx = ctx.clone();
    FULL_BURST.schedule(ctx, (), move |_| async move {
        refresh_catalog(&refresh_ctx).await;
    });
}

/// Coalesce focus events into one pass over the apps they named.
fn schedule_app_refresh(ctx: &Context, pid: i64) {
    let refresh_ctx = ctx.clone();
    FOCUS_BURST.schedule(ctx, pid, move |pids| async move {
        refresh_apps(&refresh_ctx, pids.into_iter().collect()).await;
    });
}

/// Re-snapshot the app once its AX burst settles.
fn schedule_ax_refresh(ctx: &Context, pid: i64) {
    let refresh_ctx = ctx.clone();
    AX_BURST.schedule(ctx, pid, move |pids| async move {
        refresh_apps(&refresh_ctx, pids.into_iter().collect()).await;
    });
}

/// Whether a flashlight open is due a whole sweep: none has begun within
/// [`SWEEP_TTL`].
fn sweep_due(last: Option<Instant>, now: Instant) -> bool {
    last.is_none_or(|last| now.saturating_duration_since(last) >= SWEEP_TTL)
}

/// Record a sweep beginning at `now` when one is due.
fn claim_sweep(now: Instant) -> bool {
    let mut last = LAST_SWEEP.lock().unwrap_or_else(|e| e.into_inner());
    let due = sweep_due(*last, now);
    if due {
        *last = Some(now);
    }
    due
}

/// Re-snapshot the named apps and republish the catalog from the last-good
/// rows of every other app. An app that is no longer running drops out.
async fn refresh_apps(ctx: &Context, pids: Vec<i64>) {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            let started_at = Instant::now();
            for pid in pids {
                let Some(app) = running.iter().find(|app| app.pid == pid) else {
                    ROWS_BY_PID
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&pid);
                    continue;
                };
                if let Some(rows) = window_rows(&ctx, pid).await {
                    let app_label = app_label(app);
                    let candidates = rows
                        .iter()
                        .map(|row| candidate(&app_label, pid, row))
                        .collect();
                    ROWS_BY_PID
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .insert(pid, candidates);
                }
            }
            let count = publish_rows(&ctx);
            log_refresh(
                &ctx,
                if count == 0 { "empty" } else { "ok" },
                count,
                started_at,
            );
        })
        .await
}

/// Publish every retained app's rows, in pid order, under the row cap.
fn publish_rows(ctx: &Context) -> usize {
    let rows: Vec<Candidate> = ROWS_BY_PID
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .values()
        .flat_map(|rows| rows.iter().cloned())
        .take(TOTAL_ROWS_LIMIT)
        .collect();
    let count = rows.len();
    ctx.publish(rows);
    count
}

// ---------------------------------------------------------------------------
// Catalog refresh
// ---------------------------------------------------------------------------

/// Rebuild and publish the window catalog. Returns whether a snapshot was
/// published this cycle. Per-app snapshots run sequentially — the AX broker
/// serializes on one host queue anyway, and each windows-only walk is tiny —
/// with a hard per-call timeout so one wedged app cannot stall the cycle.
async fn refresh_catalog(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            let started_at = Instant::now();
            *LAST_SWEEP.lock().unwrap_or_else(|e| e.into_inner()) = Some(started_at);
            let mut by_pid: BTreeMap<i64, Vec<Candidate>> = BTreeMap::new();
            let mut total = 0usize;
            let mut snapshot_failures = 0usize;
            let mut apps_walked = 0usize;
            for app in running.iter().take(APPS_PER_REFRESH_LIMIT) {
                if app.pid <= 0 {
                    continue;
                }
                if total >= TOTAL_ROWS_LIMIT {
                    break;
                }
                apps_walked += 1;
                match window_rows(&ctx, app.pid).await {
                    Some(rows) => {
                        let app_label = app_label(app);
                        let candidates: Vec<Candidate> = rows
                            .iter()
                            .take(TOTAL_ROWS_LIMIT - total)
                            .map(|row| candidate(&app_label, app.pid, row))
                            .collect();
                        total += candidates.len();
                        by_pid.insert(app.pid, candidates);
                    }
                    None => snapshot_failures += 1,
                }
            }
            // Every app failing (with apps present) means the broker itself is
            // unhealthy (AX grant missing, host busy): keep the last-good
            // snapshot instead of flapping to empty. Partial failure is normal
            // (some apps expose no AX tree) and the partial result is
            // authoritative.
            if apps_walked > 0 && snapshot_failures == apps_walked {
                log_refresh(&ctx, "failed", 0, started_at);
                return false;
            }
            *ROWS_BY_PID.lock().unwrap_or_else(|e| e.into_inner()) = by_pid;
            let count = publish_rows(&ctx);
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

/// Snapshot one app's windows: titles only, no child descent, no geometry.
/// `None` means the broker call failed (transient); `Some(vec)` is
/// authoritative for this app, including an empty list.
async fn window_rows(ctx: &Context, pid: i64) -> Option<Vec<WindowRow>> {
    let value = ctx
        .ax_snapshot_timeout(
            json!({
                "pid": pid,
                "roots": "windows",
                // A nonexistent child attribute: the walk stays on the window
                // roots themselves, so every returned node is one window.
                "follow": ["AXFlashNoChildren"],
                "collect": ["AXRole", "AXTitle"],
                "max_nodes": WINDOWS_PER_APP_LIMIT,
                "geometry": false,
            }),
            SNAPSHOT_TIMEOUT,
        )
        .await;
    let nodes = ax_nodes(&value)?;
    Some(rows_from_nodes(&nodes))
}

/// Decode a broker reply; `None` when the call failed outright.
fn ax_nodes(value: &Value) -> Option<Vec<AxNode>> {
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    value
        .get("nodes")
        .cloned()
        .map(|nodes| serde_json::from_value(nodes).unwrap_or_default())
}

/// Keep titled windows only. Untitled AX windows are palettes, sheets, and
/// helper surfaces the user cannot meaningfully jump to by name.
fn rows_from_nodes(nodes: &[AxNode]) -> Vec<WindowRow> {
    nodes
        .iter()
        .enumerate()
        .filter(|(_, node)| {
            node.attr("AXRole")
                .map(|role| role == "AXWindow")
                .unwrap_or(true)
        })
        .filter_map(|(index, node)| {
            let title = node.attr("AXTitle")?.trim();
            if title.is_empty() {
                return None;
            }
            Some(WindowRow {
                title: title.chars().take(MAX_TITLE_CHARS).collect(),
                index,
            })
        })
        .collect()
}

fn app_label(app: &flash_plugin::RunningApplication) -> String {
    let name = app.localized_name.trim();
    if name.is_empty() {
        app.bundle_id.clone()
    } else {
        name.to_string()
    }
}

/// One row: `title = "AppName — WindowTitle"`. The raw window title and its
/// snapshot index ride metadata for re-resolution; handles never do (the
/// broker purges them per (owner, pid) on every fresh snapshot).
fn candidate(app_label: &str, pid: i64, row: &WindowRow) -> Candidate {
    Candidate::new(SOURCE_ITEMS, format!("{app_label} — {}", row.title))
        .kind("window")
        .subtitle(app_label)
        .pid(pid)
        .metadata("window_title", &row.title)
        .metadata("window_index", row.index.to_string())
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// Pick the window to raise from a fresh snapshot: exact title match first
/// (the stable identity), then the remembered index (same position after a
/// title change), else nothing.
fn pick_window(rows: &[(u64, WindowRow)], title: &str, index: Option<usize>) -> Option<u64> {
    if let Some((handle, _)) = rows.iter().find(|(_, row)| row.title == title) {
        return Some(*handle);
    }
    index.and_then(|index| {
        rows.iter()
            .find(|(_, row)| row.index == index)
            .map(|(handle, _)| *handle)
    })
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        ctx.log("warn", "[windows] resolve row missing pid");
        return PerformResponse::unhandled();
    };
    let title = row.meta("window_title").unwrap_or_default();
    let index = row
        .meta("window_index")
        .and_then(|raw| raw.parse::<usize>().ok());

    // Re-snapshot at resolve time: broker handles are owner-scoped and were
    // purged the moment any later snapshot of this app ran.
    let value = ctx
        .ax_snapshot_timeout(
            json!({
                "pid": pid,
                "roots": "windows",
                "follow": ["AXFlashNoChildren"],
                "collect": ["AXRole", "AXTitle"],
                "max_nodes": WINDOWS_PER_APP_LIMIT,
                "geometry": false,
            }),
            SNAPSHOT_TIMEOUT,
        )
        .await;
    let handle = ax_nodes(&value).and_then(|nodes| {
        let rows: Vec<(u64, WindowRow)> = nodes
            .iter()
            .map(|node| node.handle)
            .zip(rows_with_all_indices(&nodes))
            .collect();
        pick_window(&rows, title, index)
    });

    let raised = match handle {
        Some(handle) => {
            // One concurrent host wave: activate the app and raise/focus the
            // exact window (mirrors the tmux plugin's raise path).
            let (activated, raised, main, focused) = tokio::join!(
                ctx.activate(pid),
                ctx.ax_perform(handle, "AXRaise"),
                ctx.ax_set(handle, "AXMain", true),
                ctx.ax_set(handle, "AXFocused", true),
            );
            activated && (raised || main || focused)
        }
        None => false,
    };
    if !raised {
        // The window vanished (or the broker degraded): activating the app is
        // still the right jump, and target_pid still records it in movement
        // history.
        if !ctx.activate(pid).await {
            ctx.log("warn", "[windows] resolve host.activate failed");
            return PerformResponse::fail("window activation failed");
        }
    }
    PerformResponse::ok().target_pid(pid)
}

/// Row list aligned 1:1 with `nodes` (unlike [`rows_from_nodes`], which
/// filters) so handles zip against positions faithfully.
fn rows_with_all_indices(nodes: &[AxNode]) -> Vec<WindowRow> {
    nodes
        .iter()
        .enumerate()
        .map(|(index, node)| WindowRow {
            title: node.attr("AXTitle").unwrap_or_default().trim().to_string(),
            index,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    ctx.log_fields(
        "debug",
        "[windows] warm refresh",
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
    run(Windows);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn broker_reply(nodes: serde_json::Value) -> Value {
        json!({ "ok": true, "nodes": nodes })
    }

    #[test]
    fn failed_broker_replies_decode_to_none() {
        assert!(ax_nodes(&json!({ "ok": false, "error": "no ax" })).is_none());
        assert!(ax_nodes(&json!({})).is_none());
        assert!(ax_nodes(&broker_reply(json!([]))).unwrap().is_empty());
    }

    #[test]
    fn rows_keep_titled_windows_and_drop_helper_surfaces() {
        let nodes: Vec<AxNode> = serde_json::from_value(json!([
            { "handle": 1, "attrs": { "AXRole": "AXWindow", "AXTitle": "main.rs — flash" } },
            { "handle": 2, "attrs": { "AXRole": "AXWindow", "AXTitle": "   " } },
            { "handle": 3, "attrs": { "AXRole": "AXWindow" } },
            { "handle": 4, "attrs": { "AXRole": "AXPopover", "AXTitle": "Completions" } },
            { "handle": 5, "attrs": { "AXTitle": "Untyped role window" } },
        ]))
        .unwrap();
        let rows = rows_from_nodes(&nodes);
        assert_eq!(
            rows,
            vec![
                WindowRow {
                    title: "main.rs — flash".to_string(),
                    index: 0,
                },
                WindowRow {
                    title: "Untyped role window".to_string(),
                    index: 4,
                },
            ]
        );
    }

    #[test]
    fn titles_are_length_capped() {
        let nodes: Vec<AxNode> = serde_json::from_value(json!([
            { "handle": 1, "attrs": { "AXRole": "AXWindow", "AXTitle": "x".repeat(MAX_TITLE_CHARS + 50) } },
        ]))
        .unwrap();
        let rows = rows_from_nodes(&nodes);
        assert_eq!(rows[0].title.chars().count(), MAX_TITLE_CHARS);
    }

    #[test]
    fn candidates_carry_app_prefix_pid_and_reresolution_metadata() {
        let row = WindowRow {
            title: "Inbox".to_string(),
            index: 2,
        };
        let candidate = candidate("Mail", 421, &row);
        assert_eq!(candidate.title, "Mail — Inbox");
        assert_eq!(candidate.meta("kind"), Some("window"));
        assert_eq!(candidate.source, SOURCE_ITEMS);
        assert_eq!(candidate.pid_value(), Some(421));
        assert_eq!(candidate.meta("window_title"), Some("Inbox"));
        assert_eq!(candidate.meta("window_index"), Some("2"));
        assert!(candidate.url.is_none());
    }

    #[test]
    fn app_label_falls_back_to_the_bundle_id() {
        let app = flash_plugin::RunningApplication {
            bundle_id: "com.example.app".to_string(),
            pid: 7,
            localized_name: "  ".to_string(),
        };
        assert_eq!(app_label(&app), "com.example.app");
    }

    #[test]
    fn pick_window_prefers_exact_title_then_index_then_gives_up() {
        let rows = vec![
            (
                10,
                WindowRow {
                    title: "A".to_string(),
                    index: 0,
                },
            ),
            (
                11,
                WindowRow {
                    title: "B".to_string(),
                    index: 1,
                },
            ),
        ];
        assert_eq!(pick_window(&rows, "B", Some(0)), Some(11));
        assert_eq!(pick_window(&rows, "gone", Some(1)), Some(11));
        assert_eq!(pick_window(&rows, "gone", Some(9)), None);
        assert_eq!(pick_window(&rows, "gone", None), None);
    }

    fn polls(frames: &[Value]) -> Vec<&Value> {
        frames
            .iter()
            .filter(|frame| frame["method"] == "poll")
            .collect()
    }

    /// Events drive every refresh: startup registers no cadence.
    #[tokio::test]
    async fn startup_registers_no_cadence() {
        let mut harness = flash_plugin::testing::Harness::new("windows");
        Windows.on_start(harness.context()).await;
        let frames = harness.drain();
        assert!(polls(&frames).is_empty(), "{frames:?}");
    }

    fn ax_changed(notification: &str) -> Event {
        Event {
            name: "core:ax.changed".into(),
            bundle_id: Some("com.example.editor".into()),
            pid: Some(42),
            notification: Some(notification.into()),
            ..Event::default()
        }
    }

    /// A window retitled, created or destroyed re-snapshots its app alone
    /// once the burst settles; the keystrokes typed meanwhile do not.
    #[tokio::test]
    async fn an_ax_change_resnapshots_its_app_once_the_burst_settles() {
        let mut harness = flash_plugin::testing::Harness::new("windows");
        harness.set_running_applications(vec![flash_plugin::RunningApplication {
            bundle_id: "com.example.editor".to_string(),
            pid: 42,
            localized_name: "Editor".to_string(),
        }]);
        for notification in AX_REFRESH_NOTIFICATIONS
            .into_iter()
            .chain([ax_notifications::VALUE_CHANGED; 3])
        {
            Windows
                .on_event(harness.context(), ax_changed(notification))
                .await;
        }
        // The burst waits on one host deadline, never a sleep: play the host
        // and fire it once the burst has been quiet for its settle.
        let deadlines = harness
            .drain_poll_registrations()
            .expect("a settle deadline");
        assert_eq!(deadlines.len(), 1, "{deadlines:?}");
        let (name, entry) = deadlines.into_iter().next().unwrap();
        assert_eq!(entry["priority"], "normal");
        tokio::time::sleep(AX_SETTLE).await;
        drop(
            harness
                .deliver_poll_tick(&name)
                .expect("the settled burst refreshes"),
        );
        let (id, method, params) = harness.next_host_request().await.expect("snapshot");
        assert_eq!(method, "host.ax_snapshot");
        assert_eq!(params["pid"], 42);
        assert!(harness.reply_host(
            id,
            broker_reply(json!([
                { "handle": 1, "attrs": { "AXRole": "AXWindow", "AXTitle": "notes.md" } }
            ]))
        ));
        let rows = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let frames = harness.drain();
                if let Some(frame) = frames.iter().find(|frame| frame["method"] == "publish") {
                    break frame["params"]["rows"].clone();
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("published");
        assert_eq!(rows[0]["title"], "Editor — notes.md");
        assert!(
            harness.next_host_request().await.is_none(),
            "one burst, one snapshot"
        );
    }

    /// Value, selection, focus, layout and geometry changes cannot change a
    /// window row: none of them snapshots anything.
    #[tokio::test]
    async fn irrelevant_ax_changes_snapshot_nothing() {
        let mut harness = flash_plugin::testing::Harness::new("windows");
        for notification in ax_notifications::ALL
            .into_iter()
            .filter(|notification| !AX_REFRESH_NOTIFICATIONS.contains(notification))
        {
            Windows
                .on_event(harness.context(), ax_changed(notification))
                .await;
        }
        assert!(harness.next_host_request().await.is_none());
    }

    #[test]
    fn a_flashlight_open_sweeps_every_app_at_most_once_per_ttl() {
        let now = Instant::now();
        assert!(sweep_due(None, now));
        assert!(!sweep_due(Some(now - Duration::from_secs(5)), now));
        assert!(sweep_due(Some(now - SWEEP_TTL), now));
    }
}

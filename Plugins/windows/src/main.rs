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
//!      queue is bounded, so a focus storm collapses into one refresh), and
//!   3. on a 60 s interval as a safety net for title changes no event covers.
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

use flash_plugin::{run, Candidate, Context, Event, PerformResponse, RefreshGate};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

const SOURCE_ITEMS: &str = "windows.items";

/// Safety-net poll for renames/moves that emit no host event.
const REFRESH_SECONDS: u64 = 60;
/// Event bursts (an app launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
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
/// Debounce latch: one pending coalesced refresh at a time.
static REFRESH_SCHEDULED: AtomicBool = AtomicBool::new(false);

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
        drop(
            ctx.interval(Duration::from_secs(REFRESH_SECONDS), |ctx| async move {
                refresh_catalog(&ctx).await;
            }),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:apps.changed" | "core:window.focus.changed" | "core:focus.changed"
        ) {
            schedule_refresh(&ctx);
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }
}

/// Coalesce event bursts: the first event schedules a refresh
/// [`EVENT_DEBOUNCE`] out; followers piggyback on it.
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
            let mut candidates: Vec<Candidate> = Vec::new();
            let mut snapshot_failures = 0usize;
            let mut apps_walked = 0usize;
            for app in running.iter().take(APPS_PER_REFRESH_LIMIT) {
                if app.pid <= 0 {
                    continue;
                }
                if candidates.len() >= TOTAL_ROWS_LIMIT {
                    break;
                }
                apps_walked += 1;
                match window_rows(&ctx, app.pid).await {
                    Some(rows) => {
                        let app_label = app_label(app);
                        for row in rows {
                            if candidates.len() >= TOTAL_ROWS_LIMIT {
                                break;
                            }
                            candidates.push(candidate(&app_label, app.pid, &row));
                        }
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
}

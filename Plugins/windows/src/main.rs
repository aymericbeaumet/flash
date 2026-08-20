//! Windows plugin — cross-app window switcher rows (`@windows`).
//!
//! ## Warm-location contract
//!
//! The catalog is one row per AX window of every regular running app. Each
//! refresh walks `ctx.running_applications()` and asks the host's AX broker
//! (`ax.snapshot`, `roots: "windows"`, no child descent) for that app's
//! window titles. The refresh runs:
//!
//!   1. in `on_start` under an 8 s budget (authoritative empty + background
//!      retry on timeout, mirroring the history plugin),
//!   2. debounced/coalesced on `core:apps.changed` /
//!      `core:window.focus.changed` / `core:focus.changed` (the SDK event
//!      queue is bounded, so a focus storm collapses into one refresh), and
//!   3. on a 60 s interval as a safety net for title changes no event covers.
//!
//! `sources.snapshot` is served from the SDK warm store — no AX I/O on the
//! flashlight hot path.
//!
//! ## Resolution
//!
//! AX handles are broker-owned and purged per `(owner, pid)` on every fresh
//! snapshot, so rows never carry handles. `resolve_candidate` re-snapshots
//! the app, finds the window by exact title (index fallback), performs
//! `AXRaise` + `AXMain`/`AXFocused` on it, activates the app, and returns
//! `target_pid` so movement history records the jump. A vanished window
//! degrades to plain app activation.

use flash_plugin::{run, Candidate, Context, Event, RefreshGate, ResolveResponse};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

const SOURCE_ID: &str = "plugin:windows";
const SOURCE_ITEMS: &str = "windows.items";

/// Startup refresh must finish well inside the host's 15 s initialize
/// deadline; on expiry an authoritative empty ships and a background retry
/// replaces it.
const STARTUP_REFRESH_BUDGET: Duration = Duration::from_secs(8);
/// Safety-net poll for renames/moves that emit no host event.
const REFRESH_SECONDS: u64 = 60;
/// Event bursts (an app launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
/// Per-`ax.snapshot` host RPC deadline. One wedged app must not consume the
/// whole refresh budget.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(2);

/// Row caps. ~300 rows is far beyond what the flashlight shows and keeps the
/// catalog far below the 10,000-row / 4 MiB publication limits.
const TOTAL_ROWS_LIMIT: usize = 300;
const _: () = assert!(TOTAL_ROWS_LIMIT < 10_000);
/// Apps walked per refresh (running_applications order, i.e. host order).
const APPS_PER_REFRESH_LIMIT: usize = 60;
/// Broker node cap per app: with no child descent every node is a window.
const WINDOWS_PER_APP_LIMIT: usize = 20;
const _: () = assert!(APPS_PER_REFRESH_LIMIT * WINDOWS_PER_APP_LIMIT < 10_000);
const MAX_TITLE_CHARS: usize = 256;

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// Fingerprint of the last published catalog: `sources.invalidated` fires
/// only when a refresh actually changed content.
static LAST_FINGERPRINT: Mutex<Option<u64>> = Mutex::new(None);
/// Debounce latch: one pending coalesced refresh at a time.
static REFRESH_SCHEDULED: AtomicBool = AtomicBool::new(false);

/// One flat node from an `ax.snapshot` reply.
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
        let initial_succeeded =
            match tokio::time::timeout(STARTUP_REFRESH_BUDGET, refresh_catalog(&ctx)).await {
                Ok(succeeded) => succeeded,
                Err(_) => {
                    ctx.log_fields(
                        "warn",
                        "[windows] initial warm refresh timed out",
                        BTreeMap::from([
                            (
                                "budget_ms".to_string(),
                                STARTUP_REFRESH_BUDGET.as_millis().to_string(),
                            ),
                            (
                                "outcome".to_string(),
                                "timed_out_background_retry".to_string(),
                            ),
                        ]),
                    );
                    false
                }
            };
        if !initial_succeeded && !ctx.has_locations(SOURCE_ID) {
            // Authoritative empty placeholder so initialize never blocks on a
            // wedged AX broker; the background retry replaces it in place.
            publish(&ctx, Vec::new());
        }
        if !initial_succeeded {
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

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
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
                log_refresh(&ctx, "failed", ctx.warm_locations().len(), started_at);
                return false;
            }
            let count = candidates.len();
            publish(&ctx, candidates);
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
        .call_host_timeout(
            "ax.snapshot",
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
    Candidate::new(format!("{app_label} — {}", row.title))
        .kind("window")
        .source_id(SOURCE_ID)
        .source(SOURCE_ITEMS)
        .subtitle(app_label)
        .pid(pid)
        .metadata("window_title", &row.title)
        .metadata("window_index", row.index.to_string())
}

fn publish(ctx: &Context, candidates: Vec<Candidate>) {
    let fingerprint = fingerprint_of(&candidates);
    let previous = LAST_FINGERPRINT
        .lock()
        .map(|mut last| last.replace(fingerprint))
        .unwrap_or(None);
    ctx.set_locations(SOURCE_ID, candidates);
    if previous.is_some_and(|last| last != fingerprint) {
        ctx.invalidate_sources();
    }
}

fn fingerprint_of(candidates: &[Candidate]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for candidate in candidates {
        candidate.title.hash(&mut hasher);
        candidate.meta("pid").hash(&mut hasher);
        candidate.meta("window_index").hash(&mut hasher);
    }
    hasher.finish()
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

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let Some(pid) = candidate.pid_value() else {
        ctx.log("warn", "[windows] resolve candidate missing pid");
        return ResolveResponse::unresolved();
    };
    let title = candidate.meta("window_title").unwrap_or_default();
    let index = candidate
        .meta("window_index")
        .and_then(|raw| raw.parse::<usize>().ok());

    // Re-snapshot at resolve time: broker handles are owner-scoped and were
    // purged the moment any later snapshot of this app ran.
    let value = ctx
        .call_host_timeout(
            "ax.snapshot",
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
                ctx.call_host("app.activate", json!({ "pid": pid })),
                ctx.call_host(
                    "ax.perform",
                    json!({ "handle": handle, "action": "AXRaise" })
                ),
                ctx.call_host(
                    "ax.set",
                    json!({ "handle": handle, "attribute": "AXMain", "value": true }),
                ),
                ctx.call_host(
                    "ax.set",
                    json!({ "handle": handle, "attribute": "AXFocused", "value": true }),
                ),
            );
            let ok = |value: &Value| value.get("ok").and_then(Value::as_bool) == Some(true);
            ok(&activated) && (ok(&raised) || ok(&main) || ok(&focused))
        }
        None => false,
    };
    if !raised {
        // The window vanished (or the broker degraded): activating the app is
        // still the right jump, and target_pid still records it in movement
        // history.
        let activated = ctx.call_host("app.activate", json!({ "pid": pid })).await;
        if activated.get("ok").and_then(Value::as_bool) != Some(true) {
            ctx.log("warn", "[windows] resolve app.activate failed");
            return ResolveResponse::unresolved();
        }
    }
    ResolveResponse::resolved(Some(pid))
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
    fn startup_budget_stays_below_host_initialize_deadline() {
        assert!(STARTUP_REFRESH_BUDGET < Duration::from_secs(15));
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
        assert_eq!(candidate.meta("source"), Some(SOURCE_ITEMS));
        assert_eq!(candidate.meta("source_id"), Some(SOURCE_ID));
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

    #[test]
    fn fingerprints_change_with_content() {
        let row = WindowRow {
            title: "One".to_string(),
            index: 0,
        };
        let before = vec![candidate("App", 1, &row)];
        let after = vec![candidate("App", 2, &row)];
        assert_eq!(fingerprint_of(&before), fingerprint_of(&before.clone()));
        assert_ne!(fingerprint_of(&before), fingerprint_of(&after));
    }
}

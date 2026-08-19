use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, Event, RefreshGate, ResolveResponse,
};

const SOURCE_ID: &str = "plugin:processes";
const POLL_SECONDS: u64 = 10;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

struct Processes;

flash_plugin::plugin!(Processes);

impl FlashPlugin for Processes {
    async fn on_start(&self, ctx: Context) {
        let initial_succeeded = refresh_candidates(&ctx).await;
        if should_publish_degraded_initial(initial_succeeded, ctx.has_locations(SOURCE_ID)) {
            log_degraded_initial(&ctx);
            ctx.set_locations(SOURCE_ID, Vec::new());
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_candidates(&retry_ctx).await;
            });
        }
        drop(
            ctx.interval(Duration::from_secs(POLL_SECONDS), |ctx| async move {
                refresh_candidates(&ctx).await;
            }),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:apps.launched" | "core:apps.terminated"
        ) {
            refresh_candidates(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "refresh" => {
                if refresh_candidates(&ctx).await {
                    CommandResponse::toast("processes refreshed")
                } else {
                    CommandResponse::error("processes refresh failed")
                }
            }
            "kill" => kill_command(&ctx, command.query().trim()).await,
            other => CommandResponse::error(format!("unknown subcommand: {other}")),
        }
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        let Some(pid) = candidate.payload_str().and_then(|s| s.parse::<i32>().ok()) else {
            return ResolveResponse::unresolved();
        };
        match send_term(&ctx, pid).await {
            Ok(()) => {
                // Best effort: refresh so the row disappears immediately.
                let refresh_ctx = ctx.clone();
                tokio::spawn(async move {
                    refresh_candidates(&refresh_ctx).await;
                });
                ResolveResponse::resolved(None)
            }
            Err(error) => {
                ctx.log(
                    "warn",
                    &format!("[processes] kill pid {pid} failed: {error}"),
                );
                ResolveResponse::unresolved()
            }
        }
    }
}

#[derive(Clone)]
struct ProcessRow {
    pid: i32,
    comm: String,
    cpu: f32,
    mem: f32,
}

async fn refresh_candidates(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, _running| async move {
            refresh_candidates_inner(&ctx).await
        })
        .await
}

async fn refresh_candidates_inner(ctx: &Context) -> bool {
    let started_at = Instant::now();
    let Some(candidates) = collect_candidates(ctx).await else {
        log_refresh(ctx, "failed", ctx.warm_locations().len(), started_at);
        return false;
    };
    // A libproc listing is never empty on success (this process exists), so
    // list_processes treats empty as failure and the previous snapshot is
    // preserved; a successful listing always replaces the store.
    let count = candidates.len();
    ctx.set_locations(SOURCE_ID, candidates);
    log_refresh(
        ctx,
        if count == 0 { "empty" } else { "ok" },
        count,
        started_at,
    );
    true
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("outcome".to_string(), outcome.to_string()),
        ("candidates".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[processes] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[processes] warm refresh slow", fields);
    }
}

fn should_publish_degraded_initial(initial_succeeded: bool, has_last_good: bool) -> bool {
    !initial_succeeded && !has_last_good
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[processes] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "empty_without_last_good".to_string()),
            ("candidates".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

async fn collect_candidates(ctx: &Context) -> Option<Vec<Candidate>> {
    let rows = list_processes(ctx).await?;
    Some(rows.into_iter().map(|row| candidate_for(&row)).collect())
}

fn candidate_for(row: &ProcessRow) -> Candidate {
    let pid = row.pid;
    let subtitle = format!("pid {} · {:.1}% CPU · {:.1}% MEM", pid, row.cpu, row.mem);
    Candidate::new(&row.comm)
        .kind("process")
        .source_id(SOURCE_ID)
        .source("processes.processes")
        .subtitle(&subtitle)
        .aliases([pid.to_string()])
        .payload(pid.to_string())
}

/// Sample window for the instantaneous CPU measurement — long enough to be
/// meaningful, short enough that the 10s poll cadence dwarfs it.
const CPU_SAMPLE_WINDOW: Duration = Duration::from_millis(150);

async fn list_processes(ctx: &Context) -> Option<Vec<ProcessRow>> {
    // host.process_table, not /bin/ps or in-process libproc: no subprocess,
    // no process_info seatbelt allowance, and one process model (the
    // host's). An empty table is impossible (the host exists), so empty
    // means the call failed.
    let response = ctx
        .call_host(
            "host.process_table",
            serde_json::json!({ "sample_window_ms": CPU_SAMPLE_WINDOW.as_millis() as u64 }),
        )
        .await;
    let rows: Vec<ProcessRow> = response
        .get("processes")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    Some(ProcessRow {
                        pid: row.get("pid")?.as_i64()? as i32,
                        comm: row.get("comm")?.as_str()?.to_string(),
                        cpu: row.get("cpu_percent")?.as_f64()? as f32,
                        mem: row.get("mem_percent")?.as_f64()? as f32,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if rows.is_empty() {
        ctx.log("warn", "[processes] host.process_table returned no rows");
        return None;
    }
    Some(rows)
}

async fn kill_command(ctx: &Context, query: &str) -> CommandResponse {
    if query.is_empty() {
        return CommandResponse::error("usage: !kill <pid|name>");
    }
    // Pure-numeric query is treated as an exact PID — no fuzzy match.
    if let Ok(pid) = query.parse::<i32>() {
        return match send_term(ctx, pid).await {
            Ok(()) => CommandResponse::toast(format!("SIGTERM → pid {pid}")),
            Err(error) => CommandResponse::error(format!("kill pid {pid}: {error}")),
        };
    }
    let Some(rows) = list_processes(ctx).await else {
        return CommandResponse::error("process list failed");
    };
    let needle = query.to_ascii_lowercase();
    let matches: Vec<&ProcessRow> = rows
        .iter()
        .filter(|row| row.comm.to_ascii_lowercase().contains(&needle))
        .collect();
    match matches.as_slice() {
        [] => CommandResponse::error(format!("no process matches {query:?}")),
        [single] => {
            let pid = single.pid;
            let name = single.comm.clone();
            match send_term(ctx, pid).await {
                Ok(()) => CommandResponse::toast(format!("SIGTERM → {name} (pid {pid})")),
                Err(error) => CommandResponse::error(format!("kill {name} (pid {pid}): {error}")),
            }
        }
        many => {
            let preview: Vec<String> = many
                .iter()
                .take(5)
                .map(|row| format!("{} (pid {})", row.comm, row.pid))
                .collect();
            CommandResponse::error(format!(
                "ambiguous match ({}): {}; refine with !kill <pid>",
                many.len(),
                preview.join(", ")
            ))
        }
    }
}

async fn send_term(ctx: &Context, pid: i32) -> Result<(), String> {
    let response = ctx
        .call_host("host.signal", serde_json::json!({ "pid": pid }))
        .await;
    if response.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return Ok(());
    }
    Err(response
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("host.signal failed")
        .to_string())
}

fn main() {
    run(Processes);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The libproc listing itself now lives host-side (host.process_table,
    /// with a Swift golden-output test against /bin/ps); plugin-side the
    /// contract is the row -> candidate mapping.
    #[test]
    fn candidate_carries_pid_payload_and_alias() {
        let row = ProcessRow {
            pid: 4242,
            comm: "Safari".into(),
            cpu: 12.5,
            mem: 3.25,
        };
        let candidate = candidate_for(&row);
        assert_eq!(candidate.title, "Safari");
        assert_eq!(candidate.payload_str(), Some("4242"));
        let subtitle = candidate
            .metadata
            .get(flash_plugin::candidate_metadata::SUBTITLE)
            .expect("subtitle");
        assert!(subtitle.contains("pid 4242"), "subtitle: {subtitle}");
        assert!(subtitle.contains("12.5% CPU"), "subtitle: {subtitle}");
    }

    #[test]
    fn transient_startup_failure_only_uses_empty_when_no_last_good_exists() {
        assert!(should_publish_degraded_initial(false, false));
        assert!(!should_publish_degraded_initial(false, true));
        assert!(!should_publish_degraded_initial(true, false));
    }
}

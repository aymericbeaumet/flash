use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{run, Candidate, CommandRequest, Context, Event, PerformResponse, RefreshGate};

const SOURCE_PROCESSES: &str = "processes.processes";
const POLL_SECONDS: u64 = 10;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

struct Processes;

flash_plugin::plugin!(Processes);

impl FlashPlugin for Processes {
    async fn on_start(&self, ctx: Context) {
        // A failed initial listing publishes nothing — the host serves its
        // last-good catalog (which survives restarts) while a background
        // retry warms this process.
        if !refresh_candidates(&ctx).await {
            log_degraded_initial(&ctx);
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

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "refresh" => {
                if refresh_candidates(&ctx).await {
                    PerformResponse::ok().message("processes refreshed")
                } else {
                    PerformResponse::fail("processes refresh failed")
                }
            }
            "kill" => kill_command(&ctx, command.query().trim()).await,
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        let Some(pid) = row.payload_str().and_then(|s| s.parse::<i32>().ok()) else {
            return PerformResponse::unhandled();
        };
        match send_term(&ctx, pid).await {
            Ok(()) => {
                // Best effort: refresh so the row disappears immediately.
                let refresh_ctx = ctx.clone();
                tokio::spawn(async move {
                    refresh_candidates(&refresh_ctx).await;
                });
                PerformResponse::ok()
            }
            Err(error) => {
                ctx.log(
                    "warn",
                    &format!("[processes] kill pid {pid} failed: {error}"),
                );
                PerformResponse::fail("kill failed")
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
        log_refresh(ctx, "failed", 0, started_at);
        return false;
    };
    // A libproc listing is never empty on success (this process exists), so
    // list_processes treats empty as failure and nothing is published — the
    // host keeps its last-good catalog; a successful listing always
    // publishes a full replacement.
    let count = candidates.len();
    ctx.publish(candidates);
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

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[processes] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
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
    Candidate::new(SOURCE_PROCESSES, &row.comm)
        .kind("process")
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
        .process_table(Some(CPU_SAMPLE_WINDOW.as_millis() as u64))
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

async fn kill_command(ctx: &Context, query: &str) -> PerformResponse {
    if query.is_empty() {
        return PerformResponse::fail("usage: !kill <pid|name>");
    }
    // Pure-numeric query is treated as an exact PID — no fuzzy match.
    if let Ok(pid) = query.parse::<i32>() {
        return match send_term(ctx, pid).await {
            Ok(()) => PerformResponse::ok().message(format!("SIGTERM → pid {pid}")),
            Err(error) => PerformResponse::fail(format!("kill pid {pid}: {error}")),
        };
    }
    let Some(rows) = list_processes(ctx).await else {
        return PerformResponse::fail("process list failed");
    };
    let needle = query.to_ascii_lowercase();
    let matches: Vec<&ProcessRow> = rows
        .iter()
        .filter(|row| row.comm.to_ascii_lowercase().contains(&needle))
        .collect();
    match matches.as_slice() {
        [] => PerformResponse::fail(format!("no process matches {query:?}")),
        [single] => {
            let pid = single.pid;
            let name = single.comm.clone();
            match send_term(ctx, pid).await {
                Ok(()) => PerformResponse::ok().message(format!("SIGTERM → {name} (pid {pid})")),
                Err(error) => PerformResponse::fail(format!("kill {name} (pid {pid}): {error}")),
            }
        }
        many => {
            let preview: Vec<String> = many
                .iter()
                .take(5)
                .map(|row| format!("{} (pid {})", row.comm, row.pid))
                .collect();
            PerformResponse::fail(format!(
                "ambiguous match ({}): {}; refine with !kill <pid>",
                many.len(),
                preview.join(", ")
            ))
        }
    }
}

async fn send_term(ctx: &Context, pid: i32) -> Result<(), String> {
    ctx.signal(pid.into()).await
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
}

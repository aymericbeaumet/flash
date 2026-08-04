use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    run, run_command, Candidate, CommandOutput, CommandRequest, CommandResponse, Context, Event,
    RefreshGate, ResolveResponse,
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
        let result = send_term(&ctx, pid).await;
        if result.ok {
            // Best effort: refresh so the row disappears immediately.
            let refresh_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_candidates(&refresh_ctx).await;
            });
            ResolveResponse::resolved(None)
        } else {
            ctx.log(
                "warn",
                &format!("[processes] kill pid {} failed: {}", pid, result.stderr),
            );
            ResolveResponse::unresolved()
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
    // A successful empty `ps` response is authoritative. Only an execution
    // failure preserves the previous snapshot.
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

async fn list_processes(ctx: &Context) -> Option<Vec<ProcessRow>> {
    // Empty `=` headers omit the column titles, so output is rows only.
    let argv = [
        "/bin/ps".to_string(),
        "-axo".to_string(),
        "pid=,pcpu=,pmem=,comm=".to_string(),
    ];
    let result = run_command(ctx, &argv, Duration::from_secs(5)).await;
    if !result.ok {
        ctx.log("warn", &format!("[processes] ps failed: {}", result.stderr));
        return None;
    }
    Some(result.stdout.lines().filter_map(parse_ps_row).collect())
}

fn parse_ps_row(line: &str) -> Option<ProcessRow> {
    let mut parts = line.split_whitespace();
    let pid: i32 = parts.next()?.parse().ok()?;
    let cpu: f32 = parts.next()?.parse().ok().unwrap_or(0.0);
    let mem: f32 = parts.next()?.parse().ok().unwrap_or(0.0);
    let comm_path = parts.collect::<Vec<_>>().join(" ");
    let comm = basename(comm_path.trim());
    if comm.is_empty() {
        return None;
    }
    Some(ProcessRow {
        pid,
        comm,
        cpu,
        mem,
    })
}

fn basename(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

async fn kill_command(ctx: &Context, query: &str) -> CommandResponse {
    if query.is_empty() {
        return CommandResponse::error("usage: !kill <pid|name>");
    }
    // Pure-numeric query is treated as an exact PID — no fuzzy match.
    if let Ok(pid) = query.parse::<i32>() {
        let result = send_term(ctx, pid).await;
        return if result.ok {
            CommandResponse::toast(format!("SIGTERM → pid {pid}"))
        } else {
            CommandResponse::error(format!("kill pid {pid}: {}", result.stderr.trim()))
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
            let result = send_term(ctx, pid).await;
            if result.ok {
                CommandResponse::toast(format!("SIGTERM → {name} (pid {pid})"))
            } else {
                CommandResponse::error(format!("kill {name} (pid {pid}): {}", result.stderr.trim()))
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

async fn send_term(ctx: &Context, pid: i32) -> CommandOutput {
    run_command(
        ctx,
        &[
            "/bin/kill".to_string(),
            "-TERM".to_string(),
            pid.to_string(),
        ],
        Duration::from_secs(5),
    )
    .await
}

fn main() {
    run(Processes);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ps_row_with_path_comm() {
        let row = parse_ps_row(" 12345  1.2  0.4 /usr/bin/node").unwrap();
        assert_eq!(row.pid, 12345);
        assert_eq!(row.comm, "node");
        assert!((row.cpu - 1.2).abs() < 0.001);
        assert!((row.mem - 0.4).abs() < 0.001);
    }

    #[test]
    fn parses_ps_row_with_spaces_in_path() {
        let row = parse_ps_row(
            " 99  0.0  0.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        .unwrap();
        assert_eq!(row.pid, 99);
        assert_eq!(row.comm, "Google Chrome");
    }

    #[test]
    fn rejects_empty_or_malformed_row() {
        assert!(parse_ps_row("").is_none());
        assert!(parse_ps_row("notapid 1 2 cmd").is_none());
    }

    #[test]
    fn transient_startup_failure_only_uses_empty_when_no_last_good_exists() {
        assert!(should_publish_degraded_initial(false, false));
        assert!(!should_publish_degraded_initial(false, true));
        assert!(!should_publish_degraded_initial(true, false));
    }
}

use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, Event, ResolveResponse,
};

const SOURCE_ID: &str = "plugin:processes";
const POLL_SECONDS: u64 = 10;

struct Processes;

flash_plugin::plugin!(Processes);

impl FlashPlugin for Processes {
    async fn on_start(&self, ctx: Context) {
        emit_candidates(&ctx).await;
        let poll_ctx = ctx.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(POLL_SECONDS)).await;
                emit_candidates(&poll_ctx).await;
            }
        });
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:flash.started" | "core:apps.launched" | "core:apps.terminated"
        ) {
            emit_candidates(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "refresh" => {
                emit_candidates(&ctx).await;
                CommandResponse::toast("processes refreshed")
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
                emit_candidates(&refresh_ctx).await;
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

async fn emit_candidates(ctx: &Context) {
    let rows = list_processes(ctx).await;
    let candidates: Vec<Candidate> = rows.into_iter().map(|row| candidate_for(&row)).collect();
    ctx.emit_snapshot(SOURCE_ID, candidates);
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

async fn list_processes(ctx: &Context) -> Vec<ProcessRow> {
    // Empty `=` headers omit the column titles, so output is rows only.
    let argv = [
        "/bin/ps".to_string(),
        "-axo".to_string(),
        "pid=,pcpu=,pmem=,comm=".to_string(),
    ];
    let result = run_command(ctx, &argv, Duration::from_secs(5)).await;
    if !result.ok {
        ctx.log("warn", &format!("[processes] ps failed: {}", result.stderr));
        return Vec::new();
    }
    result.stdout.lines().filter_map(parse_ps_row).collect()
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
    let rows = list_processes(ctx).await;
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

#[derive(Clone, Debug, Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> CommandOutput {
    let Some((program, args)) = argv.split_first() else {
        return CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            _status: -1,
            ..Default::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .current_dir(&ctx.data_dir)
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .env(
            "PATH",
            format!(
                "{}:{}",
                ctx.bin_dir().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CommandOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            _status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CommandOutput {
            ok: false,
            stderr: err.to_string(),
            _status: -1,
            ..Default::default()
        },
        Err(_) => CommandOutput {
            ok: false,
            stderr: format!("timed out after {}ms", timeout.as_millis()),
            _status: 124,
            ..Default::default()
        },
    }
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
}

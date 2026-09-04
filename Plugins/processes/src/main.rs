use std::collections::BTreeMap;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{run, Candidate, CommandRequest, Context, Event, PerformResponse, RefreshGate};
use serde_json::Value;

const SOURCE_PROCESSES: &str = "processes.processes";
const POLL_SECONDS: u64 = 10;
const FOCUSED_STATUS_POLL_SECONDS: u64 = 5;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static FOCUSED_REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static FOCUSED_STATE: LazyLock<Mutex<FocusedState>> =
    LazyLock::new(|| Mutex::new(FocusedState::default()));

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
        let initial_ctx = ctx.clone();
        tokio::spawn(async move {
            initialize_focused_status(&initial_ctx).await;
        });
        drop(ctx.interval(
            Duration::from_secs(FOCUSED_STATUS_POLL_SECONDS),
            |ctx| async move {
                refresh_focused_status(&ctx).await;
            },
        ));
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:apps.launched" | "core:apps.terminated"
        ) {
            refresh_candidates(&ctx).await;
        }
        if event.name == "core:focus.changed" {
            let Some(app) = FocusedApp::from_event(&event) else {
                clear_focused_status(&ctx);
                return;
            };
            let sample = replace_focused_app(app);
            publish_focused_status_if_current(
                &ctx,
                &sample,
                focused_app_placeholder(&sample.app, "Collecting metrics…"),
            );
            tokio::spawn(async move {
                refresh_focused_status(&ctx).await;
            });
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

#[derive(Clone, Debug, PartialEq, Eq)]
struct FocusedApp {
    pid: i64,
    bundle_id: String,
}

impl FocusedApp {
    fn from_event(event: &Event) -> Option<Self> {
        let pid = event.pid.filter(|pid| *pid > 0)?;
        Some(Self {
            pid,
            bundle_id: event.bundle_id.clone().unwrap_or_default(),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
struct FocusedProcessMetrics {
    comm: String,
    cpu_percent: f64,
    memory_bytes: u64,
    mem_percent: f64,
    process_count: u64,
    network_socket_count: u64,
    thread_count: u64,
    uptime_seconds: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FocusedSample {
    app: FocusedApp,
    generation: u64,
}

#[derive(Debug, Default)]
struct FocusedState {
    app: Option<FocusedApp>,
    generation: u64,
}

impl FocusedState {
    fn replace(&mut self, app: FocusedApp) -> FocusedSample {
        self.generation = self.generation.wrapping_add(1);
        self.app = Some(app.clone());
        FocusedSample {
            app,
            generation: self.generation,
        }
    }

    fn install_if_empty(&mut self, app: FocusedApp) -> Option<FocusedSample> {
        self.app.is_none().then(|| self.replace(app))
    }

    fn clear(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.app = None;
    }

    fn snapshot(&self) -> Option<FocusedSample> {
        self.app.clone().map(|app| FocusedSample {
            app,
            generation: self.generation,
        })
    }

    fn is_current(&self, sample: &FocusedSample) -> bool {
        self.generation == sample.generation && self.app.as_ref() == Some(&sample.app)
    }
}

async fn initialize_focused_status(ctx: &Context) {
    let Some(target) = ctx.normal_mode_target().await else {
        clear_focused_status(ctx);
        return;
    };
    let app = FocusedApp {
        pid: target.pid,
        bundle_id: target.bundle_id,
    };
    let Some(sample) = install_focused_app_if_empty(app) else {
        return;
    };
    publish_focused_status_if_current(
        ctx,
        &sample,
        focused_app_placeholder(&sample.app, "Collecting metrics…"),
    );
    refresh_focused_status(ctx).await;
}

async fn refresh_focused_status(ctx: &Context) {
    FOCUSED_REFRESH_GATE
        .run(ctx, |ctx, _applications| async move {
            let Some(sample) = focused_sample() else {
                return;
            };
            let response = ctx
                .process_metrics(sample.app.pid, Some(CPU_SAMPLE_WINDOW.as_millis() as u64))
                .await;
            let content = focused_process_metrics(&response, sample.app.pid)
                .map(|metrics| focused_app_details(&sample.app, &metrics))
                .unwrap_or_else(|| focused_app_placeholder(&sample.app, "Metrics unavailable"));
            publish_focused_status_if_current(&ctx, &sample, content);
        })
        .await;
}

fn focused_process_metrics(response: &Value, pid: i64) -> Option<FocusedProcessMetrics> {
    let row = response
        .get("processes")?
        .as_array()?
        .iter()
        .find(|row| row.get("pid").and_then(Value::as_i64) == Some(pid))?;
    Some(FocusedProcessMetrics {
        comm: row.get("comm")?.as_str()?.to_string(),
        cpu_percent: row.get("cpu_percent")?.as_f64()?,
        memory_bytes: row.get("memory_bytes")?.as_u64()?,
        mem_percent: row.get("mem_percent")?.as_f64()?,
        process_count: row.get("process_count")?.as_u64()?,
        network_socket_count: row.get("network_socket_count")?.as_u64()?,
        thread_count: row.get("thread_count")?.as_u64()?,
        uptime_seconds: row.get("uptime_seconds")?.as_u64()?,
        disk_read_bytes: row.get("disk_read_bytes")?.as_u64()?,
        disk_write_bytes: row.get("disk_write_bytes")?.as_u64()?,
    })
}

fn focused_app_details(app: &FocusedApp, metrics: &FocusedProcessMetrics) -> String {
    [
        format!("Bundle: {}", bundle_label(app)),
        format!("PID: {} · Process: {}", app.pid, metrics.comm),
        format!("CPU: {:.1}%", metrics.cpu_percent),
        format!(
            "Memory: {} ({:.1}%)",
            format_bytes(metrics.memory_bytes),
            metrics.mem_percent
        ),
        format!(
            "Network: {} IPv4/IPv6 sockets",
            metrics.network_socket_count
        ),
        format!(
            "Processes: {} · Threads: {}",
            metrics.process_count, metrics.thread_count,
        ),
        format!("Uptime: {}", format_duration(metrics.uptime_seconds)),
        format!(
            "Disk I/O: {} read · {} written",
            format_bytes(metrics.disk_read_bytes),
            format_bytes(metrics.disk_write_bytes)
        ),
    ]
    .join("\n")
}

fn focused_app_placeholder(app: &FocusedApp, state: &str) -> String {
    format!("Bundle: {}\nPID: {}\n{state}", bundle_label(app), app.pid)
}

fn bundle_label(app: &FocusedApp) -> &str {
    let bundle = app.bundle_id.trim();
    if bundle.is_empty() {
        "Unavailable"
    } else {
        bundle
    }
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    if bytes < 1_024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1_024.0 && unit < UNITS.len() - 1 {
        value /= 1_024.0;
        unit += 1;
    }
    if value.fract().abs() < 0.05 || value >= 100.0 {
        format!("{value:.0} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn format_duration(seconds: u64) -> String {
    let days = seconds / 86_400;
    let hours = seconds % 86_400 / 3_600;
    let minutes = seconds % 3_600 / 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}

fn replace_focused_app(app: FocusedApp) -> FocusedSample {
    FOCUSED_STATE
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .replace(app)
}

fn install_focused_app_if_empty(app: FocusedApp) -> Option<FocusedSample> {
    FOCUSED_STATE
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .install_if_empty(app)
}

fn focused_sample() -> Option<FocusedSample> {
    FOCUSED_STATE
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .snapshot()
}

fn clear_focused_status(ctx: &Context) {
    FOCUSED_STATE
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clear();
    ctx.status([("focused_app_details", "")]);
}

fn publish_focused_status_if_current(ctx: &Context, sample: &FocusedSample, content: String) {
    let current = FOCUSED_STATE
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    if current.is_current(sample) {
        ctx.status([("focused_app_details", content)]);
    }
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

    #[test]
    fn focused_app_details_formats_live_and_lifetime_metrics() {
        let app = FocusedApp {
            pid: 4242,
            bundle_id: "org.mozilla.firefox".into(),
        };
        let metrics = FocusedProcessMetrics {
            comm: "firefox".into(),
            cpu_percent: 12.5,
            memory_bytes: 1_610_612_736,
            mem_percent: 6.25,
            process_count: 9,
            network_socket_count: 7,
            thread_count: 42,
            uptime_seconds: 7_384,
            disk_read_bytes: 536_870_912,
            disk_write_bytes: 67_108_864,
        };

        assert_eq!(
            focused_app_details(&app, &metrics),
            "Bundle: org.mozilla.firefox\nPID: 4242 · Process: firefox\nCPU: 12.5%\nMemory: 1.5 GB (6.2%)\nNetwork: 7 IPv4/IPv6 sockets\nProcesses: 9 · Threads: 42\nUptime: 2h 3m\nDisk I/O: 512 MB read · 64 MB written"
        );
    }

    #[test]
    fn focused_app_placeholder_never_reuses_another_apps_metrics() {
        let app = FocusedApp {
            pid: 99,
            bundle_id: "com.example.Editor".into(),
        };
        assert_eq!(
            focused_app_placeholder(&app, "Collecting metrics…"),
            "Bundle: com.example.Editor\nPID: 99\nCollecting metrics…"
        );
    }

    #[test]
    fn focused_metrics_parse_the_exact_requested_process() {
        let response = serde_json::json!({
            "ok": true,
            "processes": [{
                "pid": 7,
                "comm": "wrong"
            }, {
                "pid": 42,
                "comm": "right",
                "cpu_percent": 1.25,
                "memory_bytes": 2048,
                "mem_percent": 0.5,
                "process_count": 4,
                "network_socket_count": 2,
                "thread_count": 3,
                "uptime_seconds": 4,
                "disk_read_bytes": 5,
                "disk_write_bytes": 6
            }]
        });

        let metrics = focused_process_metrics(&response, 42).expect("metrics");
        assert_eq!(metrics.comm, "right");
        assert_eq!(metrics.network_socket_count, 2);
        assert_eq!(metrics.process_count, 4);
        assert_eq!(metrics.disk_write_bytes, 6);
    }

    #[test]
    fn focused_app_is_built_only_from_a_valid_focus_event() {
        let valid = Event {
            name: "core:focus.changed".into(),
            bundle_id: Some("com.example.App".into()),
            pid: Some(123),
            ..Event::default()
        };
        assert_eq!(
            FocusedApp::from_event(&valid),
            Some(FocusedApp {
                pid: 123,
                bundle_id: "com.example.App".into()
            })
        );
        assert!(FocusedApp::from_event(&Event {
            pid: Some(0),
            ..Event::default()
        })
        .is_none());
    }

    #[test]
    fn focus_generation_rejects_an_older_in_flight_sample() {
        let mut state = FocusedState::default();
        let old = state.replace(FocusedApp {
            pid: 1,
            bundle_id: "com.example.Old".into(),
        });
        let current = state.replace(FocusedApp {
            pid: 2,
            bundle_id: "com.example.Current".into(),
        });

        assert!(!state.is_current(&old));
        assert!(state.is_current(&current));
        assert!(state
            .install_if_empty(FocusedApp {
                pid: 3,
                bundle_id: "com.example.StaleInitialization".into(),
            })
            .is_none());
        assert!(state.is_current(&current));
    }
}

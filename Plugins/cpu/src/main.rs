use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use flash_plugin::status::{duration_uptime, percent2, sparkline_padded, sparkline_percent};
use flash_plugin::{
    run, run_command, sys, Color, CommandRequest, Context, History, Markup, PerformResponse,
    Preview, Published, StatusValue,
};
use nix::time::{clock_gettime, ClockId};

// CPU load comes from `host_processor_info` tick counters sampled once per
// period in-process; only the GPU metadata still shells out (`ioreg`).
const CPU_SAMPLE_PERIOD: Duration = Duration::from_secs(1);
const GPU_INTERVAL: Duration = Duration::from_secs(15);
const GPU_TIMEOUT: Duration = Duration::from_secs(4);
const HISTORY_SAMPLES: usize = 20;
const IOREG: &str = "/usr/sbin/ioreg";
static LOGICAL_CPU_COUNT: LazyLock<Option<usize>> =
    LazyLock::new(|| std::thread::available_parallelism().ok().map(usize::from));

type CpuHistory = History<HISTORY_SAMPLES>;

#[derive(Clone, Debug, PartialEq)]
struct CpuSnapshot {
    user: f64,
    system: f64,
    idle: f64,
    load: [f64; 3],
    logical_cpus: Option<usize>,
    /// Seconds since boot, sleep included; read with each CPU sample.
    uptime_seconds: Option<u64>,
}

impl CpuSnapshot {
    fn total(&self) -> f64 {
        (self.user + self.system).clamp(0.0, 100.0)
    }
}

#[derive(Clone, Debug, PartialEq)]
struct GpuSnapshot {
    utilization: f64,
    model: Option<String>,
}

enum Collection<T> {
    Fresh(T),
    Busy,
    Failed,
}

#[derive(Clone, Copy)]
enum GatePolicy {
    Wait,
    SkipIfBusy,
}

/// One rendered status frame: the popup-free bar label, the visible summary
/// and the hover preview shown behind it, plus the raw numeric segments.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Report {
    label: Markup,
    summary: Markup,
    preview: Preview,
    raw: RawMetrics,
}

/// Plain values without markup, for templates and widgets that scale or chart
/// numbers themselves. An empty value clears its segment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct RawMetrics {
    /// Total CPU as an integer 0–100; unlike the label, never capped at 99.
    percent: String,
    /// The retained samples as space-separated integers, oldest first.
    history: String,
    /// One-minute load average with two decimals.
    load: String,
    /// Two-unit uptime such as `3d 4h`.
    uptime: String,
}

impl Report {
    fn segments(&self) -> [(&'static str, StatusValue); 7] {
        [
            (
                "summary",
                StatusValue::text(self.summary.clone()).with_preview(self.preview.clone()),
            ),
            ("label", StatusValue::text(self.label.clone())),
            ("details", StatusValue::text(self.preview.render())),
            ("percent", plain(&self.raw.percent)),
            ("history", plain(&self.raw.history)),
            ("load", plain(&self.raw.load)),
            ("uptime", plain(&self.raw.uptime)),
        ]
    }
}

/// A raw segment's value as literal text: no styling and no preview.
fn plain(value: &str) -> StatusValue {
    StatusValue::text(Markup::text(value))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SummaryMode {
    Compact,
    Full,
}

fn parse_summary_mode(configured: &str) -> (SummaryMode, bool) {
    match configured {
        "" | "compact" => (SummaryMode::Compact, true),
        "full" => (SummaryMode::Full, true),
        _ => (SummaryMode::Compact, false),
    }
}

fn configured_summary_mode(ctx: &Context) -> SummaryMode {
    parse_summary_mode(&ctx.config_str("summary_mode")).0
}

fn warn_invalid_summary_mode(ctx: &Context) {
    if !parse_summary_mode(&ctx.config_str("summary_mode")).1 {
        ctx.log(
            "warn",
            "[cpu] summary_mode must be compact or full; using compact",
        );
    }
}

#[derive(Default)]
struct MonitorState {
    cpu: Option<CpuSnapshot>,
    /// Baseline for the next differential sample.
    ticks: Option<sys::CpuTicks>,
    gpu: Option<GpuSnapshot>,
    history: CpuHistory,
    published: Published<Report>,
    cpu_failure_logged: bool,
    gpu_failure_logged: bool,
}

impl MonitorState {
    fn report(&self, summary_mode: SummaryMode) -> Option<Report> {
        let cpu = self.cpu.as_ref()?;
        Some(render_report(
            cpu,
            self.gpu.as_ref(),
            &self.history,
            summary_mode,
        ))
    }
}

struct Cpu {
    state: Arc<Mutex<MonitorState>>,
    cpu_gate: Arc<tokio::sync::Mutex<()>>,
    gpu_gate: Arc<tokio::sync::Mutex<()>>,
}

impl Default for Cpu {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(MonitorState::default())),
            cpu_gate: Arc::new(tokio::sync::Mutex::new(())),
            gpu_gate: Arc::new(tokio::sync::Mutex::new(())),
        }
    }
}

flash_plugin::plugin!(Cpu);

impl FlashPlugin for Cpu {
    async fn on_start(&self, ctx: Context) {
        warn_invalid_summary_mode(&ctx);
        refresh_all(
            &ctx,
            &self.state,
            &self.cpu_gate,
            &self.gpu_gate,
            GatePolicy::Wait,
        )
        .await;

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.cpu_gate);
        drop(ctx.interval(CPU_SAMPLE_PERIOD, move |ctx| {
            let state = Arc::clone(&state);
            let gate = Arc::clone(&gate);
            async move {
                refresh_cpu(&ctx, &state, &gate).await;
            }
        }));

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.gpu_gate);
        drop(ctx.interval(GPU_INTERVAL, move |ctx| {
            let state = Arc::clone(&state);
            let gate = Arc::clone(&gate);
            async move {
                refresh_gpu(&ctx, &state, &gate).await;
            }
        }));
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => details_response(current_report(&ctx, &self.state)),
            "refresh" => {
                refresh_all(
                    &ctx,
                    &self.state,
                    &self.cpu_gate,
                    &self.gpu_gate,
                    GatePolicy::SkipIfBusy,
                )
                .await;
                details_response(current_report(&ctx, &self.state))
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_all(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    cpu_gate: &Arc<tokio::sync::Mutex<()>>,
    gpu_gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) {
    let (cpu, gpu) = tokio::join!(
        collect_cpu(state, cpu_gate, policy),
        collect_gpu(ctx, gpu_gate, policy)
    );
    apply_cpu_result(ctx, state, cpu);
    apply_gpu_result(ctx, state, gpu);
    publish_if_changed(ctx, state);
}

async fn refresh_cpu(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
) {
    let result = collect_cpu(state, gate, GatePolicy::Wait).await;
    apply_cpu_result(ctx, state, result);
    publish_if_changed(ctx, state);
}

async fn refresh_gpu(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
) {
    let result = collect_gpu(ctx, gate, GatePolicy::Wait).await;
    apply_gpu_result(ctx, state, result);
    publish_if_changed(ctx, state);
}

async fn collect_cpu(
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) -> Collection<CpuSnapshot> {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return Collection::Busy;
    };
    let baseline = lock_state(state).ticks;
    let previous = match baseline {
        Some(ticks) => ticks,
        None => {
            // First sample: bracket one period so the initial publish carries a
            // real figure instead of waiting for the next loop iteration.
            let Ok(first) = sys::cpu_ticks() else {
                return Collection::Failed;
            };
            tokio::time::sleep(CPU_SAMPLE_PERIOD).await;
            first
        }
    };
    let Ok(current) = sys::cpu_ticks() else {
        return Collection::Failed;
    };
    lock_state(state).ticks = Some(current);
    let Some(percentages) = current.percentages_since(&previous) else {
        // No ticks elapsed between two back-to-back samples (an event refresh
        // right after the poll): keep the last figure without reporting a failure.
        return Collection::Busy;
    };
    let Ok(load) = sys::load_averages() else {
        return Collection::Failed;
    };
    cpu_snapshot(percentages.user, percentages.system, percentages.idle, load)
        .map(|mut snapshot| {
            snapshot.logical_cpus = *LOGICAL_CPU_COUNT;
            snapshot.uptime_seconds = uptime_seconds();
            Collection::Fresh(snapshot)
        })
        .unwrap_or(Collection::Failed)
}

/// Seconds since boot, sleep included: the figure `uptime(1)` prints. Darwin
/// derives `CLOCK_MONOTONIC` from `kern.boottime`, whereas `Instant` reads
/// `CLOCK_UPTIME_RAW`, which stops while the machine sleeps. One clock read
/// per CPU sample; it arms no timer of its own.
fn uptime_seconds() -> Option<u64> {
    let since_boot = clock_gettime(ClockId::CLOCK_MONOTONIC).ok()?;
    u64::try_from(since_boot.tv_sec()).ok()
}

async fn collect_gpu(
    ctx: &Context,
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) -> Collection<Option<GpuSnapshot>> {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return Collection::Busy;
    };
    let output = run_command(
        ctx,
        &[
            IOREG.to_string(),
            "-r".to_string(),
            "-c".to_string(),
            "IOAccelerator".to_string(),
            "-l".to_string(),
            "-w".to_string(),
            "0".to_string(),
        ],
        GPU_TIMEOUT,
    )
    .await;
    if !output.ok {
        return Collection::Failed;
    }
    match parse_ioreg_gpu(&output.stdout) {
        Some(snapshot) => Collection::Fresh(Some(snapshot)),
        None if output.stdout.contains("Utilization %") => Collection::Failed,
        None => Collection::Fresh(None),
    }
}

fn begin_collection(gate: &tokio::sync::Mutex<()>) -> Option<tokio::sync::MutexGuard<'_, ()>> {
    gate.try_lock().ok()
}

async fn acquire_collection<'a>(
    gate: &'a tokio::sync::Mutex<()>,
    policy: GatePolicy,
) -> Option<tokio::sync::MutexGuard<'a, ()>> {
    match policy {
        GatePolicy::Wait => Some(gate.lock().await),
        GatePolicy::SkipIfBusy => begin_collection(gate),
    }
}

fn apply_cpu_result(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    result: Collection<CpuSnapshot>,
) {
    let mut state = lock_state(state);
    match result {
        Collection::Fresh(snapshot) => {
            state.history.push(snapshot.total());
            state.cpu = Some(snapshot);
            state.cpu_failure_logged = false;
        }
        Collection::Failed if !state.cpu_failure_logged => {
            state.cpu_failure_logged = true;
            drop(state);
            ctx.log(
                "warn",
                "[cpu] CPU sample unavailable; retaining last good value",
            );
        }
        Collection::Busy | Collection::Failed => {}
    }
}

fn apply_gpu_result(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    result: Collection<Option<GpuSnapshot>>,
) {
    let mut state = lock_state(state);
    match result {
        Collection::Fresh(snapshot) => {
            state.gpu = snapshot;
            state.gpu_failure_logged = false;
        }
        Collection::Failed if !state.gpu_failure_logged => {
            state.gpu_failure_logged = true;
            drop(state);
            ctx.log(
                "warn",
                "[cpu] GPU sample unavailable; retaining last good value",
            );
        }
        Collection::Busy | Collection::Failed => {}
    }
}

fn publish_if_changed(ctx: &Context, state: &Arc<Mutex<MonitorState>>) {
    let segments = {
        let mut state = lock_state(state);
        let Some(report) = state.report(configured_summary_mode(ctx)) else {
            return;
        };
        state.published.update(report).map(Report::segments)
    };
    if let Some(segments) = segments {
        ctx.status(segments);
    }
}

fn current_report(ctx: &Context, state: &Arc<Mutex<MonitorState>>) -> Option<Report> {
    lock_state(state).report(configured_summary_mode(ctx))
}

fn lock_state(state: &Arc<Mutex<MonitorState>>) -> std::sync::MutexGuard<'_, MonitorState> {
    state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn details_response(report: Option<Report>) -> PerformResponse {
    report
        .map(|report| PerformResponse::ok().message(report.preview.render_plain()))
        .unwrap_or_else(|| PerformResponse::fail("CPU information unavailable"))
}

/// Validates one differential sample the way the old `iostat` row parser did:
/// finite percentages that sum to 100 and non-negative load averages.
fn cpu_snapshot(user: f64, system: f64, idle: f64, load: [f64; 3]) -> Option<CpuSnapshot> {
    let snapshot = CpuSnapshot {
        user,
        system,
        idle,
        load,
        logical_cpus: None,
        uptime_seconds: None,
    };
    let percentages = [snapshot.user, snapshot.system, snapshot.idle];
    if percentages
        .iter()
        .any(|value| !value.is_finite() || !(0.0..=100.0).contains(value))
        || snapshot
            .load
            .iter()
            .any(|value| !value.is_finite() || *value < 0.0)
        || (percentages.iter().sum::<f64>() - 100.0).abs() > 1.0
    {
        return None;
    }
    Some(snapshot)
}

fn parse_ioreg_gpu(raw: &str) -> Option<GpuSnapshot> {
    accelerator_scopes(raw)
        .into_iter()
        .filter_map(parse_ioreg_gpu_scope)
        .reduce(|current, candidate| {
            if candidate.utilization > current.utilization {
                candidate
            } else {
                current
            }
        })
}

fn accelerator_scopes(raw: &str) -> Vec<&str> {
    let mut starts = Vec::new();
    if raw.starts_with("+-o ") {
        starts.push(0);
    }
    starts.extend(raw.match_indices("\n+-o ").map(|(offset, _)| offset + 1));
    if starts.is_empty() {
        return vec![raw];
    }
    starts
        .iter()
        .enumerate()
        .map(|(index, start)| {
            let end = starts.get(index + 1).copied().unwrap_or(raw.len());
            &raw[*start..end]
        })
        .collect()
}

fn parse_ioreg_gpu_scope(raw: &str) -> Option<GpuSnapshot> {
    let utilization = max_ioreg_number(raw, "\"Device Utilization %\"")
        .or_else(|| max_ioreg_number(raw, "\"Renderer Utilization %\""))
        .or_else(|| max_ioreg_number(raw, "\"Tiler Utilization %\""))?;

    let model = raw.lines().find_map(|line| {
        let (_, value) = line.split_once("\"model\"")?;
        let (_, value) = value.split_once('=')?;
        quoted_value(value)
    });
    let model = model.or_else(|| {
        raw.lines()
            .next()?
            .strip_prefix("+-o ")?
            .split_whitespace()
            .next()
            .map(ToOwned::to_owned)
    });

    Some(GpuSnapshot { utilization, model })
}

fn max_ioreg_number(raw: &str, key: &str) -> Option<f64> {
    let mut maximum: Option<f64> = None;
    let mut remaining = raw;
    while let Some((_, after_key)) = remaining.split_once(key) {
        let Some((_, after_equals)) = after_key.split_once('=') else {
            break;
        };
        let number = after_equals
            .trim_start()
            .chars()
            .take_while(|character| character.is_ascii_digit() || *character == '.')
            .collect::<String>();
        if let Ok(value) = number.parse::<f64>() {
            if value.is_finite() && (0.0..=100.0).contains(&value) {
                maximum = Some(maximum.map_or(value, |current| current.max(value)));
            }
        }
        remaining = after_equals;
    }
    maximum
}

fn quoted_value(raw: &str) -> Option<String> {
    let start = raw.find('"')? + 1;
    let end = raw[start..].find('"')? + start;
    let value = raw[start..end].trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn render_report(
    cpu: &CpuSnapshot,
    gpu: Option<&GpuSnapshot>,
    history: &CpuHistory,
    summary_mode: SummaryMode,
) -> Report {
    let (gpu_value, model) = gpu.map_or_else(
        || ("      —".to_string(), Markup::text("—")),
        |gpu| {
            (
                format!("{:>5.1} %", gpu.utilization),
                Markup::text(gpu.model.as_deref().unwrap_or("GPU")),
            )
        },
    );
    let preview = Preview::new()
        .title("CPU")
        .row("Total", format!("{:>5.1} %", cpu.total()))
        .row("User", format!("{:>5.1} %", cpu.user))
        .row("System", format!("{:>5.1} %", cpu.system))
        .row("Idle", format!("{:>5.1} %", cpu.idle))
        .row(
            "Logical CPUs",
            cpu.logical_cpus
                .map_or_else(|| "—".to_string(), |count| count.to_string()),
        )
        .row(
            "Load",
            format!(
                "{:>5.2}  {:>5.2}  {:>5.2}",
                cpu.load[0], cpu.load[1], cpu.load[2]
            ),
        )
        .row(
            "History",
            sparkline_padded(&sparkline_percent(history), CpuHistory::CAPACITY),
        )
        .row(
            "Recent avg",
            if history.is_empty() {
                "—".to_string()
            } else {
                format!(
                    "{:.1} %",
                    history.iter().sum::<f64>() / history.len() as f64
                )
            },
        )
        .row(
            "Recent peak",
            history
                .iter()
                .reduce(f64::max)
                .map_or_else(|| "—".to_string(), |value| format!("{value:.1} %")),
        )
        .row(
            "Load / CPU",
            cpu.logical_cpus.filter(|count| *count > 0).map_or_else(
                || "—".to_string(),
                |count| {
                    format!(
                        "{:.2}  {:.2}  {:.2}",
                        cpu.load[0] / count as f64,
                        cpu.load[1] / count as f64,
                        cpu.load[2] / count as f64
                    )
                },
            ),
        )
        .note("Load: 1 / 5 / 15 min · recent: last 20 samples")
        .row("GPU", gpu_value)
        .row("Model", model);
    Report {
        label: metric("CPU", cpu.total()),
        summary: visible_summary(cpu, gpu, history, summary_mode),
        preview,
        raw: raw_metrics(cpu, history),
    }
}

fn raw_metrics(cpu: &CpuSnapshot, history: &CpuHistory) -> RawMetrics {
    RawMetrics {
        percent: whole_percent(cpu.total()).to_string(),
        history: percent_series(history),
        load: format!("{:.2}", cpu.load[0]),
        uptime: cpu.uptime_seconds.map(duration_uptime).unwrap_or_default(),
    }
}

/// Rounded to the nearest integer and clamped to 0–100; NaN reads as 0.
fn whole_percent(value: f64) -> u8 {
    if value > 0.0 {
        value.min(100.0).round() as u8
    } else {
        0
    }
}

fn percent_series(history: &CpuHistory) -> String {
    history
        .iter()
        .map(|sample| whole_percent(sample).to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Yellow section name plus the grey two-digit percentage the monitor labels
/// share.
fn metric(name: &str, percent: f64) -> Markup {
    Markup::colored(name, Color::TITLE) + " " + Markup::colored(percent2(percent), Color::MUTED)
}

fn visible_summary(
    cpu: &CpuSnapshot,
    gpu: Option<&GpuSnapshot>,
    history: &CpuHistory,
    summary_mode: SummaryMode,
) -> Markup {
    let mut visible = metric("CPU", cpu.total());
    if summary_mode == SummaryMode::Compact {
        return visible;
    }
    if let Some(gpu) = gpu {
        visible += " ";
        visible += Markup::colored("· ", Color::MUTED);
        visible += metric("GPU", gpu.utilization);
    }
    if !history.is_empty() {
        visible += " ";
        visible += sparkline_percent(history);
    }
    visible
}

fn main() {
    run(Cpu::default());
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    /// The wire strings `Context::status` publishes for a report.
    fn wire(report: &Report) -> BTreeMap<&'static str, String> {
        report
            .segments()
            .into_iter()
            .map(|(name, value)| (name, value.render().expect("preview fits inline")))
            .collect()
    }

    fn history(samples: impl IntoIterator<Item = f64>) -> CpuHistory {
        let mut history = CpuHistory::new();
        for sample in samples {
            history.push(sample);
        }
        history
    }

    #[test]
    fn label_keeps_percent_width_through_full_utilization_without_popup_markup() {
        for (user, expected) in [
            (0.0, " 0%"),
            (9.0, " 9%"),
            (10.0, "10%"),
            (99.6, "99%"),
            (100.0, "99%"),
        ] {
            let cpu = CpuSnapshot {
                user,
                system: 0.0,
                idle: 100.0 - user,
                load: [0.0; 3],
                logical_cpus: None,
                uptime_seconds: None,
            };
            let report = render_report(&cpu, None, &history([user]), SummaryMode::Full);
            assert_eq!(
                report.label.as_str(),
                format!("#[fg=#EBCB8B]CPU#[default] #[fg=colour245]{expected}#[default]")
            );
            let segments = wire(&report);
            assert_eq!(segments["label"], report.label.as_str());
            assert!(segments["summary"].contains("popup="));
        }
    }

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn compact_cpu_summary_caps_values_that_would_render_as_three_digits() {
        for (user, expected) in [
            (
                9.0,
                "#[fg=#EBCB8B]CPU#[default] #[fg=colour245] 9%#[default]",
            ),
            (
                10.0,
                "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]10%#[default]",
            ),
            (
                99.6,
                "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]99%#[default]",
            ),
            (
                100.0,
                "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]99%#[default]",
            ),
        ] {
            let cpu = CpuSnapshot {
                user,
                system: 0.0,
                idle: 100.0 - user,
                load: [0.0; 3],
                logical_cpus: None,
                uptime_seconds: None,
            };
            assert_eq!(
                visible_summary(&cpu, None, &CpuHistory::new(), SummaryMode::Compact).as_str(),
                expected
            );
        }
    }

    #[test]
    fn full_cpu_summary_caps_gpu_at_two_percentage_digits() {
        let cpu = CpuSnapshot {
            user: 9.0,
            system: 0.0,
            idle: 91.0,
            load: [0.0; 3],
            logical_cpus: None,
            uptime_seconds: None,
        };
        let gpu = GpuSnapshot {
            utilization: 100.0,
            model: None,
        };

        assert_eq!(
            visible_summary(&cpu, Some(&gpu), &CpuHistory::new(), SummaryMode::Full).as_str(),
            "#[fg=#EBCB8B]CPU#[default] #[fg=colour245] 9%#[default] #[fg=colour245]\
· #[default]#[fg=#EBCB8B]GPU#[default] #[fg=colour245]99%#[default]"
        );
    }

    #[test]
    fn accepts_a_consistent_differential_sample() {
        let snapshot = cpu_snapshot(12.5, 7.25, 80.25, [1.25, 2.5, 3.75]).expect("CPU snapshot");
        assert_eq!(snapshot.total(), 19.75);
        assert_eq!(snapshot.load, [1.25, 2.5, 3.75]);
    }

    #[test]
    fn rejects_impossible_cpu_samples() {
        assert!(cpu_snapshot(90.0, 20.0, 0.0, [1.0, 2.0, 3.0]).is_none());
        assert!(cpu_snapshot(f64::NAN, 0.0, 100.0, [1.0, 2.0, 3.0]).is_none());
        assert!(cpu_snapshot(10.0, 10.0, 80.0, [-1.0, 2.0, 3.0]).is_none());
    }

    #[test]
    fn an_in_flight_collection_is_skipped_instead_of_queued() {
        let gate = tokio::sync::Mutex::new(());
        let held = begin_collection(&gate).expect("first collection");
        assert!(begin_collection(&gate).is_none());
        drop(held);
        assert!(begin_collection(&gate).is_some());
    }

    #[test]
    fn parses_best_effort_ioreg_gpu_fixture() {
        let gpu = parse_ioreg_gpu(include_str!("../fixtures/ioreg.txt")).expect("GPU snapshot");
        assert_eq!(gpu.utilization, 59.0);
        assert_eq!(gpu.model.as_deref(), Some("Apple M4 Pro"));
    }

    #[test]
    fn highest_utilization_accelerator_keeps_its_own_model() {
        let gpu =
            parse_ioreg_gpu(include_str!("../fixtures/ioreg-multi.txt")).expect("GPU snapshot");
        assert_eq!(gpu.utilization, 81.0);
        assert_eq!(gpu.model.as_deref(), Some("Discrete Example"));
    }

    #[test]
    fn gpu_parser_falls_back_to_renderer_and_omits_unsupported_hardware() {
        let gpu = parse_ioreg_gpu(
            "+-o IntelAccelerator <class IntelAccelerator>\n  | \"Renderer Utilization %\"=34",
        )
        .expect("renderer fallback");
        assert_eq!(gpu.utilization, 34.0);
        assert_eq!(gpu.model.as_deref(), Some("IntelAccelerator"));
        assert!(parse_ioreg_gpu("+-o Unsupported <class Unsupported>").is_none());
    }

    #[test]
    fn device_utilization_wins_and_uses_the_highest_accelerator_value() {
        let gpu = parse_ioreg_gpu(
            "\"Device Utilization %\"=17 \"Renderer Utilization %\"=90\n\
             \"Device Utilization %\"=42",
        )
        .expect("GPU snapshot");
        assert_eq!(gpu.utilization, 42.0);
    }

    #[test]
    fn history_keeps_the_newest_twenty_samples() {
        let history = history((0..25).map(|value| f64::from(value) * 4.0));
        assert_eq!(history.len(), HISTORY_SAMPLES);
        assert_eq!(history.iter().next(), Some(20.0));
    }

    #[test]
    fn unchanged_reports_stay_off_the_wire() {
        let cpu = cpu_snapshot(10.0, 5.0, 85.0, [1.0, 2.0, 3.0]).expect("CPU snapshot");
        let mut state = MonitorState {
            cpu: Some(cpu),
            ..MonitorState::default()
        };
        let report = state.report(SummaryMode::Compact).expect("report");
        assert!(state.published.update(report.clone()).is_some());
        assert!(state.published.update(report).is_none());
        state.history.push(50.0);
        let changed = state.report(SummaryMode::Compact).expect("report");
        assert!(state.published.update(changed).is_some());
    }

    #[test]
    fn rendered_status_is_compact_styled_and_popup_backed() {
        let cpu = CpuSnapshot {
            user: 12.5,
            system: 7.25,
            idle: 80.25,
            load: [1.25, 2.5, 3.75],
            logical_cpus: Some(16),
            uptime_seconds: None,
        };
        let gpu = GpuSnapshot {
            utilization: 59.0,
            model: Some("Apple M4 Pro".into()),
        };
        let history = history([10.0, 20.0]);
        let report = render_report(&cpu, Some(&gpu), &history, SummaryMode::Compact);
        let segments = wire(&report);
        assert!(segments["summary"].starts_with("#[popup=inline:"));
        assert!(segments["summary"].ends_with("#[nopopup]"));
        assert!(segments["summary"].contains("CPU#[default] #[fg=colour245]20%#[default]"));
        assert!(!segments["summary"].contains("GPU#[default]"));
        assert!(!segments["summary"].contains("▂"));
        assert_eq!(
            report.summary.as_str(),
            "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]20%#[default]"
        );
        assert!(
            visible_summary(&cpu, Some(&gpu), &history, SummaryMode::Full)
                .as_str()
                .contains("#[fg=#EBCB8B]GPU#[default] #[fg=colour245]59%#[default] ▂▂")
        );
        assert_eq!(CPU_SAMPLE_PERIOD, Duration::from_secs(1));
        assert_eq!(GPU_INTERVAL, Duration::from_secs(15));
        assert_eq!(
            segments["details"],
            "#[fg=#EBCB8B]CPU#[default]\n\
#[fg=colour245]Total         #[default] 19.8 %\n\
#[fg=colour245]User          #[default] 12.5 %\n\
#[fg=colour245]System        #[default]  7.2 %\n\
#[fg=colour245]Idle          #[default] 80.2 %\n\
#[fg=colour245]Logical CPUs  #[default]16\n\
#[fg=colour245]Load          #[default] 1.25   2.50   3.75\n\
#[fg=colour245]History       #[default]··················▂▂\n\
#[fg=colour245]Recent avg    #[default]15.0 %\n\
#[fg=colour245]Recent peak   #[default]20.0 %\n\
#[fg=colour245]Load / CPU    #[default]0.08  0.16  0.23\n\
#[fg=colour245]Load: 1 / 5 / 15 min · recent: last 20 samples#[default]\n\
#[fg=colour245]GPU           #[default] 59.0 %\n\
#[fg=colour245]Model         #[default]Apple M4 Pro"
        );
        assert!(!segments["details"].ends_with('\n'));
        assert_eq!(
            report.preview.render_plain(),
            "CPU\n\
Total          19.8 %\n\
User           12.5 %\n\
System          7.2 %\n\
Idle           80.2 %\n\
Logical CPUs  16\n\
Load           1.25   2.50   3.75\n\
History       ··················▂▂\n\
Recent avg    15.0 %\n\
Recent peak   20.0 %\n\
Load / CPU    0.08  0.16  0.23\n\
Load: 1 / 5 / 15 min · recent: last 20 samples\n\
GPU            59.0 %\n\
Model         Apple M4 Pro"
        );

        let without_gpu = render_report(&cpu, None, &CpuHistory::new(), SummaryMode::Compact);
        assert!(wire(&without_gpu)["details"].ends_with(
            "#[fg=colour245]GPU           #[default]      —\n#[fg=colour245]Model         #[default]—"
        ));
    }

    #[test]
    fn popup_details_escape_marker_looking_gpu_models() {
        let cpu = CpuSnapshot {
            user: 10.0,
            system: 5.0,
            idle: 85.0,
            load: [1.0, 2.0, 3.0],
            logical_cpus: None,
            uptime_seconds: None,
        };
        let gpu = GpuSnapshot {
            utilization: 20.0,
            model: Some("GPU #[fg=colour196] #1".into()),
        };

        let report = render_report(&cpu, Some(&gpu), &CpuHistory::new(), SummaryMode::Compact);
        let details = report.preview.render();
        assert!(details
            .as_str()
            .contains("#[fg=colour245]Model         #[default]GPU ##[fg=colour196] ##1"));
        assert!(report
            .preview
            .render_plain()
            .ends_with("Model         GPU #[fg=colour196] #1"));
    }

    #[test]
    fn detail_statistics_describe_the_sampled_cpu_window() {
        let cpu = CpuSnapshot {
            user: 20.0,
            system: 5.0,
            idle: 75.0,
            load: [4.0, 3.0, 2.0],
            logical_cpus: Some(8),
            uptime_seconds: None,
        };
        let details = render_report(
            &cpu,
            None,
            &history([10.0, 20.0, 60.0]),
            SummaryMode::Compact,
        )
        .preview
        .render_plain();
        assert!(details.contains("Recent avg    30.0 %"), "{details}");
        assert!(details.contains("Recent peak   60.0 %"), "{details}");
        assert!(
            details.contains("Load / CPU    0.50  0.38  0.25"),
            "{details}"
        );
        assert!(details.contains("1 / 5 / 15 min"), "{details}");
        assert!(details.lines().all(|line| line.chars().count() <= 50));
        let empty = render_report(&cpu, None, &CpuHistory::new(), SummaryMode::Compact)
            .preview
            .render_plain();
        assert!(empty.contains("Recent avg    —"), "{empty}");
        assert!(empty.contains("Recent peak   —"), "{empty}");
    }

    fn sample(user: f64, load: f64, uptime_seconds: Option<u64>) -> CpuSnapshot {
        CpuSnapshot {
            user,
            system: 0.0,
            idle: 100.0 - user,
            load: [load, 0.0, 0.0],
            logical_cpus: None,
            uptime_seconds,
        }
    }

    #[test]
    fn raw_segments_publish_plain_numbers_with_history_oldest_first() {
        let cpu = CpuSnapshot {
            user: 12.5,
            system: 7.25,
            idle: 80.25,
            load: [1.254, 2.5, 3.75],
            logical_cpus: Some(16),
            uptime_seconds: Some(3 * 86_400 + 4 * 3_600 + 59 * 60),
        };
        let report = render_report(
            &cpu,
            None,
            &history([0.4, 50.5, 99.6, 100.0]),
            SummaryMode::Compact,
        );
        let segments = wire(&report);
        assert_eq!(segments["percent"], "20");
        assert_eq!(segments["history"], "0 51 100 100");
        assert_eq!(segments["load"], "1.25");
        assert_eq!(segments["uptime"], "3d 4h");
        for name in ["percent", "history", "load", "uptime"] {
            assert!(!segments[name].contains("#["), "{name}: {}", segments[name]);
        }
    }

    #[test]
    fn raw_percent_rounds_to_an_integer_without_the_label_cap() {
        for (user, expected) in [
            (0.0, "0"),
            (0.4, "0"),
            (0.5, "1"),
            (9.5, "10"),
            (99.4, "99"),
            (99.6, "100"),
            (100.0, "100"),
        ] {
            let report = render_report(
                &sample(user, 0.0, None),
                None,
                &CpuHistory::new(),
                SummaryMode::Compact,
            );
            assert_eq!(report.raw.percent, expected, "{user}");
        }
        assert_eq!(whole_percent(f64::NAN), 0);
        assert_eq!(whole_percent(-3.0), 0);
        assert_eq!(whole_percent(250.0), 100);
    }

    #[test]
    fn raw_history_keeps_the_newest_twenty_samples_oldest_first() {
        let report = render_report(
            &sample(10.0, 0.0, None),
            None,
            &history((0..25).map(f64::from)),
            SummaryMode::Compact,
        );
        let expected = (5..25).map(|value| value.to_string()).collect::<Vec<_>>();
        assert_eq!(report.raw.history, expected.join(" "));
    }

    #[test]
    fn raw_load_keeps_two_decimals_and_missing_values_clear_their_segments() {
        let report = render_report(
            &sample(10.0, 12.3, None),
            None,
            &CpuHistory::new(),
            SummaryMode::Compact,
        );
        let segments = wire(&report);
        assert_eq!(segments["load"], "12.30");
        assert_eq!(segments["history"], "");
        assert_eq!(segments["uptime"], "");
        assert_eq!(
            raw_metrics(&sample(0.0, 0.0, Some(42)), &CpuHistory::new()).load,
            "0.00"
        );
    }

    #[test]
    fn raw_uptime_uses_two_units_and_republishes_only_when_its_text_changes() {
        for (seconds, expected) in [
            (42, "42s"),
            (5 * 60 + 59, "5m"),
            (2 * 3_600 + 3 * 60, "2h 3m"),
            (86_400 + 2 * 3_600 + 59 * 60, "1d 2h"),
        ] {
            assert_eq!(
                raw_metrics(&sample(0.0, 0.0, Some(seconds)), &CpuHistory::new()).uptime,
                expected
            );
        }

        let mut published = Published::new();
        let render = |uptime| {
            render_report(
                &sample(10.0, 1.0, Some(uptime)),
                None,
                &CpuHistory::new(),
                SummaryMode::Compact,
            )
        };
        assert!(published.update(render(86_400 + 60)).is_some());
        assert!(published.update(render(86_400 + 120)).is_none());
        assert!(published.update(render(86_400 + 3_600)).is_some());
    }

    #[test]
    fn uptime_reads_the_boot_relative_clock() {
        assert!(uptime_seconds().is_some_and(|seconds| seconds > 0));
    }
}

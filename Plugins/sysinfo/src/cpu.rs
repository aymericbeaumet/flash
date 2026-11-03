//! CPU and GPU: `host_processor_info` tick counters sampled once per period,
//! GPU utilization from the IOKit registry, both in-process.

use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use flash_plugin::status::{duration_uptime, percent2, sparkline_padded, sparkline_percent};
use flash_plugin::{
    Color, Context, History, Markup, ObservedCadences, PerformResponse, PollPriority, Preview,
    Published, StatusValue, sys,
};
use nix::time::{ClockId, clock_gettime};

use crate::common::{
    GatePolicy, HISTORY_SAMPLES, SummaryMode, acquire_collection, configured_summary_mode, lock,
    percent_series, plain, whole_percent,
};

/// The `core:status.observed` prefix of this domain's segments.
pub(crate) const PREFIX: &str = "cpu_";
/// The published segments, in manifest order.
pub(crate) const SEGMENTS: [&str; 7] = [
    "cpu_summary",
    "cpu_label",
    "cpu_details",
    "cpu_percent",
    "cpu_history",
    "cpu_load",
    "cpu_uptime",
];

const CPU_SAMPLE_PERIOD: Duration = Duration::from_secs(1);
const GPU_INTERVAL: Duration = Duration::from_secs(15);
/// `PerformanceStatistics` keys in preference order: the first one an
/// accelerator publishes with a usable value is its utilization.
const UTILIZATION_KEYS: [&str; 3] = [
    "Device Utilization %",
    "Renderer Utilization %",
    "Tiler Utilization %",
];
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
        let [summary, label, details, percent, history, load, uptime] = SEGMENTS;
        [
            (
                summary,
                StatusValue::text(self.summary.clone()).with_preview(self.preview.clone()),
            ),
            (label, StatusValue::text(self.label.clone())),
            (details, StatusValue::text(self.preview.render())),
            (percent, plain(&self.raw.percent)),
            (history, plain(&self.raw.history)),
            (load, plain(&self.raw.load)),
            (uptime, plain(&self.raw.uptime)),
        ]
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

pub(crate) struct Cpu {
    state: Arc<Mutex<MonitorState>>,
    cpu_gate: Arc<tokio::sync::Mutex<()>>,
    gpu_gate: Arc<tokio::sync::Mutex<()>>,
    cadences: ObservedCadences,
}

impl Default for Cpu {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(MonitorState::default())),
            cpu_gate: Arc::new(tokio::sync::Mutex::new(())),
            gpu_gate: Arc::new(tokio::sync::Mutex::new(())),
            cadences: ObservedCadences::default(),
        }
    }
}

impl Cpu {
    /// The initial sample, then the cadences behind the segments.
    pub(crate) async fn start(&self, ctx: &Context) {
        refresh_all(
            ctx,
            &self.state,
            &self.cpu_gate,
            &self.gpu_gate,
            GatePolicy::Wait,
        )
        .await;

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.cpu_gate);
        // `High`: a one-second figure on screen; a tenth of a second of
        // slack would make it tick visibly unevenly.
        self.cadences
            .interval(ctx, CPU_SAMPLE_PERIOD, PollPriority::High, move |ctx| {
                let state = Arc::clone(&state);
                let gate = Arc::clone(&gate);
                async move {
                    refresh_cpu(&ctx, &state, &gate).await;
                }
            });

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.gpu_gate);
        // `Normal`: a fifteen-second sample nobody watches tick.
        self.cadences
            .interval(ctx, GPU_INTERVAL, PollPriority::Normal, move |ctx| {
                let state = Arc::clone(&state);
                let gate = Arc::clone(&gate);
                async move {
                    refresh_gpu(&ctx, &state, &gate).await;
                }
            });
    }

    /// `core:status.observed`, reduced to this domain's segments.
    pub(crate) fn observe(&self, ctx: &Context, segments: &[String]) {
        if self.cadences.observe(segments) {
            let ctx = ctx.clone();
            let (state, cpu_gate, gpu_gate) = (
                Arc::clone(&self.state),
                Arc::clone(&self.cpu_gate),
                Arc::clone(&self.gpu_gate),
            );
            tokio::spawn(async move {
                refresh_all(&ctx, &state, &cpu_gate, &gpu_gate, GatePolicy::Wait).await;
            });
        }
    }

    /// The details; unobserved, nothing samples between commands, so it
    /// samples first.
    pub(crate) async fn show(&self, ctx: &Context) -> PerformResponse {
        if !self.cadences.observed() {
            self.refresh(ctx).await;
        }
        details_response(current_report(ctx, &self.state))
    }

    /// A sample that skips a busy collector rather than queueing behind it.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        refresh_all(
            ctx,
            &self.state,
            &self.cpu_gate,
            &self.gpu_gate,
            GatePolicy::SkipIfBusy,
        )
        .await;
    }

    /// The visible summary of the last report.
    pub(crate) fn summary(&self, ctx: &Context) -> Option<Markup> {
        current_report(ctx, &self.state).map(|report| report.summary)
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
        collect_cpu(ctx, state, cpu_gate, policy),
        collect_gpu(gpu_gate, policy)
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
    let result = collect_cpu(ctx, state, gate, GatePolicy::Wait).await;
    apply_cpu_result(ctx, state, result);
    publish_if_changed(ctx, state);
}

async fn refresh_gpu(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
) {
    let result = collect_gpu(gate, GatePolicy::Wait).await;
    apply_gpu_result(ctx, state, result);
    publish_if_changed(ctx, state);
}

async fn collect_cpu(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) -> Collection<CpuSnapshot> {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return Collection::Busy;
    };
    let baseline = lock(state).ticks;
    let previous = match baseline {
        Some(ticks) => ticks,
        None => {
            // First sample: bracket one period, on the host's clock, so the
            // initial publish carries a real figure instead of waiting for
            // the next tick.
            let Ok(first) = sys::cpu_ticks() else {
                return Collection::Failed;
            };
            ctx.wait(CPU_SAMPLE_PERIOD, PollPriority::High).await;
            first
        }
    };
    let Ok(current) = sys::cpu_ticks() else {
        return Collection::Failed;
    };
    lock(state).ticks = Some(current);
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
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) -> Collection<Option<GpuSnapshot>> {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return Collection::Busy;
    };
    // A registry read of tens of microseconds, like the CPU tick sample.
    match sys::gpu_statistics() {
        Ok(accelerators) => gpu_collection(&accelerators),
        Err(_) => Collection::Failed,
    }
}

/// A GPU without utilization statistics renders as `—`; one whose
/// utilization keys hold no usable value is a failed sample, which keeps the
/// last good figure.
fn gpu_collection(accelerators: &[sys::GpuStatistics]) -> Collection<Option<GpuSnapshot>> {
    match gpu_snapshot(accelerators) {
        Some(snapshot) => Collection::Fresh(Some(snapshot)),
        None if accelerators.iter().any(|accelerator| {
            UTILIZATION_KEYS
                .iter()
                .any(|key| accelerator.performance.contains_key(*key))
        }) =>
        {
            Collection::Failed
        }
        None => Collection::Fresh(None),
    }
}

fn apply_cpu_result(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    result: Collection<CpuSnapshot>,
) {
    let mut state = lock(state);
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
                "[sysinfo] CPU sample unavailable; retaining last good value",
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
    let mut state = lock(state);
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
                "[sysinfo] GPU sample unavailable; retaining last good value",
            );
        }
        Collection::Busy | Collection::Failed => {}
    }
}

fn publish_if_changed(ctx: &Context, state: &Arc<Mutex<MonitorState>>) {
    let segments = {
        let mut state = lock(state);
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
    lock(state).report(configured_summary_mode(ctx))
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

/// The busiest accelerator, which keeps its own model name.
fn gpu_snapshot(accelerators: &[sys::GpuStatistics]) -> Option<GpuSnapshot> {
    accelerators
        .iter()
        .filter_map(accelerator_snapshot)
        .reduce(|current, candidate| {
            if candidate.utilization > current.utilization {
                candidate
            } else {
                current
            }
        })
}

fn accelerator_snapshot(accelerator: &sys::GpuStatistics) -> Option<GpuSnapshot> {
    let utilization = UTILIZATION_KEYS.iter().find_map(|key| {
        accelerator
            .performance
            .get(*key)
            .copied()
            .filter(|value| value.is_finite() && (0.0..=100.0).contains(value))
    })?;
    let model = accelerator
        .model
        .as_deref()
        .map(str::trim)
        .filter(|model| !model.is_empty())
        .or_else(|| Some(accelerator.name.trim()).filter(|name| !name.is_empty()))
        .map(ToOwned::to_owned);
    Some(GpuSnapshot { utilization, model })
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
        // The template owns the name and the width (`#[label]CPU #[default]#{p-3:…}`).
        label: Markup::text(percent2(cpu.total()).trim()),
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

/// Yellow section name plus the grey two-digit percentage. `summary` only:
/// `label` is the percentage, and the template owns the name.
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
    fn segments_carry_the_domain_prefix_in_manifest_order() {
        let report = render_report(
            &sample(10.0, 1.0, None),
            None,
            &CpuHistory::new(),
            SummaryMode::Compact,
        );
        assert_eq!(report.segments().map(|(name, _)| name), SEGMENTS);
        assert!(SEGMENTS.iter().all(|name| name.starts_with(PREFIX)));
    }

    #[test]
    fn label_keeps_percent_width_through_full_utilization_without_popup_markup() {
        for (user, expected) in [
            (0.0, "0%"),
            (9.0, "9%"),
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
            assert_eq!(report.label.as_str(), expected);
            assert!(!report.label.as_str().contains("#["));
            let segments = wire(&report);
            assert_eq!(segments["cpu_label"], report.label.as_str());
            assert!(segments["cpu_summary"].contains("popup="));
        }
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

    fn accelerator(
        name: &str,
        model: Option<&str>,
        performance: &[(&str, f64)],
    ) -> sys::GpuStatistics {
        sys::GpuStatistics {
            name: name.to_string(),
            model: model.map(ToOwned::to_owned),
            performance: performance
                .iter()
                .map(|(key, value)| (key.to_string(), *value))
                .collect(),
        }
    }

    #[test]
    fn device_utilization_and_model_describe_the_gpu() {
        let gpu = gpu_snapshot(&[accelerator(
            "AGXAcceleratorG16X",
            Some("Apple M4 Pro"),
            &[
                ("Tiler Utilization %", 22.0),
                ("Renderer Utilization %", 47.0),
                ("Device Utilization %", 59.0),
                ("In use system memory", 1.5e9),
            ],
        )])
        .expect("GPU snapshot");
        assert_eq!(gpu.utilization, 59.0);
        assert_eq!(gpu.model.as_deref(), Some("Apple M4 Pro"));
    }

    #[test]
    fn highest_utilization_accelerator_keeps_its_own_model() {
        let gpu = gpu_snapshot(&[
            accelerator(
                "SlowAccelerator",
                Some("Integrated Example"),
                &[
                    ("Renderer Utilization %", 95.0),
                    ("Device Utilization %", 24.0),
                ],
            ),
            accelerator(
                "FastAccelerator",
                Some("Discrete Example"),
                &[
                    ("Renderer Utilization %", 70.0),
                    ("Device Utilization %", 81.0),
                ],
            ),
        ])
        .expect("GPU snapshot");
        assert_eq!(gpu.utilization, 81.0);
        assert_eq!(gpu.model.as_deref(), Some("Discrete Example"));
    }

    #[test]
    fn gpu_falls_back_to_renderer_then_tiler_and_to_the_entry_name() {
        let renderer = gpu_snapshot(&[accelerator(
            "IntelAccelerator",
            None,
            &[
                ("Renderer Utilization %", 34.0),
                ("Tiler Utilization %", 12.0),
            ],
        )])
        .expect("renderer fallback");
        assert_eq!(renderer.utilization, 34.0);
        assert_eq!(renderer.model.as_deref(), Some("IntelAccelerator"));
        let tiler = gpu_snapshot(&[accelerator(
            "Tiled",
            Some("  "),
            &[
                ("Device Utilization %", 140.0),
                ("Tiler Utilization %", 12.0),
            ],
        )])
        .expect("tiler fallback past an out-of-range device value");
        assert_eq!(tiler.utilization, 12.0);
        assert_eq!(tiler.model.as_deref(), Some("Tiled"));
    }

    #[test]
    fn gpu_collection_distinguishes_unsupported_hardware_from_bad_samples() {
        assert!(matches!(gpu_collection(&[]), Collection::Fresh(None)));
        assert!(matches!(
            gpu_collection(&[accelerator("Unsupported", None, &[("recoveryCount", 0.0)])]),
            Collection::Fresh(None)
        ));
        assert!(matches!(
            gpu_collection(&[accelerator(
                "Broken",
                None,
                &[
                    ("Device Utilization %", -1.0),
                    ("Renderer Utilization %", f64::NAN)
                ]
            )]),
            Collection::Failed
        ));
        assert!(matches!(
            gpu_collection(&[accelerator("Busy", None, &[("Device Utilization %", 42.0)])]),
            Collection::Fresh(Some(GpuSnapshot {
                utilization: 42.0,
                ..
            }))
        ));
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
        assert!(segments["cpu_summary"].starts_with("#[popup=inline:"));
        assert!(segments["cpu_summary"].ends_with("#[nopopup]"));
        assert!(segments["cpu_summary"].contains("CPU#[default] #[fg=colour245]20%#[default]"));
        assert!(!segments["cpu_summary"].contains("GPU#[default]"));
        assert!(!segments["cpu_summary"].contains("▂"));
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
            segments["cpu_details"],
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
        assert!(!segments["cpu_details"].ends_with('\n'));
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
        assert!(wire(&without_gpu)["cpu_details"].ends_with(
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
        assert!(
            details
                .as_str()
                .contains("#[fg=colour245]Model         #[default]GPU ##[fg=colour196] ##1")
        );
        assert!(
            report
                .preview
                .render_plain()
                .ends_with("Model         GPU #[fg=colour196] #1")
        );
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
        assert_eq!(segments["cpu_percent"], "20");
        assert_eq!(segments["cpu_history"], "0 51 100 100");
        assert_eq!(segments["cpu_load"], "1.25");
        assert_eq!(segments["cpu_uptime"], "3d 4h");
        for name in ["cpu_percent", "cpu_history", "cpu_load", "cpu_uptime"] {
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
        assert_eq!(segments["cpu_load"], "12.30");
        assert_eq!(segments["cpu_history"], "");
        assert_eq!(segments["cpu_uptime"], "");
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

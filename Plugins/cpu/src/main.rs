use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, run_command_with_slow_threshold,
    CommandRequest, Context, PerformResponse,
};

// iostat blocks for the one-second differential sample but consumes
// negligible CPU, unlike repeatedly launching top on a busy machine.
const CPU_SAMPLE_PERIOD: Duration = Duration::from_secs(1);
const GPU_INTERVAL: Duration = Duration::from_secs(15);
const CPU_TIMEOUT: Duration = Duration::from_secs(3);
const CPU_SLOW_THRESHOLD: Duration = Duration::from_millis(1_500);
const GPU_TIMEOUT: Duration = Duration::from_secs(4);
const HISTORY_SAMPLES: usize = 20;
const DETAIL_LABEL_WIDTH: usize = 14;
const IOSTAT: &str = "/usr/sbin/iostat";
const IOREG: &str = "/usr/sbin/ioreg";

#[derive(Clone, Debug, PartialEq)]
struct CpuSnapshot {
    user: f64,
    system: f64,
    idle: f64,
    load: [f64; 3],
    logical_cpus: Option<usize>,
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

#[derive(Clone, Debug, PartialEq, Eq)]
struct StatusSegments {
    summary: String,
    label: String,
    details: String,
    plain_details: String,
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
    gpu: Option<GpuSnapshot>,
    history: VecDeque<f64>,
    published: Option<StatusSegments>,
    cpu_failure_logged: bool,
    gpu_failure_logged: bool,
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

        let cpu_ctx = ctx.clone();
        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.cpu_gate);
        drop(tokio::spawn(async move {
            loop {
                let started = Instant::now();
                refresh_cpu(&cpu_ctx, &state, &gate).await;
                tokio::time::sleep(cpu_sample_delay(started.elapsed())).await;
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
            "" => details_response(current_status(&ctx, &self.state)),
            "refresh" => {
                refresh_all(
                    &ctx,
                    &self.state,
                    &self.cpu_gate,
                    &self.gpu_gate,
                    GatePolicy::SkipIfBusy,
                )
                .await;
                details_response(current_status(&ctx, &self.state))
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
        collect_cpu(ctx, cpu_gate, policy),
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
    let result = collect_cpu(ctx, gate, GatePolicy::Wait).await;
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
    ctx: &Context,
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) -> Collection<CpuSnapshot> {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return Collection::Busy;
    };
    let output = run_command_with_slow_threshold(
        ctx,
        &[
            IOSTAT.to_string(),
            "-c".to_string(),
            "2".to_string(),
            "-w".to_string(),
            "1".to_string(),
        ],
        CPU_TIMEOUT,
        CPU_SLOW_THRESHOLD,
    )
    .await;
    if !output.ok {
        return Collection::Failed;
    }
    parse_iostat(&output.stdout)
        .map(|mut snapshot| {
            snapshot.logical_cpus = std::thread::available_parallelism().ok().map(usize::from);
            Collection::Fresh(snapshot)
        })
        .unwrap_or(Collection::Failed)
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

fn cpu_sample_delay(elapsed: Duration) -> Duration {
    CPU_SAMPLE_PERIOD.saturating_sub(elapsed)
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
            append_history(&mut state.history, snapshot.total());
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
    let next = {
        let mut state = lock_state(state);
        let cpu = match state.cpu.as_ref() {
            Some(cpu) => cpu,
            None => return,
        };
        let rendered = render_status(
            cpu,
            state.gpu.as_ref(),
            &state.history,
            configured_summary_mode(ctx),
        );
        if state.published.as_ref() == Some(&rendered) {
            return;
        }
        state.published = Some(rendered.clone());
        rendered
    };
    ctx.status([
        ("summary", next.summary.as_str()),
        ("label", next.label.as_str()),
        ("details", next.details.as_str()),
    ]);
}

fn current_status(ctx: &Context, state: &Arc<Mutex<MonitorState>>) -> Option<StatusSegments> {
    let state = lock_state(state);
    let cpu = state.cpu.as_ref()?;
    Some(render_status(
        cpu,
        state.gpu.as_ref(),
        &state.history,
        configured_summary_mode(ctx),
    ))
}

fn lock_state(state: &Arc<Mutex<MonitorState>>) -> std::sync::MutexGuard<'_, MonitorState> {
    state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn details_response(status: Option<StatusSegments>) -> PerformResponse {
    status
        .map(|status| PerformResponse::ok().message(status.plain_details))
        .unwrap_or_else(|| PerformResponse::fail("CPU information unavailable"))
}

fn parse_iostat(raw: &str) -> Option<CpuSnapshot> {
    raw.lines().rev().find_map(parse_iostat_row)
}

fn parse_iostat_row(line: &str) -> Option<CpuSnapshot> {
    let values = line
        .split_whitespace()
        .map(str::parse::<f64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let offset = values.len().checked_sub(6)?;
    let snapshot = CpuSnapshot {
        user: values[offset],
        system: values[offset + 1],
        idle: values[offset + 2],
        load: [values[offset + 3], values[offset + 4], values[offset + 5]],
        logical_cpus: None,
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

fn append_history(history: &mut VecDeque<f64>, value: f64) {
    history.push_back(value.clamp(0.0, 100.0));
    while history.len() > HISTORY_SAMPLES {
        history.pop_front();
    }
}

fn sparkline(history: &VecDeque<f64>) -> String {
    const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    history
        .iter()
        .map(|value| {
            let index = (value.clamp(0.0, 100.0) / 100.0 * 7.0).round() as usize;
            BARS[index]
        })
        .collect()
}

fn render_status(
    cpu: &CpuSnapshot,
    gpu: Option<&GpuSnapshot>,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> StatusSegments {
    let total = cpu.total();
    let visible = visible_summary(cpu, gpu, history, summary_mode);

    let body = format!(
        "User: {:.1}% · System: {:.1}% · Idle: {:.1}%\n\
Load: {:.2} · {:.2} · {:.2}",
        cpu.user, cpu.system, cpu.idle, cpu.load[0], cpu.load[1], cpu.load[2]
    );
    let (gpu_value, model) = gpu
        .map(|gpu| {
            (
                format!("{:>5.1} %", gpu.utilization),
                escape_status_text(gpu.model.as_deref().unwrap_or("GPU")),
            )
        })
        .unwrap_or_else(|| ("      —".to_string(), "—".to_string()));
    let details = [
        "#[fg=#EBCB8B]CPU#[default]".to_string(),
        detail_row("Total", &format!("{total:>5.1} %")),
        detail_row("User", &format!("{:>5.1} %", cpu.user)),
        detail_row("System", &format!("{:>5.1} %", cpu.system)),
        detail_row("Idle", &format!("{:>5.1} %", cpu.idle)),
        detail_row(
            "Logical CPUs",
            &cpu.logical_cpus
                .map(|count| count.to_string())
                .unwrap_or_else(|| "—".into()),
        ),
        detail_row(
            "Load",
            &format!(
                "{:>5.2}  {:>5.2}  {:>5.2}",
                cpu.load[0], cpu.load[1], cpu.load[2]
            ),
        ),
        detail_row("History", &padded_history(history)),
        detail_row("GPU", &gpu_value),
        detail_row("Model", &model),
    ]
    .join("\n");
    let mut plain_details = format!("CPU {total:.1}%\n{body}");
    if let Some(count) = cpu.logical_cpus {
        plain_details.push_str(&format!("\nLogical CPUs: {count}"));
    }
    if !history.is_empty() {
        let history = format!("\nHistory: {}", sparkline(history));
        plain_details.push_str(&history);
    }
    if let Some(gpu) = gpu {
        let label = gpu.model.as_deref().unwrap_or("GPU");
        plain_details.push_str(&format!("\n\nGPU\n{label}: {:.0}%", gpu.utilization));
    }

    StatusSegments {
        summary: inline_status_popup(&visible, &details),
        label: format!(
            "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]{:>2.0}%#[default]",
            total.min(99.0)
        ),
        details,
        plain_details,
    }
}

fn detail_row(label: &str, value: &str) -> String {
    format!(
        "#[fg=colour245]{label:<width$}#[default]{value}",
        width = DETAIL_LABEL_WIDTH
    )
}

fn padded_history(history: &VecDeque<f64>) -> String {
    let chart = sparkline(history);
    let padding = HISTORY_SAMPLES.saturating_sub(chart.chars().count());
    format!("{}{chart}", "·".repeat(padding))
}

fn visible_summary(
    cpu: &CpuSnapshot,
    gpu: Option<&GpuSnapshot>,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> String {
    let total = cpu.total().min(99.0);
    let mut visible = format!("#[fg=#EBCB8B]CPU#[default] #[fg=colour245]{total:>2.0}%#[default]");
    if summary_mode == SummaryMode::Compact {
        return visible;
    }
    if let Some(gpu) = gpu {
        let utilization = gpu.utilization.min(99.0);
        visible.push_str(&format!(
            " #[fg=colour245]· #[fg=#EBCB8B]GPU#[default] #[fg=colour245]{:>2.0}%#[default]",
            utilization,
        ));
    }
    if !history.is_empty() {
        visible.push(' ');
        visible.push_str(&sparkline(history));
    }
    visible
}

fn main() {
    run(Cpu::default());
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

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
            };
            let status = render_status(&cpu, None, &VecDeque::from([user]), SummaryMode::Full);
            assert_eq!(
                status.label,
                format!("#[fg=#EBCB8B]CPU#[default] #[fg=colour245]{expected}#[default]")
            );
            assert!(status.summary.contains("popup="));
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
            };
            assert_eq!(
                visible_summary(&cpu, None, &VecDeque::new(), SummaryMode::Compact),
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
        };
        let gpu = GpuSnapshot {
            utilization: 100.0,
            model: None,
        };

        assert_eq!(
            visible_summary(&cpu, Some(&gpu), &VecDeque::new(), SummaryMode::Full),
            "#[fg=#EBCB8B]CPU#[default] #[fg=colour245] 9%#[default] #[fg=colour245]\
· #[fg=#EBCB8B]GPU#[default] #[fg=colour245]99%#[default]"
        );
    }

    #[test]
    fn parses_second_iostat_cpu_and_load_fixture() {
        let snapshot = parse_iostat(include_str!("../fixtures/iostat.txt")).expect("CPU snapshot");
        assert_eq!(snapshot.user, 12.5);
        assert_eq!(snapshot.system, 7.25);
        assert_eq!(snapshot.idle, 80.25);
        assert_eq!(snapshot.total(), 19.75);
        assert_eq!(snapshot.load, [1.25, 2.5, 3.75]);
    }

    #[test]
    fn rejects_incomplete_or_impossible_cpu_samples() {
        assert!(parse_iostat("disk0 cpu load average\nKB/t tps MB/s us sy id 1m 5m 15m").is_none());
        assert!(parse_iostat("1 2 3 90 20 0 1 2 3").is_none());
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
    fn history_is_bounded_and_sparkline_is_deterministic() {
        let mut history = VecDeque::new();
        for value in 0..25 {
            append_history(&mut history, f64::from(value) * 4.0);
        }
        assert_eq!(history.len(), HISTORY_SAMPLES);
        assert_eq!(history.front().copied(), Some(20.0));
        assert_eq!(
            sparkline(&VecDeque::from([0.0, 12.5, 50.0, 87.5, 100.0])),
            "▁▂▅▇█"
        );
    }

    #[test]
    fn rendered_status_is_compact_styled_and_popup_backed() {
        let cpu = CpuSnapshot {
            user: 12.5,
            system: 7.25,
            idle: 80.25,
            load: [1.25, 2.5, 3.75],
            logical_cpus: Some(16),
        };
        let gpu = GpuSnapshot {
            utilization: 59.0,
            model: Some("Apple M4 Pro".into()),
        };
        let history = VecDeque::from([10.0, 20.0]);
        let rendered = render_status(&cpu, Some(&gpu), &history, SummaryMode::Compact);
        assert!(rendered.summary.starts_with("#[popup=inline:"));
        assert!(rendered.summary.ends_with("#[nopopup]"));
        assert!(rendered
            .summary
            .contains("CPU#[default] #[fg=colour245]20%#[default]"));
        assert!(!rendered.summary.contains("GPU#[default]"));
        assert!(!rendered.summary.contains("▂"));
        assert_eq!(
            visible_summary(&cpu, Some(&gpu), &history, SummaryMode::Compact),
            "#[fg=#EBCB8B]CPU#[default] #[fg=colour245]20%#[default]"
        );
        assert!(
            visible_summary(&cpu, Some(&gpu), &history, SummaryMode::Full)
                .contains("#[fg=#EBCB8B]GPU#[default] #[fg=colour245]59%#[default] ▂▂")
        );
        assert_eq!(CPU_SAMPLE_PERIOD, Duration::from_secs(1));
        assert_eq!(GPU_INTERVAL, Duration::from_secs(15));
        assert_eq!(
            rendered.details,
            "#[fg=#EBCB8B]CPU#[default]\n\
#[fg=colour245]Total         #[default] 19.8 %\n\
#[fg=colour245]User          #[default] 12.5 %\n\
#[fg=colour245]System        #[default]  7.2 %\n\
#[fg=colour245]Idle          #[default] 80.2 %\n\
#[fg=colour245]Logical CPUs  #[default]16\n\
#[fg=colour245]Load          #[default] 1.25   2.50   3.75\n\
#[fg=colour245]History       #[default]··················▂▂\n\
#[fg=colour245]GPU           #[default] 59.0 %\n\
#[fg=colour245]Model         #[default]Apple M4 Pro"
        );
        assert!(!rendered.details.ends_with('\n'));
        assert!(!rendered.plain_details.contains("#["));
        assert!(rendered.plain_details.starts_with("CPU 19.8%\n"));
        assert!(rendered.plain_details.contains("GPU\nApple M4 Pro: 59%"));
        assert!(rendered.plain_details.contains("Logical CPUs: 16"));

        let without_gpu = render_status(&cpu, None, &VecDeque::new(), SummaryMode::Compact);
        assert!(without_gpu.details.ends_with(
            "#[fg=colour245]History       #[default]····················\n#[fg=colour245]GPU           #[default]      —\n#[fg=colour245]Model         #[default]—"
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
        };
        let gpu = GpuSnapshot {
            utilization: 20.0,
            model: Some("GPU #[fg=colour196] #1".into()),
        };

        let details =
            render_status(&cpu, Some(&gpu), &VecDeque::new(), SummaryMode::Compact).details;
        assert!(details.contains("#[fg=colour245]Model         #[default]GPU ##[fg=colour196] ##1"));
    }

    #[test]
    fn cpu_sampler_accounts_for_the_blocking_iostat_window() {
        assert_eq!(
            cpu_sample_delay(Duration::from_millis(250)),
            Duration::from_millis(750)
        );
        assert_eq!(cpu_sample_delay(Duration::from_secs(1)), Duration::ZERO);
        assert_eq!(cpu_sample_delay(Duration::from_secs(2)), Duration::ZERO);
    }
}

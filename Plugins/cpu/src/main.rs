use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, run_command_with_slow_threshold,
    CommandRequest, Context, PerformResponse,
};

// iostat blocks for the one-second differential sample but consumes
// negligible CPU, unlike repeatedly launching top on a busy machine.
const CPU_INTERVAL: Duration = Duration::from_secs(5);
const GPU_INTERVAL: Duration = Duration::from_secs(15);
const CPU_TIMEOUT: Duration = Duration::from_secs(3);
const CPU_SLOW_THRESHOLD: Duration = Duration::from_millis(1_500);
const GPU_TIMEOUT: Duration = Duration::from_secs(4);
const HISTORY_SAMPLES: usize = 20;
const IOSTAT: &str = "/usr/sbin/iostat";
const IOREG: &str = "/usr/sbin/ioreg";

#[derive(Clone, Debug, PartialEq)]
struct CpuSnapshot {
    user: f64,
    system: f64,
    idle: f64,
    load: [f64; 3],
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

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.cpu_gate);
        drop(ctx.interval(CPU_INTERVAL, move |ctx| {
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
        .map(Collection::Fresh)
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
    let mut details = format!("#[fg=colour178,bold]CPU#[default] {total:.1}%\n{body}");
    let mut plain_details = format!("CPU {total:.1}%\n{body}");
    if !history.is_empty() {
        let history = format!("\nHistory: {}", sparkline(history));
        details.push_str(&history);
        plain_details.push_str(&history);
    }
    if let Some(gpu) = gpu {
        let label = gpu.model.as_deref().unwrap_or("GPU");
        details.push_str(&format!(
            "\n\n#[fg=colour178,bold]GPU#[default]\n{}: {:.0}%",
            escape_status_text(label),
            gpu.utilization
        ));
        plain_details.push_str(&format!("\n\nGPU\n{label}: {:.0}%", gpu.utilization));
    }

    StatusSegments {
        summary: inline_status_popup(&visible, &details),
        details,
        plain_details,
    }
}

fn visible_summary(
    cpu: &CpuSnapshot,
    gpu: Option<&GpuSnapshot>,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> String {
    let mut visible = format!("#[fg=colour178,bold]CPU#[default] {:.0}%", cpu.total());
    if summary_mode == SummaryMode::Compact {
        return visible;
    }
    if let Some(gpu) = gpu {
        visible.push_str(&format!(
            " #[fg=colour245]· #[fg=colour178,bold]GPU#[default] {:.0}%",
            gpu.utilization
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
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn compact_cpu_summary_uses_natural_percentage_width() {
        for (user, expected) in [
            (0.0, "#[fg=colour178,bold]CPU#[default] 0%"),
            (100.0, "#[fg=colour178,bold]CPU#[default] 100%"),
        ] {
            let cpu = CpuSnapshot {
                user,
                system: 0.0,
                idle: 100.0 - user,
                load: [0.0; 3],
            };
            assert_eq!(
                visible_summary(&cpu, None, &VecDeque::new(), SummaryMode::Compact),
                expected
            );
        }
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
        };
        let gpu = GpuSnapshot {
            utilization: 59.0,
            model: Some("Apple M4 Pro".into()),
        };
        let history = VecDeque::from([10.0, 20.0]);
        let rendered = render_status(&cpu, Some(&gpu), &history, SummaryMode::Compact);
        assert!(rendered.summary.starts_with("#[popup=inline:"));
        assert!(rendered.summary.ends_with("#[nopopup]"));
        assert!(rendered.summary.contains("CPU#[default] 20%"));
        assert!(!rendered.summary.contains("GPU#[default]"));
        assert!(!rendered.summary.contains("▂"));
        assert_eq!(
            visible_summary(&cpu, Some(&gpu), &history, SummaryMode::Compact),
            "#[fg=colour178,bold]CPU#[default] 20%"
        );
        assert!(
            visible_summary(&cpu, Some(&gpu), &history, SummaryMode::Full)
                .contains("GPU#[default] 59% ▂▂")
        );
        assert!(rendered
            .details
            .contains("User: 12.5% · System: 7.2% · Idle: 80.2%"));
        assert!(rendered.details.contains("Load: 1.25 · 2.50 · 3.75"));
        assert!(rendered.details.contains("Apple M4 Pro: 59%"));
        assert!(!rendered.plain_details.contains("#["));
        assert!(rendered.plain_details.starts_with("CPU 19.8%\n"));
        assert!(rendered.plain_details.contains("GPU\nApple M4 Pro: 59%"));
    }
}

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use flash_plugin::{inline_status_popup, run, sys, CommandRequest, Context, PerformResponse};

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_SAMPLES: usize = 20;
const DETAIL_LABEL_WIDTH: usize = 14;
const KIB: u64 = 1024;
const MIB: u64 = KIB * 1024;
const GIB: u64 = MIB * 1024;
const TIB: u64 = GIB * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
struct MemorySnapshot {
    total: u64,
    occupied: u64,
    free: u64,
    wired: u64,
    compressed: u64,
    swap_total: u64,
    swap_used: u64,
    page_size: u64,
}

impl MemorySnapshot {
    fn occupied_percent(&self) -> f64 {
        self.occupied as f64 / self.total as f64 * 100.0
    }
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
            "[memory] summary_mode must be compact or full; using compact",
        );
    }
}

#[derive(Clone, Copy)]
enum GatePolicy {
    Wait,
    SkipIfBusy,
}

#[derive(Default)]
struct MonitorState {
    snapshot: Option<MemorySnapshot>,
    history: VecDeque<f64>,
    published: Option<StatusSegments>,
    failure_logged: bool,
}

struct Memory {
    state: Arc<Mutex<MonitorState>>,
    refresh_gate: Arc<tokio::sync::Mutex<()>>,
}

impl Default for Memory {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(MonitorState::default())),
            refresh_gate: Arc::new(tokio::sync::Mutex::new(())),
        }
    }
}

flash_plugin::plugin!(Memory);

impl FlashPlugin for Memory {
    async fn on_start(&self, ctx: Context) {
        warn_invalid_summary_mode(&ctx);
        refresh_and_publish(&ctx, &self.state, &self.refresh_gate, GatePolicy::Wait).await;

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.refresh_gate);
        drop(ctx.interval(REFRESH_INTERVAL, move |ctx| {
            let state = Arc::clone(&state);
            let gate = Arc::clone(&gate);
            async move {
                refresh_and_publish(&ctx, &state, &gate, GatePolicy::Wait).await;
            }
        }));
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => details_response(current_status(&ctx, &self.state)),
            "refresh" => {
                refresh_and_publish(
                    &ctx,
                    &self.state,
                    &self.refresh_gate,
                    GatePolicy::SkipIfBusy,
                )
                .await;
                details_response(current_status(&ctx, &self.state))
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_and_publish(
    ctx: &Context,
    state: &Arc<Mutex<MonitorState>>,
    gate: &Arc<tokio::sync::Mutex<()>>,
    policy: GatePolicy,
) {
    let Some(_guard) = acquire_collection(gate, policy).await else {
        return;
    };
    let result = sys::memory_stats().ok().and_then(snapshot_from).ok_or(());
    {
        let mut state = lock_state(state);
        match result {
            Ok(snapshot) => {
                append_history(&mut state.history, snapshot.occupied_percent());
                state.snapshot = Some(snapshot);
                state.failure_logged = false;
            }
            Err(()) if !state.failure_logged => {
                state.failure_logged = true;
                drop(state);
                ctx.log(
                    "warn",
                    "[memory] sample unavailable; retaining last good value",
                );
            }
            Err(()) => {}
        }
    }
    publish_if_changed(ctx, state);
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

fn publish_if_changed(ctx: &Context, state: &Arc<Mutex<MonitorState>>) {
    let next = {
        let mut state = lock_state(state);
        let snapshot = match state.snapshot.as_ref() {
            Some(snapshot) => snapshot,
            None => return,
        };
        let rendered = render_status(snapshot, &state.history, configured_summary_mode(ctx));
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
    Some(render_status(
        state.snapshot.as_ref()?,
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
        .unwrap_or_else(|| PerformResponse::fail("memory information unavailable"))
}

/// Same composition the old `vm_stat` + `sysctl` parser produced, from the
/// kernel counters directly: free counts speculative pages, and every
/// component is clamped to physical memory.
fn snapshot_from(stats: sys::MemoryStats) -> Option<MemorySnapshot> {
    let page_size = stats.page_size;
    let total = stats.total_bytes;
    if page_size == 0 || total == 0 {
        return None;
    }
    let swap_total = stats.swap_total_bytes;
    let swap_used = stats.swap_used_bytes.min(swap_total);

    let free = stats
        .free_pages
        .checked_add(stats.speculative_pages)?
        .checked_mul(page_size)?
        .min(total);
    let wired = stats.wired_pages.checked_mul(page_size)?.min(total);
    let compressed = stats.compressor_pages.checked_mul(page_size)?.min(total);

    Some(MemorySnapshot {
        total,
        occupied: total.saturating_sub(free),
        free,
        wired,
        compressed,
        swap_total,
        swap_used,
        page_size,
    })
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

fn format_bytes(bytes: u64) -> String {
    if bytes >= TIB {
        format!("{:.1} TB", bytes as f64 / TIB as f64)
    } else if bytes >= GIB {
        format!("{:.1} GB", bytes as f64 / GIB as f64)
    } else if bytes >= MIB {
        format!("{:.0} MB", bytes as f64 / MIB as f64)
    } else if bytes >= KIB {
        format!("{:.0} KB", bytes as f64 / KIB as f64)
    } else {
        format!("{bytes} B")
    }
}

fn render_status(
    snapshot: &MemorySnapshot,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> StatusSegments {
    let percent = snapshot.occupied_percent();
    let visible = visible_summary(snapshot, history, summary_mode);
    let mut body = format!(
        "Occupied: {} / {} ({percent:.0}%)\n\
Free: {}\n\
Wired: {} · Compressed: {}\n\
Swap: {} / {}\n\
Page size: {}",
        format_bytes(snapshot.occupied),
        format_bytes(snapshot.total),
        format_bytes(snapshot.free),
        format_bytes(snapshot.wired),
        format_bytes(snapshot.compressed),
        format_bytes(snapshot.swap_used),
        format_bytes(snapshot.swap_total),
        format_bytes(snapshot.page_size),
    );
    if !history.is_empty() {
        body.push_str(&format!("\nHistory: {}", sparkline(history)));
    }
    let details = [
        "#[fg=#EBCB8B]Memory#[default]".to_string(),
        detail_row("Usage", &format!("{percent:>5.1} %")),
        detail_row("Used", &format!("{:>10}", format_bytes(snapshot.occupied))),
        detail_row("Total", &format!("{:>10}", format_bytes(snapshot.total))),
        detail_row("Free", &format!("{:>10}", format_bytes(snapshot.free))),
        detail_row("Wired", &format!("{:>10}", format_bytes(snapshot.wired))),
        detail_row(
            "Compressed",
            &format!("{:>10}", format_bytes(snapshot.compressed)),
        ),
        detail_row(
            "Swap used",
            &format!("{:>10}", format_bytes(snapshot.swap_used)),
        ),
        detail_row(
            "Swap total",
            &format!("{:>10}", format_bytes(snapshot.swap_total)),
        ),
        detail_row(
            "Page size",
            &format!("{:>10}", format_bytes(snapshot.page_size)),
        ),
        detail_row("History", &padded_history(history)),
    ]
    .join("\n");
    let plain_details = format!("Memory\n{body}");

    StatusSegments {
        summary: inline_status_popup(&visible, &details),
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
    snapshot: &MemorySnapshot,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> String {
    let percent = snapshot.occupied_percent().min(99.0);
    let mut visible =
        format!("#[fg=#EBCB8B]MEM#[default] #[fg=colour245]{percent:>2.0}%#[default]");
    if summary_mode == SummaryMode::Full && !history.is_empty() {
        visible.push(' ');
        visible.push_str(&sparkline(history));
    }
    visible
}

fn main() {
    run(Memory::default());
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
    fn compact_memory_summary_caps_values_that_would_render_as_three_digits() {
        let mut snapshot = MemorySnapshot {
            total: 100,
            occupied: 9,
            free: 91,
            wired: 0,
            compressed: 0,
            swap_total: 0,
            swap_used: 0,
            page_size: 4096,
        };
        assert_eq!(
            visible_summary(&snapshot, &VecDeque::new(), SummaryMode::Compact),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245] 9%#[default]"
        );
        snapshot.occupied = 10;
        snapshot.free = 90;
        assert_eq!(
            visible_summary(&snapshot, &VecDeque::new(), SummaryMode::Compact),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]10%#[default]"
        );
        snapshot.total = 1_000;
        snapshot.occupied = 999;
        snapshot.free = 1;
        assert_eq!(
            visible_summary(&snapshot, &VecDeque::new(), SummaryMode::Compact),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]99%#[default]"
        );
    }

    #[test]
    fn an_in_flight_collection_is_skipped_instead_of_queued() {
        let gate = tokio::sync::Mutex::new(());
        let held = begin_collection(&gate).expect("first collection");
        assert!(begin_collection(&gate).is_none());
        drop(held);
        assert!(begin_collection(&gate).is_some());
    }

    fn stats(free: u64, speculative: u64, wired: u64, compressor: u64) -> sys::MemoryStats {
        sys::MemoryStats {
            total_bytes: 17_179_869_184,
            page_size: 4096,
            free_pages: free,
            speculative_pages: speculative,
            wired_pages: wired,
            compressor_pages: compressor,
            swap_total_bytes: 2_147_483_648,
            swap_used_bytes: 537_395_200,
        }
    }

    #[test]
    fn builds_the_snapshot_from_kernel_counters_with_runtime_page_size() {
        let snapshot = snapshot_from(stats(100, 20, 300, 50)).expect("memory snapshot");
        assert_eq!(snapshot.page_size, 4096);
        assert_eq!(snapshot.total, 17_179_869_184);
        assert_eq!(snapshot.free, 120 * 4096);
        assert_eq!(snapshot.wired, 300 * 4096);
        assert_eq!(snapshot.compressed, 50 * 4096);
        assert_eq!(snapshot.swap_total, 2_147_483_648);
        assert_eq!(snapshot.swap_used, 537_395_200);
        assert_eq!(snapshot.occupied, snapshot.total - snapshot.free);
    }

    #[test]
    fn rejects_zero_total_or_page_size() {
        let mut zero_total = stats(1, 0, 1, 0);
        zero_total.total_bytes = 0;
        assert!(snapshot_from(zero_total).is_none());
        let mut zero_page = stats(1, 0, 1, 0);
        zero_page.page_size = 0;
        assert!(snapshot_from(zero_page).is_none());
    }

    #[test]
    fn clamps_impossible_free_memory_and_swap_used() {
        let mut huge = stats(999_999_999, 0, 1, 0);
        huge.total_bytes = 4096;
        huge.swap_used_bytes = huge.swap_total_bytes + 1;
        let snapshot = snapshot_from(huge).expect("clamped snapshot");
        assert_eq!(snapshot.free, 4096);
        assert_eq!(snapshot.occupied, 0);
        assert_eq!(snapshot.swap_used, snapshot.swap_total);
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
        let snapshot = MemorySnapshot {
            total: 16 * GIB,
            occupied: 12 * GIB,
            free: 4 * GIB,
            wired: 2 * GIB,
            compressed: GIB / 2,
            swap_total: 4 * GIB,
            swap_used: GIB,
            page_size: 16_384,
        };
        let history = VecDeque::from([50.0, 75.0]);
        let rendered = render_status(&snapshot, &history, SummaryMode::Compact);
        assert!(rendered.summary.starts_with("#[popup=inline:"));
        assert!(rendered.summary.ends_with("#[nopopup]"));
        assert!(rendered
            .summary
            .contains("MEM#[default] #[fg=colour245]75%#[default]"));
        assert!(!rendered.summary.contains("▅▆"));
        assert_eq!(
            visible_summary(&snapshot, &history, SummaryMode::Compact),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default]"
        );
        assert_eq!(
            visible_summary(&snapshot, &history, SummaryMode::Full),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default] ▅▆"
        );
        assert_eq!(REFRESH_INTERVAL, Duration::from_secs(1));
        assert_eq!(
            rendered.details,
            "#[fg=#EBCB8B]Memory#[default]\n\
#[fg=colour245]Usage         #[default] 75.0 %\n\
#[fg=colour245]Used          #[default]   12.0 GB\n\
#[fg=colour245]Total         #[default]   16.0 GB\n\
#[fg=colour245]Free          #[default]    4.0 GB\n\
#[fg=colour245]Wired         #[default]    2.0 GB\n\
#[fg=colour245]Compressed    #[default]    512 MB\n\
#[fg=colour245]Swap used     #[default]    1.0 GB\n\
#[fg=colour245]Swap total    #[default]    4.0 GB\n\
#[fg=colour245]Page size     #[default]     16 KB\n\
#[fg=colour245]History       #[default]··················▅▆"
        );
        assert!(!rendered.details.ends_with('\n'));
        assert!(!rendered.plain_details.contains("#["));
        assert!(rendered.plain_details.starts_with("Memory\nOccupied:"));
    }
}

use std::sync::{Arc, Mutex};
use std::time::Duration;

use flash_plugin::status::{bytes_iec, percent2, sparkline_padded, sparkline_percent};
use flash_plugin::{
    run, sys, Color, CommandRequest, Context, History, Markup, PerformResponse, Preview, Published,
    StatusValue,
};

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_SAMPLES: usize = 20;

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

/// The published segments: `label` is the bare bar text, `summary` adds the
/// inline history in full mode, and the preview backs both `summary` and
/// `details`.
#[derive(Debug, PartialEq, Eq)]
struct Status {
    label: Markup,
    summary: Markup,
    preview: Preview,
}

impl Status {
    fn segments(&self) -> [(&'static str, StatusValue); 3] {
        [
            (
                "summary",
                StatusValue::text(self.summary.clone()).with_preview(self.preview.clone()),
            ),
            ("label", StatusValue::text(self.label.clone())),
            ("details", StatusValue::text(self.preview.render())),
        ]
    }
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
    history: History<HISTORY_SAMPLES>,
    published: Published<Status>,
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
                state.history.push(snapshot.occupied_percent());
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
    let segments = {
        let mut state = lock_state(state);
        let Some(snapshot) = state.snapshot.as_ref() else {
            return;
        };
        let rendered = render_status(snapshot, &state.history, configured_summary_mode(ctx));
        let Some(status) = state.published.update(rendered) else {
            return;
        };
        status.segments()
    };
    ctx.status(segments);
}

fn current_status(ctx: &Context, state: &Arc<Mutex<MonitorState>>) -> Option<Status> {
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

fn details_response(status: Option<Status>) -> PerformResponse {
    status
        .map(|status| PerformResponse::ok().message(status.preview.render_plain()))
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

fn render_status(
    snapshot: &MemorySnapshot,
    history: &History<HISTORY_SAMPLES>,
    summary_mode: SummaryMode,
) -> Status {
    let percent = snapshot.occupied_percent();
    let label = Markup::colored("MEM", Color::TITLE)
        + " "
        + Markup::colored(percent2(percent), Color::MUTED);
    let mut summary = label.clone();
    if summary_mode == SummaryMode::Full && !history.is_empty() {
        summary += " ";
        summary += sparkline_percent(history);
    }
    let bytes = |value: u64| format!("{:>10}", bytes_iec(value));
    let composition = |value: u64| {
        format!(
            "{} · {:>5.1} %",
            bytes(value),
            value as f64 / snapshot.total as f64 * 100.0
        )
    };
    let preview = Preview::new()
        .title("Memory")
        .note("Used includes cached and reclaimable pages")
        .row("Usage", format!("{percent:>5.1} %"))
        .row("Used", bytes(snapshot.occupied))
        .row("Total", bytes(snapshot.total))
        .row("Free", composition(snapshot.free))
        .row("Wired", composition(snapshot.wired))
        .row("Compressed", composition(snapshot.compressed))
        .row("Swap used", bytes(snapshot.swap_used))
        .row("Swap total", bytes(snapshot.swap_total))
        .row(
            "Swap free",
            bytes_iec(snapshot.swap_total.saturating_sub(snapshot.swap_used)),
        )
        .row("Page size", bytes(snapshot.page_size))
        .row(
            "History",
            sparkline_padded(&sparkline_percent(history), HISTORY_SAMPLES),
        );
    Status {
        label,
        summary,
        preview,
    }
}

fn main() {
    run(Memory::default());
}

#[cfg(test)]
mod tests {
    use super::*;

    const GIB: u64 = 1 << 30;

    fn history(samples: &[f64]) -> History<HISTORY_SAMPLES> {
        let mut history = History::new();
        for &sample in samples {
            history.push(sample);
        }
        history
    }

    fn snapshot(total: u64, occupied: u64) -> MemorySnapshot {
        MemorySnapshot {
            total,
            occupied,
            free: total - occupied,
            wired: 0,
            compressed: 0,
            swap_total: 0,
            swap_used: 0,
            page_size: 4096,
        }
    }

    #[test]
    fn details_explain_composition_and_remaining_swap() {
        let snapshot = MemorySnapshot {
            total: 16 * GIB,
            occupied: 12 * GIB,
            free: 4 * GIB,
            wired: 2 * GIB,
            compressed: GIB,
            swap_total: 4 * GIB,
            swap_used: GIB,
            page_size: 16_384,
        };
        let details = render_status(&snapshot, &history(&[]), SummaryMode::Compact)
            .preview
            .render_plain();
        assert!(details.contains("25.0 %"), "{details}");
        assert!(details.contains("12.5 %"), "{details}");
        assert!(details.contains("6.2 %"), "{details}");
        assert!(details.contains("Swap free     3.0 GiB"), "{details}");
        assert!(details.lines().all(|line| line.chars().count() <= 50));
    }

    #[test]
    fn label_keeps_percent_width_through_full_utilization_without_popup_markup() {
        for (occupied, expected) in [
            (0, " 0%"),
            (90, " 9%"),
            (100, "10%"),
            (999, "99%"),
            (1000, "99%"),
        ] {
            let status = render_status(
                &snapshot(1000, occupied),
                &history(&[9.0]),
                SummaryMode::Full,
            );
            let [(_, summary), (_, label), _] = status.segments();
            assert_eq!(
                label.render().unwrap(),
                format!("#[fg=#EBCB8B]MEM#[default] #[fg=colour245]{expected}#[default]")
            );
            assert!(summary.render().unwrap().contains("popup="));
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
    fn compact_memory_summary_caps_values_that_would_render_as_three_digits() {
        let compact = |total, occupied| {
            render_status(
                &snapshot(total, occupied),
                &History::new(),
                SummaryMode::Compact,
            )
            .summary
        };
        assert_eq!(
            compact(100, 9).as_str(),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245] 9%#[default]"
        );
        assert_eq!(
            compact(100, 10).as_str(),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]10%#[default]"
        );
        assert_eq!(
            compact(1_000, 999).as_str(),
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
        let history = history(&[50.0, 75.0]);
        let rendered = render_status(&snapshot, &history, SummaryMode::Compact);
        let [(_, summary), (_, label), (_, details)] = rendered.segments();
        let summary = summary.render().unwrap();
        assert!(summary.starts_with("#[popup=inline:"));
        assert!(
            summary.ends_with("]#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default]#[nopopup]")
        );
        assert!(!summary.contains("▅▆"));
        assert_eq!(
            label.render().unwrap(),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default]"
        );
        assert_eq!(
            render_status(&snapshot, &history, SummaryMode::Full)
                .summary
                .as_str(),
            "#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default] ▅▆"
        );
        assert_eq!(REFRESH_INTERVAL, Duration::from_secs(1));
        assert_eq!(
            details.render().unwrap(),
            "#[fg=#EBCB8B]Memory#[default]\n\
#[fg=colour245]Used includes cached and reclaimable pages#[default]\n\
#[fg=colour245]Usage         #[default] 75.0 %\n\
#[fg=colour245]Used          #[default]    12 GiB\n\
#[fg=colour245]Total         #[default]    16 GiB\n\
#[fg=colour245]Free          #[default]   4.0 GiB ·  25.0 %\n\
#[fg=colour245]Wired         #[default]   2.0 GiB ·  12.5 %\n\
#[fg=colour245]Compressed    #[default]   512 MiB ·   3.1 %\n\
#[fg=colour245]Swap used     #[default]   1.0 GiB\n\
#[fg=colour245]Swap total    #[default]   4.0 GiB\n\
#[fg=colour245]Swap free     #[default]3.0 GiB\n\
#[fg=colour245]Page size     #[default]    16 KiB\n\
#[fg=colour245]History       #[default]··················▅▆"
        );
        assert_eq!(
            rendered.preview.render_plain(),
            "Memory\n\
Used includes cached and reclaimable pages\n\
Usage          75.0 %\n\
Used              12 GiB\n\
Total             16 GiB\n\
Free             4.0 GiB ·  25.0 %\n\
Wired            2.0 GiB ·  12.5 %\n\
Compressed       512 MiB ·   3.1 %\n\
Swap used        1.0 GiB\n\
Swap total       4.0 GiB\n\
Swap free     3.0 GiB\n\
Page size         16 KiB\n\
History       ··················▅▆"
        );
    }

    #[test]
    fn unchanged_renders_stay_off_the_wire() {
        let mut published = Published::new();
        let history = history(&[50.0]);
        let first = render_status(&snapshot(100, 50), &history, SummaryMode::Compact);
        assert!(published.update(first).is_some());
        let same = render_status(&snapshot(100, 50), &history, SummaryMode::Compact);
        assert!(published.update(same).is_none());
        let changed = render_status(&snapshot(100, 51), &history, SummaryMode::Compact);
        assert!(published.update(changed).is_some());
    }
}

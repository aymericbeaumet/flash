//! Memory: the kernel counters `vm_stat` and `sysctl` print, sampled once
//! per second while a segment is shown.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use flash_plugin::status::{bytes_iec, percent2, sparkline_padded, sparkline_percent};
use flash_plugin::{
    Color, Context, History, Markup, ObservedCadences, PerformResponse, PollPriority, Preview,
    Published, StatusValue, sys,
};

use crate::common::{
    GatePolicy, HISTORY_SAMPLES, SummaryMode, acquire_collection, configured_summary_mode, lock,
    percent_series, plain, whole_percent,
};

/// The `core:status.observed` prefix of this domain's segments.
pub(crate) const PREFIX: &str = "memory_";
/// The published segments, in manifest order.
pub(crate) const SEGMENTS: [&str; 5] = [
    "memory_summary",
    "memory_label",
    "memory_details",
    "memory_percent",
    "memory_history",
];

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);

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
/// `details`. `percent` and `history` carry the same figures as plain
/// integers for templates and widgets that scale or chart them themselves.
#[derive(Debug, PartialEq, Eq)]
struct Status {
    label: Markup,
    summary: Markup,
    preview: Preview,
    /// Used memory as an integer 0–100; unlike the label, never capped at 99.
    percent: String,
    /// The retained samples as space-separated integers, oldest first; empty
    /// clears the segment.
    history: String,
}

impl Status {
    fn segments(&self) -> [(&'static str, StatusValue); 5] {
        let [summary, label, details, percent, history] = SEGMENTS;
        [
            (
                summary,
                StatusValue::text(self.summary.clone()).with_preview(self.preview.clone()),
            ),
            (label, StatusValue::text(self.label.clone())),
            (details, StatusValue::text(self.preview.render())),
            (percent, plain(&self.percent)),
            (history, plain(&self.history)),
        ]
    }
}

#[derive(Default)]
struct MonitorState {
    snapshot: Option<MemorySnapshot>,
    history: History<HISTORY_SAMPLES>,
    published: Published<Status>,
    failure_logged: bool,
}

pub(crate) struct Memory {
    state: Arc<Mutex<MonitorState>>,
    refresh_gate: Arc<tokio::sync::Mutex<()>>,
    cadences: ObservedCadences,
}

impl Default for Memory {
    fn default() -> Self {
        Self {
            state: Arc::new(Mutex::new(MonitorState::default())),
            refresh_gate: Arc::new(tokio::sync::Mutex::new(())),
            cadences: ObservedCadences::default(),
        }
    }
}

impl Memory {
    /// The initial sample, then the cadence behind the segments.
    pub(crate) async fn start(&self, ctx: &Context) {
        refresh_and_publish(ctx, &self.state, &self.refresh_gate, GatePolicy::Wait).await;

        let state = Arc::clone(&self.state);
        let gate = Arc::clone(&self.refresh_gate);
        // `High`: a one-second figure on screen; a tenth of a second of
        // slack would make it tick visibly unevenly.
        self.cadences
            .interval(ctx, REFRESH_INTERVAL, PollPriority::High, move |ctx| {
                let state = Arc::clone(&state);
                let gate = Arc::clone(&gate);
                async move {
                    refresh_and_publish(&ctx, &state, &gate, GatePolicy::Wait).await;
                }
            });
    }

    /// `core:status.observed`, reduced to this domain's segments.
    pub(crate) fn observe(&self, ctx: &Context, segments: &[String]) {
        if self.cadences.observe(segments) {
            let ctx = ctx.clone();
            let (state, gate) = (Arc::clone(&self.state), Arc::clone(&self.refresh_gate));
            tokio::spawn(async move {
                refresh_and_publish(&ctx, &state, &gate, GatePolicy::Wait).await;
            });
        }
    }

    /// The details; unobserved, nothing samples between commands, so it
    /// samples first.
    pub(crate) async fn show(&self, ctx: &Context) -> PerformResponse {
        if !self.cadences.observed() {
            self.refresh(ctx).await;
        }
        details_response(current_status(ctx, &self.state))
    }

    /// A sample that skips a busy collector rather than queueing behind it.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        refresh_and_publish(ctx, &self.state, &self.refresh_gate, GatePolicy::SkipIfBusy).await;
    }

    /// The visible summary of the last sample.
    pub(crate) fn summary(&self, ctx: &Context) -> Option<Markup> {
        current_status(ctx, &self.state).map(|status| status.summary)
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
        let mut state = lock(state);
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
                    "[sysinfo] memory sample unavailable; retaining last good value",
                );
            }
            Err(()) => {}
        }
    }
    publish_if_changed(ctx, state);
}

fn publish_if_changed(ctx: &Context, state: &Arc<Mutex<MonitorState>>) {
    let segments = {
        let mut state = lock(state);
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
    let state = lock(state);
    Some(render_status(
        state.snapshot.as_ref()?,
        &state.history,
        configured_summary_mode(ctx),
    ))
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
    // The template owns the name and the width (`#[label]MEM #[default]#{p-3:…}`).
    let label = Markup::text(percent2(percent).trim());
    let mut summary = Markup::colored("MEM", Color::TITLE)
        + " "
        + Markup::colored(percent2(percent), Color::MUTED);
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
        percent: whole_percent(percent).to_string(),
        history: percent_series(history),
    }
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
    fn segments_carry_the_domain_prefix_in_manifest_order() {
        let status = render_status(&snapshot(100, 50), &History::new(), SummaryMode::Compact);
        assert_eq!(status.segments().map(|(name, _)| name), SEGMENTS);
        assert!(SEGMENTS.iter().all(|name| name.starts_with(PREFIX)));
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
            (0, "0%"),
            (90, "9%"),
            (100, "10%"),
            (999, "99%"),
            (1000, "99%"),
        ] {
            let status = render_status(
                &snapshot(1000, occupied),
                &history(&[9.0]),
                SummaryMode::Full,
            );
            let [(_, summary), (_, label), ..] = status.segments();
            assert_eq!(label.render().unwrap(), expected);
            assert!(!label.render().unwrap().contains("#["));
            assert!(summary.render().unwrap().contains("popup="));
        }
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
        let [(_, summary), (_, label), (_, details), ..] = rendered.segments();
        let summary = summary.render().unwrap();
        assert!(summary.starts_with("#[popup=inline:"));
        assert!(
            summary.ends_with("]#[fg=#EBCB8B]MEM#[default] #[fg=colour245]75%#[default]#[nopopup]")
        );
        assert!(!summary.contains("▅▆"));
        assert_eq!(label.render().unwrap(), "75%");
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

    fn wire(status: &Status) -> std::collections::BTreeMap<&'static str, String> {
        status
            .segments()
            .into_iter()
            .map(|(name, value)| (name, value.render().expect("preview fits inline")))
            .collect()
    }

    #[test]
    fn raw_segments_publish_plain_integers_with_history_oldest_first() {
        let status = render_status(
            &snapshot(16 * GIB, 12 * GIB),
            &history(&[50.4, 62.5, 75.0]),
            SummaryMode::Compact,
        );
        let segments = wire(&status);
        assert_eq!(segments["memory_percent"], "75");
        assert_eq!(segments["memory_history"], "50 63 75");
        assert!(!segments["memory_percent"].contains("#["));
        assert!(!segments["memory_history"].contains("#["));

        let empty = wire(&render_status(
            &snapshot(100, 0),
            &History::new(),
            SummaryMode::Compact,
        ));
        assert_eq!(empty["memory_percent"], "0");
        assert_eq!(
            empty["memory_history"], "",
            "an empty history clears its segment"
        );
    }

    #[test]
    fn raw_percent_rounds_to_an_integer_without_the_label_cap() {
        for (occupied, expected) in [
            (0, "0"),
            (4, "0"),
            (5, "1"),
            (95, "10"),
            (994, "99"),
            (996, "100"),
            (1_000, "100"),
        ] {
            let status = render_status(
                &snapshot(1_000, occupied),
                &History::new(),
                SummaryMode::Compact,
            );
            assert_eq!(status.percent, expected, "{occupied}");
        }
        assert!(
            render_status(&snapshot(1_000, 996), &History::new(), SummaryMode::Compact)
                .label
                .as_str()
                .contains("99%")
        );
    }

    /// The kernel counters this Mac publishes render as a figure at once.
    #[tokio::test]
    async fn a_sample_renders_this_macs_memory() {
        let mut harness = flash_plugin::testing::Harness::new("sysinfo");
        let memory = Memory::default();
        memory.refresh(&harness.context()).await;
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1, "{frames:?}");
        assert!(frames[0]["memory_label"].ends_with('%'), "{frames:?}");
        assert!(memory.summary(&harness.context()).is_some());
    }
}

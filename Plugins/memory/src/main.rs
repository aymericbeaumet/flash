use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use flash_plugin::{
    inline_status_popup, run, run_command, CommandRequest, Context, PerformResponse,
};

const REFRESH_INTERVAL: Duration = Duration::from_secs(5);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const HISTORY_SAMPLES: usize = 20;
const VM_STAT: &str = "/usr/bin/vm_stat";
const SYSCTL: &str = "/usr/sbin/sysctl";
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
    let result = collect_memory(ctx).await;
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

async fn collect_memory(ctx: &Context) -> Result<MemorySnapshot, ()> {
    let vm_stat_argv = [VM_STAT.to_string()];
    let sysctl_argv = [
        SYSCTL.to_string(),
        "hw.memsize".to_string(),
        "vm.swapusage".to_string(),
    ];
    let (vm_stat, sysctl) = tokio::join!(
        run_command(ctx, &vm_stat_argv, COMMAND_TIMEOUT),
        run_command(ctx, &sysctl_argv, COMMAND_TIMEOUT)
    );
    if !vm_stat.ok || !sysctl.ok {
        return Err(());
    }
    parse_memory(&vm_stat.stdout, &sysctl.stdout).ok_or(())
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

fn parse_memory(vm_stat: &str, sysctl: &str) -> Option<MemorySnapshot> {
    let page_size = parse_page_size(vm_stat)?;
    let free_pages = vm_counter(vm_stat, "Pages free")?;
    let speculative_pages = vm_counter(vm_stat, "Pages speculative").unwrap_or(0);
    let wired_pages = vm_counter(vm_stat, "Pages wired down")?;
    let compressed_pages = vm_counter(vm_stat, "Pages occupied by compressor").unwrap_or(0);

    let total = sysctl
        .lines()
        .find_map(|line| line.trim().strip_prefix("hw.memsize:"))?
        .trim()
        .parse::<u64>()
        .ok()?;
    if total == 0 {
        return None;
    }
    let swap_line = sysctl
        .lines()
        .find(|line| line.trim().starts_with("vm.swapusage:"))?;
    let swap_total = named_size(swap_line, "total")?;
    let swap_used = named_size(swap_line, "used")?.min(swap_total);

    let free = free_pages
        .checked_add(speculative_pages)?
        .checked_mul(page_size)?
        .min(total);
    let wired = wired_pages.checked_mul(page_size)?.min(total);
    let compressed = compressed_pages.checked_mul(page_size)?.min(total);

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

fn parse_page_size(raw: &str) -> Option<u64> {
    let (_, after_marker) = raw.split_once("page size of ")?;
    let digits = after_marker
        .chars()
        .take_while(char::is_ascii_digit)
        .collect::<String>();
    let size = digits.parse::<u64>().ok()?;
    (size > 0).then_some(size)
}

fn vm_counter(raw: &str, label: &str) -> Option<u64> {
    raw.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.trim() != label {
            return None;
        }
        value
            .trim()
            .trim_end_matches('.')
            .replace(',', "")
            .parse::<u64>()
            .ok()
    })
}

fn named_size(raw: &str, name: &str) -> Option<u64> {
    let marker = format!("{name} =");
    let (_, after_marker) = raw.split_once(&marker)?;
    parse_size(after_marker.split_whitespace().next()?)
}

fn parse_size(raw: &str) -> Option<u64> {
    let raw = raw.trim();
    let (number, multiplier) = match raw.as_bytes().last().copied()? {
        b'K' | b'k' => (&raw[..raw.len() - 1], KIB),
        b'M' | b'm' => (&raw[..raw.len() - 1], MIB),
        b'G' | b'g' => (&raw[..raw.len() - 1], GIB),
        b'T' | b't' => (&raw[..raw.len() - 1], TIB),
        b'B' | b'b' => (&raw[..raw.len() - 1], 1),
        character if character.is_ascii_digit() => (raw, 1),
        _ => return None,
    };
    let value = number.parse::<f64>().ok()?;
    let bytes = value * multiplier as f64;
    if !bytes.is_finite() || bytes < 0.0 || bytes > u64::MAX as f64 {
        return None;
    }
    Some(bytes.round() as u64)
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
    let details = format!("#[fg=colour75,bold]Memory#[default]\n{body}");
    let plain_details = format!("Memory\n{body}");

    StatusSegments {
        summary: inline_status_popup(&visible, &details),
        details,
        plain_details,
    }
}

fn visible_summary(
    snapshot: &MemorySnapshot,
    history: &VecDeque<f64>,
    summary_mode: SummaryMode,
) -> String {
    let mut visible = format!(
        "#[fg=colour75,bold]MEM#[default] {:.0}%",
        snapshot.occupied_percent()
    );
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
    fn compact_memory_summary_uses_natural_percentage_width() {
        let mut snapshot = MemorySnapshot {
            total: 100,
            occupied: 0,
            free: 100,
            wired: 0,
            compressed: 0,
            swap_total: 0,
            swap_used: 0,
            page_size: 4096,
        };
        assert_eq!(
            visible_summary(&snapshot, &VecDeque::new(), SummaryMode::Compact),
            "#[fg=colour75,bold]MEM#[default] 0%"
        );
        snapshot.occupied = 100;
        snapshot.free = 0;
        assert_eq!(
            visible_summary(&snapshot, &VecDeque::new(), SummaryMode::Compact),
            "#[fg=colour75,bold]MEM#[default] 100%"
        );
    }

    #[test]
    fn parses_vm_stat_and_sysctl_with_runtime_page_size() {
        let snapshot = parse_memory(
            include_str!("../fixtures/vm_stat.txt"),
            include_str!("../fixtures/sysctl.txt"),
        )
        .expect("memory snapshot");
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
    fn rejects_missing_page_size_total_and_required_counters() {
        let sysctl = include_str!("../fixtures/sysctl.txt");
        assert!(parse_memory("Pages free: 1.", sysctl).is_none());
        assert!(parse_memory(
            "Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages wired down: 1.",
            sysctl
        )
        .is_none());
        assert!(parse_memory(
            include_str!("../fixtures/vm_stat.txt"),
            "vm.swapusage: total = 0M used = 0M"
        )
        .is_none());
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
    fn parses_binary_swap_units_and_clamps_impossible_free_memory() {
        assert_eq!(parse_size("1.5G"), Some(1_610_612_736));
        assert_eq!(parse_size("512K"), Some(524_288));
        let snapshot = parse_memory(
            "Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages free: 999999999.\nPages wired down: 1.",
            "hw.memsize: 4096\nvm.swapusage: total = 0.00M used = 0.00M",
        )
        .expect("clamped snapshot");
        assert_eq!(snapshot.free, 4096);
        assert_eq!(snapshot.occupied, 0);
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
        assert!(rendered.summary.contains("MEM#[default] 75%"));
        assert!(!rendered.summary.contains("▅▆"));
        assert_eq!(
            visible_summary(&snapshot, &history, SummaryMode::Compact),
            "#[fg=colour75,bold]MEM#[default] 75%"
        );
        assert_eq!(
            visible_summary(&snapshot, &history, SummaryMode::Full),
            "#[fg=colour75,bold]MEM#[default] 75% ▅▆"
        );
        assert!(rendered
            .details
            .contains("Occupied: 12.0 GB / 16.0 GB (75%)"));
        assert!(rendered.details.contains("Free: 4.0 GB"));
        assert!(rendered
            .details
            .contains("Wired: 2.0 GB · Compressed: 512 MB"));
        assert!(rendered.details.contains("Swap: 1.0 GB / 4.0 GB"));
        assert!(rendered.details.contains("Page size: 16 KB"));
        assert!(!rendered.plain_details.contains("#["));
        assert!(rendered.plain_details.starts_with("Memory\nOccupied:"));
    }
}

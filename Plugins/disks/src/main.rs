use std::collections::BTreeMap;
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::status::{
    bytes_iec, bytes_iec_compact, percent2, rate_iec, sparkline_padded, sparkline_scaled,
};
use flash_plugin::{
    run, run_command, Color, CommandRequest, Context, History, Markup, PerformResponse, Preview,
    Published, RefreshGate, StatusValue,
};

const ACTIVITY_POLL: Duration = Duration::from_secs(3);
const CAPACITY_POLL: Duration = Duration::from_secs(30);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const MIN_RATE_INTERVAL: Duration = Duration::from_secs(1);
const MAX_RATE_INTERVAL: Duration = Duration::from_secs(45);
const HISTORY_LEN: usize = 20;

static STATE: LazyLock<Mutex<DiskState>> = LazyLock::new(|| Mutex::new(DiskState::default()));
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct IoCounters {
    read: u64,
    written: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct IoSnapshot {
    devices: BTreeMap<String, IoCounters>,
}

#[derive(Clone, Debug)]
struct TimedIoSnapshot {
    snapshot: IoSnapshot,
    sampled_at: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct IoRates {
    read: f64,
    written: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Volume {
    name: String,
    mount: String,
    total: u64,
    used: u64,
    percent: u8,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct CapacitySnapshot {
    volumes: Vec<Volume>,
}

impl CapacitySnapshot {
    fn primary(&self) -> Option<&Volume> {
        self.volumes
            .iter()
            .find(|volume| volume.mount == "/")
            .or_else(|| self.volumes.first())
    }
}

/// The popup-backed summary's visible text and hover preview, plus the
/// popup-free label; `details` publishes the preview on its own.
#[derive(Clone, Debug, PartialEq, Eq)]
struct RenderedStatus {
    visible: Markup,
    label: Markup,
    preview: Preview,
    raw: RawMetrics,
}

/// Plain values without markup, for templates and widgets that scale or chart
/// numbers themselves. An empty value clears its segment: no capacity or no
/// current rate is unknown, not zero.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct RawMetrics {
    /// Startup-volume usage as an integer 0–100; unlike the label, never
    /// capped at 99.
    percent: String,
    /// Whole bytes per second.
    read_bps: String,
    write_bps: String,
    /// The same rates in binary units, as the details show them: `1.5 MiB/s`.
    read: String,
    write: String,
}

impl RenderedStatus {
    fn segments(&self) -> [(&'static str, StatusValue); 8] {
        [
            (
                "summary",
                StatusValue::text(self.visible.clone()).with_preview(self.preview.clone()),
            ),
            ("label", StatusValue::text(self.label.clone())),
            ("details", StatusValue::text(self.preview.render())),
            ("percent", plain(&self.raw.percent)),
            ("read_bps", plain(&self.raw.read_bps)),
            ("write_bps", plain(&self.raw.write_bps)),
            ("read", plain(&self.raw.read)),
            ("write", plain(&self.raw.write)),
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
            "[disks] summary_mode must be compact or full; using compact",
        );
    }
}

#[derive(Default)]
struct DiskState {
    previous_io: Option<TimedIoSnapshot>,
    rates: Option<IoRates>,
    read_history: History<HISTORY_LEN>,
    write_history: History<HISTORY_LEN>,
    capacity: Option<CapacitySnapshot>,
    last_capacity_attempt: Option<Instant>,
    last_io_success: Option<Instant>,
    published: Published<RenderedStatus>,
    io_failure_logged: bool,
    capacity_failure_logged: bool,
}

impl DiskState {
    fn apply_io(&mut self, sample: TimedIoSnapshot) {
        self.last_io_success = Some(sample.sampled_at);
        let Some(previous) = self.previous_io.as_ref() else {
            self.previous_io = Some(sample);
            return;
        };
        match calculate_io_rates(previous, &sample) {
            RateDecision::TooSoon => {}
            RateDecision::Reset => {
                self.previous_io = Some(sample);
                self.rates = None;
                self.read_history.clear();
                self.write_history.clear();
            }
            RateDecision::Rates(rates) => {
                self.previous_io = Some(sample);
                self.rates = Some(rates);
                self.read_history.push(rates.read);
                self.write_history.push(rates.written);
            }
        }
    }

    fn expire_stale_rates(&mut self, now: Instant) -> bool {
        let stale = self.rates.is_some()
            && self.last_io_success.is_some_and(|sampled_at| {
                now.saturating_duration_since(sampled_at) > MAX_RATE_INTERVAL
            });
        if !stale {
            return false;
        }
        self.rates = None;
        self.read_history.clear();
        self.write_history.clear();
        true
    }
}

enum RateDecision {
    TooSoon,
    Reset,
    Rates(IoRates),
}

struct Disks;

flash_plugin::plugin!(Disks);

impl FlashPlugin for Disks {
    async fn on_start(&self, ctx: Context) {
        warn_invalid_summary_mode(&ctx);
        refresh_disks(&ctx, true).await;
        drop(ctx.interval(ACTIVITY_POLL, |ctx| async move {
            refresh_disks(&ctx, false).await;
        }));
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => current_response(),
            "refresh" => {
                try_refresh_disks(&ctx, true).await;
                current_response()
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_disks(ctx: &Context, force_capacity: bool) {
    REFRESH_GATE
        .run(ctx, move |ctx, _applications| async move {
            refresh_disks_locked(&ctx, force_capacity).await;
        })
        .await;
}

async fn try_refresh_disks(ctx: &Context, force_capacity: bool) {
    let _ = REFRESH_GATE
        .try_run(ctx, move |ctx, _applications| async move {
            refresh_disks_locked(&ctx, force_capacity).await;
        })
        .await;
}

async fn refresh_disks_locked(ctx: &Context, force_capacity: bool) {
    let capacity_due = {
        let state = state();
        force_capacity
            || state
                .last_capacity_attempt
                .is_none_or(|last| last.elapsed() >= CAPACITY_POLL)
    };

    let io_argv = [
        "/usr/sbin/ioreg".to_string(),
        "-r".to_string(),
        "-c".to_string(),
        "IOBlockStorageDriver".to_string(),
        "-d".to_string(),
        "1".to_string(),
        "-w".to_string(),
        "0".to_string(),
    ];
    let io_future = async {
        let output = run_command(ctx, &io_argv, COMMAND_TIMEOUT).await;
        (output, Instant::now())
    };
    let capacity_future = async {
        if !capacity_due {
            return None;
        }
        let argv = ["/bin/df".to_string(), "-kP".to_string(), "-l".to_string()];
        Some(run_command(ctx, &argv, COMMAND_TIMEOUT).await)
    };
    let ((io_output, io_sampled_at), capacity_output) = tokio::join!(io_future, capacity_future);

    let parsed_io = io_output
        .ok
        .then(|| parse_ioreg_snapshot(&io_output.stdout))
        .flatten();
    let parsed_capacity = capacity_output.as_ref().and_then(|output| {
        output
            .ok
            .then(|| parse_df_snapshot(&output.stdout))
            .flatten()
    });
    let io_failed = !io_output.ok || parsed_io.is_none();
    let capacity_failed = capacity_due
        && capacity_output
            .as_ref()
            .is_none_or(|output| !output.ok || parsed_capacity.is_none());

    let (log_io_failure, log_capacity_failure) = {
        let mut state = state();
        if let Some(snapshot) = parsed_io {
            state.apply_io(TimedIoSnapshot {
                snapshot,
                sampled_at: io_sampled_at,
            });
        }
        if capacity_due {
            state.last_capacity_attempt = Some(Instant::now());
            if let Some(capacity) = parsed_capacity {
                state.capacity = Some(capacity);
            }
        }
        state.expire_stale_rates(Instant::now());
        let log_io_failure = first_failure(&mut state.io_failure_logged, io_failed);
        let log_capacity_failure =
            capacity_due && first_failure(&mut state.capacity_failure_logged, capacity_failed);
        (log_io_failure, log_capacity_failure)
    };

    if log_io_failure {
        ctx.log("warn", "[disks] I/O Registry collection failed");
    }
    if log_capacity_failure {
        ctx.log("warn", "[disks] capacity collection failed");
    }
    publish_status(ctx, &mut state());
}

fn current_response() -> PerformResponse {
    match render_preview(&state()) {
        Some(preview) => PerformResponse::ok().message(preview.render_plain()),
        None => PerformResponse::fail("disk metrics are not available yet"),
    }
}

fn publish_status(ctx: &Context, state: &mut DiskState) {
    let Some(rendered) = render_status(state, configured_summary_mode(ctx)) else {
        return;
    };
    if let Some(rendered) = state.published.update(rendered) {
        ctx.status(rendered.segments());
    }
}

fn first_failure(already_logged: &mut bool, failed: bool) -> bool {
    if failed {
        let first = !*already_logged;
        *already_logged = true;
        first
    } else {
        *already_logged = false;
        false
    }
}

fn state() -> MutexGuard<'static, DiskState> {
    STATE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn parse_ioreg_snapshot(output: &str) -> Option<IoSnapshot> {
    let mut current_id = None;
    let mut devices = BTreeMap::new();
    for line in output.lines() {
        if let Some(id) = parse_registry_id(line) {
            current_id = Some(id);
        }
        if !line.contains("\"Statistics\"") {
            continue;
        }
        let Some(id) = current_id.as_ref() else {
            continue;
        };
        let (Some(read), Some(written)) = (
            parse_ioreg_integer(line, "Bytes (Read)"),
            parse_ioreg_integer(line, "Bytes (Write)"),
        ) else {
            continue;
        };
        devices.insert(id.clone(), IoCounters { read, written });
    }
    (!devices.is_empty()).then_some(IoSnapshot { devices })
}

fn parse_registry_id(line: &str) -> Option<String> {
    let (_, suffix) = line.split_once("id ")?;
    let id: String = suffix
        .chars()
        .take_while(|character| character.is_ascii_hexdigit() || *character == 'x')
        .collect();
    (id.starts_with("0x") && id.len() > 2).then_some(id)
}

fn parse_ioreg_integer(line: &str, key: &str) -> Option<u64> {
    let marker = format!("\"{key}\"=");
    let (_, suffix) = line.split_once(&marker)?;
    let digits: String = suffix.chars().take_while(char::is_ascii_digit).collect();
    (!digits.is_empty()).then(|| digits.parse().ok()).flatten()
}

fn calculate_io_rates(previous: &TimedIoSnapshot, current: &TimedIoSnapshot) -> RateDecision {
    let elapsed = current
        .sampled_at
        .saturating_duration_since(previous.sampled_at);
    if elapsed < MIN_RATE_INTERVAL {
        return RateDecision::TooSoon;
    }
    if elapsed > MAX_RATE_INTERVAL {
        return RateDecision::Reset;
    }

    let mut shared_device = false;
    let mut read_delta = 0_u64;
    let mut write_delta = 0_u64;
    for (id, counters) in &current.snapshot.devices {
        let Some(old) = previous.snapshot.devices.get(id) else {
            continue;
        };
        shared_device = true;
        if counters.read < old.read || counters.written < old.written {
            return RateDecision::Reset;
        }
        read_delta = read_delta.saturating_add(counters.read - old.read);
        write_delta = write_delta.saturating_add(counters.written - old.written);
    }
    if !shared_device {
        return RateDecision::Reset;
    }
    let seconds = elapsed.as_secs_f64();
    RateDecision::Rates(IoRates {
        read: read_delta as f64 / seconds,
        written: write_delta as f64 / seconds,
    })
}

fn parse_df_snapshot(output: &str) -> Option<CapacitySnapshot> {
    const DATA_MOUNT: &str = "/System/Volumes/Data";

    let mut root = None;
    let mut data = None;
    let mut visible_volumes = Vec::new();
    for line in output.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 6 {
            continue;
        }
        let mount = fields[5..].join(" ");
        if mount != DATA_MOUNT && !is_visible_mount(&mount) {
            continue;
        }
        let (Ok(total_kib), Ok(available_kib)) =
            (fields[1].parse::<u64>(), fields[3].parse::<u64>())
        else {
            continue;
        };
        if total_kib == 0 {
            continue;
        }
        let total = total_kib.saturating_mul(1024);
        let available = available_kib.min(total_kib).saturating_mul(1024);
        let used = total.saturating_sub(available);
        let percent =
            (((u128::from(used) * 100) + u128::from(total / 2)) / u128::from(total)).min(100) as u8;
        let name = if mount == "/" || mount == DATA_MOUNT {
            "Startup".to_string()
        } else {
            mount.trim_start_matches("/Volumes/").to_string()
        };
        let volume = Volume {
            name,
            mount: if mount == DATA_MOUNT {
                "/".to_string()
            } else {
                mount.clone()
            },
            total,
            used,
            percent,
        };
        if mount == "/" {
            root = Some(volume);
        } else if mount == DATA_MOUNT {
            data = Some(volume);
        } else {
            visible_volumes.push(volume);
        }
    }
    visible_volumes.sort_by_key(|volume| volume.name.to_lowercase());
    let mut volumes = Vec::with_capacity(visible_volumes.len() + 1);
    if let Some(startup) = data.or(root) {
        volumes.push(startup);
    }
    volumes.extend(visible_volumes);
    (!volumes.is_empty()).then_some(CapacitySnapshot { volumes })
}

fn is_visible_mount(mount: &str) -> bool {
    if mount == "/" {
        return true;
    }
    mount
        .strip_prefix("/Volumes/")
        .is_some_and(|name| !name.is_empty() && !name.contains('/'))
}

fn render_status(state: &DiskState, summary_mode: SummaryMode) -> Option<RenderedStatus> {
    let preview = render_preview(state)?;
    let bar = |metric: String| {
        Markup::colored("DSK", Color::TITLE) + " " + Markup::colored(metric, Color::MUTED)
    };
    let percent = state
        .capacity
        .as_ref()
        .and_then(CapacitySnapshot::primary)
        .map(|volume| percent2(f64::from(volume.percent)));
    let mut visible = bar(percent.clone().unwrap_or_else(|| "—".to_string()));
    if summary_mode == SummaryMode::Full {
        let (read, written) = state
            .rates
            .map(|rates| {
                (
                    bytes_iec_compact(rates.read),
                    bytes_iec_compact(rates.written),
                )
            })
            .unwrap_or_else(|| ("—".to_string(), "—".to_string()));
        visible += " ";
        visible += Markup::colored(format!("↓{read}"), Color::INBOUND);
        visible += " ";
        visible += Markup::colored(format!("↑{written}"), Color::OUTBOUND);
        let chart = sparkline_scaled(
            state
                .read_history
                .iter()
                .zip(&state.write_history)
                .map(|(read, written)| read.max(written)),
        );
        if !chart.is_empty() {
            visible += " ";
            visible += chart;
        }
    }
    Some(RenderedStatus {
        visible,
        label: bar(percent.unwrap_or_else(|| "  —".to_string())),
        preview,
        raw: raw_metrics(state),
    })
}

fn raw_metrics(state: &DiskState) -> RawMetrics {
    let percent = state
        .capacity
        .as_ref()
        .and_then(CapacitySnapshot::primary)
        .map(|volume| volume.percent.to_string())
        .unwrap_or_default();
    let (read_bps, write_bps, read, write) = state
        .rates
        .map(|rates| {
            (
                whole_rate(rates.read).to_string(),
                whole_rate(rates.written).to_string(),
                rate_iec(rates.read),
                rate_iec(rates.written),
            )
        })
        .unwrap_or_default();
    RawMetrics {
        percent,
        read_bps,
        write_bps,
        read,
        write,
    }
}

/// Whole bytes per second, rounded; NaN or a negative rate reads as 0.
fn whole_rate(bytes_per_second: f64) -> u64 {
    if bytes_per_second > 0.0 {
        bytes_per_second.round() as u64
    } else {
        0
    }
}

fn render_preview(state: &DiskState) -> Option<Preview> {
    if state.capacity.is_none() && state.previous_io.is_none() {
        return None;
    }
    let capacity = state
        .capacity
        .as_ref()
        .and_then(CapacitySnapshot::primary)
        .map_or_else(
            || "—".to_string(),
            |volume| format!("{:>3} %", volume.percent),
        );
    let (read, written) = state
        .rates
        .map(|rates| (rate_iec(rates.read), rate_iec(rates.written)))
        .unwrap_or_else(|| ("—".to_string(), "—".to_string()));
    let totals = state.previous_io.as_ref().map(|sample| {
        sample
            .snapshot
            .devices
            .values()
            .fold(IoCounters::default(), |total, next| IoCounters {
                read: total.read.saturating_add(next.read),
                written: total.written.saturating_add(next.written),
            })
    });
    let mut preview = Preview::new()
        .title("Disks")
        .row("Capacity", format!("{capacity:>5}"))
        .row("Read", format!("{read:>12}"))
        .row("Write", format!("{written:>12}"))
        .row(
            "Read total",
            totals.map_or_else(|| "—".to_string(), |totals| bytes_iec(totals.read)),
        )
        .row(
            "Write total",
            totals.map_or_else(|| "—".to_string(), |totals| bytes_iec(totals.written)),
        )
        .note("Totals since device reset · rates sampled every 3s")
        .row(
            "Read history",
            sparkline_padded(&sparkline_scaled(&state.read_history), HISTORY_LEN),
        )
        .row(
            "Write history",
            sparkline_padded(&sparkline_scaled(&state.write_history), HISTORY_LEN),
        );
    for volume in state.capacity.iter().flat_map(|capacity| &capacity.volumes) {
        preview = preview
            .row("Volume", Markup::text(&volume.name))
            .row("Mount", Markup::text(&volume.mount))
            .row(
                "Space",
                format!(
                    "{:>3} % · {:>10} / {:>10}",
                    volume.percent,
                    bytes_iec(volume.used),
                    bytes_iec(volume.total)
                ),
            )
            .row("Free", bytes_iec(volume.total.saturating_sub(volume.used)));
    }
    Some(preview)
}

fn main() {
    run(Disks);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    fn startup(percent: u8) -> Volume {
        Volume {
            name: "Startup".to_string(),
            mount: "/".to_string(),
            total: 100,
            used: u64::from(percent),
            percent,
        }
    }

    fn history(values: impl IntoIterator<Item = f64>) -> History<HISTORY_LEN> {
        let mut history = History::new();
        for value in values {
            history.push(value);
        }
        history
    }

    fn activity_state() -> DiskState {
        DiskState {
            rates: Some(IoRates {
                read: 1_572_864.0,
                written: 2_048.0,
            }),
            read_history: history([1.0]),
            write_history: history([0.5]),
            capacity: Some(CapacitySnapshot {
                volumes: vec![Volume {
                    name: "Startup".to_string(),
                    mount: "/".to_string(),
                    total: 1_000 * 1024,
                    used: 900 * 1024,
                    percent: 90,
                }],
            }),
            ..DiskState::default()
        }
    }

    #[test]
    fn details_include_free_capacity_and_sampled_transfer_totals() {
        let mut state = activity_state();
        state.previous_io = Some(TimedIoSnapshot {
            sampled_at: Instant::now(),
            snapshot: IoSnapshot {
                devices: BTreeMap::from([
                    (
                        "disk0".to_string(),
                        IoCounters {
                            read: 1 << 30,
                            written: 2 << 30,
                        },
                    ),
                    (
                        "disk1".to_string(),
                        IoCounters {
                            read: 2 << 30,
                            written: 1 << 30,
                        },
                    ),
                ]),
            },
        });
        let details = render_preview(&state).unwrap().render_plain();
        assert!(details.contains("Free          100 KiB"), "{details}");
        assert!(details.contains("Read total    3.0 GiB"), "{details}");
        assert!(details.contains("Write total   3.0 GiB"), "{details}");
        assert!(
            details.lines().all(|line| line.chars().count() <= 50),
            "{details}"
        );
    }

    #[test]
    fn label_keeps_startup_usage_width_and_excludes_popup_markup() {
        for (percent, expected) in [(0, " 0%"), (9, " 9%"), (10, "10%"), (100, "99%")] {
            let state = DiskState {
                capacity: Some(CapacitySnapshot {
                    volumes: vec![
                        Volume {
                            name: "Backup".to_string(),
                            mount: "/Volumes/Backup".to_string(),
                            total: 100,
                            used: 99,
                            percent: 99,
                        },
                        startup(percent),
                    ],
                }),
                ..DiskState::default()
            };
            let [(_, summary), (_, label), ..] =
                render_status(&state, SummaryMode::Full).unwrap().segments();
            assert_eq!(
                label.render().unwrap(),
                format!("#[fg=#EBCB8B]DSK#[default] #[fg=colour245]{expected}#[default]")
            );
            assert!(summary.render().unwrap().contains("popup="));
        }
        let state = DiskState {
            capacity: Some(CapacitySnapshot::default()),
            ..DiskState::default()
        };
        assert_eq!(
            render_status(&state, SummaryMode::Compact)
                .unwrap()
                .label
                .as_str(),
            "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]  —#[default]"
        );
    }

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn compact_disk_summary_caps_at_two_percentage_digits() {
        for (percent, expected) in [
            (9, "#[fg=#EBCB8B]DSK#[default] #[fg=colour245] 9%#[default]"),
            (
                10,
                "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]10%#[default]",
            ),
            (
                100,
                "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]99%#[default]",
            ),
        ] {
            let state = DiskState {
                capacity: Some(CapacitySnapshot {
                    volumes: vec![startup(percent)],
                }),
                ..DiskState::default()
            };
            let visible = render_status(&state, SummaryMode::Compact)
                .expect("rendered disk status")
                .visible;
            assert_eq!(visible.as_str(), expected);
        }
    }

    fn io_snapshot(devices: &[(&str, u64, u64)], sampled_at: Instant) -> TimedIoSnapshot {
        TimedIoSnapshot {
            snapshot: IoSnapshot {
                devices: devices
                    .iter()
                    .map(|(id, read, written)| {
                        (
                            (*id).to_string(),
                            IoCounters {
                                read: *read,
                                written: *written,
                            },
                        )
                    })
                    .collect(),
            },
            sampled_at,
        }
    }

    #[test]
    fn parses_each_ioreg_device_by_registry_id() {
        let output = r#"
+-o IOBlockStorageDriver  <class IOBlockStorageDriver, id 0x100000c6f, registered>
  {
    "IOClass" = "IOBlockStorageDriver"
    "IOProviderClass" = "IOBlockStorageDevice"
    "Statistics" = {"Bytes (Read)"=100,"Bytes (Write)"=200}
  }
+-o IOBlockStorageDriver  <class IOBlockStorageDriver, id 0x1000007ea, registered>
  {
    "IOClass" = "IOBlockStorageDriver"
    "Statistics" = {"Operations (Write)"=5,"Bytes (Write)"=900,"Bytes (Read)"=700}
  }
"#;
        let snapshot = parse_ioreg_snapshot(output).unwrap();
        assert_eq!(
            snapshot.devices.get("0x100000c6f"),
            Some(&IoCounters {
                read: 100,
                written: 200
            })
        );
        assert_eq!(
            snapshot.devices.get("0x1000007ea"),
            Some(&IoCounters {
                read: 700,
                written: 900
            })
        );
    }

    #[test]
    fn io_rates_use_elapsed_time_and_ignore_new_device_lifetime_totals() {
        let start = Instant::now();
        let previous = io_snapshot(&[("disk-a", 100, 200)], start);
        let current = io_snapshot(
            &[("disk-a", 300, 500), ("new-disk", 9_000_000, 8_000_000)],
            start + Duration::from_secs(5),
        );
        let RateDecision::Rates(rates) = calculate_io_rates(&previous, &current) else {
            panic!("expected rates");
        };
        assert_eq!(rates.read, 40.0);
        assert_eq!(rates.written, 60.0);
    }

    #[test]
    fn io_rates_reset_after_wake_or_complete_device_replacement() {
        let start = Instant::now();
        let previous = io_snapshot(&[("disk-a", 100, 200)], start);
        assert!(matches!(
            calculate_io_rates(
                &previous,
                &io_snapshot(&[("disk-a", 200, 300)], start + Duration::from_secs(46))
            ),
            RateDecision::Reset
        ));
        assert!(matches!(
            calculate_io_rates(
                &previous,
                &io_snapshot(&[("disk-b", 200, 300)], start + Duration::from_secs(5))
            ),
            RateDecision::Reset
        ));
    }

    #[test]
    fn io_rates_discard_an_interval_when_either_counter_rolls_back() {
        let start = Instant::now();
        let previous = io_snapshot(&[("disk-a", 1_000, 2_000), ("disk-b", 3_000, 4_000)], start);
        let current = io_snapshot(
            &[("disk-a", 900, 2_500), ("disk-b", 3_500, 4_500)],
            start + Duration::from_secs(10),
        );
        assert!(matches!(
            calculate_io_rates(&previous, &current),
            RateDecision::Reset
        ));
    }

    #[test]
    fn stale_rates_expire_without_discarding_capacity() {
        let sampled_at = Instant::now();
        let capacity = CapacitySnapshot {
            volumes: vec![Volume {
                name: "Startup".to_string(),
                mount: "/".to_string(),
                total: 1_000,
                used: 500,
                percent: 50,
            }],
        };
        let mut state = DiskState {
            rates: Some(IoRates {
                read: 10.0,
                written: 20.0,
            }),
            read_history: history([10.0]),
            write_history: history([20.0]),
            capacity: Some(capacity.clone()),
            last_io_success: Some(sampled_at),
            ..DiskState::default()
        };

        assert!(!state.expire_stale_rates(sampled_at + MAX_RATE_INTERVAL));
        assert!(state.expire_stale_rates(sampled_at + MAX_RATE_INTERVAL + Duration::from_millis(1)));
        assert_eq!(state.rates, None);
        assert!(state.read_history.is_empty());
        assert!(state.write_history.is_empty());
        assert_eq!(state.capacity, Some(capacity));
        let preview = render_preview(&state).unwrap().render();
        assert!(preview
            .as_str()
            .contains("#[fg=colour245]Read          #[default]           —"));
        assert!(preview
            .as_str()
            .contains("#[fg=colour245]Volume        #[default]Startup"));
    }

    #[test]
    fn apfs_data_capacity_replaces_root_and_keeps_direct_visible_volumes() {
        let output = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
/dev/disk3s1s1 1000 100 800 10% /\n\
/dev/disk3s5 1000 900 50 90% /System/Volumes/Data\n\
/dev/disk4s1 2000 500 1000 50% /Volumes/Backup Drive\n\
/dev/disk5s1 3000 100 2500 4% /Volumes/Backup Drive/Nested\n";
        let snapshot = parse_df_snapshot(output).unwrap();
        assert_eq!(snapshot.volumes.len(), 2);
        let startup = snapshot.primary().unwrap();
        assert_eq!(startup.name, "Startup");
        assert_eq!(startup.mount, "/");
        assert_eq!(startup.used, 950 * 1024);
        assert_eq!(startup.percent, 95);
        assert_eq!(snapshot.volumes[1].name, "Backup Drive");
        assert_eq!(snapshot.volumes[1].percent, 50);
    }

    #[test]
    fn root_is_used_when_apfs_data_volume_is_absent() {
        let output = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
/dev/disk3s1s1 1000 100 800 10% /\n";
        let snapshot = parse_df_snapshot(output).unwrap();
        let startup = snapshot.primary().unwrap();
        assert_eq!(startup.name, "Startup");
        assert_eq!(startup.used, 200 * 1024);
        assert_eq!(startup.percent, 20);
    }

    #[test]
    fn mount_filter_rejects_hidden_and_nested_mounts() {
        assert!(is_visible_mount("/"));
        assert!(is_visible_mount("/Volumes/Backup"));
        assert!(!is_visible_mount("/System/Volumes/Data"));
        assert!(!is_visible_mount("/Volumes/Backup/Nested"));
    }

    #[test]
    fn plain_command_reply_is_the_preview_without_markup() {
        assert_eq!(
            render_preview(&activity_state()).unwrap().render_plain(),
            "Disks\n\
Capacity       90 %\n\
Read             1.5 MiB/s\n\
Write            2.0 KiB/s\n\
Read total    —\n\
Write total   —\n\
Totals since device reset · rates sampled every 3s\n\
Read history  ···················█\n\
Write history ···················█\n\
Volume        Startup\n\
Mount         /\n\
Space          90 % ·    900 KiB /   1000 KiB\n\
Free          100 KiB"
        );
        assert!(render_preview(&DiskState::default()).is_none());
    }

    #[test]
    fn renders_capacity_only_summary_with_activity_in_inline_popup() {
        let state = activity_state();
        let rendered = render_status(&state, SummaryMode::Compact).unwrap();
        assert_eq!(
            rendered.visible.as_str(),
            "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]90%#[default]"
        );
        let [(_, summary), _, (_, details), ..] = rendered.segments();
        let summary = summary.render().unwrap();
        assert!(summary.starts_with("#[popup=inline:"));
        assert!(
            summary.ends_with("]#[fg=#EBCB8B]DSK#[default] #[fg=colour245]90%#[default]#[nopopup]")
        );
        assert_eq!(
            render_status(&state, SummaryMode::Full).unwrap().visible.as_str(),
            "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]90%#[default] #[fg=colour39]↓1.5MiB#[default] #[fg=colour214]↑2.0KiB#[default] █"
        );
        assert_eq!(ACTIVITY_POLL, Duration::from_secs(3));
        assert_eq!(CAPACITY_POLL, Duration::from_secs(30));
        assert_eq!(HISTORY_LEN, 20);
        assert_eq!(
            details.render().unwrap(),
            "#[fg=#EBCB8B]Disks#[default]\n\
#[fg=colour245]Capacity      #[default] 90 %\n\
#[fg=colour245]Read          #[default]   1.5 MiB/s\n\
#[fg=colour245]Write         #[default]   2.0 KiB/s\n\
#[fg=colour245]Read total    #[default]—\n\
#[fg=colour245]Write total   #[default]—\n\
#[fg=colour245]Totals since device reset · rates sampled every 3s#[default]\n\
#[fg=colour245]Read history  #[default]···················█\n\
#[fg=colour245]Write history #[default]···················█\n\
#[fg=colour245]Volume        #[default]Startup\n\
#[fg=colour245]Mount         #[default]/\n\
#[fg=colour245]Space         #[default] 90 % ·    900 KiB /   1000 KiB\n\
#[fg=colour245]Free          #[default]100 KiB"
        );
    }

    #[test]
    fn identical_rendered_status_is_published_once() {
        let mut harness = Harness::new("disks");
        let ctx = harness.context();
        let mut state = DiskState {
            capacity: Some(CapacitySnapshot {
                volumes: vec![startup(90)],
            }),
            ..DiskState::default()
        };

        publish_status(&ctx, &mut state);
        publish_status(&ctx, &mut state);
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert_eq!(
            frames[0]["label"],
            "#[fg=#EBCB8B]DSK#[default] #[fg=colour245]90%#[default]"
        );
        assert!(frames[0]["summary"].starts_with("#[popup=inline:"));
        assert!(frames[0]["summary"]
            .ends_with("]#[fg=#EBCB8B]DSK#[default] #[fg=colour245]90%#[default]#[nopopup]"));
        assert_eq!(
            frames[0]["details"],
            render_preview(&state).unwrap().render().as_str()
        );
        assert_eq!(frames[0]["percent"], "90");
        for rate in ["read_bps", "write_bps", "read", "write"] {
            assert_eq!(frames[0][rate], "", "no rate yet clears {rate}");
        }

        state.capacity = Some(CapacitySnapshot {
            volumes: vec![startup(91)],
        });
        publish_status(&ctx, &mut state);
        assert_eq!(harness.drain_status().len(), 1);

        publish_status(&ctx, &mut DiskState::default());
        assert!(harness.drain_status().is_empty());
    }

    #[test]
    fn rich_details_escape_markup_from_volume_names_and_mounts() {
        let state = DiskState {
            capacity: Some(CapacitySnapshot {
                volumes: vec![Volume {
                    name: "Backup #[fg=colour196]".to_string(),
                    mount: "/Volumes/#1".to_string(),
                    total: 1_000,
                    used: 500,
                    percent: 50,
                }],
            }),
            ..DiskState::default()
        };

        let preview = render_preview(&state).unwrap();
        assert!(preview
            .render_plain()
            .contains("Volume        Backup #[fg=colour196]\nMount         /Volumes/#1"));
        assert!(preview.render().as_str().contains(
            "#[fg=colour245]Volume        #[default]Backup ##[fg=colour196]\n#[fg=colour245]Mount         #[default]/Volumes/##1"
        ));
    }

    #[test]
    fn collection_failure_logs_once_until_a_success_rearms_it() {
        let mut logged = false;
        assert!(first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, false));
        assert!(first_failure(&mut logged, true));
    }

    #[test]
    fn raw_segments_carry_startup_percent_and_whole_byte_rates() {
        let raw = render_status(&activity_state(), SummaryMode::Compact)
            .unwrap()
            .raw;
        assert_eq!(
            raw,
            RawMetrics {
                percent: "90".to_string(),
                read_bps: "1572864".to_string(),
                write_bps: "2048".to_string(),
                read: "1.5 MiB/s".to_string(),
                write: "2.0 KiB/s".to_string(),
            }
        );
    }

    #[test]
    fn raw_rates_round_to_whole_bytes_and_idle_reads_zero() {
        let mut state = activity_state();
        state.rates = Some(IoRates {
            read: 1_234.5,
            written: 0.4,
        });
        let raw = raw_metrics(&state);
        assert_eq!(
            (raw.read_bps.as_str(), raw.write_bps.as_str()),
            ("1235", "0")
        );

        state.rates = Some(IoRates {
            read: 0.0,
            written: 0.0,
        });
        let raw = raw_metrics(&state);
        assert_eq!(
            (
                raw.read_bps.as_str(),
                raw.write_bps.as_str(),
                raw.read.as_str(),
                raw.write.as_str()
            ),
            ("0", "0", "0 B/s", "0 B/s")
        );
        assert_eq!(whole_rate(f64::NAN), 0);
        assert_eq!(whole_rate(-5.0), 0);
    }

    #[test]
    fn raw_percent_reaches_one_hundred_and_unknown_values_clear() {
        let state = DiskState {
            capacity: Some(CapacitySnapshot {
                volumes: vec![startup(100)],
            }),
            ..DiskState::default()
        };
        let rendered = render_status(&state, SummaryMode::Compact).unwrap();
        assert!(rendered.label.as_str().contains("99%"));
        assert_eq!(rendered.raw.percent, "100");
        assert_eq!(rendered.raw.read_bps, "");

        let mut stale = activity_state();
        stale.capacity = Some(CapacitySnapshot::default());
        stale.last_io_success = Some(Instant::now());
        assert!(stale.expire_stale_rates(Instant::now() + MAX_RATE_INTERVAL * 2));
        assert_eq!(raw_metrics(&stale), RawMetrics::default());
    }
}

use std::collections::{BTreeMap, VecDeque};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, CommandRequest, Context,
    PerformResponse, RefreshGate,
};

const ACTIVITY_POLL: Duration = Duration::from_secs(10);
const CAPACITY_POLL: Duration = Duration::from_secs(30);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const MIN_RATE_INTERVAL: Duration = Duration::from_secs(1);
const MAX_RATE_INTERVAL: Duration = Duration::from_secs(45);
const HISTORY_LEN: usize = 16;

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

#[derive(Clone, Debug, PartialEq, Eq)]
struct RenderedStatus {
    summary: String,
    details: String,
}

#[derive(Default)]
struct DiskState {
    previous_io: Option<TimedIoSnapshot>,
    rates: Option<IoRates>,
    read_history: VecDeque<f64>,
    write_history: VecDeque<f64>,
    capacity: Option<CapacitySnapshot>,
    last_capacity_attempt: Option<Instant>,
    last_io_success: Option<Instant>,
    last_status: Option<RenderedStatus>,
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
                push_history(&mut self.read_history, rates.read);
                push_history(&mut self.write_history, rates.written);
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
    emit_status_if_changed(ctx);
}

fn current_response() -> PerformResponse {
    match render_details(&state()) {
        Some(details) => PerformResponse::ok().message(details),
        None => PerformResponse::fail("disk metrics are not available yet"),
    }
}

fn emit_status_if_changed(ctx: &Context) {
    let rendered = {
        let mut state = state();
        let Some(rendered) = render_status(&state) else {
            return;
        };
        let Some(rendered) = status_update(&mut state.last_status, rendered) else {
            return;
        };
        rendered
    };
    ctx.status([("summary", rendered.summary), ("details", rendered.details)]);
}

fn status_update(
    last: &mut Option<RenderedStatus>,
    next: RenderedStatus,
) -> Option<RenderedStatus> {
    if last.as_ref() == Some(&next) {
        return None;
    }
    *last = Some(next.clone());
    Some(next)
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

fn push_history(history: &mut VecDeque<f64>, value: f64) {
    if history.len() == HISTORY_LEN {
        history.pop_front();
    }
    history.push_back(value);
}

fn render_status(state: &DiskState) -> Option<RenderedStatus> {
    let plain_details = render_details(state)?;
    let details = escape_status_text(&plain_details);
    let primary = state.capacity.as_ref().and_then(CapacitySnapshot::primary);
    let percent = primary
        .map(|volume| format!("{}%", volume.percent))
        .unwrap_or_else(|| "—".to_string());
    let color = match primary.map(|volume| volume.percent) {
        Some(90..) => "colour196",
        Some(75..) => "colour178",
        _ => "colour45",
    };
    let visible = format!("#[fg={color},bold]DSK#[default] {percent}");
    Some(RenderedStatus {
        summary: inline_status_popup(&visible, &details),
        details,
    })
}

fn render_details(state: &DiskState) -> Option<String> {
    if state.capacity.is_none() && state.previous_io.is_none() {
        return None;
    }
    let mut lines = vec!["Disks".to_string()];
    if let Some(rates) = state.rates {
        lines.push(format!("Read: {}", format_rate(rates.read)));
        lines.push(format!("Write: {}", format_rate(rates.written)));
    } else {
        lines.push("Activity: sampling…".to_string());
    }
    let read_history: Vec<f64> = state.read_history.iter().copied().collect();
    let write_history: Vec<f64> = state.write_history.iter().copied().collect();
    let read_chart = sparkline(&read_history);
    let write_chart = sparkline(&write_history);
    if !read_chart.is_empty() {
        lines.push(format!("Read history: {read_chart}"));
    }
    if !write_chart.is_empty() {
        lines.push(format!("Write history: {write_chart}"));
    }
    if let Some(capacity) = &state.capacity {
        lines.push("Volumes".to_string());
        for volume in &capacity.volumes {
            lines.push(format!(
                "{} ({}): {}% · {} / {}",
                volume.name,
                volume.mount,
                volume.percent,
                format_bytes(volume.used),
                format_bytes(volume.total)
            ));
        }
    }
    Some(lines.join("\n"))
}

fn format_rate(bytes_per_second: f64) -> String {
    format!("{}/s", scaled_bytes(bytes_per_second, true))
}

fn format_bytes(bytes: u64) -> String {
    scaled_bytes(bytes as f64, true)
}

fn scaled_bytes(bytes: f64, spaced: bool) -> String {
    let separator = if spaced { " " } else { "" };
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
    let mut value = bytes.max(0.0);
    let mut unit = 0;
    while value >= 1024.0 && unit < units.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    let number = if unit == 0 || value >= 10.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    };
    format!("{number}{separator}{}", units[unit])
}

fn sparkline(values: &[f64]) -> String {
    const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let maximum = values.iter().copied().fold(0.0_f64, f64::max);
    values
        .iter()
        .map(|value| {
            if maximum <= f64::EPSILON {
                BARS[0]
            } else {
                let index = ((*value / maximum) * (BARS.len() - 1) as f64).floor() as usize;
                BARS[index.min(BARS.len() - 1)]
            }
        })
        .collect()
}

fn main() {
    run(Disks);
}

#[cfg(test)]
mod tests {
    use super::*;

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
            read_history: VecDeque::from([10.0]),
            write_history: VecDeque::from([20.0]),
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
        assert!(render_details(&state)
            .unwrap()
            .contains("Activity: sampling…"));
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
    fn history_is_bounded_and_sparkline_scales() {
        let mut history = VecDeque::new();
        for value in 0..20 {
            push_history(&mut history, f64::from(value));
        }
        assert_eq!(history.len(), HISTORY_LEN);
        assert_eq!(history.front(), Some(&4.0));
        assert_eq!(sparkline(&[0.0, 1.0, 2.0, 3.0]), "▁▃▅█");
    }

    #[test]
    fn renders_capacity_only_summary_with_activity_in_inline_popup() {
        let mut state = DiskState {
            rates: Some(IoRates {
                read: 1_572_864.0,
                written: 2_048.0,
            }),
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
        };
        push_history(&mut state.read_history, 1.0);
        push_history(&mut state.write_history, 0.5);
        let rendered = render_status(&state).unwrap();
        assert!(rendered.summary.starts_with("#[popup=inline:"));
        assert!(rendered
            .summary
            .ends_with("]#[fg=colour196,bold]DSK#[default] 90%#[nopopup]"));
        assert!(!rendered.summary.contains("R1.5MiB"));
        assert!(!rendered.summary.contains("W2.0KiB"));
        assert!(rendered.details.contains("Read: 1.5 MiB/s"));
        assert!(rendered.details.contains("Write: 2.0 KiB/s"));
        assert!(rendered.details.contains("Read history: █"));
        assert!(rendered.details.contains("Write history: █"));
        assert!(rendered.details.contains("Startup (/): 90%"));
    }

    #[test]
    fn identical_rendered_status_is_suppressed() {
        let rendered = RenderedStatus {
            summary: "summary".to_string(),
            details: "details".to_string(),
        };
        let mut last = None;
        assert_eq!(
            status_update(&mut last, rendered.clone()),
            Some(rendered.clone())
        );
        assert_eq!(status_update(&mut last, rendered), None);
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

        let plain = render_details(&state).unwrap();
        let rendered = render_status(&state).unwrap();

        assert!(plain.contains("Backup #[fg=colour196] (/Volumes/#1)"));
        assert!(rendered
            .details
            .contains("Backup ##[fg=colour196] (/Volumes/##1)"));
    }

    #[test]
    fn collection_failure_logs_once_until_a_success_rearms_it() {
        let mut logged = false;
        assert!(first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, false));
        assert!(first_failure(&mut logged, true));
    }
}

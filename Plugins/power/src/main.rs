use std::collections::VecDeque;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, CommandRequest, Context, Event,
    PerformResponse, RefreshGate,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const REFRESH_INTERVAL: Duration = Duration::from_secs(1);
const HEALTH_REFRESH_INTERVAL: Duration = Duration::from_secs(30);
const HISTORY_LEN: usize = 20;
const DETAIL_LABEL_WIDTH: usize = 14;
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static LAST_GOOD: LazyLock<Mutex<Option<StatusSegments>>> = LazyLock::new(|| Mutex::new(None));
static LAST_HEALTH: LazyLock<Mutex<Option<BatteryHealth>>> = LazyLock::new(|| Mutex::new(None));
static LAST_HEALTH_ATTEMPT: LazyLock<Mutex<Option<Instant>>> = LazyLock::new(|| Mutex::new(None));
static REFRESH_FAILURE_LOGGED: LazyLock<Mutex<bool>> = LazyLock::new(|| Mutex::new(false));
static CHARGE_HISTORY: LazyLock<Mutex<VecDeque<f64>>> =
    LazyLock::new(|| Mutex::new(VecDeque::new()));

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BatteryState {
    Charging,
    Charged,
    Discharging,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PowerSource {
    Adapter,
    Battery,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct BatterySnapshot {
    percent: u8,
    state: BatteryState,
    estimate_minutes: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PowerSnapshot {
    source: PowerSource,
    battery: Option<BatterySnapshot>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct BatteryHealth {
    cycle_count: Option<u64>,
    design_capacity: Option<u64>,
    maximum_capacity: Option<u64>,
    temperature_centi_celsius: Option<u64>,
    adapter_watts: Option<u64>,
    condition: Option<String>,
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
            "[power] summary_mode must be compact or full; using compact",
        );
    }
}

struct Power;

flash_plugin::plugin!(Power);

impl FlashPlugin for Power {
    async fn on_start(&self, ctx: Context) {
        warn_invalid_summary_mode(&ctx);
        let _ = refresh_and_publish(&ctx, true).await;
        drop(ctx.interval(REFRESH_INTERVAL, |ctx| async move {
            let _ = refresh_and_publish(&ctx, false).await;
        }));
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name == "core:power.changed" {
            let _ = refresh_and_publish(&ctx, true).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => details_response(last_good()),
            "refresh" => {
                let refreshed = try_refresh_and_publish(&ctx, true).await.flatten();
                details_response(refreshed.or_else(last_good))
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_and_publish(ctx: &Context, force_health: bool) -> Option<StatusSegments> {
    REFRESH_GATE
        .run(ctx, move |ctx, _applications| {
            collect_and_publish(ctx, force_health)
        })
        .await
}

async fn try_refresh_and_publish(
    ctx: &Context,
    force_health: bool,
) -> Option<Option<StatusSegments>> {
    REFRESH_GATE
        .try_run(ctx, move |ctx, _applications| {
            collect_and_publish(ctx, force_health)
        })
        .await
}

async fn collect_and_publish(ctx: Context, force_health: bool) -> Option<StatusSegments> {
    let health_due = {
        let last_attempt = LAST_HEALTH_ATTEMPT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        health_refresh_due(*last_attempt, force_health, Instant::now())
    };
    let pmset_argv = vec![PMSET.to_string(), "-g".to_string(), "batt".to_string()];
    let ioreg_argv = vec![
        IOREG.to_string(),
        "-r".to_string(),
        "-c".to_string(),
        "AppleSmartBattery".to_string(),
        "-l".to_string(),
    ];
    let ioreg = async {
        if !health_due {
            return None;
        }
        Some(run_command(&ctx, &ioreg_argv, COMMAND_TIMEOUT).await)
    };
    let (pmset, ioreg) = tokio::join!(run_command(&ctx, &pmset_argv, COMMAND_TIMEOUT), ioreg,);
    if health_due {
        *LAST_HEALTH_ATTEMPT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Instant::now());
    }

    let Some(snapshot) = parse_pmset_snapshot(&pmset.stdout) else {
        let should_log = {
            let mut logged = REFRESH_FAILURE_LOGGED
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            first_failure(&mut logged, true)
        };
        if should_log {
            ctx.log("warn", "[power] refresh failed");
        }
        return None;
    };
    {
        let mut logged = REFRESH_FAILURE_LOGGED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        first_failure(&mut logged, false);
    }

    let health = if snapshot.battery.is_some() {
        let previous = LAST_HEALTH
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let fresh = ioreg
            .as_ref()
            .filter(|output| output.ok)
            .and_then(|output| parse_ioreg_health(&output.stdout));
        merge_health(fresh, previous)
    } else {
        None
    };
    *LAST_HEALTH
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = health.clone();

    let history = {
        let mut history = CHARGE_HISTORY
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(battery) = snapshot.battery.as_ref() {
            push_history(&mut history, f64::from(battery.percent));
        } else {
            history.clear();
        }
        history.clone()
    };
    let status = render_status(
        &snapshot,
        health.as_ref(),
        configured_summary_mode(&ctx),
        &history,
    );
    let should_publish = {
        let mut last = LAST_GOOD
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let changed = last.as_ref() != Some(&status);
        *last = Some(status.clone());
        changed
    };
    if should_publish {
        ctx.status([
            ("summary", status.summary.as_str()),
            ("label", status.label.as_str()),
            ("details", status.details.as_str()),
        ]);
    }
    Some(status)
}

fn health_refresh_due(last_attempt: Option<Instant>, force: bool, now: Instant) -> bool {
    force
        || last_attempt.is_none_or(|last_attempt| {
            now.saturating_duration_since(last_attempt) >= HEALTH_REFRESH_INTERVAL
        })
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

fn details_response(status: Option<StatusSegments>) -> PerformResponse {
    status
        .map(|status| PerformResponse::ok().message(status.plain_details))
        .unwrap_or_else(|| PerformResponse::fail("power information unavailable"))
}

fn last_good() -> Option<StatusSegments> {
    LAST_GOOD
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

fn parse_pmset_snapshot(raw: &str) -> Option<PowerSnapshot> {
    let source = if raw.contains("AC Power") {
        PowerSource::Adapter
    } else if raw.contains("Battery Power") {
        PowerSource::Battery
    } else {
        PowerSource::Unknown
    };
    let mut nonempty_lines = raw.lines().map(str::trim).filter(|line| !line.is_empty());
    let source_only = nonempty_lines
        .next()
        .is_some_and(|line| line.contains("drawing from 'AC Power'"))
        && nonempty_lines.next().is_none()
        && source == PowerSource::Adapter;
    if raw.contains("No batteries are currently installed") || source_only {
        return Some(PowerSnapshot {
            source,
            battery: None,
        });
    }

    let percent = battery_percent(raw)?;
    let state = if raw.contains("; charging") || raw.contains("; finishing charge") {
        BatteryState::Charging
    } else if raw.contains("; charged") {
        BatteryState::Charged
    } else if raw.contains("; discharging") {
        BatteryState::Discharging
    } else {
        BatteryState::Unknown
    };
    Some(PowerSnapshot {
        source,
        battery: Some(BatterySnapshot {
            percent,
            state,
            estimate_minutes: battery_estimate_minutes(raw),
        }),
    })
}

fn parse_ioreg_health(raw: &str) -> Option<BatteryHealth> {
    let health = BatteryHealth {
        cycle_count: ioreg_u64(raw, "CycleCount"),
        design_capacity: ioreg_u64(raw, "DesignCapacity"),
        maximum_capacity: ioreg_u64(raw, "AppleRawMaxCapacity")
            .or_else(|| ioreg_u64(raw, "NominalChargeCapacity"))
            .or_else(|| ioreg_u64(raw, "MaxCapacity")),
        temperature_centi_celsius: ioreg_u64(raw, "Temperature")
            .filter(|temperature| *temperature <= 10_000),
        adapter_watts: ioreg_u64(raw, "Watts"),
        condition: ioreg_string(raw, "BatteryHealthCondition"),
    };
    (health != BatteryHealth::default()).then_some(health)
}

fn merge_health(
    fresh: Option<BatteryHealth>,
    previous: Option<BatteryHealth>,
) -> Option<BatteryHealth> {
    let Some(mut fresh) = fresh else {
        return previous;
    };
    if let Some(previous) = previous {
        fresh.cycle_count = fresh.cycle_count.or(previous.cycle_count);
        fresh.design_capacity = fresh.design_capacity.or(previous.design_capacity);
        fresh.maximum_capacity = fresh.maximum_capacity.or(previous.maximum_capacity);
        fresh.temperature_centi_celsius = fresh
            .temperature_centi_celsius
            .or(previous.temperature_centi_celsius);
        fresh.adapter_watts = fresh.adapter_watts.or(previous.adapter_watts);
        fresh.condition = fresh.condition.or(previous.condition);
    }
    Some(fresh)
}

fn render_status(
    snapshot: &PowerSnapshot,
    health: Option<&BatteryHealth>,
    summary_mode: SummaryMode,
    history: &VecDeque<f64>,
) -> StatusSegments {
    let mut rows = match snapshot.battery {
        Some(ref battery) => vec![
            format!("Charge: {}%", battery.percent),
            format!("State: {}", battery.state.label()),
            format!("Source: {}", snapshot.source.label()),
            format!("Estimate: {}", estimate_label(battery)),
        ],
        None => vec![
            "Charge: Not installed".to_string(),
            "State: Not installed".to_string(),
            format!("Source: {}", snapshot.source.label()),
            "Estimate: Unavailable".to_string(),
        ],
    };
    if let Some(health) = health {
        match (health.maximum_capacity, health.design_capacity) {
            (Some(maximum), Some(design)) if design > 0 => {
                let percent =
                    ((u128::from(maximum) * 100) + u128::from(design / 2)) / u128::from(design);
                let suffix = health
                    .condition
                    .as_deref()
                    .map(|condition| format!(" ({condition})"))
                    .unwrap_or_default();
                rows.push(format!("Health: {percent}% of design{suffix}"));
            }
            (_, _) => {
                if let Some(condition) = health.condition.as_deref() {
                    rows.push(format!("Health: {condition}"));
                }
            }
        }
        if let Some(cycles) = health.cycle_count {
            rows.push(format!("Cycles: {cycles}"));
        }
        if let Some(temperature) = health.temperature_centi_celsius {
            rows.push(format!(
                "Temperature: {}.{}°C",
                temperature / 100,
                (temperature % 100) / 10
            ));
        }
        if snapshot.source == PowerSource::Adapter {
            if let Some(watts) = health.adapter_watts {
                rows.push(format!("Adapter: {watts} W"));
            }
        }
    }
    let plain_details = rows.join("\n");
    let details = render_popup_details(snapshot, health, history);
    let visible = visible_summary(snapshot, summary_mode);
    StatusSegments {
        summary: inline_status_popup(&visible, &details),
        label: visible,
        details,
        plain_details,
    }
}

fn render_popup_details(
    snapshot: &PowerSnapshot,
    health: Option<&BatteryHealth>,
    history: &VecDeque<f64>,
) -> String {
    let battery = snapshot.battery.as_ref();
    let health_percent =
        health.and_then(
            |health| match (health.maximum_capacity, health.design_capacity) {
                (Some(maximum), Some(design)) if design > 0 => Some(
                    ((u128::from(maximum) * 100) + u128::from(design / 2)) / u128::from(design),
                ),
                _ => None,
            },
        );
    let rows = [
        "#[fg=#EBCB8B]Battery#[default]".to_string(),
        detail_row(
            "Charge",
            &battery
                .map(|battery| format!("{:>3} %", battery.percent))
                .unwrap_or_else(|| "    —".to_string()),
        ),
        detail_row(
            "State",
            battery
                .map(|battery| battery.state.label())
                .unwrap_or("Not installed"),
        ),
        detail_row("Source", snapshot.source.label()),
        detail_row(
            "Estimate",
            &battery
                .map(estimate_label)
                .unwrap_or_else(|| "Unavailable".to_string()),
        ),
        detail_row(
            "Health",
            &health_percent
                .map(|percent| format!("{percent:>3} %"))
                .unwrap_or_else(|| "    —".to_string()),
        ),
        detail_row(
            "Condition",
            &health
                .and_then(|health| health.condition.as_deref())
                .map(escape_status_text)
                .unwrap_or_else(|| "—".to_string()),
        ),
        detail_row(
            "Cycles",
            &health
                .and_then(|health| health.cycle_count)
                .map(|cycles| format!("{cycles:>10}"))
                .unwrap_or_else(|| "         —".to_string()),
        ),
        detail_row(
            "Temperature",
            &health
                .and_then(|health| health.temperature_centi_celsius)
                .map(|temperature| format!("{:>5.1} °C", temperature as f64 / 100.0))
                .unwrap_or_else(|| "    — °C".to_string()),
        ),
        detail_row(
            "Adapter",
            &health
                .and_then(|health| health.adapter_watts)
                .filter(|_| snapshot.source == PowerSource::Adapter)
                .map(|watts| format!("{watts:>3} W"))
                .unwrap_or_else(|| "  — W".to_string()),
        ),
        detail_row("History", &padded_history(history)),
    ];
    rows.join("\n")
}

fn detail_row(label: &str, value: &str) -> String {
    format!(
        "#[fg=colour245]{label:<width$}#[default]{value}",
        width = DETAIL_LABEL_WIDTH
    )
}

fn push_history(history: &mut VecDeque<f64>, value: f64) {
    if history.len() == HISTORY_LEN {
        history.pop_front();
    }
    history.push_back(value.clamp(0.0, 100.0));
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

fn padded_history(history: &VecDeque<f64>) -> String {
    let chart = sparkline(history);
    let padding = HISTORY_LEN.saturating_sub(chart.chars().count());
    format!("{}{chart}", "·".repeat(padding))
}

fn visible_summary(snapshot: &PowerSnapshot, summary_mode: SummaryMode) -> String {
    if snapshot.source == PowerSource::Adapter
        && snapshot
            .battery
            .as_ref()
            .is_some_and(|battery| battery.percent == 100)
    {
        return "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]".to_string();
    }
    let (mut value, breathing) = match snapshot.battery {
        Some(ref battery) => (
            format!("{:>2}%", battery.percent),
            snapshot.source == PowerSource::Adapter,
        ),
        None => ("—".to_string(), false),
    };
    if summary_mode == SummaryMode::Full {
        let secondary = snapshot
            .battery
            .as_ref()
            .and_then(|battery| battery.estimate_minutes.map(natural_duration))
            .unwrap_or_else(|| snapshot.source.label().to_string());
        value.push_str(" · ");
        value.push_str(&secondary);
    }
    let breathing_open = if breathing { "#[breathing]" } else { "" };
    let breathing_close = if breathing { "#[nobreathing]" } else { "" };
    format!(
        "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]{breathing_open}{value}{breathing_close}#[norange]#[default]#[pop-default]"
    )
}

fn natural_duration(minutes: u32) -> String {
    let hours = minutes / 60;
    let minutes = minutes % 60;
    match (hours, minutes) {
        (0, minutes) => format!("{minutes}m"),
        (hours, 0) => format!("{hours}h"),
        (hours, minutes) => format!("{hours}h {minutes}m"),
    }
}

impl BatteryState {
    fn label(self) -> &'static str {
        match self {
            Self::Charging => "Charging",
            Self::Charged => "Fully charged",
            Self::Discharging => "Discharging",
            Self::Unknown => "Unknown",
        }
    }
}

impl PowerSource {
    fn label(self) -> &'static str {
        match self {
            Self::Adapter => "AC adapter",
            Self::Battery => "Battery",
            Self::Unknown => "Unknown",
        }
    }
}

fn battery_percent(raw: &str) -> Option<u8> {
    let percent_index = raw.find('%')?;
    let digits = raw[..percent_index]
        .chars()
        .rev()
        .take_while(char::is_ascii_digit)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    digits.parse::<u8>().ok().filter(|percent| *percent <= 100)
}

fn battery_estimate_minutes(raw: &str) -> Option<u32> {
    let before_remaining = raw.split(" remaining").next()?;
    let token = before_remaining.split_whitespace().last()?;
    let (hours, minutes) = token.split_once(':')?;
    let hours = hours.parse::<u32>().ok()?;
    let minutes = minutes.parse::<u32>().ok()?;
    (minutes < 60)
        .then(|| hours.checked_mul(60)?.checked_add(minutes))
        .flatten()
}

fn estimate_label(battery: &BatterySnapshot) -> String {
    match (battery.state, battery.estimate_minutes) {
        (BatteryState::Charging, Some(minutes)) if minutes > 0 => {
            format!("Full in {}", natural_duration(minutes))
        }
        (BatteryState::Discharging, Some(minutes)) if minutes > 0 => {
            format!("{} remaining", natural_duration(minutes))
        }
        (BatteryState::Charged, _) => "Fully charged".to_string(),
        _ => "Unavailable".to_string(),
    }
}

fn ioreg_u64(raw: &str, key: &str) -> Option<u64> {
    let tail = ioreg_value_tail(raw, key)?;
    if let Some(hex) = tail.strip_prefix("0x") {
        let digits = hex
            .chars()
            .take_while(char::is_ascii_hexdigit)
            .collect::<String>();
        return u64::from_str_radix(&digits, 16).ok();
    }
    let digits = tail
        .chars()
        .take_while(char::is_ascii_digit)
        .collect::<String>();
    digits.parse::<u64>().ok()
}

fn ioreg_string(raw: &str, key: &str) -> Option<String> {
    let tail = ioreg_value_tail(raw, key)?.strip_prefix('"')?;
    let value = tail.split('"').next()?.trim();
    (!value.is_empty() && value.len() <= 64 && !value.chars().any(char::is_control))
        .then(|| value.to_string())
}

fn ioreg_value_tail<'a>(raw: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\"");
    let after_key = raw.split_once(&needle)?.1;
    after_key.lines().next()?.split_once('=')?.1.trim().into()
}

fn main() {
    run(Power);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn compact_power_summary_uses_grey_two_column_percentage() {
        for (percent, expected) in [(9, " 9%"), (10, "10%"), (99, "99%")] {
            let snapshot = PowerSnapshot {
                source: PowerSource::Battery,
                battery: Some(BatterySnapshot {
                    percent,
                    state: BatteryState::Discharging,
                    estimate_minutes: None,
                }),
            };
            assert_eq!(
                visible_summary(&snapshot, SummaryMode::Compact),
                format!(
                    "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]{expected}#[norange]#[default]#[pop-default]"
                )
            );
        }
        let no_battery = PowerSnapshot {
            source: PowerSource::Adapter,
            battery: None,
        };
        assert!(visible_summary(&no_battery, SummaryMode::Compact).contains(
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]—"
        ));
    }

    #[test]
    fn label_preserves_charge_without_embedding_a_document_popup() {
        let snapshot = parse_pmset_snapshot(DISCHARGING).unwrap();
        let status = render_status(&snapshot, None, SummaryMode::Compact, &VecDeque::new());
        assert_eq!(
            status.label,
            visible_summary(&snapshot, SummaryMode::Compact)
        );
        assert!(status.label.contains("26%"));
        assert!(!status.label.contains("popup="));
        assert!(status.summary.contains("popup="));
    }

    const DISCHARGING: &str = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=35127395) 26%; discharging; 6:26 remaining present: true";
    const CHARGING: &str = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=35127395) 73%; charging; 1:24 remaining present: true";

    #[test]
    fn parses_pmset_source_state_charge_and_estimate() {
        assert_eq!(
            parse_pmset_snapshot(DISCHARGING),
            Some(PowerSnapshot {
                source: PowerSource::Battery,
                battery: Some(BatterySnapshot {
                    percent: 26,
                    state: BatteryState::Discharging,
                    estimate_minutes: Some(386),
                }),
            })
        );
        assert_eq!(
            parse_pmset_snapshot(CHARGING),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: Some(BatterySnapshot {
                    percent: 73,
                    state: BatteryState::Charging,
                    estimate_minutes: Some(84),
                }),
            })
        );
    }

    #[test]
    fn missing_battery_outputs_are_valid_snapshots() {
        assert_eq!(
            parse_pmset_snapshot(
                "Now drawing from 'AC Power'\nNo batteries are currently installed."
            ),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: None,
            })
        );
        assert_eq!(
            parse_pmset_snapshot("Now drawing from 'AC Power'\n"),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: None,
            })
        );
        assert_eq!(
            parse_pmset_snapshot("Currently drawing from 'AC Power'\n"),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: None,
            })
        );
        assert_eq!(
            parse_pmset_snapshot("Now drawing from 'Battery Power'\n"),
            None
        );
        assert_eq!(parse_pmset_snapshot("pmset failed"), None);
    }

    #[test]
    fn parses_ioreg_health_without_exposing_serials() {
        let raw = r#"
          | |   "CycleCount" = 187
          | |   "DesignCapacity" = 6075
          | |   "AppleRawMaxCapacity" = 5528
          | |   "Temperature" = 3031
          | |   "BatteryHealthCondition" = "Good"
          | |   "SerialNumber" = "SECRET-BATTERY-SERIAL"
          | |   "AdapterDetails" = {"Watts"=67,"Name"="USB-C Power Adapter","SerialString"="SECRET-ADAPTER-SERIAL"}
        "#;
        let health = parse_ioreg_health(raw).unwrap();
        assert_eq!(health.cycle_count, Some(187));
        assert_eq!(health.design_capacity, Some(6075));
        assert_eq!(health.maximum_capacity, Some(5528));
        assert_eq!(health.temperature_centi_celsius, Some(3031));
        assert_eq!(health.adapter_watts, Some(67));
        assert_eq!(health.condition.as_deref(), Some("Good"));

        let snapshot = parse_pmset_snapshot(CHARGING).unwrap();
        let details = render_status(
            &snapshot,
            Some(&health),
            SummaryMode::Compact,
            &VecDeque::new(),
        )
        .details;
        assert!(!details.contains("SECRET"));
        assert!(!details.to_ascii_lowercase().contains("serial"));
    }

    #[test]
    fn renders_compact_balanced_summary_and_rich_details() {
        let snapshot = parse_pmset_snapshot(CHARGING).unwrap();
        let health = BatteryHealth {
            cycle_count: Some(187),
            design_capacity: Some(6075),
            maximum_capacity: Some(5528),
            temperature_centi_celsius: Some(3031),
            adapter_watts: Some(67),
            condition: Some("Good #[fg=colour196] #1".to_string()),
        };
        let status = render_status(
            &snapshot,
            Some(&health),
            SummaryMode::Compact,
            &VecDeque::new(),
        );

        assert_eq!(
            visible_summary(&snapshot, SummaryMode::Compact),
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]#[breathing]73%#[nobreathing]#[norange]#[default]#[pop-default]"
        );
        assert!(visible_summary(&snapshot, SummaryMode::Full).contains("73% · 1h 24m"));
        assert!(status.summary.contains("popup="));
        assert!(status.label.contains("73%"));
        assert_eq!(
            status.details,
            "#[fg=#EBCB8B]Battery#[default]\n\
#[fg=colour245]Charge        #[default] 73 %\n\
#[fg=colour245]State         #[default]Charging\n\
#[fg=colour245]Source        #[default]AC adapter\n\
#[fg=colour245]Estimate      #[default]Full in 1h 24m\n\
#[fg=colour245]Health        #[default] 91 %\n\
#[fg=colour245]Condition     #[default]Good ##[fg=colour196] ##1\n\
#[fg=colour245]Cycles        #[default]       187\n\
#[fg=colour245]Temperature   #[default] 30.3 °C\n\
#[fg=colour245]Adapter       #[default] 67 W\n\
#[fg=colour245]History       #[default]····················"
        );
        assert_eq!(REFRESH_INTERVAL, Duration::from_secs(1));
        assert_eq!(HEALTH_REFRESH_INTERVAL, Duration::from_secs(30));
        assert!(!status.details.ends_with('\n'));
        assert!(status
            .plain_details
            .contains("Health: 91% of design (Good #[fg=colour196] #1)"));
    }

    #[test]
    fn summary_keeps_percentage_except_when_full_on_ac_power() {
        for (source, percent, label_only) in [
            (PowerSource::Adapter, 0, false),
            (PowerSource::Adapter, 73, false),
            (PowerSource::Adapter, 99, false),
            (PowerSource::Adapter, 100, true),
            (PowerSource::Battery, 0, false),
            (PowerSource::Battery, 73, false),
            (PowerSource::Battery, 99, false),
            (PowerSource::Battery, 100, false),
            (PowerSource::Unknown, 73, false),
            (PowerSource::Unknown, 100, false),
        ] {
            for state in [
                BatteryState::Charging,
                BatteryState::Charged,
                BatteryState::Discharging,
                BatteryState::Unknown,
            ] {
                let snapshot = PowerSnapshot {
                    source,
                    battery: Some(BatterySnapshot {
                        percent,
                        state,
                        estimate_minutes: None,
                    }),
                };
                for mode in [SummaryMode::Compact, SummaryMode::Full] {
                    let status = render_status(&snapshot, None, mode, &VecDeque::new());
                    assert!(!status.label.is_empty(), "{snapshot:?} {mode:?}");
                    assert!(status.summary.contains("popup="), "{snapshot:?} {mode:?}");
                    assert!(!status.label.contains("popup="));
                    assert!(status.label.contains("range=user|bat-prefs"));
                    if label_only {
                        assert_eq!(
                            status.label,
                            "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]",
                            "{snapshot:?} {mode:?}"
                        );
                    } else {
                        assert!(
                            status.label.contains(&format!("{percent:>2}%")),
                            "{snapshot:?} {mode:?}"
                        );
                        if mode == SummaryMode::Full {
                            assert!(status.label.contains(source.label()));
                        }
                    }
                    assert!(status
                        .plain_details
                        .contains(&format!("Charge: {percent}%")));
                }
            }
        }
    }

    #[test]
    fn full_pmset_battery_keeps_bat_label_across_charging_states() {
        for state in ["charging", "finishing charge", "charged"] {
            let raw = format!(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 100%; {state}; 0:00 remaining present: true"
            );
            let snapshot = parse_pmset_snapshot(&raw).unwrap();
            assert_eq!(
                visible_summary(&snapshot, SummaryMode::Compact),
                "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]",
                "{state}"
            );
        }
    }

    #[test]
    fn low_battery_is_grey_and_does_not_breathe() {
        let snapshot = parse_pmset_snapshot(
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 25%; discharging; (no estimate) present: true",
        )
        .unwrap();
        assert_eq!(
            visible_summary(&snapshot, SummaryMode::Compact),
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]25%#[norange]#[default]#[pop-default]"
        );
        assert_eq!(
            render_status(&snapshot, None, SummaryMode::Compact, &VecDeque::new()).details,
            "#[fg=#EBCB8B]Battery#[default]\n\
#[fg=colour245]Charge        #[default] 25 %\n\
#[fg=colour245]State         #[default]Discharging\n\
#[fg=colour245]Source        #[default]Battery\n\
#[fg=colour245]Estimate      #[default]Unavailable\n\
#[fg=colour245]Health        #[default]    —\n\
#[fg=colour245]Condition     #[default]—\n\
#[fg=colour245]Cycles        #[default]         —\n\
#[fg=colour245]Temperature   #[default]    — °C\n\
#[fg=colour245]Adapter       #[default]  — W\n\
#[fg=colour245]History       #[default]····················"
        );
    }

    #[test]
    fn stale_health_survives_a_transient_ioreg_failure() {
        let previous = BatteryHealth {
            cycle_count: Some(8),
            ..BatteryHealth::default()
        };
        assert_eq!(merge_health(None, Some(previous.clone())), Some(previous));
    }

    #[test]
    fn formats_natural_duration() {
        assert_eq!(natural_duration(24), "24m");
        assert_eq!(natural_duration(60), "1h");
        assert_eq!(natural_duration(84), "1h 24m");
    }

    #[test]
    fn charge_history_is_bounded_and_left_padded_to_stable_width() {
        let mut history = VecDeque::new();
        for value in 0..25 {
            push_history(&mut history, f64::from(value) * 4.0);
        }
        assert_eq!(history.len(), HISTORY_LEN);
        assert_eq!(history.front(), Some(&20.0));
        assert_eq!(
            padded_history(&VecDeque::from([0.0, 100.0])),
            "··················▁█"
        );
    }

    #[test]
    fn battery_health_refresh_is_forced_or_periodically_due() {
        let now = Instant::now();
        assert!(health_refresh_due(None, false, now));
        assert!(!health_refresh_due(Some(now), false, now));
        assert!(health_refresh_due(
            Some(now - HEALTH_REFRESH_INTERVAL),
            false,
            now
        ));
        assert!(health_refresh_due(Some(now), true, now));
    }

    #[test]
    fn refresh_failures_log_once_until_success() {
        let mut logged = false;
        assert!(first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, true));
        assert!(!first_failure(&mut logged, false));
        assert!(first_failure(&mut logged, true));
    }
}

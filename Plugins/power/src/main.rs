use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use flash_plugin::{
    escape_status_text, inline_status_popup, run, run_command, CommandRequest, Context, Event,
    PerformResponse, RefreshGate,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static LAST_GOOD: LazyLock<Mutex<Option<StatusSegments>>> = LazyLock::new(|| Mutex::new(None));
static LAST_HEALTH: LazyLock<Mutex<Option<BatteryHealth>>> = LazyLock::new(|| Mutex::new(None));

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
    details: String,
    plain_details: String,
}

struct Power;

flash_plugin::plugin!(Power);

impl FlashPlugin for Power {
    async fn on_start(&self, ctx: Context) {
        let _ = refresh_and_publish(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name == "core:power.changed" {
            let _ = refresh_and_publish(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "" => details_response(last_good()),
            "refresh" => {
                let refreshed = try_refresh_and_publish(&ctx).await.flatten();
                details_response(refreshed.or_else(last_good))
            }
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

async fn refresh_and_publish(ctx: &Context) -> Option<StatusSegments> {
    REFRESH_GATE
        .run(ctx, |ctx, _applications| collect_and_publish(ctx))
        .await
}

async fn try_refresh_and_publish(ctx: &Context) -> Option<Option<StatusSegments>> {
    REFRESH_GATE
        .try_run(ctx, |ctx, _applications| collect_and_publish(ctx))
        .await
}

async fn collect_and_publish(ctx: Context) -> Option<StatusSegments> {
    let pmset_argv = vec![PMSET.to_string(), "-g".to_string(), "batt".to_string()];
    let ioreg_argv = vec![
        IOREG.to_string(),
        "-r".to_string(),
        "-c".to_string(),
        "AppleSmartBattery".to_string(),
        "-l".to_string(),
    ];
    let (pmset, ioreg) = tokio::join!(
        run_command(&ctx, &pmset_argv, COMMAND_TIMEOUT),
        run_command(&ctx, &ioreg_argv, COMMAND_TIMEOUT),
    );

    let Some(snapshot) = parse_pmset_snapshot(&pmset.stdout) else {
        ctx.log("warn", "[power] refresh failed");
        return None;
    };

    let health = if snapshot.battery.is_some() {
        let previous = LAST_HEALTH
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        merge_health(parse_ioreg_health(&ioreg.stdout), previous)
    } else {
        None
    };
    *LAST_HEALTH
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = health.clone();

    let status = render_status(&snapshot, health.as_ref());
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
            ("details", status.details.as_str()),
        ]);
    }
    Some(status)
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
    if raw.contains("No batteries are currently installed") {
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

fn render_status(snapshot: &PowerSnapshot, health: Option<&BatteryHealth>) -> StatusSegments {
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
    let details = escape_status_text(&plain_details);
    let visible = visible_summary(snapshot);
    StatusSegments {
        summary: inline_status_popup(&visible, &details),
        details,
        plain_details,
    }
}

fn visible_summary(snapshot: &PowerSnapshot) -> String {
    let (text, color, breathing) = match snapshot.battery {
        Some(ref battery) => (
            format!("BAT {}%", battery.percent),
            if snapshot.source == PowerSource::Adapter || battery.percent > 25 {
                "colour178"
            } else {
                "red"
            },
            snapshot.source == PowerSource::Adapter,
        ),
        None => ("BAT —".to_string(), "colour245", false),
    };
    let breathing_open = if breathing { "#[breathing]" } else { "" };
    let breathing_close = if breathing { "#[nobreathing]" } else { "" };
    format!(
        "#[push-default]#[range=user|bat-prefs fg={color}]{breathing_open}{text}{breathing_close}#[norange]#[default]#[pop-default]"
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
    fn explicit_missing_battery_is_a_valid_snapshot() {
        assert_eq!(
            parse_pmset_snapshot(
                "Now drawing from 'AC Power'\nNo batteries are currently installed."
            ),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: None,
            })
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
        let details = render_status(&snapshot, Some(&health)).details;
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
            condition: Some("Good #1".to_string()),
        };
        let status = render_status(&snapshot, Some(&health));

        assert_eq!(
            visible_summary(&snapshot),
            "#[push-default]#[range=user|bat-prefs fg=colour178]#[breathing]BAT 73%#[nobreathing]#[norange]#[default]#[pop-default]"
        );
        assert!(status.summary.starts_with("#[popup=inline:"));
        assert!(status.summary.ends_with("#[nopopup]"));
        assert!(status
            .summary
            .contains("]#[push-default]#[range=user|bat-prefs"));
        assert_eq!(
            status.details,
            "Charge: 73%\nState: Charging\nSource: AC adapter\nEstimate: Full in 1h 24m\nHealth: 91% of design (Good ##1)\nCycles: 187\nTemperature: 30.3°C\nAdapter: 67 W"
        );
        assert!(status
            .plain_details
            .contains("Health: 91% of design (Good #1)"));
    }

    #[test]
    fn low_battery_is_red_and_does_not_breathe() {
        let snapshot = parse_pmset_snapshot(
            "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 25%; discharging; (no estimate) present: true",
        )
        .unwrap();
        assert_eq!(
            visible_summary(&snapshot),
            "#[push-default]#[range=user|bat-prefs fg=red]BAT 25%#[norange]#[default]#[pop-default]"
        );
        assert_eq!(
            render_status(&snapshot, None).details,
            "Charge: 25%\nState: Discharging\nSource: Battery\nEstimate: Unavailable"
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
}

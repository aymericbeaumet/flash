use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::status::{duration_hours_minutes, percent3, sparkline_padded, sparkline_percent};
use flash_plugin::{
    run, run_command, Color, CommandRequest, Context, Event, History, Markup, PerformResponse,
    Preview, Published, RefreshGate, StatusValue, Style,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
/// Safety poll only: `core:power.changed` (an IOKit power-source notification
/// the host relays) drives every charge, source, and state change, so the
/// timer merely bounds how stale the display can get if an event is missed.
const REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const HEALTH_REFRESH_INTERVAL: Duration = Duration::from_secs(30);
const PMSET: &str = "/usr/bin/pmset";
const IOREG: &str = "/usr/sbin/ioreg";

type ChargeHistory = History<20>;

static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static LAST_GOOD: LazyLock<Mutex<Published<PowerStatus>>> = LazyLock::new(Mutex::default);
static LAST_HEALTH: LazyLock<Mutex<Option<BatteryHealth>>> = LazyLock::new(|| Mutex::new(None));
static LAST_HEALTH_ATTEMPT: LazyLock<Mutex<Option<Instant>>> = LazyLock::new(|| Mutex::new(None));
static REFRESH_FAILURE_LOGGED: LazyLock<Mutex<bool>> = LazyLock::new(|| Mutex::new(false));
static CHARGE_HISTORY: LazyLock<Mutex<ChargeHistory>> = LazyLock::new(Mutex::default);

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
struct PowerStatus {
    summary: Markup,
    label: Markup,
    preview: Preview,
}

impl PowerStatus {
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

async fn refresh_and_publish(ctx: &Context, force_health: bool) -> Option<PowerStatus> {
    REFRESH_GATE
        .run(ctx, move |ctx, _applications| {
            collect_and_publish(ctx, force_health)
        })
        .await
}

async fn try_refresh_and_publish(ctx: &Context, force_health: bool) -> Option<Option<PowerStatus>> {
    REFRESH_GATE
        .try_run(ctx, move |ctx, _applications| {
            collect_and_publish(ctx, force_health)
        })
        .await
}

async fn collect_and_publish(ctx: Context, force_health: bool) -> Option<PowerStatus> {
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
        match snapshot.battery.as_ref() {
            Some(battery) => history.push(f64::from(battery.percent)),
            None => history.clear(),
        }
        history.clone()
    };
    let status = render_status(
        &snapshot,
        health.as_ref(),
        configured_summary_mode(&ctx),
        &history,
    );
    {
        let mut last = LAST_GOOD
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(changed) = last.update(status.clone()) {
            ctx.status(changed.segments());
        }
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

fn details_response(status: Option<PowerStatus>) -> PerformResponse {
    status
        .map(|status| PerformResponse::ok().message(status.preview.render_plain()))
        .unwrap_or_else(|| PerformResponse::fail("power information unavailable"))
}

fn last_good() -> Option<PowerStatus> {
    LAST_GOOD
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .last()
        .cloned()
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
    history: &ChargeHistory,
) -> PowerStatus {
    // Charge is slow-moving, so it shows a true 100% rather than the 99 cap
    // the fast metrics use; `percent3` is fixed-width, so the label never
    // shifts its neighbours on the way there.
    let charge = snapshot.battery.as_ref().map_or_else(
        || "   —".to_string(),
        |battery| percent3(f64::from(battery.percent)),
    );
    PowerStatus {
        summary: visible_summary(snapshot, summary_mode),
        label: Markup::colored("BAT", Color::TITLE) + " " + Markup::colored(charge, Color::MUTED),
        preview: preview(snapshot, health, history),
    }
}

fn preview(
    snapshot: &PowerSnapshot,
    health: Option<&BatteryHealth>,
    history: &ChargeHistory,
) -> Preview {
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
    Preview::new()
        .title("Battery")
        .row(
            "Charge",
            battery.map_or_else(
                || "    —".to_string(),
                |battery| format!("{:>3} %", battery.percent),
            ),
        )
        .row(
            "State",
            battery.map_or("Not installed", |battery| battery.state.label()),
        )
        .row("Source", snapshot.source.label())
        .row(
            "Estimate",
            battery.map_or_else(|| "Unavailable".to_string(), estimate_label),
        )
        .row(
            "Health",
            health_percent.map_or_else(|| "    —".to_string(), |percent| format!("{percent:>3} %")),
        )
        .row(
            "Condition",
            health
                .and_then(|health| health.condition.as_deref())
                .map_or_else(|| Markup::from("—"), Markup::text),
        )
        .row(
            "Cycles",
            health.and_then(|health| health.cycle_count).map_or_else(
                || "         —".to_string(),
                |cycles| format!("{cycles:>10}"),
            ),
        )
        .row(
            "Temperature",
            health
                .and_then(|health| health.temperature_centi_celsius)
                .map_or_else(
                    || "    — °C".to_string(),
                    |temperature| format!("{:>5.1} °C", temperature as f64 / 100.0),
                ),
        )
        .row(
            "Adapter",
            health
                .and_then(|health| health.adapter_watts)
                .filter(|_| snapshot.source == PowerSource::Adapter)
                .map_or_else(|| "  — W".to_string(), |watts| format!("{watts:>3} W")),
        )
        .row(
            "History",
            sparkline_padded(&sparkline_percent(history), ChargeHistory::CAPACITY),
        )
}

fn visible_summary(snapshot: &PowerSnapshot, summary_mode: SummaryMode) -> Markup {
    if snapshot.source == PowerSource::Adapter
        && snapshot
            .battery
            .as_ref()
            .is_some_and(|battery| battery.percent == 100)
    {
        return Markup::colored(Markup::range("BAT", "bat-prefs"), Color::TITLE);
    }
    let (mut value, breathing) = match snapshot.battery {
        Some(ref battery) => (
            percent3(f64::from(battery.percent)),
            snapshot.source == PowerSource::Adapter,
        ),
        None => ("—".to_string(), false),
    };
    if summary_mode == SummaryMode::Full {
        let secondary = snapshot
            .battery
            .as_ref()
            .and_then(|battery| battery.estimate_minutes.map(duration_hours_minutes))
            .unwrap_or_else(|| snapshot.source.label().to_string());
        value.push_str(" · ");
        value.push_str(&secondary);
    }
    if breathing {
        value = format!("#[breathing]{value}#[nobreathing]");
    }
    Markup::colored("BAT", Color::TITLE)
        + " "
        + Markup::raw(format!(
            "#[push-default]#[range=user|bat-prefs {}]{value}#[norange]#[default]#[pop-default]",
            Style::fg(Color::MUTED)
        ))
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
            format!("Full in {}", duration_hours_minutes(minutes))
        }
        (BatteryState::Discharging, Some(minutes)) if minutes > 0 => {
            format!("{} remaining", duration_hours_minutes(minutes))
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
    fn label_keeps_charge_width_and_leaves_popup_interactions_to_the_template() {
        // Charge is slow-moving, so unlike the fast metrics it reaches a true
        // 100% — at a fixed four-column width, so the label never shifts.
        for (percent, expected) in [
            (None, "   —"),
            (Some(0), "  0%"),
            (Some(9), "  9%"),
            (Some(10), " 10%"),
            (Some(99), " 99%"),
            (Some(100), "100%"),
        ] {
            let snapshot = PowerSnapshot {
                source: PowerSource::Adapter,
                battery: percent.map(|percent| BatterySnapshot {
                    percent,
                    state: BatteryState::Charging,
                    estimate_minutes: Some(90),
                }),
            };
            let status = render_status(&snapshot, None, SummaryMode::Full, &ChargeHistory::new());
            assert_eq!(
                status.label.as_str(),
                format!("#[fg=#EBCB8B]BAT#[default] #[fg=colour245]{expected}#[default]")
            );
            assert!(!status.preview.is_empty());
        }
    }

    #[test]
    fn publishes_the_preview_inline_on_the_summary_only() {
        let mut harness = flash_plugin::testing::Harness::new("power");
        let snapshot = parse_pmset_snapshot(CHARGING).unwrap();
        let status = render_status(&snapshot, None, SummaryMode::Compact, &ChargeHistory::new());
        harness.context().status(status.segments());
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert!(frames[0]["summary"].starts_with("#[popup=inline:"));
        assert!(frames[0]["summary"].ends_with(&format!("]{}#[nopopup]", status.summary)));
        assert_eq!(frames[0]["label"], status.label.as_str());
        assert!(!frames[0]["label"].contains("popup="));
        assert_eq!(frames[0]["details"], status.preview.render().as_str());
    }

    #[test]
    fn summary_mode_contract_defaults_to_compact_and_rejects_unknown_values() {
        assert_eq!(parse_summary_mode(""), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("compact"), (SummaryMode::Compact, true));
        assert_eq!(parse_summary_mode("full"), (SummaryMode::Full, true));
        assert_eq!(parse_summary_mode("dense"), (SummaryMode::Compact, false));
    }

    #[test]
    fn compact_power_summary_uses_grey_three_column_percentage() {
        for (percent, expected) in [(9, "  9%"), (10, " 10%"), (99, " 99%"), (100, "100%")] {
            let snapshot = PowerSnapshot {
                source: PowerSource::Battery,
                battery: Some(BatterySnapshot {
                    percent,
                    state: BatteryState::Discharging,
                    estimate_minutes: None,
                }),
            };
            assert_eq!(
                visible_summary(&snapshot, SummaryMode::Compact).as_str(),
                format!(
                    "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]{expected}#[norange]#[default]#[pop-default]"
                )
            );
        }
        let no_battery = PowerSnapshot {
            source: PowerSource::Adapter,
            battery: None,
        };
        assert!(visible_summary(&no_battery, SummaryMode::Compact)
            .as_str()
            .contains(
                "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]—"
            ));
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
            &ChargeHistory::new(),
        )
        .preview
        .render();
        assert!(!details.as_str().contains("SECRET"));
        assert!(!details.as_str().to_ascii_lowercase().contains("serial"));
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
            &ChargeHistory::new(),
        );

        assert_eq!(
            visible_summary(&snapshot, SummaryMode::Compact).as_str(),
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]#[breathing] 73%#[nobreathing]#[norange]#[default]#[pop-default]"
        );
        assert!(visible_summary(&snapshot, SummaryMode::Full)
            .as_str()
            .contains("73% · 1h 24m"));
        assert!(status.label.as_str().contains("73%"));
        let details = status.preview.render();
        assert_eq!(
            details.as_str(),
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
        assert_eq!(REFRESH_INTERVAL, Duration::from_secs(60));
        assert_eq!(HEALTH_REFRESH_INTERVAL, Duration::from_secs(30));
        assert!(!details.as_str().ends_with('\n'));
        assert_eq!(
            status.preview.render_plain(),
            "Battery\n\
Charge         73 %\n\
State         Charging\n\
Source        AC adapter\n\
Estimate      Full in 1h 24m\n\
Health         91 %\n\
Condition     Good #[fg=colour196] #1\n\
Cycles               187\n\
Temperature    30.3 °C\n\
Adapter        67 W\n\
History       ····················"
        );
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
                    let status = render_status(&snapshot, None, mode, &ChargeHistory::new());
                    let visible = visible_summary(&snapshot, mode).into_string();
                    assert!(!status.label.is_empty(), "{snapshot:?} {mode:?}");
                    assert!(!status.preview.is_empty(), "{snapshot:?} {mode:?}");
                    assert!(!status.label.as_str().contains("popup="));
                    assert_eq!(status.summary.as_str(), visible, "{snapshot:?} {mode:?}");
                    assert!(visible.contains("range=user|bat-prefs"));
                    if label_only {
                        assert_eq!(
                            visible, "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]",
                            "{snapshot:?} {mode:?}"
                        );
                    } else {
                        assert!(
                            visible.contains(&format!("{percent:>3}%")),
                            "{snapshot:?} {mode:?}"
                        );
                        if mode == SummaryMode::Full {
                            assert!(visible.contains(source.label()));
                        }
                    }
                    assert!(status
                        .preview
                        .render_plain()
                        .contains(&format!("Charge        {percent:>3} %")));
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
                visible_summary(&snapshot, SummaryMode::Compact).as_str(),
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
            visible_summary(&snapshot, SummaryMode::Compact).as_str(),
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245] 25%#[norange]#[default]#[pop-default]"
        );
        assert_eq!(
            render_status(&snapshot, None, SummaryMode::Compact, &ChargeHistory::new())
                .preview
                .render()
                .as_str(),
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
    fn charge_history_fills_the_chart_from_the_right() {
        let mut history = ChargeHistory::new();
        history.push(0.0);
        history.push(100.0);
        let snapshot = parse_pmset_snapshot(DISCHARGING).unwrap();
        let details = render_status(&snapshot, None, SummaryMode::Compact, &history)
            .preview
            .render();
        assert!(details
            .as_str()
            .ends_with("#[fg=colour245]History       #[default]··················▁█"));
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

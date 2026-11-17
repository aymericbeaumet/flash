//! Power: the IOPowerSources snapshot `pmset -g batt` prints and the
//! `AppleSmartBattery` registry entry, read on `core:power.changed`.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::status::{duration_hours_minutes, percent, sparkline_padded, sparkline_percent};
use flash_plugin::{
    Color, Context, History, Markup, PerformResponse, Preview, Published, RefreshGate, StatusValue,
    Style, sys,
};

use crate::common::{
    HISTORY_SAMPLES, SummaryMode, configured_summary_mode, first_failure, lock, plain,
};

/// The published segments, in manifest order. Power follows
/// `core:power.changed`, so no cadence waits on `core:status.observed`.
pub(crate) const SEGMENTS: [&str; 5] = [
    "power_summary",
    "power_label",
    "power_details",
    "power_percent",
    "power_state",
];

/// Minimum age of the battery-registry health read before a power event
/// repeats it, so a burst of notifications copies the `AppleSmartBattery`
/// property table once. There is no poll: `core:power.changed` (the host's
/// IOKit power-source notification) drives every charge, source, and state
/// change.
const HEALTH_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

type ChargeHistory = History<HISTORY_SAMPLES>;

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
    /// Battery charge as a plain integer 0–100; empty (cleared) without a
    /// battery.
    percent: String,
    /// `charging`, `discharging`, `charged` or `ac`; empty when unknown.
    state: &'static str,
}

impl PowerStatus {
    fn segments(&self) -> [(&'static str, StatusValue); 5] {
        let [summary, label, details, percent, state] = SEGMENTS;
        [
            (
                summary,
                StatusValue::text(self.summary.clone()).with_preview(self.preview.clone()),
            ),
            (label, StatusValue::text(self.label.clone())),
            (details, StatusValue::text(self.preview.render())),
            (percent, plain(&self.percent)),
            (state, plain(self.state)),
        ]
    }
}

#[derive(Default)]
struct PowerState {
    published: Published<PowerStatus>,
    health: Option<BatteryHealth>,
    health_attempt: Option<Instant>,
    failure_logged: bool,
    history: ChargeHistory,
}

#[derive(Clone, Default)]
pub(crate) struct Power {
    state: Arc<Mutex<PowerState>>,
    gate: RefreshGate,
}

impl Power {
    /// The initial snapshot with a forced health read; nothing polls after.
    pub(crate) async fn start(&self, ctx: &Context) {
        let _ = self.refresh_and_publish(ctx, true).await;
    }

    /// `core:power.changed`: the charge and source at once, the health
    /// within its TTL.
    pub(crate) async fn power_changed(&self, ctx: &Context) {
        let _ = self.refresh_and_publish(ctx, false).await;
    }

    /// The details of the last good snapshot.
    pub(crate) fn show(&self) -> PerformResponse {
        details_response(self.last_good())
    }

    /// A forced health read that returns at once while a refresh is running.
    pub(crate) async fn refresh(&self, ctx: &Context) {
        let _ = self.try_refresh_and_publish(ctx, true).await;
    }

    /// The visible summary of the last good snapshot.
    pub(crate) fn summary(&self) -> Option<Markup> {
        self.last_good().map(|status| status.summary)
    }

    async fn refresh_and_publish(&self, ctx: &Context, force_health: bool) -> Option<PowerStatus> {
        let state = Arc::clone(&self.state);
        self.gate
            .run(ctx, move |ctx, _applications| {
                collect_and_publish(ctx, state, force_health)
            })
            .await
    }

    async fn try_refresh_and_publish(
        &self,
        ctx: &Context,
        force_health: bool,
    ) -> Option<Option<PowerStatus>> {
        let state = Arc::clone(&self.state);
        self.gate
            .try_run(ctx, move |ctx, _applications| {
                collect_and_publish(ctx, state, force_health)
            })
            .await
    }

    fn last_good(&self) -> Option<PowerStatus> {
        lock(&self.state).published.last().cloned()
    }
}

async fn collect_and_publish(
    ctx: Context,
    state: Arc<Mutex<PowerState>>,
    force_health: bool,
) -> Option<PowerStatus> {
    let health_due = health_refresh_due(lock(&state).health_attempt, force_health, Instant::now());
    // Both reads are in-process: IOPowerSources (what `pmset -g batt`
    // prints) answers from powerd, and the health details come from the
    // battery's IOKit registry entry (what `ioreg` prints).
    let sources = sys::power_sources();
    let battery = health_due.then(sys::smart_battery);
    if health_due {
        lock(&state).health_attempt = Some(Instant::now());
    }

    let Some(snapshot) = sources.ok().as_ref().and_then(power_snapshot) else {
        let should_log = first_failure(&mut lock(&state).failure_logged, true);
        if should_log {
            ctx.log("warn", "[sysinfo] power refresh failed");
        }
        return None;
    };
    first_failure(&mut lock(&state).failure_logged, false);

    let (health, history) = {
        let mut state = lock(&state);
        let health = if snapshot.battery.is_some() {
            let fresh = battery
                .and_then(Result::ok)
                .flatten()
                .as_ref()
                .and_then(battery_health);
            merge_health(fresh, state.health.take())
        } else {
            None
        };
        state.health = health.clone();
        match snapshot.battery.as_ref() {
            Some(battery) => state.history.push(f64::from(battery.percent)),
            None => state.history.clear(),
        }
        (health, state.history.clone())
    };
    let status = render_status(
        &snapshot,
        health.as_ref(),
        configured_summary_mode(&ctx),
        &history,
    );
    let changed = lock(&state)
        .published
        .update(status.clone())
        .map(PowerStatus::segments);
    if let Some(segments) = changed {
        ctx.status(segments);
    }
    Some(status)
}

fn health_refresh_due(last_attempt: Option<Instant>, force: bool, now: Instant) -> bool {
    force
        || last_attempt.is_none_or(|last_attempt| {
            now.saturating_duration_since(last_attempt) >= HEALTH_REFRESH_INTERVAL
        })
}

fn details_response(status: Option<PowerStatus>) -> PerformResponse {
    status
        .map(|status| PerformResponse::ok().message(status.preview.render_plain()))
        .unwrap_or_else(|| PerformResponse::fail("power information unavailable"))
}

/// What `pmset -g batt` reports, from the same IOPowerSources snapshot: the
/// providing source, then the first listed source with a charge level, read
/// the way `pmset` prints it. Without any listed source a Mac on AC power has
/// no battery; no providing source, or sources without a charge level, is a
/// failed read.
fn power_snapshot(sources: &sys::PowerSources) -> Option<PowerSnapshot> {
    let source = match sources.providing.as_deref()? {
        "AC Power" => PowerSource::Adapter,
        "Battery Power" => PowerSource::Battery,
        _ => PowerSource::Unknown,
    };
    let Some((battery, current, maximum)) = sources.sources.iter().find_map(|battery| {
        let maximum = battery.max_capacity.filter(|maximum| *maximum != 0)?;
        Some((battery, battery.current_capacity?, maximum))
    }) else {
        return (sources.sources.is_empty() && source == PowerSource::Adapter).then_some(
            PowerSnapshot {
                source,
                battery: None,
            },
        );
    };
    let percent = u8::try_from(current.checked_mul(100)? / maximum)
        .ok()
        .filter(|percent| *percent <= 100)?;
    let on_adapter = battery.state.as_deref() == Some("AC Power");
    // `pmset`'s precedence; a battery held on the adapter ("AC attached; not
    // charging") prints no estimate.
    let (state, estimated) = match battery.is_charging {
        None => (BatteryState::Unknown, true),
        Some(_) if battery.is_finishing_charge == Some(true) => (BatteryState::Charging, true),
        Some(_) if battery.is_charged == Some(true) => (BatteryState::Charged, true),
        Some(true) => (BatteryState::Charging, true),
        Some(false) if on_adapter => (BatteryState::Unknown, false),
        Some(false) => (BatteryState::Discharging, true),
    };
    let remaining = if battery.state.as_deref() == Some("Battery Power") {
        battery.time_to_empty
    } else {
        battery.time_to_full_charge
    };
    // -1 is macOS still estimating.
    let estimate_minutes = remaining
        .filter(|_| estimated)
        .and_then(|minutes| u32::try_from(minutes).ok());
    Some(PowerSnapshot {
        source,
        battery: Some(BatterySnapshot {
            percent,
            state,
            estimate_minutes,
        }),
    })
}

/// The popup's health rows from the battery's registry entry; `None` when it
/// publishes none of them. Capacities are mAh (`AppleRawMaxCapacity`, else
/// `NominalChargeCapacity`), never the percent-scaled `MaxCapacity`.
fn battery_health(battery: &sys::SmartBattery) -> Option<BatteryHealth> {
    let count = |value: Option<i64>| value.and_then(|value| u64::try_from(value).ok());
    let health = BatteryHealth {
        cycle_count: count(battery.cycle_count),
        design_capacity: count(battery.design_capacity),
        maximum_capacity: count(battery.raw_max_capacity)
            .or_else(|| count(battery.nominal_charge_capacity)),
        temperature_centi_celsius: count(battery.temperature)
            .filter(|temperature| *temperature <= 10_000),
        adapter_watts: count(battery.adapter_watts),
        condition: battery
            .health_condition
            .as_deref()
            .map(str::trim)
            .filter(|value| {
                !value.is_empty() && value.len() <= 64 && !value.chars().any(char::is_control)
            })
            .map(str::to_string),
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
    // Charge is slow-moving, so it reads true and plain: no 99 cap like the
    // fast metrics, and no padding either — it crosses a width boundary so
    // rarely that a reserved column would cost more than the shift saves.
    let charge = snapshot.battery.as_ref().map_or_else(
        || "—".to_string(),
        |battery| percent(f64::from(battery.percent)),
    );
    PowerStatus {
        summary: visible_summary(snapshot, summary_mode),
        // The template owns the name (`#[label]BAT`). Charge is unpadded: it
        // crosses a width boundary too rarely to reserve a column.
        label: Markup::text(charge.trim()),
        preview: preview(snapshot, health, history),
        percent: snapshot
            .battery
            .as_ref()
            .map(|battery| battery.percent.to_string())
            .unwrap_or_default(),
        state: raw_state(snapshot),
    }
}

/// The battery's own state wins; otherwise the source decides. `ac` covers an
/// adapter with no battery (a desktop) or a battery held without charging.
fn raw_state(snapshot: &PowerSnapshot) -> &'static str {
    match (
        snapshot.battery.as_ref().map(|battery| battery.state),
        snapshot.source,
    ) {
        (Some(BatteryState::Charging), _) => "charging",
        (Some(BatteryState::Charged), _) => "charged",
        (Some(BatteryState::Discharging), _)
        | (Some(BatteryState::Unknown), PowerSource::Battery) => "discharging",
        (_, PowerSource::Adapter) => "ac",
        _ => "",
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
            "Design",
            health
                .and_then(|health| health.design_capacity)
                .map_or_else(|| "—".to_string(), |capacity| format!("{capacity} mAh")),
        )
        .row(
            "Full charge",
            health
                .and_then(|health| health.maximum_capacity)
                .map_or_else(|| "—".to_string(), |capacity| format!("{capacity} mAh")),
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
            percent(f64::from(battery.percent)),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_carry_the_domain_prefix_in_manifest_order() {
        let status = render_status(
            &snapshot(&charging()),
            None,
            SummaryMode::Compact,
            &ChargeHistory::new(),
        );
        assert_eq!(status.segments().map(|(name, _)| name), SEGMENTS);
        assert!(SEGMENTS.iter().all(|name| name.starts_with("power_")));
    }

    #[test]
    fn label_keeps_charge_width_and_leaves_popup_interactions_to_the_template() {
        // Charge is slow-moving, so unlike the fast metrics it reads true and
        // unpadded: a plain 16% or 100%, not a reserved column.
        for (percent, expected) in [
            (None, "—"),
            (Some(0), "0%"),
            (Some(9), "9%"),
            (Some(16), "16%"),
            (Some(99), "99%"),
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
            assert_eq!(status.label.as_str(), expected);
            assert!(!status.label.as_str().contains("#["));
            assert!(!status.preview.is_empty());
        }
    }

    /// `core:power.changed` (the host's IOKit power-source notification) is
    /// the only refresh trigger after startup: nothing registers a cadence.
    #[tokio::test]
    async fn startup_registers_no_cadence() {
        let mut harness = flash_plugin::testing::Harness::new("sysinfo");
        Power::default().start(&harness.context()).await;
        let polls: Vec<_> = harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "poll")
            .collect();
        assert!(polls.is_empty(), "{polls:?}");
    }

    #[test]
    fn publishes_the_preview_inline_on_the_summary_only() {
        let mut harness = flash_plugin::testing::Harness::new("sysinfo");
        let status = render_status(
            &snapshot(&charging()),
            None,
            SummaryMode::Compact,
            &ChargeHistory::new(),
        );
        harness.context().status(status.segments());
        let frames = harness.drain_status();
        assert_eq!(frames.len(), 1);
        assert!(frames[0]["power_summary"].starts_with("#[popup=inline:"));
        assert!(frames[0]["power_summary"].ends_with(&format!("]{}#[nopopup]", status.summary)));
        assert_eq!(frames[0]["power_label"], status.label.as_str());
        assert!(!frames[0]["power_label"].contains("popup="));
        assert_eq!(frames[0]["power_details"], status.preview.render().as_str());
        assert_eq!(frames[0]["power_percent"], "73");
        assert_eq!(frames[0]["power_state"], "charging");
    }

    #[test]
    fn compact_power_summary_uses_a_grey_unpadded_percentage() {
        for (percent, expected) in [(9, "9%"), (16, "16%"), (99, "99%"), (100, "100%")] {
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

    /// An internal battery as IOPowerSources describes it: `percent` out of
    /// 100, neither charging nor charged until a test says otherwise.
    fn internal(state: &str, percent: i64) -> sys::PowerSource {
        sys::PowerSource {
            state: Some(state.to_string()),
            current_capacity: Some(percent),
            max_capacity: Some(100),
            is_charging: Some(false),
            is_charged: Some(false),
            ..sys::PowerSource::default()
        }
    }

    fn drawing_from(providing: &str, sources: Vec<sys::PowerSource>) -> sys::PowerSources {
        sys::PowerSources {
            providing: Some(providing.to_string()),
            sources,
        }
    }

    /// `pmset -g batt`: "26%; discharging; 6:26 remaining".
    fn discharging() -> sys::PowerSources {
        drawing_from(
            "Battery Power",
            vec![sys::PowerSource {
                time_to_empty: Some(386),
                time_to_full_charge: Some(-1),
                ..internal("Battery Power", 26)
            }],
        )
    }

    /// `pmset -g batt`: "73%; charging; 1:24 remaining".
    fn charging() -> sys::PowerSources {
        drawing_from(
            "AC Power",
            vec![sys::PowerSource {
                is_charging: Some(true),
                time_to_empty: Some(0),
                time_to_full_charge: Some(84),
                ..internal("AC Power", 73)
            }],
        )
    }

    fn snapshot(sources: &sys::PowerSources) -> PowerSnapshot {
        power_snapshot(sources).expect("power snapshot")
    }

    #[test]
    fn reads_source_state_charge_and_estimate_as_pmset_prints_them() {
        assert_eq!(
            power_snapshot(&discharging()),
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
            power_snapshot(&charging()),
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
    fn charge_state_follows_pmset_precedence() {
        let battery = |source: sys::PowerSource| {
            snapshot(&drawing_from("AC Power", vec![source]))
                .battery
                .expect("battery")
        };
        let on_adapter = || sys::PowerSource {
            time_to_full_charge: Some(12),
            ..internal("AC Power", 97)
        };
        // "finishing charge" wins over charged and charging.
        let finishing = battery(sys::PowerSource {
            is_finishing_charge: Some(true),
            is_charged: Some(true),
            ..on_adapter()
        });
        assert_eq!(
            (finishing.state, finishing.estimate_minutes),
            (BatteryState::Charging, Some(12))
        );
        let charged = battery(sys::PowerSource {
            is_charged: Some(true),
            is_charging: Some(true),
            ..on_adapter()
        });
        assert_eq!(charged.state, BatteryState::Charged);
        // "AC attached; not charging" prints no estimate.
        let held = battery(on_adapter());
        assert_eq!(
            (held.state, held.estimate_minutes),
            (BatteryState::Unknown, None)
        );
        // Without `Is Charging`, pmset prints no state but keeps the estimate.
        let unknown = battery(sys::PowerSource {
            is_charging: None,
            ..on_adapter()
        });
        assert_eq!(
            (unknown.state, unknown.estimate_minutes),
            (BatteryState::Unknown, Some(12))
        );
        // A battery that is not on the adapter discharges, estimating from
        // its time to empty; -1 is macOS still estimating.
        let draining = |time_to_empty| {
            snapshot(&drawing_from(
                "Battery Power",
                vec![sys::PowerSource {
                    time_to_empty: Some(time_to_empty),
                    time_to_full_charge: Some(30),
                    ..internal("Battery Power", 40)
                }],
            ))
            .battery
            .expect("battery")
        };
        assert_eq!(draining(95).estimate_minutes, Some(95));
        assert_eq!(draining(0).estimate_minutes, Some(0));
        assert_eq!(draining(-1).estimate_minutes, None);
        assert_eq!(draining(-1).state, BatteryState::Discharging);
    }

    #[test]
    fn percent_is_pmsets_truncated_integer_and_rejects_impossible_charge() {
        let percent = |current, maximum| {
            power_snapshot(&drawing_from(
                "Battery Power",
                vec![sys::PowerSource {
                    current_capacity: Some(current),
                    max_capacity: Some(maximum),
                    ..internal("Battery Power", 0)
                }],
            ))
            .map(|snapshot| snapshot.battery.expect("battery").percent)
        };
        assert_eq!(percent(79, 80), Some(98));
        assert_eq!(percent(80, 80), Some(100));
        assert_eq!(percent(0, 100), Some(0));
        assert_eq!(percent(105, 100), None);
        assert_eq!(percent(-5, 100), None);
    }

    #[test]
    fn the_first_source_with_a_charge_level_is_the_battery() {
        let ups = sys::PowerSource {
            current_capacity: None,
            ..internal("AC Power", 0)
        };
        let zero_maximum = sys::PowerSource {
            max_capacity: Some(0),
            ..internal("AC Power", 50)
        };
        let sources = drawing_from(
            "AC Power",
            vec![ups.clone(), zero_maximum, internal("AC Power", 64)],
        );
        assert_eq!(snapshot(&sources).battery.expect("battery").percent, 64);
        // Listed sources without any charge level are a failed read, as
        // pmset's output then carries no percentage.
        assert_eq!(power_snapshot(&drawing_from("AC Power", vec![ups])), None);
    }

    #[test]
    fn missing_battery_outputs_are_valid_snapshots() {
        assert_eq!(
            power_snapshot(&drawing_from("AC Power", Vec::new())),
            Some(PowerSnapshot {
                source: PowerSource::Adapter,
                battery: None,
            })
        );
        assert_eq!(
            power_snapshot(&drawing_from("Battery Power", Vec::new())),
            None
        );
        assert_eq!(power_snapshot(&drawing_from("UPS Power", Vec::new())), None);
        assert_eq!(power_snapshot(&sys::PowerSources::default()), None);
        assert_eq!(
            snapshot(&drawing_from("UPS Power", vec![internal("AC Power", 50)])).source,
            PowerSource::Unknown
        );
    }

    #[test]
    fn health_reads_registry_capacities_in_milliamp_hours() {
        let health = battery_health(&sys::SmartBattery {
            cycle_count: Some(187),
            design_capacity: Some(6075),
            raw_max_capacity: Some(5528),
            nominal_charge_capacity: Some(5600),
            temperature: Some(3031),
            adapter_watts: Some(67),
            health_condition: Some(" Check Battery ".to_string()),
        })
        .unwrap();
        assert_eq!(health.cycle_count, Some(187));
        assert_eq!(health.design_capacity, Some(6075));
        assert_eq!(health.maximum_capacity, Some(5528));
        assert_eq!(health.temperature_centi_celsius, Some(3031));
        assert_eq!(health.adapter_watts, Some(67));
        assert_eq!(health.condition.as_deref(), Some("Check Battery"));

        let nominal = battery_health(&sys::SmartBattery {
            nominal_charge_capacity: Some(5600),
            ..sys::SmartBattery::default()
        })
        .unwrap();
        assert_eq!(nominal.maximum_capacity, Some(5600));
    }

    #[test]
    fn health_drops_implausible_or_unprintable_values() {
        let health = battery_health(&sys::SmartBattery {
            cycle_count: Some(-1),
            temperature: Some(10_001),
            health_condition: Some("bad\nvalue".to_string()),
            design_capacity: Some(4000),
            ..sys::SmartBattery::default()
        })
        .unwrap();
        assert_eq!(
            health,
            BatteryHealth {
                design_capacity: Some(4000),
                ..BatteryHealth::default()
            }
        );
        for condition in ["", "   ", "x".repeat(65).as_str()] {
            let only_condition = sys::SmartBattery {
                health_condition: Some(condition.to_string()),
                ..sys::SmartBattery::default()
            };
            assert_eq!(battery_health(&only_condition), None, "{condition:?}");
        }
        assert_eq!(battery_health(&sys::SmartBattery::default()), None);
    }

    /// IOPowerSources asks powerd: without this mach service the sandbox
    /// leaves the source list silently empty, which would read as "no
    /// battery" on a laptop.
    #[test]
    fn manifest_allows_powerds_power_source_service() {
        let manifest = include_str!("../manifest.json");
        assert!(manifest.contains("\"com.apple.PowerManagement.control\""));
        assert!(!manifest.contains("/usr/bin/pmset") && !manifest.contains("/usr/sbin/ioreg"));
    }

    #[test]
    fn renders_compact_balanced_summary_and_rich_details() {
        let snapshot = snapshot(&charging());
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
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]#[breathing]73%#[nobreathing]#[norange]#[default]#[pop-default]"
        );
        assert!(
            visible_summary(&snapshot, SummaryMode::Full)
                .as_str()
                .contains("73% · 1h 24m")
        );
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
#[fg=colour245]Design        #[default]6075 mAh\n\
#[fg=colour245]Full charge   #[default]5528 mAh\n\
#[fg=colour245]Condition     #[default]Good ##[fg=colour196] ##1\n\
#[fg=colour245]Cycles        #[default]       187\n\
#[fg=colour245]Temperature   #[default] 30.3 °C\n\
#[fg=colour245]Adapter       #[default] 67 W\n\
#[fg=colour245]History       #[default]····················"
        );
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
Design        6075 mAh\n\
Full charge   5528 mAh\n\
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
                            visible.contains(&format!("{percent}%")),
                            "{snapshot:?} {mode:?}"
                        );
                        if mode == SummaryMode::Full {
                            assert!(visible.contains(source.label()));
                        }
                    }
                    assert!(
                        status
                            .preview
                            .render_plain()
                            .contains(&format!("Charge        {percent:>3} %"))
                    );
                }
            }
        }
    }

    #[test]
    fn full_battery_keeps_bat_label_across_charging_states() {
        let full = || sys::PowerSource {
            time_to_full_charge: Some(0),
            ..internal("AC Power", 100)
        };
        let charging = sys::PowerSource {
            is_charging: Some(true),
            ..full()
        };
        let finishing = sys::PowerSource {
            is_charging: Some(true),
            is_finishing_charge: Some(true),
            ..full()
        };
        let charged = sys::PowerSource {
            is_charged: Some(true),
            ..full()
        };
        for source in [charging, finishing, charged] {
            let snapshot = snapshot(&drawing_from("AC Power", vec![source.clone()]));
            assert_eq!(
                visible_summary(&snapshot, SummaryMode::Compact).as_str(),
                "#[fg=#EBCB8B]#[range=user|bat-prefs]BAT#[norange]#[default]",
                "{source:?}"
            );
        }
    }

    #[test]
    fn low_battery_is_grey_and_does_not_breathe() {
        let snapshot = snapshot(&drawing_from(
            "Battery Power",
            vec![sys::PowerSource {
                time_to_empty: Some(-1),
                ..internal("Battery Power", 25)
            }],
        ));
        assert_eq!(
            visible_summary(&snapshot, SummaryMode::Compact).as_str(),
            "#[fg=#EBCB8B]BAT#[default] #[push-default]#[range=user|bat-prefs fg=colour245]25%#[norange]#[default]#[pop-default]"
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
#[fg=colour245]Design        #[default]—\n\
#[fg=colour245]Full charge   #[default]—\n\
#[fg=colour245]Condition     #[default]—\n\
#[fg=colour245]Cycles        #[default]         —\n\
#[fg=colour245]Temperature   #[default]    — °C\n\
#[fg=colour245]Adapter       #[default]  — W\n\
#[fg=colour245]History       #[default]····················"
        );
    }

    #[test]
    fn stale_health_survives_a_transient_registry_failure() {
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
        let snapshot = snapshot(&discharging());
        let details = render_status(&snapshot, None, SummaryMode::Compact, &history)
            .preview
            .render();
        assert!(
            details
                .as_str()
                .ends_with("#[fg=colour245]History       #[default]··················▁█")
        );
    }

    #[test]
    fn details_show_original_and_current_battery_capacity() {
        let snapshot = snapshot(&discharging());
        let health = BatteryHealth {
            design_capacity: Some(5_000),
            maximum_capacity: Some(4_000),
            ..BatteryHealth::default()
        };
        let details = preview(&snapshot, Some(&health), &ChargeHistory::new()).render_plain();
        assert!(details.contains("Design        5000 mAh"), "{details}");
        assert!(details.contains("Full charge   4000 mAh"), "{details}");
        assert!(details.lines().all(|line| line.chars().count() <= 50));
    }

    #[test]
    fn battery_percentage_capacity_is_never_interpreted_as_milliamphours() {
        // `MaxCapacity` (percent-scaled) is not a registry field the health
        // reads: only the mAh `AppleRawMaxCapacity` / `NominalChargeCapacity`.
        let health = battery_health(&sys::SmartBattery {
            design_capacity: Some(5000),
            ..sys::SmartBattery::default()
        })
        .unwrap();
        assert_eq!(health.maximum_capacity, None);
        let snapshot = snapshot(&discharging());
        let details = preview(&snapshot, Some(&health), &ChargeHistory::new()).render_plain();
        assert!(!details.contains("100 mAh"));
        assert!(details.contains("Health            —"), "{details}");
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

    fn raw(sources: &sys::PowerSources) -> (String, &'static str) {
        let status = render_status(
            &snapshot(sources),
            None,
            SummaryMode::Compact,
            &ChargeHistory::new(),
        );
        (status.percent, status.state)
    }

    #[test]
    fn raw_segments_publish_plain_charge_and_state() {
        assert_eq!(raw(&charging()), ("73".to_string(), "charging"));
        assert_eq!(raw(&discharging()), ("26".to_string(), "discharging"));
        assert_eq!(
            raw(&drawing_from(
                "AC Power",
                vec![sys::PowerSource {
                    is_charged: Some(true),
                    time_to_full_charge: Some(0),
                    ..internal("AC Power", 100)
                }],
            )),
            ("100".to_string(), "charged")
        );
        assert_eq!(
            raw(&drawing_from("AC Power", vec![internal("AC Power", 80)])),
            ("80".to_string(), "ac"),
            "a battery held on the adapter is neither charging nor discharging"
        );
        assert_eq!(
            raw(&drawing_from(
                "Battery Power",
                vec![sys::PowerSource {
                    is_charging: None,
                    time_to_empty: Some(-1),
                    ..internal("Battery Power", 0)
                }],
            )),
            ("0".to_string(), "discharging")
        );
    }

    #[test]
    fn desktop_without_a_battery_clears_percent_and_reports_ac() {
        let mut harness = flash_plugin::testing::Harness::new("sysinfo");
        let snapshot = snapshot(&drawing_from("AC Power", Vec::new()));
        let status = render_status(&snapshot, None, SummaryMode::Compact, &ChargeHistory::new());
        harness.context().status(status.segments());
        let frames = harness.drain_status();
        assert_eq!(
            frames[0]["power_percent"], "",
            "no battery clears the segment"
        );
        assert_eq!(frames[0]["power_state"], "ac");

        let unknown = PowerSnapshot {
            source: PowerSource::Unknown,
            battery: None,
        };
        let status = render_status(&unknown, None, SummaryMode::Compact, &ChargeHistory::new());
        assert_eq!((status.percent.as_str(), status.state), ("", ""));
    }
}

use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

const CGSESSION: &str =
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession";

const DARK_TOGGLE: &str =
    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode";

struct System;

flash_plugin::plugin!(System);

impl FlashPlugin for System {
    async fn on_start(&self, ctx: Context) {
        publish_battery_status(&ctx).await;
        ctx.interval("battery", Duration::from_secs(30), |ctx| async move {
            publish_battery_status(&ctx).await;
        });
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "lock" => sh(&ctx, &[CGSESSION, "-suspend"], 10).await,
            "sleep" => sh(&ctx, &["/usr/bin/pmset", "sleepnow"], 10).await,
            "displaysleep" => sh(&ctx, &["/usr/bin/pmset", "displaysleepnow"], 10).await,
            "trash" => ctx
                .run_osascript(
                    "tell application \"Finder\" to empty trash",
                    Duration::from_secs(30),
                )
                .await
                .into_command(),
            "dark" => ctx
                .run_osascript(DARK_TOGGLE, Duration::from_secs(10))
                .await
                .into_command(),
            "screensaver" => sh(&ctx, &["/usr/bin/open", "-a", "ScreenSaverEngine"], 10).await,
            // Spawn caffeinate detached so the command returns immediately and
            // the assertion outlives this short-lived invocation.
            "caffeinate" => {
                sh(
                    &ctx,
                    &["/bin/sh", "-c", "nohup caffeinate -d >/dev/null 2>&1 &"],
                    10,
                )
                .await
            }
            "decaffeinate" => sh(&ctx, &["/usr/bin/killall", "caffeinate"], 10).await,
            other => CommandResponse::error(format!("unknown subcommand: {other}")),
        }
    }
}

async fn publish_battery_status(ctx: &Context) {
    let argv = [
        "/usr/bin/pmset".to_string(),
        "-g".to_string(),
        "batt".to_string(),
    ];
    // Bumped from 2s → 5s: under thermal pressure or right after wake
    // pmset has been observed to take up to ~3s, which used to trip the
    // 2s ceiling and surface "??" until the next 30s poll.
    let result = ctx.run_cli(&argv, Duration::from_secs(5)).await;
    // Parse stdout regardless of exit status. pmset writes the full
    // battery line before any error so a non-zero exit (or even a
    // timeout-induced SIGTERM) can still carry useful data; only fall
    // back to "??" when there's genuinely no percent to display.
    let segment = battery_segment(&result.stdout);
    ctx.emit_status_segments([("battery", segment)]);
}

/// Reasoning for status markers below:
/// - `range=user|bat-prefs` is the click range tmux uses for our battery
///   chip (Energy preferences pane on click).
/// - `#[breathing]` rides a subtle opacity sinusoid whenever the battery
///   is on AC power — "plugged" as the user puts it, regardless of
///   whether the cell is actively gaining charge or already topped up.
///   The Flash renderer enforces the "very subtle" curve (88 → 100 %
///   alpha, 6 s cycle); from the plugin's point of view we just have
///   to drop the marker pair around the percent text. Older Flash
///   builds that don't know the marker strip it and fall back to the
///   plain colour, so the segment stays forward-compatible.
fn battery_segment(pmset_output: &str) -> String {
    let Some(percent) = battery_percent(pmset_output) else {
        return missing_battery_segment();
    };
    let state = battery_state(pmset_output);
    let color = if state.on_ac() || percent > 25 {
        "colour178"
    } else {
        "red"
    };
    let (breathing_open, breathing_close) = if state.on_ac() {
        ("#[breathing]", "#[nobreathing]")
    } else {
        ("", "")
    };
    format!(
        "#[range=user|bat-prefs fg={color}]{breathing_open}{percent}%{breathing_close}#[norange]"
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BatteryState {
    Charging,
    Charged,
    Discharging,
    Unknown,
}

impl BatteryState {
    fn on_ac(self) -> bool {
        matches!(self, BatteryState::Charging | BatteryState::Charged)
    }
}

fn battery_state(pmset_output: &str) -> BatteryState {
    // Look at the per-battery status line, not just the header — `Now
    // drawing from 'AC Power'` only tells us the source, not whether
    // the battery is actively replenishing. We keep the three-state
    // distinction so future styling decisions (e.g. a slightly slower
    // breathe when the cell is `charged` vs `charging`) stay possible
    // without re-parsing pmset.
    if pmset_output.contains("; charging") || pmset_output.contains("; finishing charge") {
        BatteryState::Charging
    } else if pmset_output.contains("; charged") {
        BatteryState::Charged
    } else if pmset_output.contains("; discharging") {
        BatteryState::Discharging
    } else if pmset_output.contains("AC Power") {
        BatteryState::Charged
    } else {
        BatteryState::Unknown
    }
}

fn battery_percent(pmset_output: &str) -> Option<u8> {
    // pmset reports the cell percentage as `NN%` followed by a `;`.
    // Anchor on the `%` and look at the up-to-three preceding digits
    // so we don't accidentally lock on to the `id=<digits>` token or
    // the time-to-full minutes column. `u8` caps at 255 which is well
    // outside any plausible battery percent.
    let percent_idx = pmset_output.find('%')?;
    let prefix = &pmset_output[..percent_idx];
    let digits: String = prefix
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    digits.parse::<u8>().ok()
}

fn missing_battery_segment() -> String {
    "#[range=user|bat-prefs fg=red]??#[norange]".to_string()
}

async fn sh(ctx: &Context, argv: &[&str], timeout: u64) -> CommandResponse {
    let owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    ctx.run_cli(&owned, Duration::from_secs(timeout))
        .await
        .into_command()
}

fn main() {
    run(System);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_charged_battery_yellow_with_breathing() {
        // On AC: the cell is "plugged" so we wrap the percent in the
        // breathing markers regardless of whether it's actively gaining
        // charge (`charging`) or already topped up (`charged`).
        assert_eq!(
            battery_segment(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 82%; charged;"
            ),
            "#[range=user|bat-prefs fg=colour178]#[breathing]82%#[nobreathing]#[norange]"
        );
    }

    #[test]
    fn formats_healthy_discharging_battery_yellow_without_breathing() {
        // On battery power: no breathing — the chip stays still so the
        // user can tell at a glance whether the laptop is plugged in.
        assert_eq!(
            battery_segment(
                "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 26%; discharging;"
            ),
            "#[range=user|bat-prefs fg=colour178]26%#[norange]"
        );
    }

    #[test]
    fn formats_low_battery_red() {
        assert_eq!(
            battery_segment(
                "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 25%; discharging;"
            ),
            "#[range=user|bat-prefs fg=red]25%#[norange]"
        );
    }

    #[test]
    fn formats_missing_battery_red_unknown() {
        assert_eq!(
            battery_segment("No batteries are currently installed."),
            "#[range=user|bat-prefs fg=red]??#[norange]"
        );
    }

    #[test]
    fn formats_charging_battery_with_breathing_marker() {
        assert_eq!(
            battery_segment(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=35127395) 73%; charging; 1:24 remaining present: true"
            ),
            "#[range=user|bat-prefs fg=colour178]#[breathing]73%#[nobreathing]#[norange]"
        );
    }

    #[test]
    fn formats_finishing_charge_with_breathing_marker() {
        // pmset's `finishing charge` variant — on AC, last few % to top
        // up. Same "plugged in" semantics as `charging`, same breathing.
        assert_eq!(
            battery_segment(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 99%; finishing charge; 0:01 remaining present: true"
            ),
            "#[range=user|bat-prefs fg=colour178]#[breathing]99%#[nobreathing]#[norange]"
        );
    }

    #[test]
    fn parses_percent_when_id_has_many_digits() {
        // The old token-scan picked the first `<digits>%` token regardless
        // of context. The new anchor-on-% scan must still resolve to the
        // battery percent even when `id=` is a long number that would
        // otherwise dominate a left-to-right token walk.
        assert_eq!(
            battery_percent(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=35127395)\t100%; charged; 0:00 remaining present: true"
            ),
            Some(100)
        );
    }

    #[test]
    fn parses_percent_when_pmset_output_has_trailing_garbage() {
        // pmset writes the battery line before any error; a SIGTERM
        // mid-flush should still surface the percent rather than the
        // "??" fallback.
        assert_eq!(battery_percent(" 42%; charging;"), Some(42));
    }
}

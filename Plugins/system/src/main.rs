use std::time::Duration;

use flash_plugin::{run, sleep, spawn_background, CommandRequest, CommandResponse, Context};

const CGSESSION: &str =
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession";

const DARK_TOGGLE: &str =
    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode";

struct System;

flash_plugin::plugin!(System);

impl FlashPlugin for System {
    async fn on_start(&self, ctx: Context) {
        publish_battery_status(&ctx).await;
        let poll_ctx = ctx.clone();
        spawn_background(async move {
            loop {
                sleep(Duration::from_secs(30)).await;
                publish_battery_status(&poll_ctx).await;
            }
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
    let result = ctx.run_cli_quiet(&argv, Duration::from_secs(2)).await;
    let segment = if result.ok {
        battery_segment(&result.stdout)
    } else {
        missing_battery_segment()
    };
    ctx.emit_status_segments([("battery", segment)]);
}

fn battery_segment(pmset_output: &str) -> String {
    let Some(percent) = battery_percent(pmset_output) else {
        return missing_battery_segment();
    };
    let on_ac = pmset_output.contains("AC Power")
        || pmset_output.contains("; charging")
        || pmset_output.contains("; charged")
        || pmset_output.contains("; finishing charge");
    let color = if on_ac || percent > 25 {
        "colour178"
    } else {
        "red"
    };
    format!("#[range=user|bat-prefs fg={color}]{percent}%#[norange]")
}

fn battery_percent(pmset_output: &str) -> Option<u8> {
    pmset_output
        .split(|ch: char| !(ch.is_ascii_digit() || ch == '%'))
        .find_map(|token| token.strip_suffix('%')?.parse::<u8>().ok())
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
    fn formats_ac_or_healthy_battery_yellow() {
        assert_eq!(
            battery_segment(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 82%; charged;"
            ),
            "#[range=user|bat-prefs fg=colour178]82%#[norange]"
        );
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
}

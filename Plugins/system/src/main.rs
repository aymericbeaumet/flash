use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

const CGSESSION: &str =
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession";

const DARK_TOGGLE: &str =
    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode";

struct System;

flash_plugin::plugin!(System);

impl FlashPlugin for System {
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

async fn sh(ctx: &Context, argv: &[&str], timeout: u64) -> CommandResponse {
    let owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    ctx.run_cli(&owned, Duration::from_secs(timeout))
        .await
        .into_command()
}

fn main() {
    run(System);
}

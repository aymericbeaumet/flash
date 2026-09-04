use std::time::Duration;

use flash_plugin::{
    run, run_command, run_osascript, Candidate, CommandRequest, Context, PerformResponse,
};
use serde_json::Value;

const SOURCE_LABEL: &str = "system.actions";

const LOCK_KEY_CODE: i64 = 12; // kVK_ANSI_Q

const DARK_TOGGLE: &str =
    "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode";

#[derive(Clone, Copy, Debug)]
struct SystemAction {
    subcommand: &'static str,
    title: &'static str,
    subtitle: &'static str,
    aliases: &'static [&'static str],
}

const ACTIONS: &[SystemAction] = &[
    SystemAction {
        subcommand: "lock",
        title: "Lock screen",
        subtitle: "Require password and keep apps running",
        aliases: &["screen", "secure", "password"],
    },
    SystemAction {
        subcommand: "sleep",
        title: "Sleep Mac",
        subtitle: "Put the machine to sleep",
        aliases: &["suspend", "standby"],
    },
    SystemAction {
        subcommand: "displaysleep",
        title: "Turn display off",
        subtitle: "Sleep the display without sleeping the machine",
        aliases: &["display", "screen", "off"],
    },
    SystemAction {
        subcommand: "restart",
        title: "Restart Mac",
        subtitle: "Ask macOS to restart",
        aliases: &["reboot"],
    },
    SystemAction {
        subcommand: "shutdown",
        title: "Shut down Mac",
        subtitle: "Ask macOS to power off",
        aliases: &["power", "poweroff", "halt"],
    },
    SystemAction {
        subcommand: "logout",
        title: "Log out",
        subtitle: "End the current macOS login session",
        aliases: &["sign out", "signout"],
    },
    SystemAction {
        subcommand: "trash",
        title: "Empty Trash",
        subtitle: "Ask Finder to empty the Trash",
        aliases: &["bin", "garbage"],
    },
    SystemAction {
        subcommand: "dark",
        title: "Toggle dark mode",
        subtitle: "Switch between light and dark appearance",
        aliases: &["appearance", "light"],
    },
    SystemAction {
        subcommand: "screensaver",
        title: "Start screen saver",
        subtitle: "Launch ScreenSaverEngine",
        aliases: &["screen saver", "screensave"],
    },
];

struct System;

flash_plugin::plugin!(System);

impl FlashPlugin for System {
    async fn on_start(&self, ctx: Context) {
        publish_system_actions(&ctx);
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        if command.subcommand.is_empty() {
            return PerformResponse::ok().message(system_usage());
        }
        run_system_action(&ctx, command.subcommand.as_str()).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        let Some(subcommand) = row.payload_str() else {
            return PerformResponse::unhandled();
        };
        let response = run_system_action(&ctx, subcommand).await;
        if !response.is_ok() {
            ctx.log(
                "warn",
                &format!(
                    "[system] action {subcommand} failed: {}",
                    response.error_message().unwrap_or("unknown error")
                ),
            );
        }
        response
    }
}

fn publish_system_actions(ctx: &Context) {
    let candidates = ACTIONS.iter().map(system_action_candidate).collect();
    ctx.publish(candidates);
}

fn system_action_candidate(action: &SystemAction) -> Candidate {
    Candidate::new(SOURCE_LABEL, action.title)
        .kind("system_action")
        .subtitle(action.subtitle)
        .aliases(
            action
                .aliases
                .iter()
                .copied()
                .chain(std::iter::once(action.subcommand)),
        )
        .payload(action.subcommand)
        .finishes_command(true)
}

fn system_usage() -> String {
    let subcommands = ACTIONS
        .iter()
        .map(|action| action.subcommand)
        .collect::<Vec<_>>()
        .join(", ");
    format!(":system <{}> or :flashlight @system.actions", subcommands)
}

async fn run_system_action(ctx: &Context, subcommand: &str) -> PerformResponse {
    match subcommand {
        "lock" => lock_screen(ctx).await,
        "sleep" => sh(ctx, &["/usr/bin/pmset", "sleepnow"], 10).await,
        "displaysleep" => sh(ctx, &["/usr/bin/pmset", "displaysleepnow"], 10).await,
        "restart" => run_osascript(
            ctx,
            "tell application \"System Events\" to restart",
            Duration::from_secs(10),
        )
        .await
        .into_perform(),
        "shutdown" => run_osascript(
            ctx,
            "tell application \"System Events\" to shut down",
            Duration::from_secs(10),
        )
        .await
        .into_perform(),
        "logout" => run_osascript(
            ctx,
            "tell application \"System Events\" to log out",
            Duration::from_secs(10),
        )
        .await
        .into_perform(),
        "trash" => run_osascript(
            ctx,
            "tell application \"Finder\" to empty trash",
            Duration::from_secs(30),
        )
        .await
        .into_perform(),
        "dark" => run_osascript(ctx, DARK_TOGGLE, Duration::from_secs(10))
            .await
            .into_perform(),
        "screensaver" => {
            if ctx.open_app("com.apple.ScreenSaverEngine").await {
                PerformResponse::ok()
            } else {
                PerformResponse::fail("host.open ScreenSaverEngine failed")
            }
        }
        other => PerformResponse::fail(format!("unknown subcommand: {other}")),
    }
}

const LOCK_MODIFIERS: &[&str] = &["command", "control"];

async fn lock_screen(ctx: &Context) -> PerformResponse {
    let response = ctx.post_global_key(LOCK_KEY_CODE, LOCK_MODIFIERS).await;
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        PerformResponse::ok()
    } else {
        PerformResponse::fail(
            response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("host.post_global_key failed"),
        )
    }
}

async fn sh(ctx: &Context, argv: &[&str], timeout: u64) -> PerformResponse {
    let owned: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    run_command(ctx, &owned, Duration::from_secs(timeout))
        .await
        .into_perform()
}

fn main() {
    run(System);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_catalog_has_unique_subcommands() {
        let mut names = std::collections::HashSet::new();
        for action in ACTIONS {
            assert!(
                names.insert(action.subcommand),
                "duplicate {}",
                action.subcommand
            );
            assert!(!action.title.is_empty());
            assert!(!action.subtitle.is_empty());
        }
    }

    #[test]
    fn action_candidates_are_finishers_under_system_source() {
        let restart = ACTIONS
            .iter()
            .find(|action| action.subcommand == "restart")
            .unwrap();
        let candidate = system_action_candidate(restart);
        assert_eq!(candidate.title, "Restart Mac");
        assert_eq!(candidate.meta("kind"), Some("system_action"));
        assert_eq!(candidate.source, SOURCE_LABEL);
        assert_eq!(candidate.payload_str(), Some("restart"));
        assert_eq!(candidate.meta("finishes_command"), Some("1"));
        assert!(candidate.meta("aliases").unwrap_or("").contains("reboot"));
    }

    #[test]
    fn bare_system_usage_lists_picker_and_actions() {
        let usage = system_usage();
        assert!(usage.contains(":system <lock"));
        assert!(usage.contains("restart"));
        assert!(usage.contains("shutdown"));
        assert!(usage.contains(":flashlight @system.actions"));
    }

    #[test]
    fn lock_posts_the_global_control_command_q_chord() {
        assert_eq!(LOCK_KEY_CODE, 12);
        assert_eq!(LOCK_MODIFIERS, ["command", "control"]);
    }

    #[test]
    fn caffeinate_actions_live_only_in_the_dedicated_plugin() {
        assert!(!ACTIONS
            .iter()
            .any(|action| matches!(action.subcommand, "caffeinate" | "decaffeinate")));
    }
}

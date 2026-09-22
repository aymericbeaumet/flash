use std::time::Duration;

use flash_plugin::{
    run, run_command, shorten, CommandOutput, CommandRequest, Context, PerformResponse,
};

/// Apple's own capture tool writes straight to the clipboard, so no image
/// data ever passes through Flash. Using it instead of the system Screenshot
/// shortcuts means neither capture breaks when those shortcuts are remapped
/// or turned off, and the window capture needs no click.
const SCREENCAPTURE: &str = "/usr/sbin/screencapture";
/// `-x` no shutter sound, `-c` to the clipboard.
const BASE_ARGS: &[&str] = &["-x", "-c"];
/// `-o` omits the window's drop shadow, so the capture is the window itself.
const WINDOW_ARGS: &[&str] = &["-o"];
const TIMEOUT: Duration = Duration::from_secs(10);
/// What `screencapture` says when the grant is missing. macOS does not prompt
/// for a background app, so on its own the message leaves the user with
/// nothing to do about it.
const DENIED: &str = "could not create image";
const DENIED_HINT: &str =
    "grant Flash Screen Recording in System Settings > Privacy & Security, then try again";

struct Screenshot;

flash_plugin::plugin!(Screenshot);

impl FlashPlugin for Screenshot {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "screen" => finish(run_command(&ctx, &argv(None), TIMEOUT).await),
            "window" => {
                // Name the focused window to the capture tool rather than
                // making the user pick one. Its id is WindowServer metadata
                // the host already resolves for hints.
                let Some(window_id) = ctx.normal_mode_target().await.and_then(|t| t.window_id)
                else {
                    return PerformResponse::fail("no focused window to capture");
                };
                finish(run_command(&ctx, &argv(Some(window_id)), TIMEOUT).await)
            }
            other => PerformResponse::fail(format!(
                "unknown subcommand: {other} (expected `screen` or `window`)"
            )),
        }
    }
}

fn argv(window_id: Option<i64>) -> Vec<String> {
    let mut argv = vec![SCREENCAPTURE.to_string()];
    argv.extend(BASE_ARGS.iter().map(|arg| (*arg).to_string()));
    if let Some(window_id) = window_id {
        argv.extend(WINDOW_ARGS.iter().map(|arg| (*arg).to_string()));
        argv.push(format!("-l{window_id}"));
    }
    argv
}

/// `screencapture` reports a missing Screen Recording grant on stderr and a
/// nonzero status, so surface its own words rather than a generic failure.
fn finish(output: CommandOutput) -> PerformResponse {
    if output.ok {
        return PerformResponse::ok();
    }
    let combined = format!("{}{}", output.stdout, output.stderr);
    let message = combined.trim();
    if message.is_empty() {
        return PerformResponse::fail("screencapture failed");
    }
    if message.contains(DENIED) {
        return PerformResponse::fail(format!("{}: {DENIED_HINT}", shorten(message)));
    }
    PerformResponse::fail(shorten(message))
}

fn main() {
    run(Screenshot);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_capture_takes_the_whole_display_to_the_clipboard() {
        let argv = argv(None);
        assert_eq!(argv[0], SCREENCAPTURE);
        assert!(argv.contains(&"-c".to_string()), "must reach the clipboard");
        assert!(argv.contains(&"-x".to_string()), "must stay silent");
        // No window selector, so nothing is interactive.
        assert!(!argv.iter().any(|arg| arg.starts_with("-l")));
        assert!(!argv.contains(&"-w".to_string()));
        assert!(!argv.contains(&"-i".to_string()));
    }

    #[test]
    fn window_capture_names_its_window_instead_of_asking_for_a_click() {
        let argv = argv(Some(4321));
        assert!(argv.contains(&"-l4321".to_string()));
        assert!(argv.contains(&"-o".to_string()), "drop the window shadow");
        assert!(argv.contains(&"-c".to_string()));
        // `-w` and `-i` are the interactive pickers; naming the window is
        // what removes the click.
        assert!(!argv.contains(&"-w".to_string()));
        assert!(!argv.contains(&"-i".to_string()));
    }

    #[test]
    fn capture_failures_surface_the_tools_own_reason() {
        assert!(finish(CommandOutput {
            ok: true,
            ..CommandOutput::default()
        })
        .is_ok());

        // The grant is the only thing the user can act on, and macOS never
        // prompts for it here, so say so rather than repeating the tool.
        let denied = finish(CommandOutput {
            stderr: "could not create image from display\n".to_string(),
            status: 1,
            ..CommandOutput::default()
        });
        let denied = denied.error_message().unwrap_or_default().to_string();
        assert!(
            denied.starts_with("could not create image from display"),
            "{denied}"
        );
        assert!(denied.contains("Screen Recording"), "{denied}");

        // An unrelated failure is passed through untouched.
        let other = finish(CommandOutput {
            stderr: "invalid window id\n".to_string(),
            status: 1,
            ..CommandOutput::default()
        });
        assert_eq!(other.error_message(), Some("invalid window id"));

        let silent = finish(CommandOutput {
            status: 1,
            ..CommandOutput::default()
        });
        assert_eq!(silent.error_message(), Some("screencapture failed"));
    }
}

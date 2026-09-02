use std::time::Duration;

use flash_plugin::{
    run, run_osascript, shorten, CommandOutput, CommandRequest, Context, PerformResponse,
};

const SETTLE_DELAY_SECONDS: &str = "0.20";
const WINDOW_PICKER_DELAY_SECONDS: &str = "0.12";

struct Screenshot;

flash_plugin::plugin!(Screenshot);

impl FlashPlugin for Screenshot {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let Some(shortcut) = Shortcut::for_subcommand(&command.subcommand) else {
            return PerformResponse::fail(format!("unknown subcommand: {}", command.subcommand));
        };
        let output = run_osascript(&ctx, &shortcut.script(), Duration::from_secs(5)).await;
        response_for_output(output)
    }
}

fn response_for_output(output: CommandOutput) -> PerformResponse {
    if output.ok {
        return PerformResponse::ok();
    }
    let combined = format!("{}{}", output.stdout, output.stderr);
    let message = combined.trim();
    PerformResponse::fail(if message.is_empty() {
        "osascript failed".to_string()
    } else {
        shorten(message)
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Shortcut {
    key_code: u8,
    control: bool,
    then_space: bool,
}

impl Shortcut {
    fn for_subcommand(subcommand: &str) -> Option<Self> {
        match subcommand {
            "" | "options" => Some(Self::new(23, false, false)),
            "screen" => Some(Self::new(20, false, false)),
            "selection" => Some(Self::new(21, false, false)),
            "window" => Some(Self::new(21, false, true)),
            "screen_clipboard" => Some(Self::new(20, true, false)),
            "selection_clipboard" => Some(Self::new(21, true, false)),
            "window_clipboard" => Some(Self::new(21, true, true)),
            _ => None,
        }
    }

    const fn new(key_code: u8, control: bool, then_space: bool) -> Self {
        Self {
            key_code,
            control,
            then_space,
        }
    }

    fn script(self) -> String {
        let modifiers = if self.control {
            "command down, control down, shift down"
        } else {
            "command down, shift down"
        };
        let mut script = format!(
            "delay {SETTLE_DELAY_SECONDS}\n\
             tell application \"System Events\" to key code {} using {{{modifiers}}}",
            self.key_code
        );
        if self.then_space {
            script.push_str(&format!(
                "\ndelay {WINDOW_PICKER_DELAY_SECONDS}\n\
                 tell application \"System Events\" to key code 49"
            ));
        }
        script
    }
}

fn main() {
    run(Screenshot);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_registered_shortcut_has_the_expected_shape() {
        assert_eq!(
            Shortcut::for_subcommand(""),
            Some(Shortcut::new(23, false, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("options"),
            Some(Shortcut::new(23, false, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("screen"),
            Some(Shortcut::new(20, false, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("selection"),
            Some(Shortcut::new(21, false, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("window"),
            Some(Shortcut::new(21, false, true))
        );
        assert_eq!(
            Shortcut::for_subcommand("screen_clipboard"),
            Some(Shortcut::new(20, true, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("selection_clipboard"),
            Some(Shortcut::new(21, true, false))
        );
        assert_eq!(
            Shortcut::for_subcommand("window_clipboard"),
            Some(Shortcut::new(21, true, true))
        );
        assert_eq!(Shortcut::for_subcommand("unknown"), None);
    }

    #[test]
    fn scripts_preserve_modifier_and_window_picker_sequences() {
        assert_eq!(
            Shortcut::new(20, true, false).script(),
            "delay 0.20\ntell application \"System Events\" to key code 20 using {command down, control down, shift down}"
        );
        assert_eq!(
            Shortcut::new(21, false, true).script(),
            "delay 0.20\ntell application \"System Events\" to key code 21 using {command down, shift down}\ndelay 0.12\ntell application \"System Events\" to key code 49"
        );
    }

    #[test]
    fn osascript_result_preserves_empty_success_and_failure_text() {
        let success = response_for_output(CommandOutput {
            ok: true,
            stdout: "ignored output".to_string(),
            ..CommandOutput::default()
        });
        assert!(success.is_ok());

        let failure = response_for_output(CommandOutput {
            stderr: "permission denied\n".to_string(),
            status: 1,
            ..CommandOutput::default()
        });
        assert_eq!(failure.error_message(), Some("permission denied"));

        let empty = response_for_output(CommandOutput {
            status: 1,
            ..CommandOutput::default()
        });
        assert_eq!(empty.error_message(), Some("osascript failed"));
    }
}

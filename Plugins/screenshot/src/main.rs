use std::time::Duration;

use flash_plugin::{run, run_osascript, CommandRequest, CommandResponse, Context};

const SETTLE_DELAY_SECONDS: &str = "0.20";
const WINDOW_PICKER_DELAY_SECONDS: &str = "0.12";

struct Screenshot;

flash_plugin::plugin!(Screenshot);

impl FlashPlugin for Screenshot {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        let Some(shortcut) = Shortcut::for_subcommand(&command.subcommand) else {
            return CommandResponse::error(format!("unknown subcommand: {}", command.subcommand));
        };
        run_osascript(&ctx, &shortcut.script(), Duration::from_secs(5))
            .await
            .into_command()
    }
}

#[derive(Clone, Copy)]
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

    fn new(key_code: u8, control: bool, then_space: bool) -> Self {
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

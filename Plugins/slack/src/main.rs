use std::time::Duration;

use flash_plugin::{run, run_command, CommandRequest, CommandResponse, Context};

struct Slack;

flash_plugin::plugin!(Slack);

impl FlashPlugin for Slack {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        let configured = ctx.config_str("cli");
        let cli = if configured.is_empty() {
            "slack".to_string()
        } else {
            configured
        };
        let (argv, timeout): (Vec<String>, u64) = match command.subcommand.as_str() {
            "login" => (vec![cli, "login".into()], 300),
            "version" => (vec![cli, "version".into()], 120),
            "run" => (prepend(&cli, &command.args), 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}"));
            }
        };
        run_command(&ctx, &argv, Duration::from_secs(timeout))
            .await
            .into_command()
    }
}

fn prepend(program: &str, args: &[String]) -> Vec<String> {
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(program.to_string());
    argv.extend_from_slice(args);
    argv
}

fn main() {
    run(Slack);
}

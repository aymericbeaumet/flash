use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Slack;

impl Plugin for Slack {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let name = str_field(&params, "subcommand");
        let args = string_list(&params, "args");
        // `[plugin.slack] cli = "/path/to/slack"` overrides the executable;
        // defaults to `slack` on PATH.
        let cli = {
            let configured = ctx.config_str("cli");
            if configured.is_empty() {
                "slack".to_string()
            } else {
                configured
            }
        };
        let (argv, timeout): (Vec<String>, u64) = match name {
            "login" => (vec![cli, "login".into()], 300),
            "version" => (vec![cli, "version".into()], 120),
            "run" => (prepend(&cli, &args), 120),
            other => {
                return json!({ "ok": false, "error": format!("unknown subcommand: {other}") });
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .value()
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

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
        let (argv, timeout): (Vec<String>, u64) = match name {
            "login" => (vec!["slack".into(), "login".into()], 300),
            "version" => (vec!["slack".into(), "version".into()], 120),
            "run" => (prepend("slack", &args), 120),
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

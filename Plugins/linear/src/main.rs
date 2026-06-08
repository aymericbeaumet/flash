use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Linear;

impl Plugin for Linear {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let name = str_field(&params, "subcommand");
        let args = string_list(&params, "args");
        let (argv, timeout): (Vec<String>, u64) = match name {
            "login" => (linear(&["auth", "login"]), 300),
            "mine" => (linear_sub(&["issue", "mine"], &args), 120),
            "query" => (query(&args), 120),
            "start" => (linear_sub(&["issue", "start"], &args), 300),
            "view" => (linear_sub(&["issue", "view"], &args), 120),
            "pr" => (linear_sub(&["issue", "pr"], &args), 300),
            "create" => (linear_sub(&["issue", "create"], &args), 300),
            "run" => (linear_sub(&[], &args), 120),
            other => {
                return json!({ "ok": false, "error": format!("unknown subcommand: {other}") });
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .value()
    }
}

fn linear(args: &[&str]) -> Vec<String> {
    let mut argv = vec!["linear".to_string()];
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

fn linear_sub(prefix: &[&str], args: &[String]) -> Vec<String> {
    let mut argv = linear(prefix);
    argv.extend_from_slice(args);
    argv
}

fn query(args: &[String]) -> Vec<String> {
    if args.is_empty() {
        linear(&["issue", "query", "--all-teams", "--json", "--limit", "20"])
    } else {
        linear(&["issue", "query", "--search", &args.join(" "), "--json"])
    }
}

fn main() {
    run(Linear);
}

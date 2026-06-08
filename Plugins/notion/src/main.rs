use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Notion;

impl Plugin for Notion {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "action.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let name = str_field(&params, "name");
        let args = string_list(&params, "args");
        let (argv, timeout): (Vec<String>, u64) = match name {
            "login" => (ntn(&["login"]), 300),
            "version" => (ntn(&["--version"]), 120),
            "api" => (ntn_with("api", &args), 120),
            "workers" => (ntn_with("workers", &args), 120),
            "run" => (ntn_args(&args), 120),
            other => {
                return json!({ "ok": false, "error": format!("unknown action: {other}") });
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .value()
    }
}

fn ntn(args: &[&str]) -> Vec<String> {
    let mut argv = vec!["ntn".to_string()];
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

fn ntn_args(args: &[String]) -> Vec<String> {
    let mut argv = vec!["ntn".to_string()];
    argv.extend_from_slice(args);
    argv
}

fn ntn_with(sub: &str, args: &[String]) -> Vec<String> {
    let mut argv = vec!["ntn".to_string(), sub.to_string()];
    argv.extend_from_slice(args);
    argv
}

fn main() {
    run(Notion);
}

use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, Context, Plugin};

struct Github;

impl Plugin for Github {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let name = str_field(&params, "subcommand");
        let args = string_list(&params, "args");
        let (argv, timeout): (Vec<String>, u64) = match name {
            "login" => (gh(&["auth", "login", "--web"]), 300),
            "status" => (gh(&["auth", "status"]), 120),
            "issues" => (list("issue", &args), 120),
            "prs" => (list("pr", &args), 120),
            "run" => (gh_args(&args), 120),
            other => {
                return json!({ "ok": false, "error": format!("unknown subcommand: {other}") });
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .value()
    }
}

fn gh(args: &[&str]) -> Vec<String> {
    let mut argv = vec!["gh".to_string()];
    argv.extend(args.iter().map(|s| s.to_string()));
    argv
}

fn gh_args(args: &[String]) -> Vec<String> {
    let mut argv = vec!["gh".to_string()];
    argv.extend_from_slice(args);
    argv
}

fn list(kind: &str, args: &[String]) -> Vec<String> {
    if args.is_empty() {
        gh(&[
            kind,
            "list",
            "--json",
            "number,title,state,url",
            "--limit",
            "20",
        ])
    } else {
        let mut argv = gh(&[kind, "list"]);
        argv.extend_from_slice(args);
        argv
    }
}

fn main() {
    run(Github);
}

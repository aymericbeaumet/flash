use std::time::Duration;

use flash_plugin::{run, CommandResponse, Context, Plugin, Request, Response};

struct Notion;

impl Plugin for Notion {
    async fn handle(&self, ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        let args = &cmd.args;
        let (argv, timeout): (Vec<String>, u64) = match cmd.subcommand.as_str() {
            "login" => (ntn(&["login"]), 300),
            "version" => (ntn(&["--version"]), 120),
            "api" => (ntn_with("api", args), 120),
            "workers" => (ntn_with("workers", args), 120),
            "run" => (ntn_args(args), 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}")).into();
            }
        };
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .into()
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

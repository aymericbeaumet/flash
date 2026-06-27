use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

struct Calculator;

flash_plugin::plugin!(Calculator);

impl FlashPlugin for Calculator {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        // Registered as a wildcard command, so the whole remainder arrives as
        // args (`:calc 2 + 2` and `:calc 2+2` both work).
        let expr = command.query();
        if expr.is_empty() {
            return CommandResponse::error("empty expression");
        }
        let mut namespace = fasteval2::EmptyNamespace;
        let value = match fasteval2::ez_eval(&expr, &mut namespace) {
            Ok(v) => v,
            Err(err) => return CommandResponse::error(format!("cannot evaluate: {err}")),
        };
        let result = format_num(value);

        // Copy the result to the clipboard; surface "expr = result" as the
        // command stdout so the host can show it in a toast.
        let script = format!("set the clipboard to {}", applescript_quote(&result));
        run_osascript(&ctx, &script, Duration::from_secs(10)).await;

        CommandResponse::toast(format!("{expr} = {result}"))
    }
}

async fn run_osascript(ctx: &Context, script: &str, timeout: Duration) {
    let argv = [
        "/usr/bin/osascript".to_string(),
        "-e".to_string(),
        script.to_string(),
    ];
    let _ = run_command(ctx, &argv, timeout).await;
}

async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> bool {
    let Some((program, args)) = argv.split_first() else {
        return false;
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .current_dir(&ctx.data_dir)
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .env(
            "PATH",
            format!(
                "{}:{}",
                ctx.bin_dir().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => output.status.success(),
        _ => false,
    }
}

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn format_num(value: f64) -> String {
    if !value.is_finite() {
        return value.to_string();
    }
    if value.fract() == 0.0 && value.abs() < 1e15 {
        return format!("{}", value as i64);
    }
    let formatted = format!("{value:.10}");
    formatted
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
}

fn main() {
    run(Calculator);
}

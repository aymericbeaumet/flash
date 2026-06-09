use std::time::Duration;

use flash_plugin::{applescript_quote, run, CommandResponse, Context, Plugin, Request, Response};

struct Calculator;

impl Plugin for Calculator {
    async fn handle(&self, ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        // Registered as a wildcard command, so the whole remainder arrives as
        // args (`:calc 2 + 2` and `:calc 2+2` both work).
        let expr = cmd.query();
        if expr.is_empty() {
            return CommandResponse::error("empty expression").into();
        }
        let value = match meval::eval_str(&expr) {
            Ok(v) => v,
            Err(err) => return CommandResponse::error(format!("cannot evaluate: {err}")).into(),
        };
        let result = format_num(value);

        // Copy the result to the clipboard; surface "expr = result" as the
        // command stdout so the host can show it in a toast.
        let script = format!("set the clipboard to {}", applescript_quote(&result));
        ctx.run_osascript(&script, Duration::from_secs(10)).await;

        CommandResponse::toast(format!("{expr} = {result}")).into()
    }
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
